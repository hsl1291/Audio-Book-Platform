# Backlist — one place for every book you own, want, and have read

## Context

Right now the same library is scattered across four tools that don't talk: Audible
for purchase, Libation for files, Google Drive for storage, a separate player for
listening, and Goodreads for history. Playback position lives in one app, ownership
lives in a folder tree, reading history lives on a website with no API, and nothing
knows what anything else knows.

**Backlist consolidates that into one native iOS app.** What do I own, what do I
want, what do I still need to buy, what have I read, and where was I in it —
offline-first, works in the car, never dependent on any store's app.

**Decisions taken:** full custom app including the player · personal use only, not
App Store · ebooks tracked but not read in-app · **source-agnostic — no coupling to
Audible or Libation** · name is **Backlist**.

### The core principle: the folder is the contract

Backlist watches a Google Drive folder. Anything that puts a playable audio file
there is a valid source — Libation today, Libro.fm or Downpour tomorrow, a Humble
bundle, a publisher direct download. The app reads files; it does not integrate with
stores, hold store credentials, or care how a file arrived.

This is what makes switching audiobook stores free. It also means the app has no
DRM surface at all: it plays files that are already playable, and nothing else.

### Drive library — full inventory, every folder enumerated via the Drive API

```
Books/  1rIwy7YUN1OQsdjUzpvScEmOUDcVcHsBM
├── _Read/                        1E19DKW…   76 books
│   └── Books (Last Download)/    1XkWxou…   98 books
├── _Too Read/                    1yV2_52…   27 books
├── Too Sensitive [B0GBY3NQCY]/                1 book   (loose at root)
└── KRL/ · SearchEngine/ · Images/            unrelated
```

| Metric | Value |
|---|---|
| Folders on disk | **202** |
| Unique books | **106** |
| Redundant copies | **96 (47.5%)** |
| Est. size now | **~79 GB** |
| Est. size deduped | **~41 GB** |
| **Reclaimable today** | **~37.5 GB** |

- **All 96 duplicates involve `Books (Last Download)`.** Only two titles live there
  and nowhere else (*Scandalized* `B09V3G52H4`, *The Seven Husbands of Evelyn Hugo*
  `B072359S7K`). That folder is 96/98 pure duplication.
- No triplicates. Duplication is strictly `_Read`↔`LastDownload` (66 titles) and
  `_TooRead`↔`LastDownload` (30 titles).
- Every book is a folder holding exactly one `.m4b`. No cover art, no `.cue`, no
  metadata sidecar.
- Current folders are named `Title [ID]` — **Audible ASIN** (76 of 106) or **ISBN-10**
  (30 of 106). Useful for the existing library, but **the scanner must not depend on
  it**, because files from other stores won't follow that convention.
- Sizes measured: 377 MB, 479 MB, 920 MB. ~400 MB average. **41 GB deduped still
  cannot live on a phone** — selective download is mandatory, not a nicety.
- Only 3 `_Too Read` titles aren't already downloaded: *Americana* `B07565H29V`,
  *Corked with Marc Fennell* `B0F3HG3SKZ`, *The Optimist* `B0DY3576JT`.
- Goodreads `read` = 130, Drive `_Read` = 76 → **~54 finished books have no audio
  file.** The model must represent "read it, don't own it."

### The supplied PDF

A print of the Goodreads `read` shelf, 130 books. It contains **no personal ratings
and no review text** — all 130 rows read "Write a review" and the rating column is
empty throughout. The real import source is the **Goodreads CSV export** (My Books →
Import and export → Export Library), carrying ISBN13, `My Rating`, `My Review`,
`Bookshelves`, `Date Read`, `Date Added`.

### Integration constraints (researched, not assumed)

| Want | Reality | Plan |
|---|---|---|
| Goodreads sync | API retired Dec 2020, no keys, no replacement | One-way CSV import; Backlist owns tracking from then on |
| Kindle library | No official Amazon API | Periodic import of Amazon "Request My Data" export |
| Store integration | No public API for Audible; others vary | **Not attempted.** The folder is the contract |
| CarPlay list UI | Entitlement needs Apple approval, normally for App Store apps | Request it; **don't depend on it** (see below) |

---

## Architecture

Swift 6 / SwiftUI, iOS 18+, no backend server. Paid Apple Developer Program ($99/yr)
is **required** — free accounts expire provisioning every 7 days, unacceptable for an
app holding your listening position.

### Data model

```
Work            canonical book: title, authors, ISBN13, cover, description
 ├─ Copy(*)     one per format you have or want
 │    format:      .audiobook | .ebook | .physical
 │    provenance:  .audioFile | .kindle | .physicalOwned | .library | .none
 │    sourceRef:   Drive fileId / local URL / Kindle ASIN / nil
 │    bytes, duration, addedAt
 ├─ Shelf(*)    want | owned | reading | finished | abandoned | reference
 ├─ Intent      needToPurchase | wishlist | none
 └─ Journal     rating, review, startedAt, finishedAt, notes
```

`Work` is format-agnostic; `Copy` carries provenance. That split expresses "I own the
audio but not the ebook," "I want this but own nothing," and the 54 books finished
with no file.

**The four screens this model produces**, which are the whole app:

| Screen | Query | Why it exists |
|---|---|---|
| **Waiting to Read** | has a `Copy` · not `finished` · not `abandoned` | Cover grid of everything you own and haven't read. Default landing screen. A book leaves the grid the moment it's marked finished. |
| **Continue** | `reading` with a saved position | Hero card atop Waiting to Read; one tap resumes. |
| **Want** | no `Copy` · `Intent` set | The shopping list — what to buy next, wherever you buy it. |
| **Read** | `finished` | History with rating and review. Imports all 130 from Goodreads, including the ~54 with no file. |

Covers come from the embedded `covr` atom in each m4b, falling back to Open Library /
Google Books by ISBN — which is how file-less finished books and everything on the
Want list still show art.

**Persistence:** SwiftData on the **CloudKit private database**. Free sync across your
devices, no account system, no server. Audio files are *not* in CloudKit — only the
tracking graph.

### Sources

```swift
protocol LibrarySource {
    func scan() async throws -> [DiscoveredItem]
    func metadata(for: DiscoveredItem) async throws -> AudioMetadata
    func downloadRequest(for: DiscoveredItem) -> URLRequest
}
```

- `GoogleDriveSource` — OAuth via AppAuth-iOS, recursive `files.list`, `files.get?alt=media`.
- `LocalFilesSource` — Files.app / iCloud Drive import, no auth.

**Google OAuth risk, to settle in Phase 0.** Scanning a folder tree needs the
`drive.readonly` *restricted* scope. An unverified OAuth client in Testing mode
expires refresh tokens every 7 days — weekly re-auth, unacceptable. Verify early
whether a published-unverified client holds tokens acceptably for a single owner.
**If not, point your downloads at an iCloud Drive folder instead and use
`LocalFilesSource` with `startDownloadingUbiquitousItem` — no OAuth, no tokens, no
Google.** Because the protocol exists either way, the swap costs days. Decide before
Phase 2.

### Identifying books without relying on filenames

Since files will come from varied stores, identification is a cascade:

1. **Embedded MP4 tags** — title, author, narrator, chapters, cover. Authoritative
   when present, and every store writes them.
2. **Folder/filename pattern** `Title [ID]` — ASIN or ISBN-10. Covers the existing
   106 books; treated as a hint, never a requirement.
3. **Fuzzy title + author match** against Open Library / Google Books to attach an
   ISBN13 and canonical metadata.
4. **Manual fix-up UI** for whatever falls through — a one-tap "this is that book"
   search. There will always be a tail; make correcting it pleasant rather than
   trying to be perfect.

**Metadata without downloading 400 MB.** MP4 metadata lives in the `moov` atom.

*Superseded during implementation.* The original approach here was to fetch a fixed
~2 MB window from each end of the file and hope `moov` fell inside one of them. The
implemented approach is better and simpler: an MP4 file is a flat chain of top-level
atoms and **every header states its own length**, so the chain can be walked — read
16 bytes, learn the size, seek past it, repeat. Locating `moov` costs three or four
16-byte reads regardless of where it sits or how large `mdat` is, and only then is
`moov` itself fetched.

This is exact rather than heuristic, transfers less, and cannot be defeated by an
unusually large `moov`. See `MP4AtomReader`, and `testWalkSkipsLargeMdatWithoutReadingIt`
which asserts the payload is never transferred.

Chapters are deliberately *not* parsed this way — they live in a separate track whose
sample tables are expensive to walk, and once a file is on the device
`AVAsset.chapterMetadataGroups` reads them correctly for free.

### Storage policy engine — the load-bearing piece

41 GB of library against maybe 20 GB of free phone.

- **Pinned** books never evict.
- **Up Next** (top 3 of the queue) auto-downloads on Wi-Fi + charging via a background
  `URLSession` with `isDiscretionary`.
- **Finished** books evict after N days; position retained forever.
- User-set hard budget (e.g. 15 GB), LRU eviction against it.
- Every row shows `.downloaded / .partial / .cloudOnly` so offline state is never a
  surprise.
- Files in `Application Support`, flagged `isExcludedFromBackup`.

### Playback

`AVQueuePlayer` + `AVAudioSession(.playback)`, `MPNowPlayingInfoCenter`,
`MPRemoteCommandCenter`. Chapters from `AVAsset.chapterMetadataGroups`. Per-book
playback rate, skip-silence, sleep timer with shake-to-extend, smart rewind
proportional to pause length. Position persisted every 15s and on every chapter
boundary, so a crash costs seconds.

### CarPlay — plan for the fallback, treat the entitlement as upside

The CarPlay entitlement is normally granted to App Store apps; a personal app may be
declined. **This does not block driving use.** `MPNowPlayingInfoCenter` +
`MPRemoteCommandCenter` need no entitlement and already deliver cover art, title,
chapter, play/pause/skip and steering-wheel controls on the CarPlay Now Playing
screen. App Intents let Siri handle "resume my book" hands-free. What's missing
without the entitlement is only the *browsable library list*.

File the request in Phase 0 (free, slow, no downside), ship the no-entitlement
experience in Phase 4, add `CPTemplateApplicationScene` + `CPListTemplate` in Phase 6
**only if granted** — as a separate scene delegate, so the app is complete without it.

### Import

- `GoodreadsCSVImporter` — the real export, with ratings and review text.
- `KindleDataImporter` — Amazon "Request My Data" archive → `.ebook` Copies. Track
  only, no reading, no live sync.
- `DriveLibraryScanner` — recursive walk, identification cascade above.
- `DuplicateResolver` — merges the 96 known duplicates, reports reclaimable bytes.

### A note on privacy

The library includes personal-topic nonfiction. Ship a **Private shelf** — excluded
from the home screen, widgets, CarPlay lists, and Now Playing metadata on external
displays. Cheap now, painful to retrofit.

---

## Phases

### Phase −1: Drive hygiene (no code, do it this week)

1. Move *Scandalized* and *The Seven Husbands of Evelyn Hugo* out of
   `Books (Last Download)/` — they exist nowhere else.
2. Delete the rest of `Books (Last Download)/`. **Reclaims ~37.5 GB.**
3. Create `Books/_Inbox/` at root and point future downloads there, whatever store
   they come from, so new files stop landing inside `_Read`.
4. Export the Goodreads CSV — the Phase 1 fixture and the only source of your ratings.

| Phase | Deliverable | Est. |
|---|---|---|
| 0 | Xcode project, SwiftData+CloudKit schema, CI, paid dev account, **CarPlay entitlement filed**, **Google OAuth token-lifetime spike** | 1 wk |
| 1 | Tracking app: model, Goodreads CSV import, manual add, search, the four screens | 2 wk |
| 2 | Drive (or iCloud) auth + recursive scan, identification cascade, dedupe/merge, ranged-read metadata + covers | 2.5 wk |
| 3 | Download manager + storage policy engine + offline state UI | 1.5 wk |
| 4 | Player: AVQueuePlayer, chapters, speed, sleep timer, Now Playing/remote commands (**this is the CarPlay experience**), position persistence | 2 wk |
| 5 | Widgets, Live Activity, App Intents/Siri, Lock Screen | 1.5 wk |
| 6 | CarPlay list templates — **only if entitlement granted** | 1 wk |
| 7 | Kindle "Request My Data" import, unified cross-format Work view | 1.5 wk |

~12–13 weeks part-time. Phases 1–3 alone already replace Goodreads and the folder tree.

---

## Critical files (new repo — `/home/user/Audio-Book-Platform`, branch `claude/cool-darwin-lgj590`)

```
Backlist/
  Models/       Work.swift  Copy.swift  Shelf.swift  Journal.swift
  Sources/      LibrarySource.swift  GoogleDriveSource.swift
                LocalFilesSource.swift  M4BMetadataReader.swift
                BookIdentifier.swift       ← the identification cascade
  Storage/      DownloadManager.swift  StoragePolicy.swift
  Player/       PlayerEngine.swift  ChapterController.swift  NowPlayingBridge.swift
  Import/       GoodreadsCSVImporter.swift  KindleDataImporter.swift
                DriveLibraryScanner.swift   DuplicateResolver.swift
  Features/     WaitingToRead/   ← default landing screen, cover grid + Continue card
                Want/  Read/  BookDetail/  NowPlaying/  Settings/
  Intents/      ResumeBookIntent.swift
  CarPlay/      CarPlaySceneDelegate.swift  CarPlayTemplates.swift   (Phase 6, gated)
BacklistTests/
BacklistWidgets/
```

---

## Verification

- **Unit** — `GoodreadsCSVImporter` against the real export, including rows with empty
  rating and review (the dominant case). `M4BMetadataReader` against fixture m4bs in
  both faststart and trailing-`moov` layouts. `BookIdentifier` against three naming
  styles: `Title [ASIN]`, `Title [ISBN]`, and an arbitrary non-conforming name that
  must fall through to tag and fuzzy matching. `DuplicateResolver` against the
  96-item known-duplicate set computed above.
- **Integration** — full scan of `Books/`: assert 202 folders resolve to 106 `Work`s,
  and the two LastDownload-only titles survive the merge.
- **Offline** — airplane mode from cold launch: browse, resume, scrub, finish a book,
  force-quit, confirm position survives.
- **Storage** — set a 2 GB budget, queue 10 books, assert eviction order and that
  pinned/finished rules hold.
- **Playback** — the 920 MB *21st Century Monetary Policy* file on a real device:
  seek latency, chapter accuracy, memory ceiling.
- **In-car** — real head unit, no entitlement: confirm cover art, chapter title, and
  steering-wheel skip work via `MPNowPlayingInfoCenter`. Then a >1hr drive.
- **Sync** — second device: confirm CloudKit carries shelves and positions without
  carrying audio files.

---

## Explicitly out of scope

- Any store integration, credential handling, or in-app purchasing. The folder is the
  contract.
- Any DRM handling. The app plays files that are already playable.
- Live Goodreads sync — no API exists.
- Live Kindle sync or Whispersync position sharing — no API exists.
- Ebook rendering. Kindle books are tracked as owned Copies only.
- App Store distribution, and therefore App Review, privacy policy, and Google CASA
  assessment.
