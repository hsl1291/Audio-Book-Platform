# Backlist

One place for every book you own, want, and have read.

Audio you own, ebooks you own, what you still need to buy, and where you were in it —
offline-first, native iOS, no dependency on any store's app.

Full design: [`docs/PLAN.md`](docs/PLAN.md).

---

## ⚠️ Read this first: none of this has been compiled

This code was written in a Linux container with **no Swift toolchain available**
(`download.swift.org` is blocked by the environment's network policy). Nothing here
has been built, run, or type-checked. Expect compile errors on first open and treat
the first `swift test` run as the real smoke test, not a formality.

The repository is laid out specifically to make that first check fast.

## Layout, and why it is split this way

```
Package.swift              SPM package — Foundation only, builds anywhere
Sources/BacklistCore/      all parsing, matching and policy logic
Tests/BacklistCoreTests/   runs with `swift test`, no Xcode, no simulator
App/Backlist/              the iOS app: SwiftUI, SwiftData, AVFoundation
project.yml                XcodeGen spec for the app target
```

`BacklistCore` deliberately imports **nothing but Foundation**. No SwiftUI, no
SwiftData, no AVFoundation, no CarPlay. That is what lets you verify the riskiest
logic in seconds:

```sh
swift test
```

Everything platform-bound — SwiftUI screens, SwiftData persistence, the AVPlayer
engine, CarPlay templates — goes in the iOS app target that depends on this package.
That boundary is good architecture on its own terms, and it also means a broken
simulator or an expired provisioning profile never blocks you from checking whether
the import logic is correct.

## What is here so far

| Component | What it does | Verified against |
|---|---|---|
| `FolderNameParser` | Reads the `Title [ID]` convention; distinguishes Audible ASIN from ISBN-10 by full checksum | All 30 real ISBN-10s in the library |
| `MatchKey` | Normalises titles and authors so the same book matches across sources | Real title/subtitle/diacritic variants |
| `DuplicateResolver` | Collapses the same book appearing in several folders, reports reclaimable space | The real 202-folder / 106-book shape |
| `DiscoveredItem` | One found file, plus shelf inference from its path | The nested dump-folder trap |
| `StoragePolicy` | What stays on the phone out of 41 GB, and what to fetch next | Pinning, eviction order, disk pressure |
| `GoogleDriveSource` / `LocalFilesSource` | Two interchangeable ways to find files | Drive's quirks, iCloud placeholders |

Models (`Work`, `BookCopy`, `Shelf`, `Journal`, `PlaybackPosition`) are plain value
types. The SwiftData `@Model` layer sits above them in the app target.

The app target adds the four screens (Waiting to Read, Want, Read, Book Detail),
the player, and the Now Playing bridge. **None of it is covered by `swift test`** —
it needs a simulator, and it is the least verified code in the repository.

## Building the app

```sh
brew install xcodegen
xcodegen generate
open Backlist.xcodeproj
```

Before the first build on a device, set `DEVELOPMENT_TEAM` in `project.yml`. The
paid Apple Developer Program is effectively required: on a free account
provisioning expires every seven days and the app stops launching, which is not
acceptable for something holding your listening position.

The `.xcodeproj` is generated rather than committed — it is large, merge-hostile,
and adds nothing to version control when the inputs are this simple.

## The one principle everything follows

**The folder is the contract.** Backlist watches a folder. Anything that puts a
playable audio file there is a valid source. The app does not integrate with stores,
hold store credentials, or care how a file arrived — which is what makes switching
audiobook stores free, and why the app has no DRM surface at all.

Corollary, enforced throughout: the `Title [ID]` naming convention is treated as a
**hint and never a requirement**, because files from other stores will not follow it.
Identification is a cascade — embedded MP4 tags first, then the name pattern, then
fuzzy title/author matching, then a manual fix-up. There will always be a tail; the
goal is to make correcting it pleasant, not to be perfect.

## Getting started on a Mac

```sh
git clone https://github.com/hsl1291/Audio-Book-Platform.git
cd Audio-Book-Platform
swift test          # expect to fix compile errors here first — see the warning above
```

Two things worth doing before writing more code, both in the plan:

1. **Reclaim ~37.5 GB.** Rescue the two titles that exist only in
   `Books (Last Download)` (*Scandalized*, *The Seven Husbands of Evelyn Hugo*), then
   delete the rest of that folder — it is 96/98 duplication.
2. **Export your Goodreads CSV** (My Books → Import and export → Export Library).
   It is the only source of your ratings and review text, and it is the fixture the
   importer is built against.

## Known open risks

- **Google OAuth scope.** Scanning a folder tree needs `drive.readonly`, a
  *restricted* scope. An unverified client in Testing mode expires refresh tokens
  every 7 days. If that holds, the fallback is iCloud Drive via `LocalFilesSource`
  and no Google at all. Settle this before building the Drive source.
- **CarPlay entitlement.** Normally granted to App Store apps; a personal app may be
  declined. The app is designed to be complete without it — `MPNowPlayingInfoCenter`
  needs no entitlement and covers most of the driving experience.
