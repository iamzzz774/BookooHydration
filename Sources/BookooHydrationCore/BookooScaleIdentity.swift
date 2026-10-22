import Foundation

/// Discovery policy shared with offline regression tests. A brand name alone
/// is not enough: BOOKOO also makes grinders and pressure monitors.
public enum BookooScaleIdentity {
    public static let serviceUUID = "0FFE"
    public static let mt80ServiceUUID = "4D543830-0001-4B80-8F00-424F4F4B4F4F"

    public static func isCandidate(advertisedName: String?, cachedName: String?, serviceUUIDs: [String]) -> Bool {
        let names = [advertisedName, cachedName].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
        let services = serviceUUIDs.map(canonical)
        let compactNames = names.map { $0.filter { $0.isLetter || $0.isNumber } }
        guard !services.contains(mt80ServiceUUID),
              !compactNames.contains(where: { $0.contains("MT80") || $0.contains("MOTTO80") }),
              names.contains(where: { $0.hasPrefix("BOOKOO") }) else { return false }
        // Known scale names, the official advertised service, or the legacy
        // bare brand name. The latter still MUST pass the post-connect GATT gate.
        return services.contains(serviceUUID) || names.contains { name in
            name == "BOOKOO" || ["THEMIS", "ULTRA", "MINI", "SCALE"].contains(where: name.contains)
        }
    }

    public static func isScaleService(_ uuid: String) -> Bool {
        canonical(uuid) == serviceUUID
    }

    public static func hasScaleCharacteristics(serviceUUID: String, notifyUUID: String?, commandUUID: String?, canNotify: Bool, canWrite: Bool) -> Bool {
        isScaleService(serviceUUID) && notifyUUID.map(canonical) == "FF11"
            && commandUUID.map(canonical) == "FF12" && canNotify && canWrite
    }

    private static func canonical(_ uuid: String) -> String {
        let upper = uuid.uppercased()
        if upper.hasPrefix("0000"), upper.hasSuffix("-0000-1000-8000-00805F9B34FB"), upper.count == 36 {
            return String(upper.dropFirst(4).prefix(4))
        }
        return upper
    }
}
