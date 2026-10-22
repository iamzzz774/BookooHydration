import Foundation
import BookooHydrationCore

nonisolated(unsafe) private var assertionCount = 0
private func expect(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
    assertionCount += 1
    guard condition() else { fputs("ASSERTION FAILED: \(message) (\(file):\(line))\n", stderr); exit(1) }
}
private func expectNear(_ actual: Double, _ expected: Double, accuracy: Double = 0.001, _ message: String) {
    expect(abs(actual - expected) <= accuracy, "\(message): expected \(expected), got \(actual)")
}
private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
@discardableResult
private func stabilize(_ detector: DrinkDetector, weight: Double, start: TimeInterval) -> DrinkDetectorEvent? {
    _ = detector.ingest(weight: weight, at: baseDate.addingTimeInterval(start))
    _ = detector.ingest(weight: weight + 0.2, at: baseDate.addingTimeInterval(start + 1))
    return detector.ingest(weight: weight - 0.1, at: baseDate.addingTimeInterval(start + 2.1))
}
private func detector(previous: Double?, emptyCup: Double = 120) -> DrinkDetector {
    let detector = DrinkDetector()
    detector.beginFreshSession(previousWeight: previous, emptyCupWeight: emptyCup)
    return detector
}

private func testFrameAndCommands() {
    var bytes = [UInt8](repeating: 0, count: 20)
    bytes[0] = 0x03; bytes[1] = 0x0B
    bytes[2] = 0x01; bytes[3] = 0x02; bytes[4] = 0x03
    bytes[6] = 0x2D; bytes[7] = 0x00; bytes[8] = 0x30; bytes[9] = 0x39
    bytes[10] = 0x01; bytes[11] = 0x00; bytes[12] = 0xEA; bytes[13] = 87
    let frame = BookooFrameDecoder.decode(Data(bytes))
    expect(frame != nil, "valid BOOKOO frame decodes")
    expect(frame?.elapsedMilliseconds == 0x010203, "elapsed milliseconds are big-endian")
    expectNear(frame?.weightGrams ?? 0, -123.45, "signed weight decodes")
    expectNear(frame?.flowGramsPerSecond ?? 0, -2.34, "signed flow decodes")
    expect(frame?.batteryPercent == 87, "battery byte decodes")
    expect(BookooFrameDecoder.decode(Data(bytes.dropLast())) == nil, "short frame rejected")
    expect([UInt8](BookooCommandEncoder.tare()) == [0x03, 0x0A, 0x01, 0x00, 0x00, 0x08], "official tare packet")
    expect([UInt8](BookooCommandEncoder.autoOff(minutes: 5) ?? Data()) == [0x03, 0x0A, 0x03, 0x00, 0x05, 0x0F], "official 5-minute auto-off packet")
    expect([UInt8](BookooCommandEncoder.autoOff(minutes: 30) ?? Data()) == [0x03, 0x0A, 0x03, 0x00, 0x1E, 0x14], "official 30-minute auto-off packet")
    expect(BookooCommandEncoder.autoOff(minutes: 4) == nil, "auto-off below official range rejected")
    expect(BookooCommandEncoder.autoOff(minutes: 31) == nil, "auto-off above official range rejected")
}

private func testScheduleBoundaries() {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    func date(_ hour: Int, _ minute: Int, day: Int = 3) -> Date { calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute))! }
    let settings = AppSettings.defaults
    expect(!ScheduleEvaluator.evaluate(date: date(8, 59), enabledWeekdays: settings.enabledWeekdays, windows: settings.windows, calendar: calendar).isWithinWindow, "08:59 outside")
    expect(ScheduleEvaluator.evaluate(date: date(9, 0), enabledWeekdays: settings.enabledWeekdays, windows: settings.windows, calendar: calendar).isWithinWindow, "09:00 inclusive")
    expect(ScheduleEvaluator.evaluate(date: date(12, 14), enabledWeekdays: settings.enabledWeekdays, windows: settings.windows, calendar: calendar).isWithinWindow, "12:14 inside")
    expect(!ScheduleEvaluator.evaluate(date: date(12, 15), enabledWeekdays: settings.enabledWeekdays, windows: settings.windows, calendar: calendar).isWithinWindow, "12:15 exclusive")
    expect(ScheduleEvaluator.evaluate(date: date(14, 30), enabledWeekdays: settings.enabledWeekdays, windows: settings.windows, calendar: calendar).isWithinWindow, "14:30 inclusive")
    expect(!ScheduleEvaluator.evaluate(date: date(17, 30), enabledWeekdays: settings.enabledWeekdays, windows: settings.windows, calendar: calendar).isWithinWindow, "17:30 exclusive")
    expect(ScheduleEvaluator.evaluate(date: date(10, 0, day: 8), enabledWeekdays: settings.enabledWeekdays, windows: settings.windows, calendar: calendar).isWithinWindow, "Saturday enabled")
    expect(!ScheduleEvaluator.evaluate(date: date(10, 0, day: 9), enabledWeekdays: settings.enabledWeekdays, windows: settings.windows, calendar: calendar).isWithinWindow, "Sunday disabled")
}

private func testInitialMeasurement() {
    let d = detector(previous: nil)
    let event = stabilize(d, weight: 620, start: 0)
    if case .initialMeasurement(let weight) = event { expectNear(weight, 620.03, accuracy: 0.2, "first total saved") }
    else { expect(false, "first stable total is initial measurement") }
    expect(d.state == .completed, "one-shot session completes")
    expectNear(d.baselineWeight ?? 0, 620.03, accuracy: 0.2, "initial total becomes previous")
    expect(d.ingest(weight: 500, at: baseDate.addingTimeInterval(5)) == nil, "completed session ignores later frames")
}

private func testDrinkMeasurement() {
    let d = detector(previous: 620)
    let event = stabilize(d, weight: 470, start: 0)
    if case .drink(let entry) = event {
        expectNear(entry.amountML, 150, accuracy: 0.3, "total decrease records drinking")
        expectNear(entry.before, 620, "drink previous total")
        expectNear(entry.after, 470, accuracy: 0.3, "drink current total")
    } else { expect(false, "valid independent measurement records drink") }
    expectNear(d.baselineWeight ?? 0, 470, accuracy: 0.3, "drink updates persisted total")
}

private func testSamePowerCycleAfterTare() {
    let d = detector(previous: nil)
    if case .initialMeasurement(let total) = stabilize(d, weight: 420, start: 0) {
        d.beginTareRelativeSession(baselineWeight: total, emptyCupWeight: 165)
    } else { expect(false, "initial same-cycle total expected") }

    expect(stabilize(d, weight: -420, start: 4) == .cupRemoved, "tare-relative cup removal detected")
    let event = stabilize(d, weight: -80, start: 8)
    if case .drink(let entry) = event {
        expectNear(entry.amountML, 80, accuracy: 0.4, "negative tare-relative return records drink")
        expectNear(entry.after, 340, accuracy: 0.4, "relative reading reconstructs absolute total")
    } else { expect(false, "same-power-cycle return should record drink") }
    expectNear(d.baselineWeight ?? 0, 340, accuracy: 0.4, "same-cycle drink updates total")

    d.beginTareRelativeSession(baselineWeight: 340, emptyCupWeight: 165)
    _ = stabilize(d, weight: -340, start: 12)
    let refill = stabilize(d, weight: 60, start: 16)
    if case .refill(let previous, let current) = refill {
        expectNear(previous, 340, accuracy: 0.1, "same-cycle refill previous")
        expectNear(current, 400, accuracy: 0.4, "same-cycle positive return reconstructs refill total")
    } else { expect(false, "same-power-cycle refill expected") }
}

private func testRefillNoiseAndReject() {
    let refill = detector(previous: 300)
    if case .refill(let previous, let current) = stabilize(refill, weight: 650, start: 0) {
        expect(current > previous, "increase is refill")
    } else { expect(false, "refill event expected") }
    expectNear(refill.baselineWeight ?? 0, 650, accuracy: 0.3, "refill updates total")

    let noise = detector(previous: 500)
    if case .noiseIgnored = stabilize(noise, weight: 494, start: 0) {} else { expect(false, "sub-minimum change ignored") }
    expectNear(noise.baselineWeight ?? 0, 500, "noise does not drift previous total")

    let excessive = detector(previous: 800, emptyCup: 100)
    if case .decreaseRejected = stabilize(excessive, weight: 200, start: 0) {} else { expect(false, "over-500g drop rejected") }
    expectNear(excessive.baselineWeight ?? 0, 800, "rejected drop retains total")

    let impossible = detector(previous: 300, emptyCup: 150)
    if case .belowEmptyCupRejected = stabilize(impossible, weight: 120, start: 0) {} else { expect(false, "total below empty cup rejected") }
}

private func testContinuousStabilityAndCalibrationReading() {
    let d = detector(previous: nil)
    _ = d.ingest(weight: 300, at: baseDate)
    _ = d.ingest(weight: 300.1, at: baseDate.addingTimeInterval(5))
    expect(d.ingest(weight: 299.9, at: baseDate.addingTimeInterval(5.2)) == nil, "long gap resets stability")
    expect(d.baselineWeight == nil, "discontinuous frames do not complete")
    expectNear(d.calibrationWeight() ?? 0, 299.9, accuracy: 0.2, "explicit calibration uses current reading")
}

private func testSafeScheduleWindowEditing() {
    var settings = AppSettings(
        windows: [MonitoringWindow(startMinute: 540, endMinute: 600)]
    )
    let firstID = settings.windows[0].id
    settings.windows[0] = MonitoringWindow(id: firstID, startMinute: 720, endMinute: 600)
    settings.normalize()
    expect(settings.windows.count == 1, "normalization preserves edited window")
    expect(settings.windows[0].id == firstID, "normalization preserves stable window identity")
    expect(settings.windows[0].startMinute == 720, "normalization keeps requested start")
    expect(settings.windows[0].endMinute == 721, "normalization maintains one-minute interval")
    expect(settings.setWindowStartMinute(800, id: firstID), "valid start edit succeeds")
    expect(settings.windows[0].endMinute == 801, "start crossing end advances end safely")
    expect(!settings.setWindowEndMinute(900, id: UUID()), "stale window identity is ignored")
    expect(!settings.removeWindow(id: UUID()), "stale removal identity is ignored")
    expect(!settings.removeWindow(id: firstID), "last schedule window cannot be removed")

    let second = MonitoringWindow(startMinute: 900, endMinute: 1000)
    settings.windows.append(second)
    expect(settings.removeWindow(id: firstID), "valid removal succeeds when another window remains")
    expect(settings.windows.count == 1, "valid removal updates the collection")
    expect(settings.setWindowStartMinute(930, id: second.id), "binding still targets shifted window by identity")
    expect(settings.windows[0].id == second.id && settings.windows[0].startMinute == 930, "shifted row cannot redirect stale binding")

    do {
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        expect(roundTrip.windows[0].id == second.id, "window identity persists through JSON")
    } catch {
        expect(false, "window identity round-trip succeeds: \(error)")
    }
}

private func testSettingsBackwardCompatibility() {
    let legacy = Data(#"{"dailyGoalML":1800,"enabledWeekdays":[2,3,4,5,6,7],"windows":[{"startMinute":540,"endMinute":735}],"detector":{"minimumDrinkGrams":10,"maximumDrinkGrams":500,"cupAwayThresholdGrams":10,"minimumCupReturnGrams":50,"stableDurationSeconds":2,"stableToleranceGrams":1}}"#.utf8)
    do {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
        expect(decoded.emptyCupWeightG == nil, "legacy settings decode without empty cup")
        expect(decoded.tareFeedbackEnabled, "legacy settings default tare feedback on")
        expect(decoded.autoOffMinutes == 5, "legacy settings default auto-off to 5 minutes")
        expect(decoded.windows.count == 1, "legacy window without id still decodes")
    } catch { expect(false, "legacy settings should decode: \(error)") }
}

private func testPersistenceSchema() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BookooHydrationAssertions-\(UUID().uuidString)", isDirectory: true)
    let url = directory.appendingPathComponent("hydration.json"); defer { try? FileManager.default.removeItem(at: directory) }
    let entry = HydrationEntry(timestamp: baseDate, amountML: 42.5, before: 310, after: 267.5)
    let expected = HydrationData(dailyTargetML: 2000, lastCupWeightG: 267.5, entries: [entry])
    let persistence = HydrationPersistence(url: url)
    do {
        try persistence.save(expected)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        expect(object?["dailyTargetML"] as? Double == 2000, "schema dailyTargetML")
        expect(object?["lastCupWeightG"] as? Double == 267.5, "schema lastCupWeightG")
        let entries = object?["entries"] as? [[String: Any]]
        expect(entries?.first?["timestamp"] is String, "timestamp ISO text")
        expect(entries?.first?["amountML"] as? Double == 42.5, "entry amountML")
        let loaded = try persistence.load()
        expectNear(loaded.lastCupWeightG ?? 0, 267.5, "last total round-trips")
        expectNear(loaded.entries.first?.amountML ?? 0, 42.5, "entry round-trips")
    } catch { expect(false, "persistence succeeds: \(error)") }
}

private func testCorruptHydrationBackup() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BookooHydrationCorrupt-\(UUID().uuidString)", isDirectory: true)
    let url = directory.appendingPathComponent("hydration.json"); defer { try? FileManager.default.removeItem(at: directory) }
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupt = Data("{not valid json".utf8); try corrupt.write(to: url)
        let result = try HydrationPersistence(url: url).loadRecoveringCorruptFile(defaultTargetML: 1800)
        expectNear(result.data.dailyTargetML, 1800, "recovery target")
        expect(result.data.entries.isEmpty, "recovery empty data")
        expect(result.backupURL != nil, "backup path created")
        if let backupURL = result.backupURL {
            let backupData = try Data(contentsOf: backupURL)
            expect(backupData == corrupt, "backup preserves bytes")
        }
    } catch { expect(false, "corrupt recovery succeeds: \(error)") }
}

private func testScaleIdentity() {
    func candidate(_ name: String?, _ cached: String? = nil, _ services: [String] = []) -> Bool {
        BookooScaleIdentity.isCandidate(advertisedName:name,cachedName:cached,serviceUUIDs:services)
    }
    expect(!candidate("BOOKOO MT80 9fccdc30"), "MT80 must never be a scale candidate")
    expect(!candidate("bookoo_motto80"), "MOTTO80 case/separator variant rejected")
    expect(!candidate("BOOKOO Themis", "BOOKOO MT80"), "conflicting cached grinder identity vetoes discovery")
    expect(!candidate("BOOKOO", nil, [BookooScaleIdentity.mt80ServiceUUID]), "MT80 service vetoes generic name")
    expect(candidate("BOOKOO Themis Ultra"), "Themis scale remains compatible")
    expect(candidate("bookoo_ultra"), "case-insensitive Ultra scale")
    expect(candidate("BOOKOO MINI SCALE"), "Mini scale identity")
    expect(candidate("BOOKOO", nil, ["0FFE"]), "scale service with legacy name")
    expect(candidate(nil, "BOOKOO", ["00000ffe-0000-1000-8000-00805f9b34fb"]), "expanded service and cached name")
    expect(candidate("BOOKOO"), "legacy generic scale proceeds to mandatory GATT check")
    expect(!candidate("BOOKOO Espresso Monitor"), "pressure monitor is not a scale")
    expect(!candidate("Other Brand Scale", nil, ["0FFE"]), "unrelated brand rejected")
    expect(!candidate(nil), "anonymous device rejected")
    expect(BookooScaleIdentity.hasScaleCharacteristics(serviceUUID:"0FFE",notifyUUID:"FF11",commandUUID:"FF12",canNotify:true,canWrite:true), "scale characteristic pair accepted")
    expect(!BookooScaleIdentity.hasScaleCharacteristics(serviceUUID:BookooScaleIdentity.mt80ServiceUUID,notifyUUID:"FF11",commandUUID:"FF12",canNotify:true,canWrite:true), "wrong service rejected even with matching characteristic IDs")
    expect(!BookooScaleIdentity.hasScaleCharacteristics(serviceUUID:"0FFE",notifyUUID:"FF11",commandUUID:nil,canNotify:true,canWrite:true), "notification alone is not readiness")
    expect(!BookooScaleIdentity.hasScaleCharacteristics(serviceUUID:"0FFE",notifyUUID:"FF11",commandUUID:"FF12",canNotify:false,canWrite:true), "notification capability required")
    expect(!BookooScaleIdentity.hasScaleCharacteristics(serviceUUID:"0FFE",notifyUUID:"FF11",commandUUID:"FF12",canNotify:true,canWrite:false), "with-response write capability required")
}

private func testStandaloneReminders() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    func date(_ hour: Int, _ minute: Int = 0, _ day: Int = 3) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute))!
    }
    var settings = AppSettings.defaults
    settings.remindersEnabled = true
    settings.remindersEnabledAt = date(9)
    var hydration = HydrationData()
    func due(_ now: Date, last: Date? = nil, paused: Bool = false) -> Bool {
        ReminderPolicy.isDue(now: now, settings: settings, hydration: hydration,
            lastReminderAt: last, paused: paused, calendar: calendar)
    }
    expect(!due(date(10, 29)), "no reminder before full idle interval")
    expect(due(date(10, 30)), "first reminder at exact idle boundary")
    expect(!due(date(10, 30), paused: true), "pause suppresses reminders")
    expect(!due(date(10, 30), last: date(10)), "successful previous attempt cools down")
    expect(due(date(11, 30), last: date(10)), "cooldown expires exactly")
    expect(!due(date(12, 15)), "window end excludes reminder")
    expect(!due(date(14, 30)), "afternoon window restarts idle grace")
    expect(due(date(16)), "afternoon reminder after full interval")
    expect(!due(date(10, 30, 9)), "disabled weekday")
    settings.remindersEnabled = false
    expect(!due(date(10, 30)), "user disable suppresses")
    settings.remindersEnabled = true
    settings.remindersEnabledAt = nil
    expect(!due(date(10, 30)), "missing enable anchor fails closed")
    settings.remindersEnabledAt = date(10, 15)
    expect(!due(date(10, 30)), "enable grants grace rather than immediate nag")
    settings.remindersEnabledAt = date(9)
    hydration.entries = [HydrationEntry(timestamp: date(10), amountML: 200, before: 500, after: 300)]
    expect(!due(date(10, 30)), "recent drink postpones notification")
    expect(due(date(11, 30)), "drink idle interval expires")
    hydration.entries[0].amountML = 2000
    expect(!due(date(11, 30)), "daily goal reached silences")
    hydration.entries[0].timestamp = date(10, 0, 2)
    expect(due(date(10, 30)), "yesterday's goal never silences today")
    hydration.entries[0].timestamp = date(12)
    expect(due(date(10, 30)), "future timestamps cannot count as drunk water")
    expect(!due(date(10, 30), last: date(11)), "clock rollback cannot trigger spam")
    settings.reminderIntervalMinutes = 0; settings.normalize()
    expect(settings.reminderIntervalMinutes == 15, "minimum reminder interval normalized")
    settings.reminderIntervalMinutes = 999; settings.normalize()
    expect(settings.reminderIntervalMinutes == 240, "maximum reminder interval normalized")
    let home = URL(fileURLWithPath: "/test-home")
    expect(BookooPaths.hydrationURL(homeDirectory: home).path == "/test-home/Library/Application Support/BookooHydration/hydration.json", "independent data path")
    expect(BookooPaths.settingsURL(homeDirectory: home).path == "/test-home/Library/Application Support/BookooHydration/settings.json", "independent settings path")
    var fence = ScaleSessionFence()
    fence.begin(); let token = fence.generation
    expect(fence.accepts(token), "live BLE callback allowed")
    fence.invalidate(); expect(!fence.accepts(token), "disconnect rejects stale callbacks")
    fence.begin(); expect(!fence.accepts(token), "new session cannot revive stale callbacks")
    do {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        expect(!old.remindersEnabled && old.reminderIntervalMinutes == 90, "legacy settings default to quiet reminders")
        let saved = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        expect(saved == settings, "reminder settings survive round trip")
        let state = ReminderState(lastReminderAt: date(10))
        let restored = try JSONDecoder().decode(ReminderState.self, from: JSONEncoder().encode(state))
        expect(restored == state, "cooldown round trip")
    } catch { expect(false, "standalone round trip: \(error)") }
}

testStandaloneReminders()
testScaleIdentity()
testFrameAndCommands()
testScheduleBoundaries()
testInitialMeasurement()
testDrinkMeasurement()
testSamePowerCycleAfterTare()
testRefillNoiseAndReject()
testContinuousStabilityAndCalibrationReading()
testSafeScheduleWindowEditing()
testSettingsBackwardCompatibility()
testPersistenceSchema()
testCorruptHydrationBackup()
print("BookooHydrationCoreAssertions: PASS (\(assertionCount) assertions)")
