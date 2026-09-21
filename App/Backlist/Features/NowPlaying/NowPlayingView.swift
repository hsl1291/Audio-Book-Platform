import SwiftUI
import SwiftData
import BacklistCore

/// Persistent bar above the tab bar. One tap to pause, one tap to open the player.
struct MiniPlayerBar: View {
    @EnvironmentObject private var player: PlayerEngine
    @State private var showFullPlayer = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentChapterTitle ?? "Playing")
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                Text(TimeFormat.remaining(player.offset, player.duration))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                Task { await player.skip(by: -NowPlayingBridge.skipBackward) }
            } label: {
                Image(systemName: "gobackward.15")
            }

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .contentShape(Rectangle())
        .onTapGesture { showFullPlayer = true }
        .sheet(isPresented: $showFullPlayer) { NowPlayingView() }
    }
}

struct NowPlayingView: View {
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.dismiss) private var dismiss
    @State private var scrubbing: Double?
    @State private var showChapters = false

    private var displayedOffset: Double {
        scrubbing ?? player.offset
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                if let chapter = player.currentChapterTitle {
                    Text(chapter)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }

                scrubber
                transport
                speedControl

                Spacer()
            }
            .padding()
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showChapters = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .disabled(player.chapters.isEmpty)
                }
            }
            .sheet(isPresented: $showChapters) { chapterList }
        }
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { displayedOffset },
                    set: { scrubbing = $0 }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    guard !editing, let target = scrubbing else { return }
                    Task {
                        await player.seek(to: target)
                        scrubbing = nil
                    }
                }
            )

            HStack {
                Text(TimeFormat.clock(displayedOffset))
                Spacer()
                Text("−" + TimeFormat.clock(max(0, player.duration - displayedOffset)))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 36) {
            Button {
                Task { await player.previousChapter() }
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .disabled(player.chapters.isEmpty)

            Button {
                Task { await player.skip(by: -NowPlayingBridge.skipBackward) }
            } label: {
                Image(systemName: "gobackward.15").font(.title)
            }

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }

            Button {
                Task { await player.skip(by: NowPlayingBridge.skipForward) }
            } label: {
                Image(systemName: "goforward.30").font(.title)
            }

            Button {
                Task { await player.nextChapter() }
            } label: {
                Image(systemName: "forward.end.fill")
            }
            .disabled(player.chapters.isEmpty)
        }
    }

    /// Speed is remembered per book: the right pace for dense nonfiction is not the
    /// right pace for a memoir.
    private var speedControl: some View {
        HStack {
            Image(systemName: "speedometer").foregroundStyle(.secondary)
            Picker("Speed", selection: $player.rate) {
                ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { value in
                    Text("\(value, specifier: "%g")×").tag(Float(value))
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var chapterList: some View {
        NavigationStack {
            List(player.chapters) { chapter in
                Button {
                    Task {
                        await player.seekToChapter(chapter.id)
                        showChapters = false
                    }
                } label: {
                    HStack {
                        Text(chapter.title).lineLimit(1)
                        Spacer()
                        Text(TimeFormat.clock(chapter.start))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(chapter.id == player.currentChapterIndex ? .tint : .primary)
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

enum TimeFormat {
    /// `h:mm:ss`, dropping the hour when there isn't one. Audiobooks routinely run
    /// past ten hours, so the hour field must not be fixed-width.
    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    static func remaining(_ offset: TimeInterval, _ duration: TimeInterval) -> String {
        guard duration > 0 else { return clock(offset) }
        return "\(clock(max(0, duration - offset))) left"
    }
}
