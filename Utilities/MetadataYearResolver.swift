import Foundation

enum MetadataYearResolver {
    private static let yearRegex = try! NSRegularExpression(pattern: #"\b(19|20)\d{2}\b"#)

    static func extractYear(from value: String?) -> String? {
        guard let value else { return nil }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty, trimmedValue != "Unknown Year" else { return nil }

        let range = NSRange(trimmedValue.startIndex..<trimmedValue.endIndex, in: trimmedValue)
        guard let match = yearRegex.firstMatch(in: trimmedValue, range: range),
              let matchRange = Range(match.range, in: trimmedValue) else {
            return nil
        }

        return String(trimmedValue[matchRange])
    }

    static func yearString(from date: Date?) -> String? {
        guard let date else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt

        let year = calendar.component(.year, from: date)
        guard (1900...2100).contains(year) else { return nil }
        return String(year)
    }

    static func resolvedYear(
        primaryYear: String?,
        releaseDate: String?,
        originalReleaseDate: String?
    ) -> String? {
        extractYear(from: primaryYear)
            ?? extractYear(from: releaseDate)
            ?? extractYear(from: originalReleaseDate)
    }

    static func resolvedYear(
        primaryYear: String?,
        releaseDate: Date?,
        originalReleaseDate: Date? = nil
    ) -> String? {
        extractYear(from: primaryYear)
            ?? yearString(from: releaseDate)
            ?? yearString(from: originalReleaseDate)
    }

    static func resolvedYearInt(
        primaryYear: String?,
        releaseDate: String?,
        originalReleaseDate: String?
    ) -> Int? {
        guard let year = resolvedYear(
            primaryYear: primaryYear,
            releaseDate: releaseDate,
            originalReleaseDate: originalReleaseDate
        ) else {
            return nil
        }

        return Int(year)
    }
}
