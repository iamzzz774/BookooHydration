import Foundation

public enum DrinkDetectorState: String, Equatable, Sendable {
    case awaitingMeasurement
    case awaitingCupRemoval
    case awaitingCupReturn
    case completed

    public var chineseName: String {
        switch self {
        case .awaitingMeasurement: "等待本次稳定称重"
        case .awaitingCupRemoval: "称重完成，可拿杯喝水"
        case .awaitingCupReturn: "杯子已拿起，等待放回"
        case .completed: "本次称重已完成"
        }
    }
}

public enum DrinkDetectorEvent: Equatable, Sendable {
    case initialMeasurement(weight: Double)
    case cupRemoved
    case drink(HydrationEntry)
    case refill(previous: Double, current: Double)
    case noiseIgnored(previous: Double, current: Double)
    case decreaseRejected(previous: Double, current: Double)
    case belowEmptyCupRejected(measured: Double, emptyCup: Double)
}

public final class DrinkDetector {
    public private(set) var configuration: DetectorConfiguration
    public private(set) var state: DrinkDetectorState = .awaitingMeasurement
    public private(set) var baselineWeight: Double?
    public private(set) var currentWeight: Double?
    public private(set) var currentStableWeight: Double?

    private enum MeasurementMode { case absolute, tareRelative }
    private var mode: MeasurementMode = .absolute
    private var emptyCupWeight: Double?
    private var candidateMean: Double?
    private var candidateStartedAt: Date?
    private var candidateSum: Double = 0
    private var candidateCount: Int = 0
    private var candidateLastSampleAt: Date?

    public init(configuration: DetectorConfiguration = DetectorConfiguration()) {
        self.configuration = configuration
    }

    public func updateConfiguration(_ configuration: DetectorConfiguration) {
        self.configuration = configuration
    }

    /// A fresh power cycle reports absolute cup+water weight.
    public func beginFreshSession(previousWeight: Double?, emptyCupWeight: Double?) {
        mode = .absolute
        state = .awaitingMeasurement
        baselineWeight = previousWeight
        self.emptyCupWeight = emptyCupWeight
        currentWeight = nil
        currentStableWeight = nil
        clearStabilityCandidate()
    }

    /// After successful tare, scale readings are relative to the just-saved total.
    /// Removing the cup yields roughly -baseline; returning it yields the consumed/refilled delta.
    public func beginTareRelativeSession(baselineWeight: Double, emptyCupWeight: Double?) {
        mode = .tareRelative
        state = .awaitingCupRemoval
        self.baselineWeight = baselineWeight
        self.emptyCupWeight = emptyCupWeight
        currentWeight = 0
        currentStableWeight = 0
        clearStabilityCandidate()
    }

    @discardableResult
    public func ingest(weight: Double, at timestamp: Date) -> DrinkDetectorEvent? {
        guard state != .completed, weight.isFinite else { return nil }
        currentWeight = weight

        let sampleGap = candidateLastSampleAt.map { timestamp.timeIntervalSince($0) }
        if let mean = candidateMean,
           let sampleGap,
           sampleGap >= 0,
           sampleGap <= 1.25,
           abs(weight - mean) <= configuration.stableToleranceGrams {
            candidateSum += weight
            candidateCount += 1
            candidateMean = candidateSum / Double(candidateCount)
            candidateLastSampleAt = timestamp
        } else {
            candidateMean = weight
            candidateSum = weight
            candidateCount = 1
            candidateStartedAt = timestamp
            candidateLastSampleAt = timestamp
            return nil
        }

        guard let startedAt = candidateStartedAt,
              candidateCount >= 3,
              timestamp.timeIntervalSince(startedAt) >= configuration.stableDurationSeconds,
              let stableWeight = candidateMean else { return nil }
        currentStableWeight = stableWeight

        switch mode {
        case .absolute:
            guard state == .awaitingMeasurement,
                  stableWeight >= configuration.minimumCupReturnGrams else { return nil }
            state = .completed
            return evaluateTotal(stableWeight, at: timestamp)

        case .tareRelative:
            guard let baselineWeight else { return nil }
            switch state {
            case .awaitingCupRemoval:
                let inferredTotal = baselineWeight + stableWeight
                guard inferredTotal <= configuration.cupAwayThresholdGrams else { return nil }
                state = .awaitingCupReturn
                clearStabilityCandidate()
                return .cupRemoved
            case .awaitingCupReturn:
                let currentTotal = baselineWeight + stableWeight
                guard currentTotal >= configuration.minimumCupReturnGrams else { return nil }
                state = .completed
                return evaluateTotal(currentTotal, at: timestamp)
            case .awaitingMeasurement, .completed:
                return nil
            }
        }
    }

    public func calibrationWeight() -> Double? {
        guard let currentWeight, currentWeight.isFinite, currentWeight >= 20 else { return nil }
        if let stable = currentStableWeight,
           abs(stable - currentWeight) <= configuration.stableToleranceGrams { return stable }
        return currentWeight
    }

    private func evaluateTotal(_ measuredTotal: Double, at timestamp: Date) -> DrinkDetectorEvent {
        if let emptyCupWeight,
           measuredTotal + configuration.stableToleranceGrams < emptyCupWeight {
            return .belowEmptyCupRejected(measured: measuredTotal, emptyCup: emptyCupWeight)
        }
        guard let previous = baselineWeight else {
            baselineWeight = measuredTotal
            return .initialMeasurement(weight: measuredTotal)
        }

        let decrease = previous - measuredTotal
        if abs(decrease) < configuration.minimumDrinkGrams {
            return .noiseIgnored(previous: previous, current: measuredTotal)
        }
        if decrease < 0 {
            baselineWeight = measuredTotal
            return .refill(previous: previous, current: measuredTotal)
        }
        if decrease > configuration.maximumDrinkGrams {
            return .decreaseRejected(previous: previous, current: measuredTotal)
        }

        baselineWeight = measuredTotal
        return .drink(HydrationEntry(timestamp: timestamp, amountML: decrease, before: previous, after: measuredTotal))
    }

    private func clearStabilityCandidate() {
        candidateMean = nil
        candidateStartedAt = nil
        candidateSum = 0
        candidateCount = 0
        candidateLastSampleAt = nil
    }
}
