import Foundation

/// What the Home Screen and Lock Screen widgets show, written by the app into the
/// shared App Group container and read by the widget extension.
///
/// Widgets cannot open the app's database, and should not: this is the smallest
/// thing that draws the widget, and nothing more of the library leaves the app.
public struct WidgetSnapshot: Codable, Equatable, Sendable {

    public static let appGroup = "group.com.backlist.app"
    public static let fileName = "widget-snapshot.json"
    public static let coverFileName = "widget-cover.jpg"
    /// Opened when the widget is tapped.
    public static let continueURL = URL(string: "backlist://continue")!

    public var title: String
    public var author: String?
    public var chapterTitle: String?
    public var offset: TimeInterval
    public var duration: TimeInterval
    public var rate: Double
    public var isPlaying: Bool
    public var hasCover: Bool
    public var updatedAt: Date

    public init(
        title: String,
        author: String?,
        chapterTitle: String?,
        offset: TimeInterval,
        duration: TimeInterval,
        rate: Double = 1,
        isPlaying: Bool,
        hasCover: Bool,
        updatedAt: Date = Date()
    ) {
        self.title = title
        self.author = author
        self.chapterTitle = chapterTitle
        self.offset = offset
        self.duration = duration
        self.rate = rate
        self.isPlaying = isPlaying
        self.hasCover = hasCover
        self.updatedAt = updatedAt
    }

    /// 0...1, or 0 when the length is not yet known.
    public var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, offset / duration))
    }

    /// Listening time left at the current speed.
    public var remaining: TimeInterval {
        max(0, duration - offset) / max(rate, 0.1)
    }

    /// "3 h 12 m left", "45 m left", "Almost done".
    public var remainingText: String {
        guard duration > 0 else { return "" }
        let minutes = Int((remaining / 60).rounded())
        if minutes < 1 { return "Almost done" }
        let (h, m) = (minutes / 60, minutes % 60)
        if h == 0 { return "\(m) m left" }
        return m == 0 ? "\(h) h left" : "\(h) h \(m) m left"
    }

    // MARK: - Storage

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) -> WidgetSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }
}
