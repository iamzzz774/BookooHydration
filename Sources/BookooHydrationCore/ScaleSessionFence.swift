/// Cancels stale callbacks before disconnecting or failing command completions.
public struct ScaleSessionFence {
    public private(set) var generation: UInt64 = 0
    public private(set) var isInvalidated = false
    public init() {}
    public mutating func invalidate() { generation &+= 1; isInvalidated = true }
    public mutating func begin() { generation &+= 1; isInvalidated = false }
    public func accepts(_ token: UInt64) -> Bool {
        !isInvalidated && token == generation
    }
}
