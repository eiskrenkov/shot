import Foundation

/// What the sidebar shows after filtering, sorting and grouping.
struct ListContent {
    var sections: [ScreenshotGroup]
    /// Top-level entries (screenshots and groups), in display order.
    var entries: [LibraryEntry]
    var isGrouped: Bool
    /// Number of visible screenshots, including those inside groups.
    var screenshotCount: Int
    /// Every visible entry, including group contents, keyed by `URL.pathKey`.
    var lookup: [String: LibraryEntry]

    static let empty = ListContent(sections: [], entries: [], isGrouped: false, screenshotCount: 0, lookup: [:])
}

enum ListBuilder {
    static func build(screenshots: [Screenshot], folders: [ScreenshotFolder], query: String,
                      preferences: Preferences, favorites: Favorites) -> ListContent {
        let kindFilter = preferences.kindFilter
        let favoritesOnly = preferences.favoritesOnly
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let isFiltering = kindFilter != .all || favoritesOnly || !terms.isEmpty

        func passesKind(_ item: Screenshot) -> Bool {
            switch kindFilter {
            case .all: true
            case .screenshots: item.kind == .image
            case .recordings: item.kind == .video
            }
        }

        func matches(_ name: String) -> Bool {
            terms.allSatisfy { name.localizedStandardContains($0) }
        }

        let key = preferences.sortKey
        let ascending = preferences.ascending

        var entries: [LibraryEntry] = screenshots.filter { item in
            passesKind(item)
                && (!favoritesOnly || favorites.contains(item.url))
                && matches(item.displayName)
        }

        for folder in folders {
            var children = folder.items.filter(passesKind)
            // A favorite group shows everything in it; otherwise only its favorite screenshots.
            if favoritesOnly && !favorites.contains(folder.url) {
                children.removeAll { !favorites.contains($0.url) }
            }
            // A group whose name matches shows everything in it; otherwise only matching screenshots.
            if !matches(folder.displayName) {
                children.removeAll { !matches($0.displayName) }
            }
            if children.isEmpty && isFiltering { continue }
            children.sort { precedes($0, $1, key: key, ascending: ascending) }
            entries.append(folder.with(items: children))
        }

        entries.sort { precedes($0, $1, key: key, ascending: ascending) }

        var lookup: [String: LibraryEntry] = [:]
        var screenshotCount = 0
        for entry in entries {
            lookup[entry.url.pathKey] = entry
            if let folder = entry as? ScreenshotFolder {
                screenshotCount += folder.items.count
                for item in folder.items { lookup[item.url.pathKey] = item }
            } else {
                screenshotCount += 1
            }
        }

        let grouping = preferences.grouping
        guard grouping != .none else {
            return ListContent(sections: [], entries: entries, isGrouped: false,
                               screenshotCount: screenshotCount, lookup: lookup)
        }

        let calendar = Calendar.current
        var buckets: [Date: [LibraryEntry]] = [:]
        for entry in entries {
            // Appending keeps the within-section sort order.
            buckets[periodStart(of: entry.sortDate, grouping: grouping, calendar: calendar), default: []]
                .append(entry)
        }

        let oldestFirst = key == .dateCreated && ascending
        let starts = buckets.keys.sorted { oldestFirst ? $0 < $1 : $0 > $1 }
        let sections = starts.map { start in
            ScreenshotGroup(
                id: "\(grouping.rawValue)-\(Int(start.timeIntervalSinceReferenceDate))",
                title: DateText.groupTitle(for: start, grouping: grouping, calendar: calendar),
                entries: buckets[start] ?? []
            )
        }
        return ListContent(sections: sections, entries: sections.flatMap(\.entries), isGrouped: true,
                           screenshotCount: screenshotCount, lookup: lookup)
    }

    private static func precedes(_ a: LibraryEntry, _ b: LibraryEntry, key: SortKey, ascending: Bool) -> Bool {
        var result: ComparisonResult
        switch key {
        case .dateCreated:
            result = a.sortDate.compare(b.sortDate)
        case .name:
            result = a.displayName.localizedStandardCompare(b.displayName)
        case .size:
            result = a.totalSize == b.totalSize ? .orderedSame
                : (a.totalSize < b.totalSize ? .orderedAscending : .orderedDescending)
        }
        if result == .orderedSame {
            result = a.sortDate.compare(b.sortDate)
        }
        if result == .orderedSame {
            result = a.url.path.compare(b.url.path)
        }
        return ascending ? result == .orderedAscending : result == .orderedDescending
    }

    private static func periodStart(of date: Date, grouping: Grouping, calendar: Calendar) -> Date {
        switch grouping {
        case .day, .none:
            return calendar.startOfDay(for: date)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
        case .month:
            return calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        }
    }
}

/// Localized date strings used throughout the UI.
enum DateText {
    private static func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private static let weekday = formatter("EEEE")
    private static let dayThisYear = formatter("EEEEMMMMd")
    private static let dayOtherYear = formatter("EEEEyMMMMd")
    private static let monthDay = formatter("MMMMd")
    private static let monthDayYear = formatter("yMMMMd")
    private static let monthYear = formatter("yMMMM")
    private static let time = formatter("jms")
    private static let shortDateTime = formatter("MMMdjm")
    private static let shortDateTimeYear = formatter("yMMMdjm")

    private static let full: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter
    }()

    static func groupTitle(for start: Date, grouping: Grouping, calendar: Calendar) -> String {
        let now = Date()
        let sameYear = calendar.isDate(start, equalTo: now, toGranularity: .year)
        switch grouping {
        case .day, .none:
            if calendar.isDateInToday(start) { return "Today" }
            if calendar.isDateInYesterday(start) { return "Yesterday" }
            if let days = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: now)).day,
               days < 7 {
                return weekday.string(from: start)
            }
            return (sameYear ? dayThisYear : dayOtherYear).string(from: start)
        case .week:
            if calendar.isDate(start, equalTo: now, toGranularity: .weekOfYear) { return "This Week" }
            if let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: now),
               calendar.isDate(start, equalTo: lastWeek, toGranularity: .weekOfYear) {
                return "Last Week"
            }
            return "Week of " + (sameYear ? monthDay : monthDayYear).string(from: start)
        case .month:
            return monthYear.string(from: start)
        }
    }

    static func timeString(_ date: Date) -> String {
        time.string(from: date)
    }

    static func shortDateTimeString(_ date: Date) -> String {
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        return (sameYear ? shortDateTime : shortDateTimeYear).string(from: date)
    }

    static func fullString(_ date: Date) -> String {
        full.string(from: date)
    }

    static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func itemCount(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "item" : "items")"
    }
}
