import AppKit
import BookooHydrationCore
import Combine
import Foundation
import ServiceManagement
import SwiftUI
import UserNotifications

private final class BlockTarget: NSObject {
    private let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func fire() { block() }
}

@MainActor
private final class MainWindowSizeDelegate: NSObject, NSWindowDelegate {
    static let minimumFrameSize = NSSize(width: 860, height: 650)

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(
            width: max(frameSize.width, Self.minimumFrameSize.width),
            height: max(frameSize.height, Self.minimumFrameSize.height)
        )
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings
    @Published private(set) var hydration: HydrationData
    @Published private(set) var scheduleEvaluation: ScheduleEvaluation
    @Published private(set) var isPaused = false
    @Published private(set) var currentWeight: Double?
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var detectorState: DrinkDetectorState = .awaitingMeasurement
    @Published private(set) var isCalibratingCup = false
    @Published private(set) var baselineWeight: Double?
    @Published private(set) var activityMessage = "等待监测时段"
    @Published var errorMessage: String?
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginStatusText = "正在检查"

    @Published private(set) var notificationStatusText = "尚未开启"
    @Published private(set) var notificationBusy = false
    private var reminderState = ReminderState()
    private var reminderStateBlocked = false
    private var lastReminderAttempt = Date.distantPast
    private let previewMode = ProcessInfo.processInfo.environment["BOOKOO_PREVIEW"] == "1"
    private var reminderStateURL: URL { settingsPersistence.url.deletingLastPathComponent().appendingPathComponent("reminder-state.json") }

    let bluetooth = BluetoothManager()

    private let hydrationPersistence: HydrationPersistence
    private let settingsPersistence: SettingsPersistence
    private let detector: DrinkDetector
    private var timer: Timer?
    private var previousInWindow: Bool?
    private var hydrationWritesBlocked = false
    private var awaitingTareConfirmation = false
    private var pendingAcknowledgement: String?
    private var acknowledgementGeneration = 0
    private var mainWindow: NSWindow?
    private let mainWindowSizeDelegate = MainWindowSizeDelegate()
    private var cancellables = Set<AnyCancellable>()
    private static let loginAgentPlistName = "io.github.iamzzz774.BookooHydration.Standalone.login.plist"
    private static let loginConfiguredKey = "BookooHydrationLoginStartupConfigured"

    init(
        hydrationPersistence: HydrationPersistence = HydrationPersistence(),
        settingsPersistence: SettingsPersistence = SettingsPersistence()
    ) {
        self.hydrationPersistence = hydrationPersistence
        self.settingsPersistence = settingsPersistence

        let settingsFileExists = !previewMode && FileManager.default.fileExists(atPath: settingsPersistence.url.path)
        var loadedSettings = previewMode ? .defaults : ((try? settingsPersistence.load()) ?? .defaults)
        let hydrationLoadResult: (data: HydrationData, backupURL: URL?)
        var hydrationLoadFailure: Error?
        do {
            hydrationLoadResult = previewMode ? (HydrationData(dailyTargetML: loadedSettings.dailyGoalML), nil) : try hydrationPersistence.loadRecoveringCorruptFile(
                defaultTargetML: loadedSettings.dailyGoalML
            )
        } catch {
            hydrationLoadFailure = error
            hydrationLoadResult = (HydrationData(dailyTargetML: loadedSettings.dailyGoalML), nil)
        }
        let loadedHydration = hydrationLoadResult.data
        if !settingsFileExists {
            loadedSettings.dailyGoalML = loadedHydration.dailyTargetML
        }

        settings = loadedSettings
        hydration = loadedHydration
        detector = DrinkDetector(configuration: loadedSettings.detector)
        scheduleEvaluation = ScheduleEvaluator.evaluate(
            date: Date(),
            enabledWeekdays: loadedSettings.enabledWeekdays,
            windows: loadedSettings.windows
        )

        bluetooth.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        bluetooth.onFreshSession = { [weak self] in self?.freshBluetoothSession() }
        bluetooth.onSessionEnded = { [weak self] in self?.endBluetoothSession() }
        bluetooth.onFrame = { [weak self] frame in self?.receive(frame: frame) }
        bluetooth.onMessage = { [weak self] message in
            guard let self else { return }
            self.activityMessage = message
        }
        if !previewMode, FileManager.default.fileExists(atPath: reminderStateURL.path) {
            do { reminderState = try JSONDecoder().decode(ReminderState.self, from: Data(contentsOf: reminderStateURL)) }
            catch { reminderStateBlocked = true; notificationStatusText = "提醒状态文件损坏，已停止提醒；请保留原文件" }
        }
        if !previewMode {
            bluetooth.prepare()
            refreshSchedule()
            refreshLaunchAtLoginStatus()
        }
        if previewMode, ProcessInfo.processInfo.environment["BOOKOO_PREVIEW_ACTION_TEST"] == "1" {
            togglePause(); manualScan(); manualDisconnect(); toggleCupCalibration()
            undoLatestEntry(); settingsDidChange(); setLaunchAtLogin(true)
            openLoginItemsSettings(); sendTestNotification(); setRemindersEnabled(true)
            assert(!canOperateBluetooth && !isPaused && !isCalibratingCup)
        }
        if previewMode, ProcessInfo.processInfo.environment["BOOKOO_UI_TEST_SHOW_WINDOW"] == "1" {
            let snapshotPath = ProcessInfo.processInfo.environment["BOOKOO_UI_TEST_SNAPSHOT_PATH"]
            DispatchQueue.main.async { [weak self] in
                self?.showMainWindow(activate: false)
                if let snapshotPath {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        self?.writeMainWindowSnapshot(to: snapshotPath)
                    }
                }
            }
        }
        if let backupURL = hydrationLoadResult.backupURL {
            errorMessage = "原喝水文件无法读取，已完整备份到：\(backupURL.path)。应用已使用新的空记录文件。"
        } else if let hydrationLoadFailure {
            hydrationWritesBlocked = true
            errorMessage = "喝水文件无法读取且无法建立安全备份，已禁止写入以保护原文件：\(hydrationLoadFailure.localizedDescription)"
        }

    }

    deinit {
        MainActor.assumeIsolated {
            timer?.invalidate()
        }
    }

    var todayTotalML: Double {
        hydration.entries
            .filter { Calendar.current.isDateInToday($0.timestamp) }
            .reduce(0) { $0 + $1.amountML }
    }

    var latestEntry: HydrationEntry? {
        hydration.entries.max { $0.timestamp < $1.timestamp }
    }

    var sortedEntries: [HydrationEntry] {
        hydration.entries.sorted { $0.timestamp > $1.timestamp }
    }

    var canOperateBluetooth: Bool {
        !previewMode && scheduleEvaluation.isWithinWindow && !isPaused
    }


    func setLaunchAtLogin(_ enabled: Bool) {
        guard !previewMode else { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            launchAtLoginEnabled = false
            launchAtLoginStatusText = "请安装应用后再设置"
            return
        }
        UserDefaults.standard.set(true, forKey: Self.loginConfiguredKey)
        let service = SMAppService.agent(plistName: Self.loginAgentPlistName)
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else if service.status != .notRegistered && service.status != .notFound {
                try service.unregister()
            }
            refreshLaunchAtLoginStatus()
        } catch {
            refreshLaunchAtLoginStatus()
            errorMessage = "修改登录启动失败：\(error.localizedDescription)"
        }
    }

    func openLoginItemsSettings() {
        guard !previewMode else { return }
        SMAppService.openSystemSettingsLoginItems()
    }

    func refreshLaunchAtLoginStatus() {
        guard !previewMode else { launchAtLoginStatusText = "预览模式：不注册登录项"; return }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            launchAtLoginEnabled = false
            launchAtLoginStatusText = "请安装应用后再设置"
            return
        }
        switch SMAppService.agent(plistName: Self.loginAgentPlistName).status {
        case .enabled:
            launchAtLoginEnabled = true
            launchAtLoginStatusText = "已启用"
        case .requiresApproval:
            launchAtLoginEnabled = false
            launchAtLoginStatusText = "等待在系统设置中允许"
        case .notRegistered:
            launchAtLoginEnabled = false
            launchAtLoginStatusText = "未启用"
        case .notFound:
            launchAtLoginEnabled = false
            launchAtLoginStatusText = "登录启动组件未安装"
        @unknown default:
            launchAtLoginEnabled = false
            launchAtLoginStatusText = "状态未知"
        }
    }

    func showMainWindow(activate: Bool = true) {
        if mainWindow == nil {
            let controller = NSHostingController(rootView: ContentView(model: self))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "BookooHydration"
            window.contentViewController = controller
            window.contentMinSize = NSSize(width: 840, height: 620)
            window.minSize = MainWindowSizeDelegate.minimumFrameSize
            window.delegate = mainWindowSizeDelegate
            window.isReleasedWhenClosed = false
            let frameName = "BookooHydrationMainWindow"
            let restored = window.setFrameUsingName(frameName)
            window.setFrameAutosaveName(frameName)
            if !restored {
                window.center()
            } else {
                enforceMinimumMainWindowSize(window)
            }
            if previewMode, let text = ProcessInfo.processInfo.environment["BOOKOO_UI_TEST_HEIGHT"], let height = Double(text), height >= 650, height <= 2400 {
                window.setContentSize(NSSize(width: 980, height: height))
            }
            mainWindow = window
        }
        if let mainWindow { enforceMinimumMainWindowSize(mainWindow) }
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private func enforceMinimumMainWindowSize(_ window: NSWindow) {
        var frame = window.frame
        let minimum = MainWindowSizeDelegate.minimumFrameSize
        guard frame.width < minimum.width || frame.height < minimum.height else { return }
        frame.size.width = max(frame.width, minimum.width)
        frame.size.height = max(frame.height, minimum.height)
        window.setFrame(frame, display: true, animate: false)
    }

    private func writeMainWindowSnapshot(to path: String) {
        mainWindow?.contentView?.layoutSubtreeIfNeeded()
        guard let view = mainWindow?.contentView,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            if previewMode {
                print("PREVIEW: snapshot=\(path) size=\(Int(view.bounds.width))x\(Int(view.bounds.height)) bluetooth=disabled loginRegistration=disabled notifications=disabled")
                fflush(stdout)
                NSApp.terminate(nil)
            }
        } catch { fputs("Snapshot failed: \(error)\n", stderr) }
    }

    func refreshSchedule(now: Date = Date()) {
        let evaluation = ScheduleEvaluator.evaluate(
            date: now,
            enabledWeekdays: settings.enabledWeekdays,
            windows: settings.windows
        )
        scheduleEvaluation = evaluation

        guard !previewMode else { return }
        armScheduleTimer(now: now)
        checkReminder(now: now)

        if previousInWindow != evaluation.isWithinWindow {
            previousInWindow = evaluation.isWithinWindow
            if evaluation.isWithinWindow, !isPaused {
                activityMessage = "监测时段已开始，正在寻找咖啡秤"
                bluetooth.activate(clearManualDisconnect: true)
            } else {
                activityMessage = evaluation.isWithinWindow ? "监测已暂停" : "当前不在监测时段"
                bluetooth.deactivateForSchedule()
            }
        }
    }

    private func armScheduleTimer(now: Date) {
        timer?.invalidate()
        let fallback = now.addingTimeInterval(30)
        let fireDate = scheduleEvaluation.nextTransition.map { min($0.addingTimeInterval(0.05), fallback) } ?? fallback
        timer = Timer(fireAt: fireDate, interval: 0, target: BlockTarget { [weak self] in
            Task { @MainActor in self?.refreshSchedule() }
        }, selector: #selector(BlockTarget.fire), userInfo: nil, repeats: false)
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func togglePause() {
        guard !previewMode else { return }
        isPaused.toggle()
        if isPaused {
            activityMessage = "已临时暂停"
            bluetooth.pause()
        } else if scheduleEvaluation.isWithinWindow {
            activityMessage = "已恢复，正在寻找咖啡秤"
            bluetooth.activate(clearManualDisconnect: true)
        } else {
            activityMessage = "已恢复；下个监测时段将自动连接"
        }
    }

    func manualScan() {
        guard canOperateBluetooth else { return }
        activityMessage = "正在手动扫描 BOOKOO"
        bluetooth.manualScan()
    }

    func manualDisconnect() {
        guard !previewMode else { return }
        activityMessage = "已手动断开；可点“扫描”重新连接"
        bluetooth.manualDisconnect()
    }

    func toggleCupCalibration() {
        guard !previewMode else { return }
        if isCalibratingCup {
            isCalibratingCup = false
            detector.beginFreshSession(
                previousWeight: hydration.lastCupWeightG,
                emptyCupWeight: settings.emptyCupWeightG
            )
            detectorState = detector.state
            baselineWeight = detector.baselineWeight
            activityMessage = "已取消空杯校准"
            return
        }
        isCalibratingCup = true
        awaitingTareConfirmation = false
        pendingAcknowledgement = nil
        detector.beginFreshSession(previousWeight: nil, emptyCupWeight: nil)
        detectorState = detector.state
        baselineWeight = hydration.lastCupWeightG
        activityMessage = "空杯校准模式：空秤开机归零后，只放空杯并等待稳定"
    }

    func undoLatestEntry() {
        guard !previewMode else { return }
        guard let latest = latestEntry,
              let index = hydration.entries.firstIndex(of: latest) else { return }
        hydration.entries.remove(at: index)
        hydration.lastCupWeightG = latest.before
        detector.beginFreshSession(previousWeight: latest.before, emptyCupWeight: settings.emptyCupWeightG)
        detectorState = detector.state
        baselineWeight = latest.before
        activityMessage = String(format: "已撤销 %.0f mL 记录，并恢复此前杯重 %.1f g", latest.amountML, latest.before)
        saveHydration()
    }

    func settingsDidChange() {
        guard !previewMode else { return }
        var normalized = settings
        normalized.normalize()
        settings = normalized
        detector.updateConfiguration(normalized.detector)
        hydration.dailyTargetML = normalized.dailyGoalML
        do {
            try settingsPersistence.save(normalized)
            if !hydrationWritesBlocked {
                try hydrationPersistence.save(hydration)
            }
        } catch {
            errorMessage = "保存设置失败：\(error.localizedDescription)"
        }
        previousInWindow = nil
        refreshSchedule()
    }

    private func endBluetoothSession() {
        acknowledgementGeneration += 1
        currentWeight = nil
        batteryPercent = nil
        detector.beginFreshSession(previousWeight: hydration.lastCupWeightG, emptyCupWeight: settings.emptyCupWeightG)
        detectorState = detector.state
        baselineWeight = hydration.lastCupWeightG
        awaitingTareConfirmation = false
        pendingAcknowledgement = nil
    }

    private func freshBluetoothSession() {
        detector.beginFreshSession(
            previousWeight: isCalibratingCup ? nil : hydration.lastCupWeightG,
            emptyCupWeight: isCalibratingCup ? nil : settings.emptyCupWeightG
        )
        currentWeight = nil
        baselineWeight = hydration.lastCupWeightG
        detectorState = detector.state
        activityMessage = isCalibratingCup
            ? "已连接：只放空杯，等待稳定以完成换杯校准"
            : "已连接：空秤归零后放上水杯，等待本次称重"
        let generation = acknowledgementGeneration
        bluetooth.configureAutoOff(minutes: settings.autoOffMinutes) { [weak self] result in
            guard let self, self.acknowledgementGeneration == generation,
                  self.canOperateBluetooth else { return }
            if case .failure(let error) = result {
                self.errorMessage = "无法设置秤自动关机：\(error.localizedDescription)"
            }
        }
    }

    private func receive(frame: BookooWeightFrame, now: Date = Date()) {
        guard canOperateBluetooth else { return }
        currentWeight = frame.weightGrams
        batteryPercent = frame.batteryPercent <= 100 ? Int(frame.batteryPercent) : nil

        if settings.emptyCupWeightG == nil, !isCalibratingCup {
            activityMessage = "首次使用请先到“设置”开始空杯校准"
            return
        }

        if awaitingTareConfirmation, abs(frame.weightGrams) <= 1 {
            awaitingTareConfirmation = false
            let message = pendingAcknowledgement ?? "称重已处理"
            pendingAcknowledgement = nil
            if let savedTotal = hydration.lastCupWeightG {
                detector.beginTareRelativeSession(
                    baselineWeight: savedTotal,
                    emptyCupWeight: settings.emptyCupWeightG
                )
                detectorState = detector.state
                baselineWeight = savedTotal
                activityMessage = "\(message)；秤已归零。可直接拿杯喝水后放回，或现在关机"
            } else {
                activityMessage = "\(message)；秤已归零，可关机；下次装水称量会建立起始总重"
            }
            return
        }

        guard let event = detector.ingest(weight: frame.weightGrams, at: now) else {
            detectorState = detector.state
            return
        }
        detectorState = detector.state

        if isCalibratingCup {
            completeCupCalibration(with: detector.currentStableWeight ?? frame.weightGrams)
            return
        }

        switch event {
        case .cupRemoved:
            activityMessage = "检测到杯子已拿起；喝水后放回并等待稳定"
        case .initialMeasurement(let weight):
            hydration.lastCupWeightG = weight
            baselineWeight = weight
            if saveHydration() {
                acknowledgeMeasurement(String(format: "已保存首次总重 %.1f g（未记录喝水）", weight))
            }
        case .drink(let entry):
            hydration.entries.append(entry)
            hydration.lastCupWeightG = entry.after
            baselineWeight = entry.after
            if saveHydration() {
                acknowledgeMeasurement(String(format: "已记录喝水 %.0f mL，当前总重 %.1f g", entry.amountML, entry.after))
            }
        case .refill(_, let current):
            hydration.lastCupWeightG = current
            baselineWeight = current
            if saveHydration() {
                acknowledgeMeasurement(String(format: "已记录加水后的总重 %.1f g", current))
            }
        case .noiseIgnored:
            acknowledgeMeasurement("重量变化小于最小喝水量，本次不记录")
        case .decreaseRejected:
            activityMessage = "重量下降超过上限，本次未记录也未归零；请检查称重"
        case .belowEmptyCupRejected(let measured, let emptyCup):
            activityMessage = String(format: "总重 %.1f g 小于已校准空杯 %.1f g，本次已拒绝", measured, emptyCup)
        }
    }

    private func completeCupCalibration(with weight: Double) {
        guard weight >= 20 else {
            errorMessage = "空杯读数过低，请确认只放了空杯且重量稳定。"
            return
        }
        settings.emptyCupWeightG = weight
        hydration.lastCupWeightG = nil
        baselineWeight = nil
        isCalibratingCup = false
        do {
            try settingsPersistence.save(settings)
            guard saveHydration() else { return }
            acknowledgeMeasurement(String(format: "空杯重量已校准为 %.1f g；下次装水称量会建立起始总重", weight))
        } catch {
            errorMessage = "保存空杯校准失败：\(error.localizedDescription)"
        }
    }

    private func acknowledgeMeasurement(_ message: String) {
        guard canOperateBluetooth else { return }
        acknowledgementGeneration += 1
        let generation = acknowledgementGeneration
        pendingAcknowledgement = message
        guard settings.tareFeedbackEnabled else {
            pendingAcknowledgement = nil
            activityMessage = message
            return
        }
        awaitingTareConfirmation = true
        activityMessage = "\(message)；正在让秤归零确认"
        bluetooth.tare { [weak self] result in
            guard let self, self.acknowledgementGeneration == generation,
                  self.canOperateBluetooth else { return }
            switch result {
            case .success:
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard let self,
                          self.acknowledgementGeneration == generation,
                          self.canOperateBluetooth,
                          self.awaitingTareConfirmation else { return }
                    self.awaitingTareConfirmation = false
                    self.pendingAcknowledgement = nil
                    self.activityMessage = "\(message)；数据已处理，但未检测到秤归零，请确认秤处于称重模式"
                }
            case .failure(let error):
                self.awaitingTareConfirmation = false
                self.pendingAcknowledgement = nil
                self.activityMessage = "\(message)；数据已处理，但秤归零失败"
                self.errorMessage = "秤归零反馈失败：\(error.localizedDescription)"
            }
        }
    }

    func setRemindersEnabled(_ enabled: Bool) {
        guard !previewMode, !notificationBusy else { return }
        if !enabled {
            settings.remindersEnabled = false
            settings.remindersEnabledAt = nil
            settingsDidChange()
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [LocalNotifications.identifier])
            notificationStatusText = "已关闭"
            return
        }
        notificationBusy = true
        Task { @MainActor in
            defer { notificationBusy = false }
            do {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                settings.remindersEnabled = allowed
                settings.remindersEnabledAt = allowed ? Date() : nil
                notificationStatusText = allowed ? "已允许；仅在监测时段提醒" : "未获授权，请在系统设置 → 通知中允许"
                settingsDidChange()
            } catch { notificationStatusText = "通知授权失败：\(error.localizedDescription)" }
        }
    }

    func refreshNotificationStatus() {
        guard !previewMode, !reminderStateBlocked else { return }
        Task { @MainActor in
            let status = await UNUserNotificationCenter.current().notificationSettings()
            switch status.authorizationStatus {
            case .authorized, .provisional: notificationStatusText = settings.remindersEnabled ? "已允许；仅在监测时段提醒" : "已获授权，提醒已关闭"
            case .denied: notificationStatusText = "系统已禁用通知，请在系统设置 → 通知中允许"
            default: notificationStatusText = "尚未授权，开启时会请求权限"
            }
        }
    }

    func sendTestNotification() {
        guard !previewMode, !notificationBusy else { return }
        notificationBusy = true
        Task { @MainActor in
            defer { notificationBusy = false }
            let status = await UNUserNotificationCenter.current().notificationSettings()
            guard status.authorizationStatus == .authorized || status.authorizationStatus == .provisional else {
                notificationStatusText = "请先开启提醒并允许系统通知"; return
            }
            do {
                try await LocalNotifications.send(total: todayTotalML, goal: settings.dailyGoalML, test: true)
                notificationStatusText = "测试通知已提交；是否显示取决于系统通知与专注模式设置"
            } catch { notificationStatusText = "发送失败：\(error.localizedDescription)" }
        }
    }

    private func checkReminder(now: Date) {
        guard !previewMode, !notificationBusy, !reminderStateBlocked, !hydrationWritesBlocked,
              now.timeIntervalSince(lastReminderAttempt) >= 60,
              ReminderPolicy.isDue(now: now, settings: settings, hydration: hydration,
                  lastReminderAt: reminderState.lastReminderAt, paused: isPaused) else { return }
        lastReminderAttempt = now
        notificationBusy = true
        Task { @MainActor in
            defer { notificationBusy = false }
            let status = await UNUserNotificationCenter.current().notificationSettings()
            guard status.authorizationStatus == .authorized || status.authorizationStatus == .provisional else {
                notificationStatusText = "系统未允许通知，请在系统设置 → 通知中检查"; return
            }
            // Re-evaluate after the await: a drink, pause or settings change can cancel this attempt.
            let sendTime = Date()
            guard ReminderPolicy.isDue(now: sendTime, settings: settings, hydration: hydration,
                lastReminderAt: reminderState.lastReminderAt, paused: isPaused) else { return }
            do {
                // Persist the cooldown before enqueue: a crash cannot cause an immediate duplicate.
                // A send failure conservatively keeps the cooldown instead of spamming retries.
                reminderState.lastReminderAt = sendTime
                try AtomicJSONWriter.write(reminderState, to: reminderStateURL)
                try await LocalNotifications.send(total: todayTotalML, goal: settings.dailyGoalML)
                notificationStatusText = "本次提醒已提交"
            } catch {
                notificationStatusText = "提醒未完成：\(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    private func saveHydration() -> Bool {
        guard !previewMode else { return false }
        guard !hydrationWritesBlocked else {
            errorMessage = "喝水数据写入已禁用：请先备份并修复现有 hydration.json。"
            return false
        }
        do {
            try hydrationPersistence.save(hydration)
            return true
        } catch {
            errorMessage = "保存喝水记录失败：\(error.localizedDescription)"
            return false
        }
    }

}
