import SwiftUI
import AppKit

/// Цветовая схема подсветки кода (по мотивам VS Code / Cursor и популярных тем).
struct SyntaxTheme: Identifiable {
    let id: String
    let name: String?            // nil — локализуемое название «Системная»
    let isDark: Bool?            // nil — следовать системной теме
    let backgroundHex: UInt32?
    let foregroundHex: UInt32?
    let keywordC: Color, stringC: Color, commentC: Color, numberC: Color, typeC: Color

    var keyword: Color { keywordC }
    var string: Color { stringC }
    var comment: Color { commentC }
    var number: Color { numberC }
    var type: Color { typeC }
    var background: Color? { backgroundHex.map(Color.init(hex:)) }
    var foreground: Color? { foregroundHex.map(Color.init(hex:)) }
    var colorScheme: ColorScheme? { isDark.map { $0 ? .dark : .light } }
    var title: String { name ?? L("Системная") }

    private init(_ id: String, _ name: String?, dark: Bool?, bg: UInt32?, fg: UInt32?,
                 kw: UInt32, str: UInt32, com: UInt32, num: UInt32, typ: UInt32) {
        self.id = id; self.name = name; isDark = dark; backgroundHex = bg; foregroundHex = fg
        keywordC = Color(hex: kw); stringC = Color(hex: str); commentC = Color(hex: com)
        numberC = Color(hex: num); typeC = Color(hex: typ)
    }

    private init(system: Void) {
        id = "system"; name = nil; isDark = nil; backgroundHex = nil; foregroundHex = nil
        keywordC = Color(nsColor: .systemPink); stringC = Color(nsColor: .systemOrange)
        commentC = Color(nsColor: .systemGreen).opacity(0.85); numberC = Color(nsColor: .systemTeal)
        typeC = Color(nsColor: .systemPurple)
    }

    static let system = SyntaxTheme(system: ())
    static let all: [SyntaxTheme] = [
        system,
        .init("dark-plus", "Dark+ (VS Code)", dark: true, bg: 0x1E1E1E, fg: 0xD4D4D4, kw: 0x569CD6, str: 0xCE9178, com: 0x6A9955, num: 0xB5CEA8, typ: 0x4EC9B0),
        .init("light-plus", "Light+ (VS Code)", dark: false, bg: 0xFFFFFF, fg: 0x000000, kw: 0x0000FF, str: 0xA31515, com: 0x008000, num: 0x098658, typ: 0x267F99),
        .init("monokai", "Monokai", dark: true, bg: 0x272822, fg: 0xF8F8F2, kw: 0xF92672, str: 0xE6DB74, com: 0x75715E, num: 0xAE81FF, typ: 0x66D9EF),
        .init("one-dark", "One Dark", dark: true, bg: 0x282C34, fg: 0xABB2BF, kw: 0xC678DD, str: 0x98C379, com: 0x5C6370, num: 0xD19A66, typ: 0xE5C07B),
        .init("github-dark", "GitHub Dark", dark: true, bg: 0x0D1117, fg: 0xC9D1D9, kw: 0xFF7B72, str: 0xA5D6FF, com: 0x8B949E, num: 0x79C0FF, typ: 0xFFA657),
        .init("github-light", "GitHub Light", dark: false, bg: 0xFFFFFF, fg: 0x24292F, kw: 0xCF222E, str: 0x0A3069, com: 0x6E7781, num: 0x0550AE, typ: 0x953800),
        .init("solarized-dark", "Solarized Dark", dark: true, bg: 0x002B36, fg: 0x839496, kw: 0x859900, str: 0x2AA198, com: 0x586E75, num: 0xD33682, typ: 0xB58900),
        .init("solarized-light", "Solarized Light", dark: false, bg: 0xFDF6E3, fg: 0x657B83, kw: 0x859900, str: 0x2AA198, com: 0x93A1A1, num: 0xD33682, typ: 0xB58900),
        .init("dracula", "Dracula", dark: true, bg: 0x282A36, fg: 0xF8F8F2, kw: 0xFF79C6, str: 0xF1FA8C, com: 0x6272A4, num: 0xBD93F9, typ: 0x8BE9FD),
    ]

    static func byID(_ id: String) -> SyntaxTheme { all.first { $0.id == id } ?? .system }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Небольшой предпросмотр схемы в настройках.
struct ThemePreview: View {
    let theme: SyntaxTheme
    private static let sample = ["// Example", "func greet(name: String) -> Int {", "    let text = \"Hello, \\(name)\"", "    return 42", "}"]
    var body: some View {
        let lang = SyntaxLang.forExtension("a.swift")!
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(Self.sample.enumerated()), id: \.offset) { _, l in
                Text(SyntaxHighlighter.highlight(l, lang: lang, theme: theme))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.foreground ?? .primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(theme.background ?? Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
    }
}
