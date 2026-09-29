import SwiftUI
import WaypointCore

struct SitesPage: View {
    @Environment(AppModel.self) private var model
    @State private var newSite = ""
    @State private var newTarget: ConnectionTarget = .vpn
    @State private var error: String?
    @State private var editing = false

    var body: some View {
        Page {
            PageHeader(screen: .sites)
            Panel(title: "Ваши правила", footer: "Правило для сайта действует и на все его поддомены.") {
                ForEach(model.siteRules.indexed(by: \.text)) { item in
                    if item.index > 0 { RowSeparator() }
                    SiteRuleRow(rule: item.value)
                }
                ForEach(siteTargets.indexed(by: \.id)) { item in
                    if item.index > 0 || !model.siteRules.isEmpty { RowSeparator() }
                    ConnectionRuleRow(rule: item.value)
                }
                if !model.siteRules.isEmpty || !siteTargets.isEmpty { RowSeparator(inset: Metrics.rowInset) }
                HStack(spacing: 8) {
                    TextField("Сайт, например youtube.com", text: $newSite).fieldBox().onSubmit(add)
                    TargetMenu(current: newTarget, allowAuto: false, size: .regular) { if let t = $0 { newTarget = t } }
                    Button("Добавить", action: add).barControl(prominent: true).disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(Metrics.rowInset)
            }
            if let error { Text(error).font(.callout).foregroundStyle(Color.wpBad) }

            if !pairs.isEmpty {
                Panel(title: "Приложение и сайт", footer: "Самые точные правила: действуют только для этого приложения на этом сайте. Добавляются в «Приложениях» (кнопка ⋯) или правым кликом в «Активности».") {
                    ForEach(pairs.indexed(by: \.id)) { item in
                        if item.index > 0 { RowSeparator() }
                        ConnectionRuleRow(rule: item.value)
                    }
                }
            }

            Panel(title: "Выучено автоматически", footer: "Сайты, которые напрямую не открылись, а через VPN — да. Раз в 6 часов Waypoint перепроверяет их и забывает, если блокировку сняли.") {
                if model.learned.isEmpty {
                    Row(title: "Пока ничего", subtitle: "Незнакомые сайты проверяются при первом открытии") { IconTile(symbol: "graduationcap.fill", color: .orange) }
                }
                ForEach(model.learned.indexed(by: \.domain)) { item in
                    if item.index > 0 { RowSeparator() }
                    Row(title: item.value.domain, subtitle: "Через VPN · выучено \(Fmt.day.string(from: item.value.learnedAt))", dot: .wpVPN) {
                        IconTile(symbol: "graduationcap.fill", color: .orange)
                    } trailing: {
                        Button("Забыть") { model.forget(item.value.domain) }.rowControl()
                    }
                }
            }

            HStack {
                Button("Редактировать как текст…") { editing = true }.barControl()
                Spacer()
                if !model.learned.isEmpty { Button("Забыть всё выученное", role: .destructive) { model.clearLearned() }.barControl() }
            }
        }
        .sheet(isPresented: $editing) { RulesTextSheet().environment(model) }
    }

    private var siteTargets: [ConnectionRule] { model.connectionRules.filter { $0.tier == .site } }
    private var pairs: [ConnectionRule] { model.connectionRules.filter { $0.tier == .pair } }

    private func add() {
        guard ConnectionRule.normalizeSite(newSite) != nil else { error = "Не похоже на адрес сайта"; return }
        error = nil
        model.setTarget(app: nil, site: newSite, newTarget)
        newSite = ""
    }
}

struct SiteRuleRow: View {
    @Environment(AppModel.self) private var model
    let rule: ManualRule

    var body: some View {
        Row(title: title, subtitle: kind, dot: rule.route.color) {
            IconTile(symbol: symbol, color: rule.route.color)
        } trailing: {
            if rule.kind == .suffix || rule.kind == .cidr {
                TargetMenu(current: ConnectionTarget(rule.route), allowAuto: false) { if let t = $0 { model.setTarget(app: nil, site: rule.value, t) } }
            } else {
                RouteMenu(selection: Binding(get: { rule.route }, set: { if let r = $0 { model.setSiteRoute(rule, r) } }), allowAuto: false)
            }
            Button { model.removeRule(rule) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.borderless).help("Удалить правило")
        }
    }

    private var title: String { rule.value }
    private var symbol: String {
        switch rule.kind { case .keyword: "textformat"; case .cidr: "number"; case .exact: "scope"; default: "globe" }
    }
    private var kind: String {
        switch rule.kind {
        case .suffix: "Сайт и поддомены · \(rule.route.title.lowercased())"
        case .exact: "Только этот адрес · \(rule.route.title.lowercased())"
        case .keyword: "Все адреса со словом · \(rule.route.title.lowercased())"
        case .cidr: "Диапазон IP · \(rule.route.title.lowercased())"
        case .app: rule.route.title
        }
    }
}

struct RulesTextSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var m = model
        VStack(alignment: .leading, spacing: 12) {
            Text("Правила текстом").font(.title2.weight(.bold))
            Text("По одному на строку: vpn youtube.com · direct sberbank.ru · block ads.example.com · vpn full:api.site.com · vpn keyword:tiktok · direct cidr:10.0.0.0/8 · vpn app:/Applications/Discord.app · # комментарий")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $m.manualText).font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden).padding(8).groupBackground()
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.barControl().keyboardShortcut(.cancelAction)
                Button("Сохранить") { model.saveManualRules(); dismiss() }.barControl(prominent: true).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 620, height: 460)
    }
}

/// A rule from connection-rules.json: a site with a special target, or an app+site pair.
struct ConnectionRuleRow: View {
    @Environment(AppModel.self) private var model
    let rule: ConnectionRule

    var body: some View {
        let title = rule.app.map { "\(AppPath.displayName($0)) → \(rule.site ?? "всё")" } ?? (rule.site ?? "")
        Row(title: title, subtitle: model.targetTitle(rule.target), dot: model.targetColor(rule.target)) {
            if let a = rule.app { AppIcon(path: a) } else { IconTile(symbol: "globe", color: model.targetColor(rule.target) ?? .gray) }
        } trailing: {
            TargetMenu(current: rule.target, allowAuto: false) { model.setTarget(app: rule.app, site: rule.site, $0) }
            Button { model.setTarget(app: rule.app, site: rule.site, nil) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless).help("Удалить правило")
        }
    }
}
