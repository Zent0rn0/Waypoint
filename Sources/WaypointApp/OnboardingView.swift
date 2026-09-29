import SwiftUI
import WaypointCore

/// First run, in the style of the «Что нового» sheets of Apple apps: what it does, then a few explicit choices.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var login = true
    @State private var startVPN = true
    @State private var tiktok = true
    @State private var strict = true
    @State private var lists = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                BrandMark(size: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Добро пожаловать в Waypoint").font(.system(size: 22, weight: .bold))
                    Text("Заблокированное — через VPN, остальное — напрямую. Само, для каждого сайта и приложения.").foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                choice($login, "power", .gray, "Открывать при входе в систему", "Иконка в строке меню появится сама")
                RowSeparator()
                choice($startVPN, "bolt.fill", .wpVPN, "Подключать VPN вместе с Waypoint", "Если клиент не подключится сам, Waypoint откроет его")
                RowSeparator()
                choice($strict, "building.columns.fill", .green, "Банки и госсервисы — только напрямую", "Защита от ошибочного «через VPN»")
                RowSeparator()
                choice($tiktok, "music.note", Color(red: 1, green: 0.17, blue: 0.4), "TikTok — свежая лента", "Весь TikTok через VPN, чтобы лента была не российской")
                RowSeparator()
                choice($lists, "list.bullet.rectangle.portrait.fill", .purple, "Списки известных блокировок", "Публичные списки с GitHub, обновляются раз в сутки")
            }
            .groupBackground()
            Text(model.tunnelInstalled ? "Системный компонент уже установлен." : "Чтобы охватить все приложения (Telegram, Discord, игры), после этого установите системный компонент — кнопка будет на главной.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Пропустить") { model.finishOnboarding() }.barControl()
                Spacer()
                Button("Продолжить") { apply() }.barControl(prominent: true).keyboardShortcut(.defaultAction)
            }
        }
        .padding(30).frame(width: 560)
    }

    private func choice(_ b: Binding<Bool>, _ symbol: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        ToggleRow(title: title, subtitle: detail, symbol: symbol, color: color, isOn: b)
    }

    private func apply() {
        if login { model.setLaunchAtLogin(true) }
        model.applySettings { $0.autoStartVPN = startVPN; $0.communityLists = lists }
        if strict { model.setPlaybook("strict-ru", true) }
        if tiktok { model.setPlaybook("tiktok", true) }
        if startVPN { Task { await model.ensureVPN() } }
        if lists { Task { await model.updateCommunityLists() } }
        model.finishOnboarding()
    }
}
