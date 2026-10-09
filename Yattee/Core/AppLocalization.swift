//
//  AppLocalization.swift
//  Yattee
//
//  Resolves materialized localized strings using the language selected in Settings.
//

import Foundation

enum AppLocalization {
    private static let fallbackLanguage = AppLanguage.english.rawValue

    static var selectedLocale: Locale {
        let language = UserDefaults.standard.string(forKey: SettingsKey.appLanguage.rawValue)
            .flatMap(AppLanguage.init(rawValue:)) ?? .english
        return language.locale
    }

    private static func bundle(for locale: Locale) -> Bundle {
        let requestedLanguage = locale.language.languageCode?.identifier ?? fallbackLanguage

        if let bundle = localizedBundle(for: requestedLanguage) {
            return bundle
        }

        return localizedBundle(for: fallbackLanguage) ?? .main
    }

    private static func localizedBundle(for language: String) -> Bundle? {
        guard let url = Bundle.main.url(forResource: language, withExtension: "lproj") else {
            return nil
        }
        return Bundle(url: url)
    }

    static func string(
        _ key: String.LocalizationValue,
        locale: Locale = selectedLocale
    ) -> String {
        String(localized: key, bundle: bundle(for: locale), locale: locale)
    }

    static func stringResource(
        _ resource: LocalizedStringResource,
        locale: Locale = selectedLocale
    ) -> String {
        let localizedResource = LocalizedStringResource(
            String.LocalizationValue(resource.key),
            table: resource.table,
            locale: locale,
            bundle: bundle(for: locale)
        )
        return String(localized: localizedResource)
    }

    static func string(
        _ key: StaticString,
        defaultValue: String.LocalizationValue,
        locale: Locale = selectedLocale
    ) -> String {
        String(
            localized: key,
            defaultValue: defaultValue,
            bundle: bundle(for: locale),
            locale: locale
        )
    }
}
