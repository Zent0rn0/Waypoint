import SwiftUI
import AppKit
import Charts
import WaypointCore

// Waypoint follows the macOS system look (System Settings, Home, App Store, Activity Monitor):
// one header card per page, grouped rows with colored icon tiles, status lines with a colored dot,
// a fixed-width content column, and exactly one vivid element per page.

enum Metrics {
    static let column: CGFloat = 628         // content width in the 900 pt window (20 pt margins), used by previews
    static let maxColumn: CGFloat = 760      // upper bound when the window is made wider (tiling, full-screen apps)
    static let groupRadius: CGFloat = 20       // grouped rows, tables
    static let cardRadius: CGFloat = 30       // hero and page headers
    static let tileRadius: CGFloat = 22       // tiles, tray modules, summary strips
    static let rowInset: CGFloat = 12
    static let tile: CGFloat = 26
    static var separatorInset: CGFloat { rowInset + tile + 10 }
}

// MARK: - Formatting

enum Fmt {
    private static let formatter: ByteCountFormatter = { let f = ByteCountFormatter(); f.countStyle = .file; f.allowsNonnumericFormatting = false; return f }()
    static func bytes(_ n: UInt64) -> String { formatter.string(fromByteCount: Int64(n)) }
    static func rate(_ bps: Double) -> String { formatter.string(fromByteCount: Int64(bps)) + "/с" }
    static func age(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "\(s) с" }
        if s < 3600 { return "\(s / 60) мин" }
        return "\(s / 3600) ч"
    }
    static let day: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMM, HH:mm"; return f }()
}

// MARK: - Palette

extension Color {
    static let wpGood = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let wpVPN = Color(red: 0.04, green: 0.52, blue: 1.00)
    static let wpDirect = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let wpWarn = Color(red: 1.00, green: 0.62, blue: 0.04)
    static let wpBad = Color(red: 1.00, green: 0.27, blue: 0.23)

    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    /// Fill of grouped rows: slightly lighter than the window in dark mode, white in light mode.
    static let groupFill = dynamic(dark: NSColor.white.withAlphaComponent(0.055), light: NSColor.white.withAlphaComponent(0.9))
    static let groupStroke = dynamic(dark: NSColor.white.withAlphaComponent(0.05), light: NSColor.black.withAlphaComponent(0.07))
}

extension View {
    /// Every grouped surface is Liquid Glass on macOS 26+, and the classic grouped fill before that.
    func groupBackground(radius: CGFloat = Metrics.groupRadius) -> some View { glassSurface(radius: radius) }

    @ViewBuilder
    func glassSurface(radius: CGFloat = Metrics.groupRadius, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else if let tint {
            self.background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(tint.gradient))
        } else {
            self.background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.groupFill))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.groupStroke))
        }
    }

    /// The most transparent glass (macOS 26 «clear»): for big surfaces like the sidebar that should let the backdrop show.
    @ViewBuilder
    func clearGlass(radius: CGFloat) -> some View {
        if #available(macOS 26.0, *) { self.glassEffect(Glass.clear, in: RoundedRectangle(cornerRadius: radius, style: .continuous)) }
        else { self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous)) }
    }

    @ViewBuilder
    func glassCapsule(tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) { self.glassEffect(Glass.regular.tint(tint), in: Capsule()) }
        else { self.background(.regularMaterial, in: Capsule()) }
    }

    /// Glass buttons (`.glass` / `.glassProminent`) on macOS 26+, bordered before that.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }

    /// The one button of the app: a capsule (soft fill, or the tint color when prominent). Buttons, pop-up menus, segmented
    /// controls and fields all share this shape, so nothing on a page looks like a leftover system control.
    func contentButton(prominent: Bool) -> some View { buttonStyle(CapsuleButtonStyle(prominent: prominent)) }
    /// Controls inside rows: small (prominent for the main action).
    func rowControl(prominent: Bool = false) -> some View { contentButton(prominent: prominent).controlSize(.small) }
    /// Controls in bars (add rows, page actions, sheets): regular size.
    func barControl(prominent: Bool = false) -> some View { contentButton(prominent: prominent).controlSize(.regular) }
    func fieldBox(height: CGFloat = 28) -> some View { modifier(FieldBox(height: height)) }

    /// Groups nearby glass shapes so they are sampled together and can blend (macOS 26+).
    @ViewBuilder
    func glassGroup(spacing: CGFloat = 0) -> some View {   // 0: neighbouring cards stay separate, no melting
        if #available(macOS 26.0, *) { GlassEffectContainer(spacing: spacing) { self } } else { self }
    }
}

// MARK: - Page scaffolding

/// Scroll view with the fixed-width content column.
struct Page<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) { content }
                .glassGroup()
                .frame(maxWidth: Metrics.maxColumn, alignment: .leading)   // fills the 900 pt window; grows a little if the window is tiled wider
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
        }
        // Rows fade out at the top (under the back/forward bar) and at the bottom instead of being cut off by a hard edge.
        .mask(
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 22)
                Rectangle().fill(.black)
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 30)
            }
        )
    }
}

/// Page header with the same composition as the Overview hero (tile · title · one sentence · ⓘ),
/// so every page opens the same way: neutral glass, the page color lives only in the glyph.
struct PageHeader<Accessory: View>: View {
    let screen: Screen
    var compact = false
    @ViewBuilder var accessory: Accessory
    var body: some View {
        HStack(alignment: .center, spacing: compact ? 12 : 16) {
            IconTile(symbol: screen.symbol, color: screen.color, size: compact ? 40 : 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(screen.title).font(.system(size: compact ? 19 : 22, weight: .bold))
                Text(screen.subtitle).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(compact ? 1 : 3).fixedSize(horizontal: false, vertical: !compact)
            }
            Spacer(minLength: 12)
            accessory
            HeaderInfoButton(title: screen.title, text: screen.help)
        }
        .padding(compact ? 14 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(radius: Metrics.cardRadius)
    }
}

extension PageHeader where Accessory == EmptyView {
    init(screen: Screen, compact: Bool = false) { self.init(screen: screen, compact: compact, accessory: { EmptyView() }) }
}

/// ⓘ everywhere (page headers and rows): the same small round button that opens the same bubble.
struct InfoButton: View {
    let title: String
    let text: String
    var size: CGFloat = 22
    var edge: Edge = .bottom
    @State private var shown = false
    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info").font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.primary.opacity(0.10)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.10)))
        }
        .buttonStyle(.plain).help("Подробнее")
        .popover(isPresented: $shown, arrowEdge: edge) { HelpBubble(title: title, text: text) }
    }
}
typealias HeaderInfoButton = InfoButton

struct HelpBubble: View {
    let title: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(width: 330, alignment: .leading)
    }
}

// MARK: - Groups and rows

/// A titled group of rows (the rounded blocks of System Settings).
struct Panel<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title { Text(title).font(.headline).padding(.leading, 4) }
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .groupBackground()
            if let footer { Text(footer).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct RowSeparator: View {
    var inset: CGFloat = Metrics.separatorInset
    var body: some View { Divider().padding(.leading, inset) }
}

/// Wraps a collection so rows can be rendered with separators between them.
struct Indexed<T>: Identifiable {
    let index: Int
    let value: T
    let id: AnyHashable
}
extension RandomAccessCollection {
    func indexed<ID: Hashable>(by key: (Element) -> ID) -> [Indexed<Element>] {
        enumerated().map { Indexed(index: $0.offset, value: $0.element, id: AnyHashable(key($0.element))) }
    }
}

/// Status line under a row title: «● Подключено».
struct StatusLine: View {
    let text: String
    var dot: Color? = nil
    var body: some View {
        HStack(spacing: 5) {
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

/// Standard row: icon · title (+ status) · trailing control.
struct Row<Icon: View, Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var dot: Color? = nil
    @ViewBuilder var icon: Icon
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                if let subtitle { StatusLine(text: subtitle, dot: dot) }
            }
            Spacer(minLength: 10)
            trailing
        }
        .padding(.horizontal, Metrics.rowInset)
        .frame(minHeight: subtitle == nil ? 42 : 52)
    }
}

extension Row where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, dot: Color? = nil, @ViewBuilder icon: () -> Icon) {
        self.init(title: title, subtitle: subtitle, dot: dot, icon: icon, trailing: { EmptyView() })
    }
}

/// A row that navigates somewhere (chevron at the end, whole row clickable).
struct LinkRow<Icon: View>: View {
    let title: String
    var subtitle: String? = nil
    var dot: Color? = nil
    var value: String? = nil
    let action: () -> Void
    @ViewBuilder var icon: Icon
    var body: some View {
        Button(action: action) {
            Row(title: title, subtitle: subtitle, dot: dot, icon: { icon }) {
                if let value { Text(value).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Icons

/// Colored glyph without a plate behind it (the plate made every list a wall of little colored squares).
/// `size` is the box it occupies, so rows keep their rhythm; the glyph itself fills about two thirds of it.
struct IconTile: View {
    let symbol: String
    var color: Color = .accentColor
    var size: CGFloat = Metrics.tile
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.68, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Self.lifted(color))
            .frame(width: size, height: size)
    }
    /// Deep system colors (blue, indigo, purple) sink into a dark background; lift them a little toward white.
    static func lifted(_ c: Color) -> Color {
        if #available(macOS 15.0, *) { return c.mix(with: .white, by: 0.18) }
        return c
    }
}

/// The app's own mark: the signpost glyph in the icon's blue→violet gradient, no plate.
/// (macOS puts a system plate under any app icon image it is asked for, so the UI draws the mark itself.)
struct BrandMark: View {
    var size: CGFloat = 34
    var body: some View {
        Image(systemName: "signpost.right.and.left.fill")
            .font(.system(size: size * 0.9, weight: .semibold))
            .foregroundStyle(LinearGradient(colors: [Color(red: 0.30, green: 0.56, blue: 1.0), Color(red: 0.58, green: 0.36, blue: 1.0)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .frame(width: size, height: size)
    }
}

/// Emoji flag on its own, no plate.
struct EmojiTile: View {
    let emoji: String
    var size: CGFloat = Metrics.tile
    var body: some View {
        Text(emoji).font(.system(size: size * 0.74)).frame(width: size, height: size)
    }
}

struct AppIcon: View {
    let path: String?
    var size: CGFloat = Metrics.tile

    /// Only real application bundles with their own icon; helper bundles without one would show a blank white document.
    static func hasOwnIcon(_ path: String) -> Bool {
        guard path.hasSuffix(".app"), let b = Bundle(path: path) else { return false }
        return b.object(forInfoDictionaryKey: "CFBundleIconFile") != nil || b.object(forInfoDictionaryKey: "CFBundleIconName") != nil
    }
    var body: some View {
        if let path, Self.hasOwnIcon(path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().interpolation(.high).frame(width: size, height: size)
        } else if let path, path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/") {
            IconTile(symbol: "gearshape.2.fill", color: Color(white: 0.45), size: size * 0.92).frame(width: size, height: size)   // system service
        } else {
            IconTile(symbol: path == nil ? "gearshape.fill" : "terminal.fill", color: Color(white: 0.3), size: size * 0.92).frame(width: size, height: size)   // command-line tool
        }
    }
}

// MARK: - Small pieces

struct StatusDot: View {
    let color: Color
    var pulse = false
    @State private var on = false
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .overlay(Circle().stroke(color.opacity(0.45), lineWidth: 4).scaleEffect(pulse && on ? 1.9 : 1).opacity(pulse && on ? 0 : 1))
            .onAppear { if pulse { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { on = true } } }
    }
}

struct Pill: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct PathBadge: View {
    let path: LiveConnection.Path
    var body: some View {
        switch path {
        case .direct: Pill(text: "Напрямую", color: .wpDirect)
        case .vpn: Pill(text: "VPN", color: .wpVPN)
        case .race: Pill(text: "Проверка", color: .wpWarn)
        case .blocked: Pill(text: "Блок", color: .gray)
        case .unknown: Pill(text: "—", color: .gray)
        }
    }
}

struct RouteBadge: View {
    let route: String
    var body: some View {
        switch route {
        case "vpn": Pill(text: "VPN", color: .wpVPN)
        case "direct": Pill(text: "Напрямую", color: .wpDirect)
        case "block": Pill(text: "Блок", color: .gray)
        default: Pill(text: "Не открылся", color: .wpBad)
        }
    }
}

extension Route {
    var title: String { switch self { case .vpn: "Через VPN"; case .direct: "Напрямую"; case .block: "Блокировать" } }
    var color: Color { switch self { case .vpn: .wpVPN; case .direct: .wpDirect; case .block: .gray } }
}

/// The one pop-up control of the app: a glass button that opens a menu with checkmarks.
/// Used for every choice in rows (route, VPN client, region…), so pop-ups look the same on every page.
struct ChoiceMenu<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, title: String)]
    var separatorAfterFirst = false
    var size: ControlSize = .small
    var body: some View {
        Menu {
            Picker("", selection: $selection) {
                ForEach(options.indices, id: \.self) { i in
                    Text(options[i].title).tag(options[i].value)
                    if separatorAfterFirst && i == 0 { Divider() }
                }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            PillMenuLabel(text: options.first { $0.value == selection }?.title ?? "—", size: size)
        }
        .pillMenu(size: size)
    }
}

/// What every pop-up menu looks like closed: text plus a small up/down chevron (the capsule is drawn around the Menu by `pillMenu`,
/// because a menu style drops backgrounds applied to its label).
struct PillMenuLabel: View {
    let text: String
    var size: ControlSize = .small
    var body: some View {
        HStack(spacing: 5) {
            Text(text).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
        }
    }
}

extension View {
    func pillMenu(size: ControlSize) -> some View {
        menuStyle(.borderlessButton).menuIndicator(.hidden).buttonStyle(.plain)
            .modifier(CapsuleLook(size: size, prominent: false, pressed: false)).fixedSize()
    }
}

/// Route choice used in lists (services, applications, sites).
struct RouteMenu: View {
    @Binding var selection: Route?
    var allowAuto = true
    var body: some View {
        ChoiceMenu(selection: Binding<Int>(
            get: { switch selection { case nil: 0; case .vpn?: 1; case .direct?: 2; case .block?: 3 } },
            set: { selection = [nil, .vpn, .direct, .block][$0] }),
                   options: (allowAuto ? [(0, "Авто")] : []) + [(1, "Через VPN"), (2, "Напрямую"), (3, "Блокировать")],
                   separatorAfterFirst: allowAuto)
    }
}

/// Text input inside a group: plain field on a soft fill (a bordered field would sit on the glass as an opaque slab).
struct FieldBox: ViewModifier {
    var height: CGFloat = 28
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain)
            .padding(.horizontal, 12).frame(height: height)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.09)))
    }
}

/// Standalone search: a glass capsule, like the search fields of Music and App Store.
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).frame(height: 32)
        .background(Color.primary.opacity(0.07), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.09)))
    }
}

// MARK: - Capsule controls

/// Shared look of buttons and pop-up labels. Height follows the control size (small in rows, regular in bars and sheets).
struct CapsuleLook: ViewModifier {
    var size: ControlSize
    var prominent: Bool
    var pressed: Bool
    @Environment(\.isEnabled) private var enabled
    func body(content: Content) -> some View {
        let small = size == .small || size == .mini
        content
            .font(.system(size: small ? 12 : 13.5, weight: .medium))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, small ? 11 : 16).frame(height: small ? 24 : 30)
            .background(Capsule().fill(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(pressed ? 0.20 : 0.11))))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(prominent ? 0 : 0.10)))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

struct CapsuleButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.controlSize) private var controlSize
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(CapsuleLook(size: controlSize, prominent: prominent, pressed: configuration.isPressed))
            .opacity(configuration.isPressed && prominent ? 0.85 : 1)
    }
}

/// Segmented choice in the same capsule language (replaces the system segmented control).
struct SegmentedPills<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, title: String)]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let on = options[i].value == selection
                Button { withAnimation(.snappy(duration: 0.18)) { selection = options[i].value } } label: {
                    Text(options[i].title).font(.system(size: 12.5, weight: on ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .padding(.horizontal, 6).frame(height: 26).frame(maxWidth: .infinity)
                        .background(Capsule().fill(on ? Color.primary.opacity(0.16) : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.09)))
    }
}

/// Segmented route choice (menu bar: few rows, the choice is the main action).
struct RoutePicker: View {
    @Binding var selection: Route?
    var body: some View {
        SegmentedPills(selection: Binding<Int>(
            get: { switch selection { case nil: 0; case .vpn?: 1; case .direct?: 2; case .block?: 3 } },
            set: { selection = [nil, .vpn, .direct, .block][$0] }),
                       options: [(0, "Авто"), (1, "VPN"), (2, "Напрямую"), (3, "Блок")])
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 36, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }
}

// MARK: - Charts

struct TrafficPoint: Identifiable { let id = UUID(); let t: Date; let up: Double; let down: Double }

struct TrafficChart: View {
    let points: [TrafficPoint]
    var height: CGFloat = 70
    var axis = false
    var body: some View {
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("t", p.t), y: .value("↓", p.down), series: .value("s", "down"))
                    .foregroundStyle(LinearGradient(colors: [Color.wpVPN.opacity(0.35), Color.wpVPN.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", p.t), y: .value("↓", p.down), series: .value("s", "down")).foregroundStyle(Color.wpVPN).interpolationMethod(.monotone)
                LineMark(x: .value("t", p.t), y: .value("↑", p.up), series: .value("s", "up")).foregroundStyle(Color.wpDirect.opacity(0.85)).interpolationMethod(.monotone)
            }
        }
        .chartYAxis { if axis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.rate(d)).font(.caption2) } } } } }
        .chartXAxis(.hidden)
        .frame(height: height)
    }
}

/// Share of bytes per path as one thin bar.
struct SplitBar: View {
    let direct: UInt64
    let vpn: UInt64
    var body: some View {
        let total = Double(max(direct + vpn, 1))
        GeometryReader { g in
            HStack(spacing: 2) {
                Capsule().fill(Color.wpDirect).frame(width: max(4, (g.size.width - 2) * Double(direct) / total))
                Capsule().fill(Color.wpVPN)
            }
        }
        .frame(height: 6)
    }
}


// MARK: - Ambient backdrop

/// Window background: graphite and charcoal melting into each other, drawn as a slowly drifting mesh (a few minutes per loop, barely noticeable),
/// plus one faint diagonal band of light. It is quiet on purpose — the glass on top is the subject — and it no longer
/// follows the app's state: state is shown by the hero badge and the dots, not by tinting the whole window.
struct AmbientBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Group {
            if #available(macOS 15.0, *) { MeshBackdrop(dark: scheme == .dark) }
            else { LinearGradient(colors: scheme == .dark ? [Color(white: 0.03), Color(white: 0.09)]
                                                         : [Color(white: 0.93), Color(white: 0.88)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing) }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

@available(macOS 15.0, *)
private struct MeshBackdrop: View {
    let dark: Bool

    private func c(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }
    private var colors: [Color] {
        // graphite and charcoal with the faintest cool-green cast: no blue, no violet
        dark ? [c(0.02, 0.02, 0.02), c(0.06, 0.06, 0.07), c(0.04, 0.05, 0.05),
                c(0.05, 0.06, 0.06), c(0.09, 0.10, 0.10), c(0.05, 0.07, 0.06),
                c(0.03, 0.03, 0.04), c(0.02, 0.02, 0.03), c(0.06, 0.07, 0.07)]
             : [c(0.93, 0.93, 0.94), c(0.90, 0.91, 0.91), c(0.92, 0.93, 0.93),
                c(0.91, 0.92, 0.92), c(0.88, 0.89, 0.90), c(0.90, 0.92, 0.91),
                c(0.94, 0.94, 0.95), c(0.91, 0.92, 0.92), c(0.89, 0.91, 0.91)]
    }

    /// A mesh point drifting slowly around its resting place.
    private func p(_ t: Double, _ x: Double, _ y: Double, _ ax: Double, _ ay: Double, _ ph: Double) -> SIMD2<Float> {
        SIMD2(Float(x + ax * sin(t + ph)), Float(y + ay * cos(t * 0.8 + ph)))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate / 16
            GeometryReader { g in
                ZStack {
                    MeshGradient(width: 3, height: 3, points: [
                        SIMD2(0, 0), p(t, 0.5, 0, 0.10, 0, 0.0), SIMD2(1, 0),
                        p(t, 0, 0.5, 0, 0.12, 1.7), p(t, 0.5, 0.5, 0.16, 0.16, 3.1), p(t, 1, 0.5, 0, 0.12, 4.4),
                        SIMD2(0, 1), p(t, 0.5, 1, 0.10, 0, 2.3), SIMD2(1, 1),
                    ], colors: colors, smoothsColors: true)
                    // one faint diagonal band of light, drifting across
                    RoundedRectangle(cornerRadius: 60)
                        .fill(LinearGradient(colors: [.clear, Color.white.opacity(dark ? 0.05 : 0.30),
                                                       Color(red: 0.55, green: 0.75, blue: 0.70).opacity(dark ? 0.04 : 0.10), .clear],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: g.size.width * 1.8, height: 110)
                        .rotationEffect(.degrees(-28))
                        .offset(x: CGFloat(sin(t * 0.6)) * g.size.width * 0.08, y: CGFloat(cos(t * 0.5)) * g.size.height * 0.10 + g.size.height * 0.05)
                        .blur(radius: 46)
                    // vignette: the edges sink into black, the glass sits on a darker field
                    RadialGradient(colors: [.clear, .black.opacity(dark ? 0.5 : 0.06)], center: .center,
                                   startRadius: min(g.size.width, g.size.height) * 0.30, endRadius: max(g.size.width, g.size.height) * 0.75)
                }
                .frame(width: g.size.width, height: g.size.height)
                .clipped()
            }
        }
    }
}
