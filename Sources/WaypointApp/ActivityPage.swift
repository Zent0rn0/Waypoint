import SwiftUI
import WaypointCore

/// Activity Monitor pattern (tabs, search, a table, a summary strip at the bottom) in the app's glass cards.
struct ActivityPage: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0
    @State private var query = ""
    @State private var detailApp: AppInfo?
    @State private var connSort = SortState(key: "got", ascending: false)
    @State private var eventSort = SortState(key: "time", ascending: false)

    /// Same column, header and glass cards as every other page; the table fills the height instead of scrolling the page.
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(screen: .activity, compact: true)
            HStack(spacing: 10) {
                SegmentedPills(selection: $tab, options: [(0, "Соединения"), (1, "Проверки сайтов")]).frame(width: 270)
                Spacer()
                SearchField(prompt: "Приложение или сайт", text: $query).frame(width: 240)
            }
            Group { if tab == 0 { connections } else { checks } }
                .frame(maxWidth: .infinity, minHeight: 120, idealHeight: 300, maxHeight: .infinity)   // a table's ideal height is all its rows: never let it size the window
                .clipShape(RoundedRectangle(cornerRadius: Metrics.groupRadius, style: .continuous))
                .groupBackground()
            SummaryStrip().groupBackground(radius: Metrics.tileRadius)
        }
        .glassGroup()
        .frame(maxWidth: Metrics.maxColumn, minHeight: 0, maxHeight: .infinity)
        .padding(.horizontal, 20).padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .sheet(item: $detailApp) { AppDetailSheet(app: $0).environment(model) }
    }

    // MARK: table pieces (own table: the system one has an opaque black header and ignores the window width)

    private static let pad: CGFloat = 14
    private func cell<C: View>(_ w: CGFloat?, _ align: Alignment = .leading, @ViewBuilder _ c: () -> C) -> some View {
        Group {
            if let w { c().frame(width: w, alignment: align) } else { c().frame(maxWidth: .infinity, alignment: align) }
        }
    }
    private func head(_ cols: [(title: String, key: String, width: CGFloat?, align: Alignment)], sort: Binding<SortState>) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ForEach(cols.indices, id: \.self) { i in
                    let col = cols[i], active = sort.wrappedValue.key == col.key
                    cell(col.width, col.align) {
                        Button {
                            if active { sort.wrappedValue.ascending.toggle() }
                            else { sort.wrappedValue = SortState(key: col.key, ascending: !["got", "ms", "time"].contains(col.key)) }
                        } label: {
                            HStack(spacing: 3) {
                                Text(col.title).lineLimit(1)
                                if active { Image(systemName: sort.wrappedValue.ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)) }
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(active ? Color.primary : Color.secondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Сортировать по колонке")
                    }
                }
            }
            .padding(.horizontal, Self.pad).padding(.vertical, 8)
            Divider()
        }
    }
    private func ordered<T, K: Comparable>(_ list: [T], _ s: SortState, _ key: (T) -> K) -> [T] {
        list.sorted { s.ascending ? key($0) < key($1) : key($0) > key($1) }
    }
    private func tableRows<T: Identifiable, R: View>(_ list: [T], @ViewBuilder row: @escaping (T) -> R) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(list) { item in
                    row(item).padding(.horizontal, Self.pad).padding(.vertical, 7).frame(minHeight: 34)
                    Divider().padding(.leading, Self.pad).opacity(0.6)
                }
            }
        }
    }

    // MARK: connections

    private var rows: [LiveConnection] {
        let list = model.connections
            .filter { query.isEmpty || $0.host.localizedCaseInsensitiveContains(query) || $0.appName.localizedCaseInsensitiveContains(query) }
        switch connSort.key {
        case "app": return ordered(list, connSort) { $0.appName.lowercased() }
        case "host": return ordered(list, connSort) { $0.host.lowercased() }
        case "path": return ordered(list, connSort) { "\($0.path)" }
        case "via": return ordered(list, connSort) { carrier($0).lowercased() }
        default: return ordered(list, connSort) { $0.download }
        }
    }

    @ViewBuilder private var connections: some View {
        if model.tunnel?.state != .running {
            EmptyState(symbol: "network.slash", title: "Нужен режим «Все приложения»",
                       text: "Список соединений всей системы доступен, когда он включён: каждое приложение, его адреса и выбранный путь.")
        } else if rows.isEmpty {
            EmptyState(symbol: "hourglass", title: query.isEmpty ? "Пока нет соединений" : "Ничего не найдено", text: "Откройте любой сайт или приложение.")
        } else {
            VStack(spacing: 0) {
                head([("Приложение", "app", 140, .leading), ("Адрес", "host", nil, .leading), ("Путь", "path", 84, .leading), ("Через", "via", 100, .leading), ("Получено", "got", 68, .trailing)], sort: $connSort)
                tableRows(rows) { c in
                    HStack(spacing: 10) {
                        cell(140) { HStack(spacing: 7) { AppIcon(path: c.appPath, size: 18); Text(c.appName).lineLimit(1) } }
                        cell(nil) { Text(c.host).lineLimit(1).truncationMode(.middle) }
                        cell(84) { PathBadge(path: c.path) }
                        cell(100) { Text(carrier(c)).foregroundStyle(.secondary).lineLimit(1) }
                        cell(68, .trailing) { Text(Fmt.bytes(c.download)).monospacedDigit().liveNumber(c.download) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { if let p = c.appPath, AppPath.isValid(p) { detailApp = AppInfo(path: p, name: c.appName, uses: 0) } }
                    .contextMenu { ConnectionContextMenu(appPath: c.appPath, appName: c.appName, host: c.host) }
                }
            }
        }
    }

    private func carrier(_ c: LiveConnection) -> String {
        switch c.carrier {
        case "via-happ": return model.settings.vpnServiceName ?? "VPN"
        case let s?: return ServerStore.outbounds(model.servers).first { $0.tag == s }?.entry.name ?? s
        default: return c.path == .direct ? "провайдер" : "—"
        }
    }

    // MARK: site checks (the racer's log)

    private var events: [RouteEvent] {
        let list = model.events.filter { query.isEmpty || $0.host.localizedCaseInsensitiveContains(query) }
        switch eventSort.key {
        case "host": return ordered(list, eventSort) { $0.host.lowercased() }
        case "result": return ordered(list, eventSort) { $0.route }
        case "ms": return ordered(list, eventSort) { $0.ms }
        case "why": return ordered(list, eventSort) { reason($0) }
        default: return ordered(list, eventSort) { $0.time }
        }
    }

    @ViewBuilder private var checks: some View {
        if events.isEmpty {
            EmptyState(symbol: "clock.arrow.circlepath", title: "Пока пусто", text: "Когда вы откроете незнакомый сайт, здесь появится, каким путём он открылся.")
        } else {
            VStack(spacing: 0) {
                head([("Время", "time", 70, .leading), ("Сайт", "host", nil, .leading), ("Результат", "result", 96, .leading), ("Заняло", "ms", 60, .trailing), ("Почему", "why", 170, .leading)], sort: $eventSort)
                tableRows(events) { e in
                    HStack(spacing: 10) {
                        cell(70) { Text(e.time.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary).monospacedDigit() }
                        cell(nil) { HStack(spacing: 5) { if e.note.contains("выучено") { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }; Text(e.host).lineLimit(1).truncationMode(.middle) } }
                        cell(96) { RouteBadge(route: e.route) }
                        cell(60, .trailing) { Text("\(e.ms) мс").foregroundStyle(.secondary).monospacedDigit() }
                        cell(170) { Text(reason(e)).foregroundStyle(.secondary).lineLimit(1).help(e.note) }
                    }
                }
            }
        }
    }

    private func reason(_ e: RouteEvent) -> String {
        switch e.source {
        case "manual": return "ваше правило или сценарий"
        case "learned": return "выучено раньше"
        case "starter": return "встроенная подсказка"
        case "local": return "локальная сеть"
        default: return e.note.isEmpty ? "проверка" : e.note.replacingOccurrences(of: "гонка: ", with: "")
        }
    }
}

/// Bottom summary, like the pane at the bottom of Activity Monitor.
struct SummaryStrip: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let t = model.traffic
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("ТРАФИК").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                if model.history.count > 2 { TrafficChart(points: model.history, height: 42) } else { Color.clear.frame(height: 42) }
            }
            .frame(width: 170)
            Divider().frame(height: 44)
            stat("Через VPN", Fmt.bytes(t.total.vpn), .wpVPN)
            stat("Напрямую", Fmt.bytes(t.total.direct), .wpDirect)
            Divider().frame(height: 44)
            stat("Сейчас ↓", Fmt.rate(t.downRate), nil)
            stat("Сейчас ↑", Fmt.rate(t.upRate), nil)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func stat(_ label: String, _ value: String, _ dot: Color?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 14, weight: .semibold)).monospacedDigit().liveNumber(value)
        }
    }
}

/// Which column a table is sorted by, and in which direction (click a header to change).
struct SortState: Equatable {
    var key: String
    var ascending: Bool
}
