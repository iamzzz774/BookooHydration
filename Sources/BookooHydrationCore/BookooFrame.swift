import Foundation

public struct BookooWeightFrame: Equatable, Sendable {
    public let elapsedMilliseconds: UInt32
    public let weightGrams: Double
    public let flowGramsPerSecond: Double
    public let batteryPercent: UInt8

    public init(
        elapsedMilliseconds: UInt32,
        weightGrams: Double,
        flowGramsPerSecond: Double,
        batteryPercent: UInt8
    ) {
        self.elapsedMilliseconds = elapsedMilliseconds
        self.weightGrams = weightGrams
        self.flowGramsPerSecond = flowGramsPerSecond
        self.batteryPercent = batteryPercent
    }
}

public enum BookooFrameDecoder {
    public static let notifyCharacteristicUUID = "0000FF11-0000-1000-8000-00805F9B34FB"
    public static let commandCharacteristicUUID = "0000FF12-0000-1000-8000-00805F9B34FB"

    public static func decode(_ data: Data) -> BookooWeightFrame? {
        let bytes = [UInt8](data)
        guard bytes.count == 20, bytes[0] == 0x03, bytes[1] == 0x0B else {
            return nil
        }

        let elapsed = UInt32(bytes[2]) << 16
            | UInt32(bytes[3]) << 8
            | UInt32(bytes[4])
        let weightRaw = UInt32(bytes[7]) << 16
            | UInt32(bytes[8]) << 8
            | UInt32(bytes[9])
        let flowRaw = UInt16(bytes[11]) << 8 | UInt16(bytes[12])

        return BookooWeightFrame(
            elapsedMilliseconds: elapsed,
            weightGrams: signedValue(raw: Double(weightRaw) / 100, signByte: bytes[6]),
            flowGramsPerSecond: signedValue(raw: Double(flowRaw) / 100, signByte: bytes[10]),
            batteryPercent: bytes[13]
        )
    }

    private static func signedValue(raw: Double, signByte: UInt8) -> Double {
        // BOOKOO firmware variants have used either 0x01 or ASCII "-" for negative.
        (signByte == 0x01 || signByte == 0x2D) ? -raw : raw
    }
}


public enum BookooCommandEncoder {
    public enum Command: UInt8, Sendable {
        case tare = 0x01
        case autoOff = 0x03
    }

    public static func tare() -> Data {
        build(.tare)
    }

    /// Official Ultra protocol supports 5...30 minutes, not immediate shutdown.
    public static func autoOff(minutes: Int) -> Data? {
        guard (5...30).contains(minutes) else { return nil }
        return build(.autoOff, data2: UInt8(minutes))
    }

    private static func build(_ command: Command, data1: UInt8 = 0, data2: UInt8 = 0) -> Data {
        var bytes: [UInt8] = [0x03, 0x0A, command.rawValue, data1, data2]
        bytes.append(bytes.reduce(0, ^))
        return Data(bytes)
    }
}
