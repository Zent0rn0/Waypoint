import SwiftUI
import AppKit
import UserNotifications
import WaypointCore

struct SettingsPage: View {
    @Environment(AppModel.self) private var model

    private func bind(_ get: @escaping () -> Bool, _ set: @escaping (Bool) -> Void) -> Binding<Bool> { Binding(get: get, set: set) }

    var body: some View {
        Page {
            PageHeader(screen: .settings)

            Panel(title: "Запуск") {
                ToggleRow(title: "Открывать при входе в систему", subtitle: "Системный компонент стартует сам при загрузке Mac", symbol: "power", color: .gray,
                          isOn: bind({ model.launchAtLogin }, { model.setLaunchAtLogin($0) }))
                RowSeparator()
                ToggleRow(title: "Подключать VPN вместе с Waypoint", subtitle: "Если клиент не подключится сам, Waypoint откроет его", symbol: "bolt.fill", color: .wpVPN,
                          isOn: bind({ model.settings.autoStartVPN ?? true }, { v in model.applySettings { $0.autoStartVPN = v } }))
                RowSeparator()
                ToggleRow(title: "Переподключать VPN при обрыве", subtitle: "Не чаще раза в 2 минуты", symbol: "arrow.clockwise", color: .indigo,
                          isOn: bind({ model.settings.reconnectVPN ?? false }, { v in model.applySettings { $0.reconnectVPN = v } }))
                RowSeparator()
                ToggleRow(title: "Уведомления", subtitle: "Выучен новый сайт, отключился VPN, пауза после сбоя", symbol: "bell.badge.fill", color: .red,
                          isOn: bind({ model.settings.notifications ?? true }, { v in model.applySettings { $0.notifications = v }; if v { UNUserNotificationCenterBridge.request() } }))
            }

            Panel(title: "VPN-клиент") {
                Row(title: "Клиент", subtitle: "Системный VPN из «Настройки → VPN»") {
                    if let p = model.vpnAppPath { AppIcon(path: p) } else { IconTile(symbol: "lock.shield.fill", color: .wpVPN) }
                } trailing: {
                    ChoiceMenu(selection: Binding(get: { model.settings.vpnServiceName ?? "" }, set: { v in model.applySettings { $0.vpnServiceName = v.isEmpty ? nil : v } }),
                               options: [("", "Не выбран")] + model.vpnServices.map { ($0, $0) }, separatorAfterFirst: true)
                }
                RowSeparator()
                Row(title: "Локальный порт клиента", subtitle: "SOCKS5, обычно находится сам") {
                    IconTile(symbol: "point.3.connected.trianglepath.dotted", color: .teal)
                } trailing: {
                    TextField("", value: Binding(get: { Int(model.settings.upstreamPort) }, set: { v in model.applySettings { $0.upstreamPort = UInt16(clamping: v) } }), format: .number.grouping(.never))
                        .fieldBox(height: 24).frame(width: 70).multilineTextAlignment(.trailing)
                    Button("Найти") {
                        Task {
                            if let p = await UpstreamProbe.detect(host: model.settings.upstreamHost) { model.applySettings { $0.upstreamPort = p }; model.flash("Найден порт \(p)") }
                            else { model.flash("Порт не найден — подключите VPN") }
                        }
                    }
                    .rowControl()
                }
                RowSeparator()
                ToggleRow(title: "Включать VPN только когда нужен", subtitle: "Подключает при первом заблокированном сайте, отключает после простоя", symbol: "timer", color: .orange,
                          isOn: bind({ model.settings.onDemandVPN }, { v in model.applySettings { $0.onDemandVPN = v } }))
                if model.settings.onDemandVPN {
                    RowSeparator()
                    Row(title: "Отключать после простоя", subtitle: "\(model.settings.idleDisconnectMinutes) мин") {
                        IconTile(symbol: "moon.fill", color: .indigo)
                    } trailing: {
                        Stepper("", value: Binding(get: { model.settings.idleDisconnectMinutes }, set: { v in model.applySettings { $0.idleDisconnectMinutes = v } }), in: 1...120).labelsHidden()
                    }
                }
            }

            Panel(title: "Как Waypoint решает") {
                Row(title: "Регион", subtitle: "Встроенные подсказки: что обычно заблокировано") {
                    IconTile(symbol: "map.fill", color: .green)
                } trailing: {
                    ChoiceMenu(selection: Binding(get: { model.settings.region }, set: { r in model.applySettings { $0.region = r } }),
                               options: Region.allCases.map { ($0, $0 == .none ? "Без подсказок" : $0.title) })
                }
                RowSeparator()
                ToggleRow(title: "Списки сообщества",
                          subtitle: model.communityBusy ? "Обновляю…" : "Известные блокировки с GitHub: \(model.communityInstalled.count) из \(CommunityList.all.count), раз в сутки",
                          symbol: "list.bullet.rectangle.portrait.fill", color: .purple,
                          isOn: bind({ model.settings.communityLists ?? false }, { v in model.applySettings { $0.communityLists = v }; if v { Task { await model.updateCommunityLists() } } }))
                RowSeparator()
                ToggleRow(title: "Звонки и игры через VPN", subtitle: "Голос Discord, игры и другой трафик без имени сайта", symbol: "phone.fill", color: .teal,
                          isOn: bind({ model.settings.tunnelUDPViaVPN ?? false }, { v in model.applySettings { $0.tunnelUDPViaVPN = v } }))
                RowSeparator()
                Row(title: "Обновлять подписки", subtitle: "Новые серверы появляются сами, пропавшие убираются; настройки серверов сохраняются") {
                    IconTile(symbol: "arrow.triangle.2.circlepath", color: .blue)
                } trailing: {
                    ChoiceMenu(selection: Binding(get: { model.settings.subscriptionHours ?? 1 }, set: { v in model.applySettings { $0.subscriptionHours = v } }),
                               options: [(1, "Каждый час"), (3, "Каждые 3 часа"), (6, "Каждые 6 часов"), (12, "Каждые 12 часов"), (24, "Раз в сутки")])
                }
                RowSeparator()
                Row(title: "Ждать прямой путь", subtitle: "\(model.settings.race.hedgeMs) мс, потом незнакомый сайт пробуется через VPN") {
                    IconTile(symbol: "stopwatch.fill", color: .orange)
                } trailing: {
                    Stepper("", value: Binding(get: { model.settings.race.hedgeMs }, set: { v in model.applySettings { $0.race.hedgeMs = v } }), in: 300...3000, step: 100).labelsHidden()
                }
            }

            Panel(title: "Системный компонент", footer: "Нужен для режима «Все приложения». Устанавливается один раз, macOS спросит пароль или Touch ID. При любом сбое он сам выключается, и интернет работает как обычно.") {
                Row(title: model.tunnelInstalled ? (model.daemonOutdated ? "Установлен, есть обновление" : "Установлен") : "Не установлен",
                    subtitle: model.tunnelInstalled ? model.tunnel?.message : nil,
                    dot: model.tunnelInstalled ? (model.daemonOutdated ? .wpWarn : .wpGood) : .gray) {
                    IconTile(symbol: "square.stack.3d.up.fill", color: .wpVPN)
                } trailing: {
                    if model.tunnelInstalled && model.daemonOutdated {
                        Button(model.daemonBusy ? "Обновление…" : "Обновить") { model.installDaemon() }.rowControl(prominent: true).disabled(model.daemonBusy)
                    }
                    if model.tunnelInstalled { Button("Удалить…", role: .destructive) { model.uninstallDaemon() }.rowControl().disabled(model.daemonBusy) }
                    else { Button(model.daemonBusy ? "Установка…" : "Установить") { model.installDaemon() }.rowControl(prominent: true).disabled(model.daemonBusy) }
                }
            }

            Panel(title: "Для опытных") {
                Row(title: "Сетевой стек") { IconTile(symbol: "cpu", color: .gray) } trailing: {
                    ChoiceMenu(selection: Binding(get: { model.settings.tunnelStack ?? "gvisor" }, set: { v in model.applySettings { $0.tunnelStack = v } }),
                               options: [("gvisor", "gvisor — надёжный"), ("system", "system — быстрее"), ("mixed", "mixed")])
                }
                RowSeparator()
                Row(title: "Журнал компонента") { IconTile(symbol: "doc.text.fill", color: .gray) } trailing: {
                    ChoiceMenu(selection: Binding(get: { model.settings.tunnelLogLevel ?? "warn" }, set: { v in model.applySettings { $0.tunnelLogLevel = v } }),
                               options: ["error", "warn", "info", "debug"].map { ($0, $0) })
                }
                RowSeparator()
                ToggleRow(title: "Системный прокси (PAC)", subtitle: "Только для работы без системного компонента", symbol: "network", color: .gray,
                          isOn: bind({ model.proxyApplied || model.proxyIgnored }, { model.setSystemProxy($0) }))
            }

            Panel(title: "Данные", footer: "В копии — настройки, правила, выученное и ваши серверы. Ссылки серверов хранятся открыто, берегите файл.") {
                LinkRow(title: "Сохранить резервную копию…", action: { model.exportBackup() }) { IconTile(symbol: "square.and.arrow.up.fill", color: .blue) }
                RowSeparator()
                LinkRow(title: "Восстановить из копии…", action: { model.importBackup() }) { IconTile(symbol: "square.and.arrow.down.fill", color: .blue) }
                RowSeparator()
                LinkRow(title: "Открыть папку данных", action: { NSWorkspace.shared.open(model.engine.supportDirectory) }) { IconTile(symbol: "folder.fill", color: .cyan) }
            }
        }
    }
}

struct ToggleRow: View {
    let title: String
    var subtitle: String? = nil
    let symbol: String
    let color: Color
    @Binding var isOn: Bool
    var body: some View {
        Row(title: title, subtitle: subtitle) {
            IconTile(symbol: symbol, color: color)
        } trailing: {
            Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
    }
}

/// UserNotifications needs a real bundle; from a bare executable it would trap, so the request is guarded.
enum UNUserNotificationCenterBridge {
    static func request() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
