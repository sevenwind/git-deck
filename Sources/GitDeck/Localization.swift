import SwiftUI

/// Язык интерфейса. Ключи в Localizable.strings — русские фразы (язык разработки), английский лежит в en.lproj.
enum AppLang: String, CaseIterable, Identifiable {
    case ru, en
    var id: String { rawValue }
    var title: String { self == .ru ? "Русский" : "English" }
    var locale: Locale { Locale(identifier: rawValue) }

    static var systemDefault: AppLang {
        (Locale.preferredLanguages.first ?? "en").hasPrefix("ru") ? .ru : .en
    }
}

enum Loc {
    nonisolated(unsafe) private static var bundle: Bundle = .main
    nonisolated(unsafe) private(set) static var lang: AppLang = {
        if let s = UserDefaults.standard.string(forKey: "appLanguage"), let l = AppLang(rawValue: s) { return l }
        return .systemDefault
    }()

    static func set(_ l: AppLang) {
        lang = l
        UserDefaults.standard.set(l.rawValue, forKey: "appLanguage")
        UserDefaults.standard.set([l.rawValue], forKey: "AppleLanguages")   // системные панели и меню — со следующего запуска
        bundle = Bundle.main.path(forResource: l.rawValue, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }

    static func tr(_ key: String) -> String { bundle.localizedString(forKey: key, value: key, table: nil) }
    static func prepare() { set(lang) }
}

/// Перевод строки вне SwiftUI-литералов (баннеры, диалоги, сообщения модели).
/// Для подстановок используйте printf-формат: `L("Ошибок: %lld", n)`, `L("Ветка %@", name)`.
func L(_ key: String, _ args: CVarArg...) -> String {
    let f = Loc.tr(key)
    return args.isEmpty ? f : String(format: f, locale: Loc.lang.locale, arguments: args)
}
