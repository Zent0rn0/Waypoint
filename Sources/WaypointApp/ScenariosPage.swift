import SwiftUI
import WaypointCore

struct ScenariosPage: View {
    var body: some View {
        Page {
            PageHeader(screen: .scenarios)
            ForEach(Playbook.groups, id: \.title) { g in
                Panel(title: g.title) {
                    ForEach(g.ids.compactMap(Playbook.playbook).indexed(by: \.id)) { item in
                        if item.index > 0 { RowSeparator() }
                        ScenarioRow(playbook: item.value)
                    }
                }
            }
        }
    }
}

struct ScenarioRow: View {
    @Environment(AppModel.self) private var model
    let playbook: Playbook

    var body: some View {
        Row(title: playbook.title, subtitle: playbook.effect) {
            IconTile(symbol: playbook.icon, color: playbook.color)
        } trailing: {
            InfoButton(title: playbook.title, text: playbook.details)
            Toggle("", isOn: Binding(get: { model.isActive(playbook.id) }, set: { model.setPlaybook(playbook.id, $0) }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
    }
}

struct ServicesPage: View {
    var body: some View {
        Page {
            PageHeader(screen: .services)
            ForEach(Service.Group.allCases, id: \.self) { g in
                let list = Catalog.services.filter { $0.group == g }
                if !list.isEmpty {
                    Panel(title: g.rawValue) {
                        ForEach(list.indexed(by: \.id)) { item in
                            if item.index > 0 { RowSeparator() }
                            ServiceRow(service: item.value)
                        }
                    }
                }
            }
        }
    }
}

struct ServiceRow: View {
    @Environment(AppModel.self) private var model
    let service: Service

    var body: some View {
        let (text, dot) = state
        Row(title: service.title, subtitle: text, dot: dot) {
            IconTile(symbol: service.symbol, color: service.color)
        } trailing: {
            RouteMenu(selection: Binding(get: { model.servicePolicy(service.id) }, set: { model.setServicePolicy(service.id, $0) }))
        }
    }

    /// What actually applies now, and why: your choice, a scenario, or the built-in default.
    private var state: (String, Color?) {
        if let r = model.servicePolicy(service.id) { return ("\(r.title) — ваш выбор", r.color) }
        if let p = Playbook.all.first(where: { model.isActive($0.id) && ($0.direct.contains(service.id) || $0.vpn.contains(service.id)) }) {
            let r: Route = p.direct.contains(service.id) ? .direct : .vpn
            return ("\(r.title) — сценарий «\(p.title)»", r.color)
        }
        switch service.defaultRoute {
        case .vpn?: return ("Через VPN — по умолчанию", Route.vpn.color)
        case .direct?: return ("Напрямую — по умолчанию", Route.direct.color)
        default: return ("Решается автоматически", nil)
        }
    }
}
