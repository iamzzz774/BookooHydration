import BookooHydrationCore
import SwiftUI

private enum AppPage: String, CaseIterable, Identifiable {
    case status = "概览"
    case records = "喝水记录"
    case settings = "设置"

    var id: Self { self }
    var icon: String {
        switch self {
        case .status: "drop.fill"
        case .records: "chart.bar.xaxis"
        case .settings: "gearshape.fill"
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var selection: AppPage

    init(model: AppModel) {
        self.model = model
        let requestedPage = ProcessInfo.processInfo.environment["BOOKOO_UI_TEST_PAGE"]
        _selection = State(initialValue: requestedPage == "settings" ? .settings : (requestedPage == "records" ? .records : .status))
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.accentColor)
                        Image(systemName: "drop.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Bookoo")
                            .font(.headline)
                        Text("Hydration")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)

                List(AppPage.allCases, selection: $selection) { page in
                    Label(page.rawValue, systemImage: page.icon)
                        .tag(page)
                        .padding(.vertical, 3)
                }
                .listStyle(.sidebar)

                sidebarProgress
                    .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 230)
        } detail: {
            Group {
                switch selection {
                case .status: StatusView(model: model)
                case .records: RecordsView(model: model)
                case .settings: SettingsView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 840, minHeight: 620)
        .alert("BookooHydration", isPresented: errorBinding) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var sidebarProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("今日进度")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress)
                .tint(.accentColor)
            Text("\(model.todayTotalML, specifier: "%.0f") / \(model.settings.dailyGoalML, specifier: "%.0f") mL")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var progress: Double {
        guard model.settings.dailyGoalML > 0 else { return 0 }
        return min(max(model.todayTotalML / model.settings.dailyGoalML, 0), 1)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }
}

private struct StatusView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                pageHeader
                hydrationHero
                HStack(spacing: 12) {
                    MetricTile(title: "当前重量", value: model.currentWeight.map { String(format: "%.1f", $0) } ?? "—", unit: "g", icon: "scalemass")
                    MetricTile(title: "秤电量", value: model.batteryPercent.map(String.init) ?? "—", unit: "%", icon: "battery.75percent")
                    MetricTile(title: "最近喝水", value: model.latestEntry.map { String(format: "%.0f", $0.amountML) } ?? "—", unit: "mL", icon: "clock.arrow.circlepath")
                }
                activityBanner
                HStack(alignment: .top, spacing: 14) {
                    connectionCard
                    workflowCard
                }
            }
            .padding(26)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .accessibilityLabel("喝水监测概览")
    }

    private var pageHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("每一次称量，都自动成为今天的进度。")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(
                text: model.isPaused ? "已暂停" : (model.scheduleEvaluation.isWithinWindow ? "正在监测" : "等待时段"),
                active: model.canOperateBluetooth
            )
        }
    }

    private var hydrationHero: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("今日喝水")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.82))
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(model.todayTotalML, format: .number.precision(.fractionLength(0)))
                        .font(.system(size: 46, weight: .semibold, design: .rounded).monospacedDigit())
                    Text("mL")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white.opacity(0.78))
                }
                Text(heroSubtitle)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.78))
            }
            Spacer()
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.22), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(.white, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    Text("\(Int(progress * 100))%")
                        .font(.title2.bold().monospacedDigit())
                    Text("目标")
                        .font(.caption)
                        .opacity(0.78)
                }
                .foregroundStyle(.white)
            }
            .frame(width: 96, height: 96)
        }
        .padding(24)
        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var activityBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: activityIcon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.11), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("当前状态")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(model.activityMessage)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var connectionCard: some View {
        SurfaceCard(title: "设备与检测", icon: "antenna.radiowaves.left.and.right") {
            DetailLine(label: "蓝牙", value: model.bluetooth.state.chineseText)
            DetailLine(label: "检测状态", value: model.detectorState.chineseName)
            DetailLine(label: "固定空杯", value: model.settings.emptyCupWeightG.map { String(format: "%.1f g", $0) } ?? "尚未校准")
            DetailLine(label: "上次总重", value: model.baselineWeight.map { String(format: "%.1f g", $0) } ?? "尚未称量")
            Divider().padding(.vertical, 2)
            HStack(spacing: 8) {
                Button(model.isPaused ? "恢复" : "暂停") { model.togglePause() }
                    .buttonStyle(.borderedProminent)
                Button("扫描") { model.manualScan() }
                    .disabled(!model.canOperateBluetooth)
                Button("断开") { model.manualDisconnect() }
                    .disabled(!model.bluetooth.state.isConnected)
                Spacer()
            }
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity)
    }

    private var workflowCard: some View {
        SurfaceCard(title: "快速称量", icon: "bolt.fill") {
            StepLine(number: 1, text: "空秤开机，等待显示 0.0 g")
            StepLine(number: 2, text: "放上水杯，保持稳定约 2 秒")
            StepLine(number: 3, text: "看到秤归零，即表示处理成功")
            Divider().padding(.vertical, 2)
            Text("归零后可直接拿杯喝水，喝完放回；也可以关机，下次重新空秤称量。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var progress: Double {
        guard model.settings.dailyGoalML > 0 else { return 0 }
        return min(max(model.todayTotalML / model.settings.dailyGoalML, 0), 1)
    }

    private var heroSubtitle: String {
        let remaining = max(model.settings.dailyGoalML - model.todayTotalML, 0)
        return remaining > 0 ? String(format: "距离今日目标还差 %.0f mL", remaining) : "今日目标已完成，继续保持"
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "早上好" }
        if hour < 18 { return "下午好" }
        return "晚上好"
    }

    private var activityIcon: String {
        if model.isPaused { return "pause.fill" }
        if model.bluetooth.state.isConnected { return "checkmark" }
        return "wave.3.right"
    }
}

private struct RecordsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("喝水记录")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text("自动记录每次喝水量与称重变化")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("撤销最新", systemImage: "arrow.uturn.backward", role: .destructive) {
                    model.undoLatestEntry()
                }
                .disabled(model.hydration.entries.isEmpty)
            }

            HStack(spacing: 12) {
                MetricTile(title: "今日累计", value: String(format: "%.0f", model.todayTotalML), unit: "mL", icon: "drop.fill")
                MetricTile(title: "记录次数", value: "\(todayEntries.count)", unit: "次", icon: "number")
                MetricTile(title: "最近一次", value: model.latestEntry.map { $0.timestamp.formatted(date: .omitted, time: .shortened) } ?? "—", unit: "", icon: "clock")
            }

            if model.sortedEntries.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "drop.circle")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(Color.accentColor)
                    Text("还没有喝水记录")
                        .font(.title2.weight(.semibold))
                    Text("装水称一次，喝水后再称一次，BookooHydration 会自动计算重量差。")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.sortedEntries) { entry in
                    HStack(spacing: 14) {
                        Image(systemName: "drop.fill")
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Color.accentColor, in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(format: "喝水 %.0f mL", entry.amountML))
                                .font(.headline.monospacedDigit())
                            Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(format: "%.1f → %.1f g", entry.before, entry.after))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 7)
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(26)
        .frame(maxWidth: 980, maxHeight: .infinity, alignment: .topLeading)
    }

    private var todayEntries: [HydrationEntry] {
        model.hydration.entries.filter { Calendar.current.isDateInToday($0.timestamp) }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var showAdvanced = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("设置")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text("按你的杯子和工作节奏调整 BookooHydration")
                        .foregroundStyle(.secondary)
                }

                SurfaceCard(title: "启动与后台", icon: "menubar.rectangle") {
                    Toggle(isOn: launchAtLoginBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("登录时自动启动")
                            Text(model.launchAtLoginStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("关闭主窗口后，菜单栏水滴图标仍会常驻并继续监测。只有从菜单栏选择“退出”或按 ⌘Q 才会停止。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.launchAtLoginStatusText.contains("等待") {
                        Button("打开登录项设置") { model.openLoginItemsSettings() }
                    }
                }

                SurfaceCard(title: "水杯校准", icon: "cup.and.saucer.fill") {
                    DetailLine(label: "固定空杯重量", value: model.settings.emptyCupWeightG.map { String(format: "%.1f g", $0) } ?? "尚未校准")
                    Button(model.isCalibratingCup ? "取消空杯校准" : "开始换杯校准", systemImage: model.isCalibratingCup ? "xmark.circle" : "scalemass") {
                        model.toggleCupCalibration()
                    }
                    .buttonStyle(.borderedProminent)
                    Text("只在首次使用或更换杯子时操作。先进入校准模式，再空秤开机归零，只放空杯并等待稳定。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SurfaceCard(title: "称重反馈", icon: "checkmark.circle.fill") {
                    Toggle("处理成功后让秤归零", isOn: $model.settings.tareFeedbackEnabled)
                    LabeledContent("自动关机等待") {
                        Stepper(value: $model.settings.autoOffMinutes, in: 5...30) {
                            Text("\(model.settings.autoOffMinutes) 分钟").monospacedDigit()
                        }
                        .frame(width: 190)
                    }
                    Text("BOOKOO 官方协议最短支持 5 分钟自动关机；立即关机仍需按物理按键。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SurfaceCard(title: "本机喝水提醒", icon: "bell.badge") {
                    Toggle("开启 Mac 通知", isOn: Binding(
                        get: { model.settings.remindersEnabled },
                        set: { model.setRemindersEnabled($0) }
                    ))
                    .disabled(model.notificationBusy)
                    LabeledContent("无饮水记录时提醒间隔") {
                        Stepper(value: $model.settings.reminderIntervalMinutes, in: 15...240, step: 15) {
                            Text("\(model.settings.reminderIntervalMinutes) 分钟").monospacedDigit()
                        }.frame(width: 190)
                    }
                    Text(model.notificationStatusText).font(.caption).foregroundStyle(.secondary)
                    Text("仅在监测时段内提醒；暂停监测、刚喝过水或达到每日目标时不提醒。默认关闭，开启时由系统询问通知权限。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("发送测试通知") { model.sendTestNotification() }
                        .disabled(model.notificationBusy)
                }

                SurfaceCard(title: "每日目标", icon: "target") {
                    LabeledContent("目标喝水量") {
                        Stepper(value: $model.settings.dailyGoalML, in: 100...10_000, step: 100) {
                            Text("\(model.settings.dailyGoalML, specifier: "%.0f") mL").monospacedDigit()
                        }
                        .frame(width: 190)
                    }
                }

                SurfaceCard(title: "监测计划", icon: "calendar.badge.clock") {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("星期").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        HStack(spacing: 15) {
                            ForEach(Weekday.mondayFirst, id: \.self) { weekday in
                                Toggle(weekday.chineseName, isOn: weekdayBinding(weekday))
                                    .toggleStyle(.checkbox)
                            }
                        }
                    }
                    Divider()
                    ForEach(model.settings.windows) { window in
                        HStack {
                            DatePicker("开始", selection: timeBinding(windowID: window.id, isStart: true), displayedComponents: .hourAndMinute)
                            DatePicker("结束", selection: timeBinding(windowID: window.id, isStart: false), displayedComponents: .hourAndMinute)
                            Spacer()
                            Button(role: .destructive) { model.settings.removeWindow(id: window.id) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .disabled(model.settings.windows.count <= 1)
                            .accessibilityLabel("删除时段 \(window.displayText)")
                        }
                    }
                    Button("添加时段", systemImage: "plus") {
                        model.settings.windows.append(MonitoringWindow(startHour: 9, startMinute: 0, endHour: 10, endMinute: 0))
                    }
                }

                SurfaceCard(title: "高级检测", icon: "slider.horizontal.3") {
                    DisclosureGroup("调整检测阈值", isExpanded: $showAdvanced) {
                        VStack(spacing: 10) {
                            thresholdRow("最小喝水量", value: $model.settings.detector.minimumDrinkGrams, range: 1...100, step: 1, unit: "g")
                            thresholdRow("最大喝水量", value: $model.settings.detector.maximumDrinkGrams, range: 100...2_000, step: 10, unit: "g")
                            thresholdRow("最小有效总重", value: $model.settings.detector.minimumCupReturnGrams, range: 20...2_000, step: 5, unit: "g")
                            thresholdRow("稳定持续时间", value: $model.settings.detector.stableDurationSeconds, range: 0.5...10, step: 0.5, unit: "秒")
                            thresholdRow("稳定容差", value: $model.settings.detector.stableToleranceGrams, range: 0.1...10, step: 0.1, unit: "g")
                        }
                        .padding(.top, 8)
                    }
                }

                SurfaceCard(title: "数据与共存", icon: "externaldrive.fill") {
                    DetailLine(label: "喝水数据", value: "~/Library/Application Support/BookooHydration/hydration.json")
                    DetailLine(label: "应用设置", value: "~/Library/Application Support/BookooHydration/settings.json")
                    Text("所有记录仅保存在本机。监测时段外自动断开咖啡秤；需要冲咖啡时请先暂停监测，完成后空秤重启归零再称量水杯。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(26)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .onChange(of: model.settings) { _ in model.settingsDidChange() }
        .onAppear { model.refreshLaunchAtLoginStatus(); model.refreshNotificationStatus() }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { model.launchAtLoginEnabled }, set: { model.setLaunchAtLogin($0) })
    }

    private func weekdayBinding(_ weekday: Weekday) -> Binding<Bool> {
        Binding(
            get: { model.settings.enabledWeekdays.contains(weekday) },
            set: { enabled in
                if enabled { model.settings.enabledWeekdays.insert(weekday) }
                else { model.settings.enabledWeekdays.remove(weekday) }
            }
        )
    }

    private func timeBinding(windowID: UUID, isStart: Bool) -> Binding<Date> {
        Binding(
            get: {
                guard let window = model.settings.window(id: windowID) else {
                    return Self.dateForMinute(isStart ? 0 : 1)
                }
                return Self.dateForMinute(isStart ? window.startMinute : window.endMinute)
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                if isStart {
                    model.settings.setWindowStartMinute(minutes, id: windowID)
                } else {
                    model.settings.setWindowEndMinute(minutes, id: windowID)
                }
            }
        )
    }

    private static func dateForMinute(_ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(calendar: Calendar.current, year: 2001, month: 1, day: 1, hour: minute / 60, minute: minute % 60)) ?? Date()
    }

    private func thresholdRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        LabeledContent(title) {
            Stepper(value: value, in: range, step: step) {
                Text("\(value.wrappedValue, specifier: step < 1 ? "%.1f" : "%.0f") \(unit)").monospacedDigit()
            }
            .frame(width: 190)
        }
    }
}

private struct StatusPill: View {
    let text: String
    let active: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(active ? Color.green : Color.secondary).frame(width: 7, height: 7)
            Text(text).font(.callout.weight(.semibold))
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background((active ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let unit: String
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon).foregroundStyle(Color.accentColor)
                Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(.title2.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.72)
                if !unit.isEmpty { Text(unit).font(.caption.weight(.medium)).foregroundStyle(.secondary) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct SurfaceCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.primary)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct DetailLine: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).fontWeight(.medium).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.callout)
    }
}

private struct StepLine: View {
    let number: Int
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
            Text(text).font(.callout)
        }
    }
}
