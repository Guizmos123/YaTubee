//
//  CountFormatter.swift
//  Yattee
//
//  Centralized utility for formatting counts with compact notation (1K, 2.5K, etc.)
//

import Foundation

/// Utility for formatting counts with compact notation and proper pluralization.
enum CountFormatter {
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private let formatter: NumberFormatter = {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = false
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 1
            return formatter
        }()

        func string(from value: Double, locale: Locale) -> String? {
            lock.withLock {
                formatter.locale = locale
                return formatter.string(from: NSNumber(value: value))
            }
        }
    }

    private static let storage = Storage()

    /// Formats a count to compact notation (e.g., 1K, 2.5K, 1M, 1B).
    /// - Parameter count: The number to format
    /// - Returns: Formatted string (e.g., "150", "1.2K", "2.5M", "1B")
    static func compact(_ count: Int) -> String {
        switch count {
        case 0..<1_000:
            return "\(count)"
        case 1_000..<1_000_000:
            return compactValue(Double(count) / 1_000, suffix: "K")
        case 1_000_000..<1_000_000_000:
            return compactValue(Double(count) / 1_000_000, suffix: "M")
        default:
            return compactValue(Double(count) / 1_000_000_000, suffix: "B")
        }
    }

    private static func compactValue(_ value: Double, suffix: String) -> String {
        let formatted = storage.string(from: value, locale: AppLocalization.selectedLocale)
        return (formatted ?? "\(value)") + suffix
    }
}
