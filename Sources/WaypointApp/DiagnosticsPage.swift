import SwiftUI
import AppKit
import WaypointCore

struct DiagnosticsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Page {
            PageHeader(screen: .diagnostics)
            Panel {
                let (text, color) = summary
                Row(title: text, subtitle: model.diagAt.map { "Проверено в \($0.formatted(date: .omitted, time: .shortened))" } ?? "Займёт около 20 секунд", dot: color) {
                    IconTile(symbol: model.diagRunning ? "ellipsis" : "stethoscope", color: color)
                } trailing: {
                    if model.diagRunning { ProgressView().controlSize(.small) }
                    Button(model.diag.isEmpty ? "Проверить" : "Проверить снова") { model.runDiagnostics() }.rowControl(prominent: true).disabled(model.diagRunning)
                }
            }
            if !model.diag.isEmpty {
                Panel(title: "Результаты") {
                    ForEach(model.diag.indexed(by: \.id)) { item in
                        if item.index > 0 { RowSeparator() }
                        DiagRow(check: item.value)
                    }
                }
                HStack {
                    Spacer()
                    Button("Скопировать отчёт") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.diagnosticsReport, forType: .string); model.flash("Отчёт скопирован")
                    }
                    .barControl().disabled(model.diagRunning)
                }
            }
        }
        .onAppear { if model.diag.isEmpty && !model.diagRunning { model.runDiagnostics() } }
    }

    private var summary: (String, Color) {
        if model.diagRunning { return ("Идёт проверка…", .gray) }
        if model.diag.isEmpty { return ("Ещё не проверялось", .gray) }
        let bad = model.diag.filter { $0.status == .fail }.count, warn = model.diag.filter { $0.status == .warn }.count
        if bad > 0 { return ("Найдены проблемы: \(bad)", .wpBad) }
        if warn > 0 { return ("Всё работает, есть советы: \(warn)", .wpWarn) }
        return ("Всё в порядке", .wpGood)
    }
}

struct DiagRow: View {
    @Environment(AppModel.self) private var model
    let check: DiagCheck

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(color).frame(width: Metrics.tile, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(check.title).fontWeight(.medium)
                Text(check.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if let h = check.hint { Text(h).font(.callout).foregroundStyle(color).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            switch check.fix {
            case .startVPN: Button("Подключить VPN") { Task { await model.ensureVPN() } }.rowControl(prominent: true)
            case .installDaemon: Button("Установить") { model.installDaemon() }.rowControl(prominent: true)
            case .enableTunnel: Button("Включить") { model.setTunnel(true) }.rowControl(prominent: true)
            default: EmptyView()
            }
        }
        .padding(.horizontal, Metrics.rowInset).padding(.vertical, 10)
    }

    private var symbol: String {
        switch check.status { case .ok: "checkmark.circle.fill"; case .warn: "exclamationmark.triangle.fill"; case .fail: "xmark.octagon.fill"; case .skip: "minus.circle"; case .running: "ellipsis.circle" }
    }
    private var color: Color {
        switch check.status { case .ok: .wpGood; case .warn: .wpWarn; case .fail: .wpBad; default: .secondary }
    }
}
