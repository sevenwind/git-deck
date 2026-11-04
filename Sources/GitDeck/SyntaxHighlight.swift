import SwiftUI
import AppKit

/// Лёгкая подсветка синтаксиса по расширению файла (без внешних зависимостей, построчно).
struct SyntaxLang {
    var lineComments: [String] = []
    var blockComment: (String, String)? = nil
    var strings: [Character] = ["\"", "'"]
    var keywords: Set<String> = []
    var caseInsensitive = false

    private static func kw(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }

    private static let cLike = "if else for while do switch case break continue return default new delete this true false null nil try catch finally throw throws class struct enum interface protocol extension func function fn let var const static public private protected internal final abstract override import export from as in is of async await yield void int long short float double char bool boolean string typeof instanceof extends implements package namespace using where guard defer self super init get set type readonly"
    private static let swiftKW = "associatedtype typealias subscript inout mutating nonmutating lazy weak unowned some any actor nonisolated @MainActor @Published @State @Binding @Environment @Observable"
    private static let pyKW = "def class if elif else for while try except finally with as import from return yield lambda pass break continue raise in is not and or None True False async await global nonlocal del assert self"
    private static let shKW = "if then else elif fi for while do done case esac function in return exit export local readonly echo cd set unset source"
    private static let sqlKW = "select from where insert into values update set delete create table alter drop index join left right inner outer on group by order having limit offset and or not null as distinct union primary key foreign references default"
    private static let goKW = "package import func var const type struct interface map chan go defer return if else for range switch case default break continue select fallthrough nil true false"
    private static let rustKW = "fn let mut const static struct enum impl trait pub use mod crate self super match if else for while loop return break continue as in where async await move ref true false unsafe dyn type"
    private static let rubyKW = "def end class module if elsif else unless while until for do begin rescue ensure return yield require include extend self nil true false then case when in and or not"

    static func forExtension(_ path: String) -> SyntaxLang? {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        switch ext {
        case "swift": return .init(lineComments: ["//"], blockComment: ("/*", "*/"), keywords: kw(cLike + " " + swiftKW))
        case "js", "jsx", "mjs", "cjs", "ts", "tsx", "java", "kt", "kts", "c", "h", "cpp", "cc", "hpp", "m", "mm", "cs", "scala", "dart", "groovy":
            return .init(lineComments: ["//"], blockComment: ("/*", "*/"), strings: ["\"", "'", "`"], keywords: kw(cLike))
        case "go": return .init(lineComments: ["//"], blockComment: ("/*", "*/"), strings: ["\"", "'", "`"], keywords: kw(goKW))
        case "rs": return .init(lineComments: ["//"], blockComment: ("/*", "*/"), keywords: kw(rustKW))
        case "php": return .init(lineComments: ["//", "#"], blockComment: ("/*", "*/"), keywords: kw(cLike + " echo function foreach endforeach elseif array require include namespace use"))
        case "py": return .init(lineComments: ["#"], keywords: kw(pyKW))
        case "rb": return .init(lineComments: ["#"], keywords: kw(rubyKW))
        case "sh", "bash", "zsh", "env": return .init(lineComments: ["#"], keywords: kw(shKW))
        case "yml", "yaml", "toml", "ini", "conf", "properties": return .init(lineComments: ["#", ";"], keywords: kw("true false null yes no on off"))
        case "json", "jsonc", "json5": return .init(lineComments: ["//"], strings: ["\""], keywords: kw("true false null"))
        case "html", "htm", "xml", "svg", "plist", "vue", "xhtml": return .init(blockComment: ("<!--", "-->"), keywords: [])
        case "css", "scss", "sass", "less": return .init(lineComments: ["//"], blockComment: ("/*", "*/"), keywords: kw("important inherit initial none auto"))
        case "sql": return .init(lineComments: ["--"], blockComment: ("/*", "*/"), keywords: kw(sqlKW), caseInsensitive: true)
        case "md", "markdown": return nil
        case "lua": return .init(lineComments: ["--"], keywords: kw("function end if then else elseif for while do return local nil true false and or not in repeat until"))
        default:
            if name == "dockerfile" { return .init(lineComments: ["#"], keywords: kw("from run cmd copy add env expose workdir entrypoint arg user volume label"), caseInsensitive: true) }
            if name == "makefile" { return .init(lineComments: ["#"], keywords: []) }
            return nil
        }
    }
}

enum SyntaxHighlighter {
    /// Подсвечивает одну строку кода. Многострочные комментарии/строки не отслеживаются (строки diff приходят порознь).
    static func highlight(_ code: String, lang: SyntaxLang, theme: SyntaxTheme) -> AttributedString {
        let keywordColor = theme.keyword, stringColor = theme.string, commentColor = theme.comment
        let numberColor = theme.number, typeColor = theme.type
        var out = AttributedString()
        let chars = Array(code)
        var i = 0
        var plain = ""
        func flush() { if !plain.isEmpty { out += AttributedString(plain); plain = "" } }
        func emit(_ s: String, _ c: Color) {
            flush()
            var a = AttributedString(s); a.foregroundColor = c; out += a
        }
        func starts(_ p: String, at k: Int) -> Bool {
            let pc = Array(p)
            guard k + pc.count <= chars.count else { return false }
            for j in 0..<pc.count where chars[k + j] != pc[j] { return false }
            return true
        }
        let trimmedStart = code.drop(while: { $0 == " " || $0 == "\t" })
        // Продолжение блочного комментария: " * текст" или "*/"
        if lang.blockComment?.0 == "/*", trimmedStart.hasPrefix("*") {
            emit(code, commentColor); return out
        }
        while i < chars.count {
            if let lc = lang.lineComments.first(where: { starts($0, at: i) && !($0 == "#" && i > 0 && chars[i - 1] == "$") && !($0 == "//" && i > 0 && chars[i - 1] == ":") }) {
                _ = lc
                emit(String(chars[i...]), commentColor); i = chars.count; break
            }
            if let (open, close) = lang.blockComment, starts(open, at: i) {
                var j = i + open.count
                while j < chars.count, !starts(close, at: j) { j += 1 }
                j = min(chars.count, j + close.count)
                emit(String(chars[i..<j]), commentColor); i = j; continue
            }
            let ch = chars[i]
            if lang.strings.contains(ch) {
                var j = i + 1
                while j < chars.count, chars[j] != ch { if chars[j] == "\\" { j += 1 }; j += 1 }
                j = min(chars.count, j + 1)
                emit(String(chars[i..<j]), stringColor); i = j; continue
            }
            if ch.isNumber, i == 0 || !(chars[i - 1].isLetter || chars[i - 1] == "_") {
                var j = i
                while j < chars.count, chars[j].isHexDigit || chars[j] == "." || chars[j] == "x" || chars[j] == "_" { j += 1 }
                emit(String(chars[i..<j]), numberColor); i = j; continue
            }
            if ch.isLetter || ch == "_" || ch == "@" {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                let w = String(chars[i..<j])
                let key = lang.caseInsensitive ? w.lowercased() : w
                if lang.keywords.contains(key) { emit(w, keywordColor) }
                else if ch.isUppercase, w.count > 1 { emit(w, typeColor) }
                else { plain += w }
                i = j; continue
            }
            plain.append(ch); i += 1
        }
        flush()
        return out
    }
}
