import SwiftUI
import BacklistCore

/// A book cover, with a readable fallback for the many works that have none.
///
/// The ~54 finished books with no audio file, and everything on the Want list,
/// have no embedded artwork to extract. A grid full of identical grey rectangles
/// would be unusable, so the fallback derives a stable colour from the title and
/// shows the title itself.
struct CoverView: View {
    let work: StoredWork

    @State private var image: UIImage?

    var body: some View {
        Group {
            if work.isPrivate {
                placeholder(text: nil, systemImage: "lock.fill")
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let remote = work.remoteCoverURL.flatMap(URL.init(string:)) {
                AsyncImage(url: remote) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder(text: work.title, systemImage: nil)
                    }
                }
            } else {
                placeholder(text: work.title, systemImage: nil)
            }
        }
        .clipped()
        .task(id: work.coverCacheKey) { await loadCachedCover() }
    }

    private func loadCachedCover() async {
        guard let key = work.coverCacheKey else {
            image = nil
            return
        }
        image = await CoverCache.shared.image(forKey: key)
    }

    @ViewBuilder
    private func placeholder(text: String?, systemImage: String?) -> some View {
        ZStack {
            LinearGradient(
                colors: Self.tint(for: text ?? "?"),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.9))
            } else if let text {
                Text(text)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .minimumScaleFactor(0.7)
                    .padding(6)
            }
        }
    }

    /// Stable hue from the title, so the same book is always the same colour and
    /// the grid stays recognisable at a glance.
    static func tint(for seed: String) -> [Color] {
        var hash: UInt64 = 5381
        for byte in seed.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        let hue = Double(hash % 360) / 360.0
        return [
            Color(hue: hue, saturation: 0.45, brightness: 0.55),
            Color(hue: hue, saturation: 0.55, brightness: 0.35),
        ]
    }
}

/// On-disk cover cache.
///
/// Covers are extracted from audio files and are not synced through CloudKit —
/// they are re-derivable, and syncing a hundred JPEGs would waste the quota that
/// the tracking graph needs.
actor CoverCache {
    static let shared = CoverCache()

    private var memory: [String: UIImage] = [:]

    private var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let covers = base.appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
        return covers
    }

    func image(forKey key: String) -> UIImage? {
        if let cached = memory[key] { return cached }
        let url = directory.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            return nil
        }
        memory[key] = image
        return image
    }

    @discardableResult
    func store(_ data: Data, forKey key: String) -> UIImage? {
        let url = directory.appendingPathComponent(key)
        try? data.write(to: url, options: .atomic)
        let image = UIImage(data: data)
        memory[key] = image
        return image
    }
}
