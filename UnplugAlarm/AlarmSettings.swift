//
//  AlarmSettings.swift
//  Unplug Alarm
//
//  User preferences for the lock screen warning, contact number,
//  voice warning and the language used for wallpaper + voice texts.
//

import Foundation
import Combine

/// Language used for the texts shown on the lock screen wallpaper and for the
/// spoken warning. Independent of the app UI language (bystanders may not
/// speak the owner's system language).
enum AlarmLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case turkish = "tr"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case portuguese = "pt-BR"
    case russian = "ru"
    case chineseSimplified = "zh-Hans"
    case arabic = "ar"
    case japanese = "ja"

    var id: String { rawValue }

    /// Native name, shown as-is in the picker regardless of UI language.
    var nativeName: String {
        switch self {
        case .english: return "English"
        case .turkish: return "Türkçe"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .portuguese: return "Português"
        case .russian: return "Русский"
        case .chineseSimplified: return "简体中文"
        case .arabic: return "العربية"
        case .japanese: return "日本語"
        }
    }

    /// BCP-47 code for `AVSpeechSynthesisVoice(language:)`. All of these have a
    /// voice installed by default on macOS.
    var voiceLanguageCode: String {
        switch self {
        case .english: return "en-US"
        case .turkish: return "tr-TR"
        case .spanish: return "es-ES"
        case .french: return "fr-FR"
        case .german: return "de-DE"
        case .portuguese: return "pt-BR"
        case .russian: return "ru-RU"
        case .chineseSimplified: return "zh-CN"
        case .arabic: return "ar-001"
        case .japanese: return "ja-JP"
        }
    }

    var isRightToLeft: Bool { self == .arabic }

    /// System language if it is one of the supported languages, else English.
    static var systemDefault: AlarmLanguage {
        for identifier in Locale.preferredLanguages {
            let locale = Locale(identifier: identifier)
            guard let code = locale.language.languageCode?.identifier else { continue }
            if code == "zh" {
                // Only Simplified Chinese is supported.
                if locale.language.script?.identifier == "Hant" { continue }
                return .chineseSimplified
            }
            if code == "pt" { return .portuguese }
            if let match = AlarmLanguage(rawValue: code) { return match }
        }
        return .english
    }

    // MARK: - Texts

    /// Localization bundle for this language (texts live in `AlarmTexts.xcstrings`).
    private var bundle: Bundle {
        if let path = Bundle.main.path(forResource: rawValue, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return Bundle.main
    }

    /// Looks up a wallpaper/voice text in this language, falling back to English.
    func text(_ key: String) -> String {
        let missing = "\u{0}missing"
        let value = bundle.localizedString(forKey: key, value: missing, table: "AlarmTexts")
        if value != missing { return value }
        if self != .english { return AlarmLanguage.english.text(key) }
        return key
    }
}

final class AlarmSettings: ObservableObject {
    static let shared = AlarmSettings()

    static let maxContactNumberLength = 24
    private static let allowedContactCharacters = Set("0123456789+-() ")

    private enum Key {
        static let showLockScreenWarning = "showLockScreenWarning"
        static let showContactNumber = "showContactNumber"
        static let contactNumber = "contactNumber"
        static let voiceWarning = "voiceWarning"
        static let alarmLanguage = "alarmLanguage"
        static let stopAlarmOnReconnect = "stopAlarmOnReconnect"
    }

    private let defaults = UserDefaults.standard

    @Published var showLockScreenWarning: Bool {
        didSet { defaults.set(showLockScreenWarning, forKey: Key.showLockScreenWarning) }
    }

    @Published var showContactNumber: Bool {
        didSet { defaults.set(showContactNumber, forKey: Key.showContactNumber) }
    }

    @Published var contactNumber: String {
        didSet {
            let sanitized = AlarmSettings.sanitizeContactNumber(contactNumber)
            if sanitized != contactNumber {
                contactNumber = sanitized // re-enters didSet once with the clean value
                return
            }
            defaults.set(contactNumber, forKey: Key.contactNumber)
        }
    }

    @Published var voiceWarning: Bool {
        didSet { defaults.set(voiceWarning, forKey: Key.voiceWarning) }
    }

    /// Stop a power-triggered alarm when the charger is plugged back in
    /// (e.g. a short power cut or an accidental unplug).
    @Published var stopAlarmOnReconnect: Bool {
        didSet { defaults.set(stopAlarmOnReconnect, forKey: Key.stopAlarmOnReconnect) }
    }

    @Published var alarmLanguage: AlarmLanguage {
        didSet { defaults.set(alarmLanguage.rawValue, forKey: Key.alarmLanguage) }
    }

    private init() {
        defaults.register(defaults: [
            Key.showLockScreenWarning: true,
            Key.showContactNumber: true,
            Key.voiceWarning: true,
            Key.stopAlarmOnReconnect: true,
        ])
        showLockScreenWarning = defaults.bool(forKey: Key.showLockScreenWarning)
        showContactNumber = defaults.bool(forKey: Key.showContactNumber)
        contactNumber = AlarmSettings.sanitizeContactNumber(defaults.string(forKey: Key.contactNumber) ?? "")
        voiceWarning = defaults.bool(forKey: Key.voiceWarning)
        stopAlarmOnReconnect = defaults.bool(forKey: Key.stopAlarmOnReconnect)
        alarmLanguage = defaults.string(forKey: Key.alarmLanguage).flatMap(AlarmLanguage.init(rawValue:))
            ?? AlarmLanguage.systemDefault
    }

    /// Contact number to show, or nil if disabled / empty.
    var effectiveContactNumber: String? {
        guard showContactNumber else { return nil }
        let trimmed = contactNumber.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func sanitizeContactNumber(_ value: String) -> String {
        String(value.filter { allowedContactCharacters.contains($0) }.prefix(maxContactNumberLength))
    }
}
