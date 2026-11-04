import SwiftUI

/// Одна строка графа: какие линии пересекают строку и где стоит точка коммита.
struct GraphRow {
    struct Edge { var from: Int; var to: Int; var color: Int }   // from — колонка сверху, to — снизу
    var column: Int
    var color: Int
    var width: Int
    var incoming: [Edge]    // от верхней границы строки к центру (to == column) и сквозные линии
    var outgoing: [Edge]    // от центра (from == column) к нижней границе
    var through: [Edge]     // сквозные вертикали (from == to)
}

enum GraphLayout {
    private struct Lane: Equatable { var hash: String; var color: Int }

    /// Раскладка по «дорожкам». Коммиты должны идти от новых к старым (родитель после ребёнка).
    static func build(_ commits: [Commit]) -> [GraphRow] {
        var lanes: [Lane?] = []
        var nextColor = 0
        var rows: [GraphRow] = []
        rows.reserveCapacity(commits.count)

        func freeSlot() -> Int {
            if let i = lanes.firstIndex(where: { $0 == nil }) { return i }
            lanes.append(nil); return lanes.count - 1
        }

        for c in commits {
            let before = lanes
            var col = lanes.firstIndex(where: { $0?.hash == c.hash }) ?? -1
            var color: Int
            if col < 0 {
                col = freeSlot()
                color = nextColor; nextColor += 1
            } else {
                color = lanes[col]!.color
            }

            var incoming: [GraphRow.Edge] = []
            var through: [GraphRow.Edge] = []
            // Все дорожки, ждавшие этот коммит, сходятся в точку
            for (i, l) in before.enumerated() {
                guard let l else { continue }
                if l.hash == c.hash { incoming.append(.init(from: i, to: col, color: l.color)) }
                else { through.append(.init(from: i, to: i, color: l.color)) }
            }
            for i in lanes.indices where lanes[i]?.hash == c.hash { lanes[i] = nil }

            var outgoing: [GraphRow.Edge] = []
            for (n, p) in c.parents.enumerated() {
                if let k = lanes.firstIndex(where: { $0?.hash == p }) {
                    outgoing.append(.init(from: col, to: k, color: lanes[k]!.color))
                } else {
                    let slot = n == 0 ? (lanes.indices.contains(col) && lanes[col] == nil ? col : freeSlot()) : freeSlot()
                    let pc: Int
                    if n == 0 { pc = color } else { pc = nextColor; nextColor += 1 }
                    lanes[slot] = Lane(hash: p, color: pc)
                    outgoing.append(.init(from: col, to: slot, color: pc))
                }
            }
            while let last = lanes.last, last == nil { lanes.removeLast() }
            let width = max(before.count, lanes.count, col + 1)
            rows.append(GraphRow(column: col, color: color, width: width,
                                 incoming: incoming, outgoing: outgoing, through: through))
        }
        return rows
    }
}

let graphPalette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .red, .indigo, .mint, .brown]

struct GraphCell: View {
    let row: GraphRow
    let maxWidth: Int
    let isHead: Bool
    static let step: CGFloat = 14

    var body: some View {
        Canvas { ctx, size in
            let step = Self.step
            func x(_ c: Int) -> CGFloat { CGFloat(c) * step + step / 2 }
            let mid = size.height / 2
            func stroke(_ a: CGPoint, _ b: CGPoint, _ color: Int) {
                var p = Path()
                p.move(to: a)
                if a.x == b.x { p.addLine(to: b) }
                else { p.addCurve(to: b, control1: CGPoint(x: a.x, y: (a.y + b.y) / 2), control2: CGPoint(x: b.x, y: (a.y + b.y) / 2)) }
                ctx.stroke(p, with: .color(graphPalette[color % graphPalette.count]), lineWidth: 1.6)
            }
            for e in row.through { stroke(CGPoint(x: x(e.from), y: 0), CGPoint(x: x(e.to), y: size.height), e.color) }
            for e in row.incoming { stroke(CGPoint(x: x(e.from), y: 0), CGPoint(x: x(e.to), y: mid), e.color) }
            for e in row.outgoing { stroke(CGPoint(x: x(e.from), y: mid), CGPoint(x: x(e.to), y: size.height), e.color) }
            let center = CGPoint(x: x(row.column), y: mid)
            let color = graphPalette[row.color % graphPalette.count]
            let r: CGFloat = isHead ? 5 : 4
            let dot = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            ctx.fill(dot, with: .color(color))
            ctx.stroke(dot, with: .color(.primary.opacity(0.55)), lineWidth: isHead ? 1.5 : 1)
        }
        .frame(width: CGFloat(maxWidth) * Self.step, height: GraphCell.rowHeight)
    }

    static let rowHeight: CGFloat = 40
}
