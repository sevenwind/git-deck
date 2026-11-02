import SwiftUI

// MARK: - Разбор файла с маркерами конфликта

enum ConflictSide { case ours, theirs }

/// Ссылка на одну строку одной из сторон конфликта.
struct LineRef: Hashable {
    let side: ConflictSide
    let index: Int
}

struct ConflictBlock {
    var ours: [String]
    var theirs: [String]
    var oursLabel: String
    var theirsLabel: String

    func lines(_ side: ConflictSide) -> [String] { side == .ours ? ours : theirs }
    func refs(_ side: ConflictSide) -> [LineRef] { lines(side).indices.map { LineRef(side: side, index: $0) } }
    func text(_ r: LineRef) -> String { lines(r.side)[r.index] }
}

enum ConflictSegment {
    case text([String])
    case block(Int)
}

struct ConflictDoc {
    var segments: [ConflictSegment] = []
    var blocks: [ConflictBlock] = []
    var endsWithNewline = true

    /// nil, если в тексте нет ни одного корректного блока конфликта.
    static func parse(_ s: String) -> ConflictDoc? {
        var doc = ConflictDoc()
        doc.endsWithNewline = s.hasSuffix("\n")
        var lines = s.components(separatedBy: "\n")
        if doc.endsWithNewline { lines.removeLast() }

        enum Mode { case text, ours, base, theirs }
        var mode = Mode.text
        var text: [String] = []
        var cur = ConflictBlock(ours: [], theirs: [], oursLabel: "", theirsLabel: "")

        func label(_ l: String, _ marker: String) -> String {
            l.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        }

        for l in lines {
            switch mode {
            case .text:
                if l.hasPrefix("<<<<<<<") {
                    if !text.isEmpty { doc.segments.append(.text(text)); text = [] }
                    cur = ConflictBlock(ours: [], theirs: [], oursLabel: label(l, "<<<<<<<"), theirsLabel: "")
                    mode = .ours
                } else { text.append(l) }
            case .ours:
                if l.hasPrefix("|||||||") { mode = .base }
                else if l.hasPrefix("=======") { mode = .theirs }
                else { cur.ours.append(l) }
            case .base:
                if l.hasPrefix("=======") { mode = .theirs }
            case .theirs:
                if l.hasPrefix(">>>>>>>") {
                    cur.theirsLabel = label(l, ">>>>>>>")
                    doc.blocks.append(cur)
                    doc.segments.append(.block(doc.blocks.count - 1))
                    mode = .text
                } else { cur.theirs.append(l) }
            }
        }
        // Незакрытый блок — файл повреждён, ручной режим не применим.
        guard mode == .text, !doc.blocks.isEmpty else { return nil }
        if !text.isEmpty { doc.segments.append(.text(text)) }
        return doc
    }

    /// Собирает итоговый файл: для каждого блока — выбранные строки в порядке выбора.
    func render(_ choices: [Int: [LineRef]]) -> String {
        var out: [String] = []
        for seg in segments {
            switch seg {
            case .text(let t): out += t
            case .block(let i): out += (choices[i] ?? []).map { blocks[i].text($0) }
            }
        }
        return out.joined(separator: "\n") + (endsWithNewline && !out.isEmpty ? "\n" : "")
    }
}

// MARK: - Экран разрешения конфликта

struct ConflictResolverView: View {
    @ObservedObject var model: RepoModel
    let file: FileEntry

    @Local private var doc: ConflictDoc?
    /// Выбранные строки по блокам; порядок в массиве = порядок кликов. [] — «оставить пусто».
    @Local private var choices: [Int: [LineRef]] = [:]
    @Local private var loadError: String?

    private var allResolved: Bool {
        guard let doc else { return false }
        return doc.blocks.indices.allSatisfy { choices[$0] != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: file.path) { await load() }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 8) {
            Text(file.path).font(.headline).lineLimit(1).truncationMode(.middle)
            Text("конфликт").font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.red.opacity(0.25)))
            Spacer()
            Menu {
                Button("Весь файл: текущая версия") { Task { await model.resolve(file, side: "ours") } }
                Button("Весь файл: входящая версия") { Task { await model.resolve(file, side: "theirs") } }
            } label: { Label("Весь файл", systemImage: "doc") }
                .fixedSize()
                .help("Взять целиком одну из версий файла и добавить его в индекс")
            if let doc {
                Button {
                    for i in doc.blocks.indices { choices[i] = doc.blocks[i].refs(.ours) }
                } label: { Text("Все блоки: текущие") }
                    .help("В каждом блоке выбрать текущую версию (файл пока не записывается)")
                Button {
                    for i in doc.blocks.indices { choices[i] = doc.blocks[i].refs(.theirs) }
                } label: { Text("Все блоки: входящие") }
                    .help("В каждом блоке выбрать входящую версию (файл пока не записывается)")
                Button { Task { await apply(doc) } } label: { Label("Применить", systemImage: "checkmark.circle.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!allResolved || model.busy)
                    .help(allResolved ? "Записать файл и добавить его в индекс" : "Сначала решите все блоки конфликта")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    // MARK: content

    @ViewBuilder private var content: some View {
        if let doc {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text("Решено блоков: \(choices.count) из \(doc.blocks.count). Нажимайте на строки или на заголовок стороны — строки попадут в результат в том порядке, в каком вы их выбрали.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.top, 8)
                    ForEach(Array(doc.segments.enumerated()), id: \.offset) { _, seg in
                        switch seg {
                        case .text(let t): ContextLines(lines: t)
                        case .block(let i): blockView(i, doc.blocks[i], total: doc.blocks.count)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else if let loadError {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 30)).foregroundStyle(.orange)
                Text(loadError).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Text("Выберите версию всего файла в меню «Весь файл» или отредактируйте его вручную и отметьте как решённый.")
                    .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func blockView(_ i: Int, _ b: ConflictBlock, total: Int) -> some View {
        let chosen = choices[i]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: chosen == nil ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(chosen == nil ? Color.orange : Color.green)
                Text("Конфликт \(i + 1) из \(total)").bold()
                Spacer()
                Button("Текущая") { choices[i] = b.refs(.ours) }
                Button("Входящая") { choices[i] = b.refs(.theirs) }
                Button("Обе: текущая → входящая") { choices[i] = b.refs(.ours) + b.refs(.theirs) }
                Button("Обе: входящая → текущая") { choices[i] = b.refs(.theirs) + b.refs(.ours) }
                Button("Пусто") { choices[i] = [] }
                Button { choices[i] = nil } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Сбросить выбор в этом блоке").disabled(chosen == nil)
            }
            .controlSize(.small)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.red.opacity(0.10))

            sideView(i, b, .ours, color: .blue)
            sideView(i, b, .theirs, color: .green)

            VStack(alignment: .leading, spacing: 0) {
                Text("Результат").font(.caption.bold()).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                if let chosen {
                    if chosen.isEmpty {
                        Text("(пусто — блок будет удалён)").font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 4)
                    }
                    ForEach(Array(chosen.enumerated()), id: \.offset) { _, r in
                        codeLine(b.text(r), bg: Color.primary.opacity(0.06))
                    }
                } else {
                    Text("Выберите строки выше").font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.bottom, 4)
                }
            }
            .background(Color.secondary.opacity(0.08))
        }
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.red.opacity(0.35)))
        .padding(.horizontal, 10)
    }

    private func sideView(_ i: Int, _ b: ConflictBlock, _ side: ConflictSide, color: Color) -> some View {
        let refs = b.refs(side)
        let selected = choices[i] ?? []
        let allOn = !refs.isEmpty && refs.allSatisfy(selected.contains)
        let title = side == .ours ? "Текущая" : "Входящая"
        let label = side == .ours ? b.oursLabel : b.theirsLabel
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                var cur = choices[i] ?? []
                if allOn { cur.removeAll { $0.side == side } }
                else { cur += refs.filter { !cur.contains($0) } }
                choices[i] = cur
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: allOn ? "checkmark.square.fill" : "square").foregroundStyle(color)
                    Text(label.isEmpty ? title : "\(title) · \(label)").font(.caption.bold()).foregroundStyle(color)
                    if refs.isEmpty { Text("(пусто)").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 8).padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .background(color.opacity(0.10))
            ForEach(refs, id: \.self) { r in
                let order = selected.firstIndex(of: r)
                Button {
                    var cur = choices[i] ?? []
                    if let k = cur.firstIndex(of: r) { cur.remove(at: k) } else { cur.append(r) }
                    choices[i] = cur
                } label: {
                    HStack(spacing: 6) {
                        ZStack {
                            Circle().stroke(color.opacity(0.6), lineWidth: 1).frame(width: 16, height: 16)
                            if let order {
                                Circle().fill(color).frame(width: 16, height: 16)
                                Text("\(order + 1)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            }
                        }
                        Text(b.text(r).isEmpty ? " " : b.text(r))
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 8).padding(.vertical, 1)
                    .background(order != nil ? color.opacity(0.18) : color.opacity(0.05))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func codeLine(_ s: String, bg: Color) -> some View {
        Text(s.isEmpty ? " " : s)
            .font(.system(size: 12, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .background(bg)
    }

    // MARK: действия

    private func load() async {
        doc = nil; loadError = nil; choices = [:]
        let url = URL(fileURLWithPath: model.path).appendingPathComponent(file.path)
        guard let data = try? Data(contentsOf: url) else {
            loadError = "Не удалось прочитать файл (возможно, он удалён с одной из сторон)."
            return
        }
        guard let s = String(data: data, encoding: .utf8) else {
            loadError = "Файл не в кодировке UTF-8 или бинарный."
            return
        }
        guard let d = ConflictDoc.parse(s) else {
            loadError = "В файле нет маркеров конфликта (<<<<<<<, =======, >>>>>>>) или они повреждены."
            return
        }
        doc = d
    }

    private func apply(_ doc: ConflictDoc) async {
        let url = URL(fileURLWithPath: model.path).appendingPathComponent(file.path)
        do {
            // Запись «на месте», чтобы сохранить права доступа файла.
            try Data(doc.render(choices).utf8).write(to: url)
        } catch {
            model.show("Конфликт: ошибка", error.localizedDescription, error: true)
            return
        }
        await model.resolve(file, side: nil)
    }
}

/// Нейтральные строки между блоками конфликта; длинные участки сворачиваются.
private struct ContextLines: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if lines.count > 8 {
                ForEach(Array(lines.prefix(3).enumerated()), id: \.offset) { _, l in row(l) }
                Text("··· скрыто строк: \(lines.count - 6) ···")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity).padding(.vertical, 2)
                ForEach(Array(lines.suffix(3).enumerated()), id: \.offset) { _, l in row(l) }
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in row(l) }
            }
        }
    }
    private func row(_ l: String) -> some View {
        Text(l.isEmpty ? " " : l)
            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18)
    }
}
