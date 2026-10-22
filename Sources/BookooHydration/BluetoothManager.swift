import Combine
import CoreBluetooth
import Foundation
import BookooHydrationCore

private enum BluetoothCommandError: LocalizedError {
    case commandCharacteristicUnavailable
    case disconnected

    var errorDescription: String? {
        switch self {
        case .commandCharacteristicUnavailable: "秤不支持或尚未发现 FF12 命令特征"
        case .disconnected: "发送命令前蓝牙已断开"
        }
    }
}

enum BluetoothConnectionState: Equatable {
    case unavailable(String)
    case idle
    case scanning
    case connecting(String)
    case connected(String)

    var chineseText: String {
        switch self {
        case .unavailable(let reason): "不可用：\(reason)"
        case .idle: "未连接"
        case .scanning: "正在扫描 BOOKOO"
        case .connecting(let name): "正在连接 \(name)"
        case .connected(let name): "已连接 \(name)"
        }
    }

    var deviceName: String? {
        switch self {
        case .connecting(let name), .connected(let name): name
        default: nil
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

@MainActor
final class BluetoothManager: NSObject, ObservableObject {
    @Published private(set) var state: BluetoothConnectionState = .idle { didSet { writeDiagnostic() } }

    var onFrame: ((BookooWeightFrame) -> Void)?
    var onFreshSession: (() -> Void)?
    var onSessionEnded: (() -> Void)?
    var onMessage: ((String) -> Void)?

    private lazy var central = CBCentralManager(delegate: self, queue: nil)
    private var peripheral: CBPeripheral?
    private var desiredActive = false
    private var sessionFence = ScaleSessionFence()

    private func accepts(_ device: CBPeripheral) -> Bool {
        sessionFence.accepts(sessionFence.generation) && desiredActive && !manuallyDisconnected
            && peripheral === device
    }
    private var manuallyDisconnected = false
    private var connectionTimeout: DispatchWorkItem?
    private let notifyUUID = CBUUID(string: BookooFrameDecoder.notifyCharacteristicUUID)
    private let commandUUID = CBUUID(string: BookooFrameDecoder.commandCharacteristicUUID)
    private var commandCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var validatedService: CBService?
    private var commandQueue: [(Data, (Result<Void, Error>) -> Void)] = []
    private var commandWriteInProgress = false
    private let scaleServiceUUID = CBUUID(string: BookooScaleIdentity.serviceUUID)
    private var rejectedDevices = Set<UUID>()
    private var lastRejectedDevice: String?
    private var lastSampleAt: Date?
    private var lastDiagnosticAt = Date.distantPast

    private func writeDiagnostic() {
        let directory = BookooPaths.dataDirectory()
        var value: [String: Any] = ["schemaVersion": 1, "observedAtMs": Int64(Date().timeIntervalSince1970 * 1000), "state": state.chineseText, "isConnected": state.isConnected, "desiredActive": desiredActive, "bluetoothAuthorization": CBManager.authorization.rawValue, "serviceValidated": commandCharacteristic != nil, "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"]
        if let peripheral { value["deviceName"] = peripheral.name; value["deviceIdentifier"] = peripheral.identifier.uuidString }
        if let lastRejectedDevice { value["lastRejectedDevice"] = lastRejectedDevice }
        if let lastSampleAt { value["lastSampleAtMs"] = Int64(lastSampleAt.timeIntervalSince1970 * 1000) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("bluetooth-status.json")
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            lastDiagnosticAt = Date()
        } catch { /* Diagnostics must never disrupt weighing or persistence. */ }
    }

    private func reject(_ device: CBPeripheral, reason: String) {
        rejectedDevices.insert(device.identifier)
        lastRejectedDevice = device.name ?? device.identifier.uuidString
        onMessage?(reason)
        writeDiagnostic()
        central.cancelPeripheralConnection(device)
    }

    func prepare() {
        _ = central
    }

    func activate(clearManualDisconnect: Bool) {
        desiredActive = true
        if clearManualDisconnect { manuallyDisconnected = false }
        guard !manuallyDisconnected else { return }
        startScanIfPossible()
    }

    func deactivateForSchedule() {
        desiredActive = false
        manuallyDisconnected = false
        stopAndDisconnect()
    }

    func pause() {
        desiredActive = false
        stopAndDisconnect()
    }

    func manualScan() {
        desiredActive = true
        manuallyDisconnected = false
        stopAndDisconnect(restart: true)
    }

    func manualDisconnect() {
        manuallyDisconnected = true
        stopAndDisconnect()
    }

    func tare(completion: @escaping (Result<Void, Error>) -> Void) {
        enqueueCommand(BookooCommandEncoder.tare(), completion: completion)
    }

    func configureAutoOff(minutes: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let data = BookooCommandEncoder.autoOff(minutes: minutes) else {
            completion(.failure(BluetoothCommandError.commandCharacteristicUnavailable))
            return
        }
        enqueueCommand(data, completion: completion)
    }

    private func enqueueCommand(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !sessionFence.isInvalidated, commandCharacteristic != nil, peripheral != nil else {
            completion(.failure(BluetoothCommandError.commandCharacteristicUnavailable))
            return
        }
        commandQueue.append((data, completion))
        flushCommandQueue()
    }

    private func flushCommandQueue() {
        guard !sessionFence.isInvalidated, !commandWriteInProgress,
              let peripheral,
              let commandCharacteristic,
              let next = commandQueue.first else { return }
        commandWriteInProgress = true
        peripheral.writeValue(next.0, for: commandCharacteristic, type: .withResponse)
    }

    private func failPendingCommands(_ error: Error = BluetoothCommandError.disconnected) {
        let pending = commandQueue
        commandQueue.removeAll()
        commandWriteInProgress = false
        pending.forEach { $0.1(.failure(error)) }
    }

    private func startScanIfPossible() {
        guard desiredActive, !manuallyDisconnected else { return }
        guard central.state == .poweredOn else {
            updateStateForCentral()
            return
        }
        guard peripheral == nil else { return }
        central.stopScan()
        state = .scanning
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func stopAndDisconnect(restart: Bool = false) {
        sessionFence.invalidate()
        connectionTimeout?.cancel()
        connectionTimeout = nil
        failPendingCommands()
        commandCharacteristic = nil
        notifyCharacteristic = nil
        validatedService = nil
        central.stopScan()
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        } else {
            state = .idle
            if restart { startScanIfPossible() }
        }
    }

    private func armConnectionTimeout(for peripheral: CBPeripheral) {
        connectionTimeout?.cancel()
        let identifier = peripheral.identifier
        let generation = sessionFence.generation
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.desiredActive,
                  self.sessionFence.accepts(generation),
                  !self.manuallyDisconnected,
                  self.peripheral?.identifier == identifier,
                  !self.state.isConnected else { return }
            self.onMessage?("连接或订阅超时，准备重试")
            self.central.cancelPeripheralConnection(peripheral)
        }
        connectionTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: item)
    }

    private func scheduleReconnect() {
        guard desiredActive, !manuallyDisconnected else { return }
        let generation = sessionFence.generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, self.sessionFence.generation == generation else { return }
            self.startScanIfPossible()
        }
    }

    private func updateStateForCentral() {
        switch central.state {
        case .poweredOn:
            state = .idle
        case .poweredOff:
            state = .unavailable("蓝牙已关闭")
        case .unauthorized:
            state = .unavailable("没有蓝牙权限")
        case .unsupported:
            state = .unavailable("此 Mac 不支持蓝牙")
        case .resetting:
            state = .unavailable("蓝牙正在重置")
        case .unknown:
            state = .unavailable("蓝牙状态未知")
        @unknown default:
            state = .unavailable("未知蓝牙状态")
        }
    }
}

extension BluetoothManager: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        updateStateForCentral()
        if central.state == .poweredOn { startScanIfPossible() }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard central.isScanning, desiredActive, !manuallyDisconnected, self.peripheral == nil else { return }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard !rejectedDevices.contains(peripheral.identifier) else { return }
        let services = ((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? [])
            + ((advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? [])
        guard BookooScaleIdentity.isCandidate(advertisedName: advertisedName, cachedName: peripheral.name, serviceUUIDs: services.map(\.uuidString)) else {
            if [advertisedName, peripheral.name].compactMap({ $0 }).contains(where: { $0.uppercased().hasPrefix("BOOKOO") }) {
                rejectedDevices.insert(peripheral.identifier)
                lastRejectedDevice = advertisedName ?? peripheral.name
                writeDiagnostic()
            }
            return
        }
        let name = advertisedName ?? peripheral.name ?? "BOOKOO 秤"

        central.stopScan()
        sessionFence.begin()
        self.peripheral = peripheral
        peripheral.delegate = self
        state = .connecting(name)
        armConnectionTimeout(for: peripheral)
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard accepts(peripheral) else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        peripheral.discoverServices([scaleServiceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        connectionTimeout?.cancel()
        connectionTimeout = nil
        failPendingCommands()
        commandCharacteristic = nil
        notifyCharacteristic = nil
        validatedService = nil
        lastSampleAt = nil
        self.peripheral = nil
        sessionFence.invalidate()
        state = .idle
        onSessionEnded?()
        onMessage?("连接失败：\(error?.localizedDescription ?? "未知错误")")
        scheduleReconnect()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        connectionTimeout?.cancel()
        connectionTimeout = nil
        failPendingCommands()
        commandCharacteristic = nil
        notifyCharacteristic = nil
        validatedService = nil
        lastSampleAt = nil
        self.peripheral = nil
        sessionFence.invalidate()
        state = .idle
        onSessionEnded?()
        if let error, desiredActive, !manuallyDisconnected {
            onMessage?("连接中断，准备重连：\(error.localizedDescription)")
        }
        scheduleReconnect()
    }
}

extension BluetoothManager: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard accepts(peripheral) else { return }
        if let error {
            onMessage?("发现服务失败：\(error.localizedDescription)")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        guard accepts(peripheral) else { return }
        guard let service = peripheral.services?.first(where: { BookooScaleIdentity.isScaleService($0.uuid.uuidString) }) else {
            reject(peripheral, reason: "设备不是兼容的 BOOKOO 咖啡秤，已跳过")
            return
        }
        validatedService = service
        peripheral.discoverCharacteristics([notifyUUID, commandUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard accepts(peripheral) else { return }
        if let error {
            onMessage?("发现特征失败：\(error.localizedDescription)")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        guard accepts(peripheral) else { return }
        guard service === validatedService else { return }
        let notify = service.characteristics?.first(where: { $0.uuid == notifyUUID })
        let command = service.characteristics?.first(where: { $0.uuid == commandUUID })
        guard BookooScaleIdentity.hasScaleCharacteristics(serviceUUID: service.uuid.uuidString,
                notifyUUID: notify?.uuid.uuidString, commandUUID: command?.uuid.uuidString,
                canNotify: notify?.properties.contains(.notify) == true, canWrite: command?.properties.contains(.write) == true),
              let notify, let command else {
            reject(peripheral, reason: "设备缺少秤的称重/命令特征，已跳过")
            return
        }
        commandCharacteristic = command
        notifyCharacteristic = notify
        peripheral.setNotifyValue(true, for: notify)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard accepts(peripheral),
              commandCharacteristic != nil, characteristic === notifyCharacteristic, characteristic.uuid == notifyUUID,
              characteristic.service?.uuid == scaleServiceUUID else { return }
        if let error {
            onMessage?("订阅称重数据失败：\(error.localizedDescription)")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        if characteristic.isNotifying {
            connectionTimeout?.cancel()
            connectionTimeout = nil
            if !state.isConnected { onFreshSession?() }
            state = .connected(peripheral.name ?? "BOOKOO")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard self.peripheral === peripheral, characteristic.uuid == commandUUID else { return }
        guard accepts(peripheral), characteristic === commandCharacteristic,
              commandWriteInProgress, !commandQueue.isEmpty else { return }
        let completed = commandQueue.removeFirst()
        commandWriteInProgress = false
        if let error {
            completed.1(.failure(error))
        } else {
            completed.1(.success(()))
        }
        flushCommandQueue()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard accepts(peripheral),
              state.isConnected, commandCharacteristic != nil, characteristic === notifyCharacteristic,
              characteristic.service?.uuid == scaleServiceUUID, characteristic.uuid == notifyUUID,
              error == nil,
              let data = characteristic.value,
              let frame = BookooFrameDecoder.decode(data) else { return }
        lastSampleAt = Date()
        if Date().timeIntervalSince(lastDiagnosticAt) >= 2 { writeDiagnostic() }
        onFrame?(frame)
    }
}
