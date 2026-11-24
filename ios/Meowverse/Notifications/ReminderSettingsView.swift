import MeowverseCore
import SwiftUI

/// 提醒: the cat's calls, on-this-day and furniture memories, and cat facts. All local, all off by default.
struct ReminderSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ReminderScheduler.self) private var reminders
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    // Opened only from Settings: the first-launch version of this page is gone (PRODUCT_PLAN §2.2,
    // Plan A). The permission prompt comes when the user first turns a reminder on.
    var body: some View {
        List {
            permissionSection
            callsSection
            memoriesSection
            factsSection
            #if DEBUG || DRILLS
            debugSection
            #endif
        }
        .navigationTitle("提醒")
        .navigationBarTitleDisplayMode(.inline)
        // 14.2 hands over to this page.
        .tourAnchor("reminder-settings", padding: 0)
        .task { reminders.reschedule(state: model.shownState) }
        // Back from the system Settings: show what was changed there.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reminders.reschedule(state: model.shownState) }
        }
    }

    private var denied: Bool { reminders.authorization == .denied }

    private func binding(_ kind: ReminderKind) -> Binding<Bool> {
        Binding(get: { reminders.isOn(kind) }, set: { on in
            Task { await reminders.set(kind, on: on, state: model.shownState) }
        })
    }

    // MARK: Permission

    private var permissionSection: some View {
        Section {
            Label(permissionText, systemImage: denied ? "bell.slash" : "bell")
                .foregroundStyle(denied ? Color.caution : Color.primary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("reminder-permission-state")
            if denied {
                Button("打开系统设置") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
                .accessibilityIdentifier("reminder-open-system-settings")
            }
        } footer: {
            Text("提醒在这台设备上安排，不经过服务器，通知里只有文字、不带照片。")
        }
    }

    private var permissionText: String {
        switch reminders.authorization {
        case .notDetermined: String(localized: "第一次打开提醒时，会询问能否发送通知。")
        case .denied: String(localized: "通知已在系统设置里关闭，提醒不会出现。")
        case .allowed: String(localized: "已允许通知。")
        }
    }

    // MARK: Calls

    private var callsSection: some View {
        Section {
            Toggle("猫咪的招呼", isOn: binding(.calls))
                .disabled(denied || reminders.asking)
                .accessibilityIdentifier("reminder-calls")
            if reminders.isOn(.calls) {
                DatePicker("时间", selection: timeBinding(slot: 0), displayedComponents: .hourAndMinute)
                    .accessibilityIdentifier("reminder-calls-time")
                Toggle("每天再叫一次", isOn: secondCallBinding)
                    .accessibilityIdentifier("reminder-calls-second")
                if reminders.settings.callTimes.count > 1 {
                    DatePicker("第二次", selection: timeBinding(slot: 1), displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier("reminder-calls-second-time")
                }
            }
        } header: {
            Text("招呼")
        } footer: {
            Text("每天到点，\(Wording.subject(model.catName))会叫你一声：「嗯～喵呜～」「零食零食」或「开饭啦～」。")
        }
    }

    private func timeBinding(slot: Int) -> Binding<Date> {
        Binding(get: {
            let times = reminders.settings.callTimes
            let time = times.indices.contains(slot) ? times[slot] : ReminderSettings().callTimes[0]
            return Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: .now) ?? .now
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            let time = ReminderTime(hour: parts.hour ?? 8, minute: parts.minute ?? 0)
            reminders.update(state: model.shownState) { settings in
                if settings.callTimes.indices.contains(slot) { settings.callTimes[slot] = time }
            }
        })
    }

    private var secondCallBinding: Binding<Bool> {
        Binding(get: { reminders.settings.callTimes.count > 1 }, set: { on in
            reminders.update(state: model.shownState) { settings in
                if settings.callTimes.isEmpty { settings.callTimes = ReminderSettings().callTimes }
                if on, settings.callTimes.count < ReminderSettings.maxCallTimes {
                    settings.callTimes.append(ReminderTime(hour: 18, minute: 30))
                } else if !on {
                    settings.callTimes = [settings.callTimes[0]]
                }
            }
        })
    }

    // MARK: Memories

    private var memoriesSection: some View {
        Section {
            Toggle("历史上的今天", isOn: binding(.onThisDay))
                .disabled(denied || reminders.asking)
                .accessibilityHint("哪天有往年同一天拍的照片，就在晚上提醒你。")
                .accessibilityIdentifier("reminder-on-this-day")
            Toggle("家具的回忆", isOn: binding(.furniture))
                .disabled(denied || reminders.asking)
                .accessibilityHint("大约每周一次，挑一件有照片的家具提醒你。")
                .accessibilityIdentifier("reminder-furniture")
        } header: {
            Text("回忆")
        } footer: {
            Text("只用照片上已知的拍摄日期，日期未知的照片不会出现在“历史上的今天”。回忆在晚上 8 点左右送达，点开会打开那件家具。")
        }
    }

    // MARK: Cat facts

    private var factsSection: some View {
        Section {
            Toggle("猫咪小知识", isOn: binding(.catFacts))
                .disabled(denied || reminders.asking)
                .accessibilityHint("大约每周一次，白天送来一条关于猫的小知识。")
                .accessibilityIdentifier("reminder-cat-facts")
        } header: {
            Text("小知识")
        } footer: {
            Text("内容整理自兽医学院和动物福利机构公开的资料，不是医疗建议。猫咪不舒服时，请咨询兽医。")
                .accessibilityIdentifier("reminder-cat-facts-footer")
        }
    }

    #if DEBUG || DRILLS
    @ViewBuilder private var debugSection: some View {
        if let fake = reminders.client as? FakeNotificationCenter {
            Section("演练") {
                let attachments = fake.recorded.reduce(0) { $0 + $1.content.attachments.count }
                let sounds = fake.recorded.filter { $0.content.sound != nil }.count
                let threads = Set(fake.recorded.map(\.content.threadIdentifier)).sorted().joined(separator: ",")
                Text(verbatim: "scheduled \(fake.recorded.count) (attachments \(attachments)) (sounds \(sounds)) [threads \(threads)]: \(fake.recorded.map(\.identifier).joined(separator: ","))")
                    .font(.caption.monospaced())
                    .accessibilityIdentifier("reminder-debug-plan")
            }
        }
    }
    #endif
}
