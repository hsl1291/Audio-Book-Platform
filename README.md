# Backlist

One place for every book you own, want, and have read.

Audio you own, what you still want, what you have read, and where you were in it —
offline-first, native iOS, no dependency on any store's app.

Full design: [`docs/PLAN.md`](docs/PLAN.md).

---

## Status

**Built and verified by CI on every push** — the core package's tests on Linux, and
the full iOS app for the simulator on macOS, under the Swift 6 language mode with
zero warnings.

**Not yet run on a device.** A clean build is not a working app. SwiftData's
CloudKit constraints, security-scoped folder access and background audio all fail at
runtime rather than compile time, so the first launch on a phone is where the next
defects will surface.

### What is built

| Area | What it does |
|---|---|
| **Library** | Pick a books folder in Files (iCloud Drive, Google Drive and others). Scans it, merges duplicates, reads titles, authors, narrators, durations and covers from the files themselves. |
| **Waiting to Read** | Cover grid of everything you own and haven't finished — audio and Kindle, with All / Audio / Kindle chips — plus a one-tap Continue card. |
| **Want** | Your shopping list; add books with +. A wanted book moves to Waiting to Read when a file or Kindle copy turns up. |
| **Read** | Your Goodreads history with ratings and reviews, searchable, merged with books you have files for. |
| **Covers** | Embedded art from the audio file; Open Library for books with no file. Cached, so they show offline. |
| **Downloads** | Keeps the next few books on the phone and releases finished ones, within a storage limit, on Wi-Fi (and optionally only while charging). Per-book Download / Remove from iPhone / Keep downloaded. Tapping play on a book in the cloud downloads it and starts it when it arrives. |
| **Player** | Chapters, per-book speed, smart rewind, position saved every 15 s and when switching books, sleep timer (countdown or end of chapter, fade-out, shake to extend — works with the screen locked). |
| **Driving** | Lock screen, AirPods and CarPlay Now Playing controls. Siri: "Resume my book in Backlist", "Play *Outliers* in Backlist", "Pause my book in Backlist". A CarPlay library screen, which turns on only if Apple grants the entitlement. |
| **Widget** | Home Screen (small, medium) and Lock Screen: current book, progress, time left. Tap to resume. |
| **Kindle** | Import from Amazon's data export; Kindle books appear as owned, with an Open in Kindle button. |
| **Privacy** | Mark a book private and it is hidden from the lists, widget, CarPlay, Siri and the lock screen. Settings → Show private books reveals them in the lists until the app is next opened. |

### Not built

- **Google Drive direct (OAuth).** The core has a Drive source, but the app reaches
  Drive through the Files app instead, which needs no sign-in and no Google review.
- **Manual "this is that book" fix-up** for files the matcher could not identify.
  They appear as their own entries, titled from the file name.
- **Live Activity** on the Lock Screen while playing. The standard Now Playing
  controls already appear there.

### Set up on your phone

1. Mac with Xcode 16 or later: `brew install xcodegen && xcodegen generate`, open
   `Backlist.xcodeproj`.
2. In `project.yml`, set `DEVELOPMENT_TEAM` for **both** targets (app and widget)
   and regenerate. With a paid developer account, Xcode registers the iCloud
   container and App Group automatically on the first device build.
3. Build to your iPhone. Settings → **Choose books folder** → your `Books` folder
   in Files. **Test this first with one book.** iCloud Drive is known to support
   what Backlist needs (lasting folder access, fetching and releasing files on
   demand). Google Drive's Files integration is unverified: if it will not let you
   pick the folder, or books never finish downloading, move `Books` to iCloud Drive
   (on a Mac, drag it into iCloud Drive in Finder) and point Libation's output
   there.
4. Settings → **Import Goodreads export** with the CSV from Goodreads.
5. Optional: Settings → **Import Kindle books** with files from Amazon's data export.
6. Optional: add the widget; try "Hey Siri, resume my book in Backlist".

## How the tabs are filled

- **Waiting to Read** — every audiobook in your folder and every Kindle book you
  have imported, until you finish it.
- **Want** — books you add yourself with the + button.
- **Read** — your Goodreads history, plus anything filed under `_Read`.

The Goodreads export is used **only as reading history**. Its Read shelf fills the
Read tab, with your ratings and reviews; its to-read and currently-reading shelves
are ignored. A book you have both read and kept appears once, matched by ISBN or by
title and author.

## Layout

```
Package.swift              SPM package — Foundation only, builds anywhere
Sources/BacklistCore/      parsing, matching, reconciliation, storage policy,
                           sleep timer, Kindle and cover lookups
Tests/BacklistCoreTests/   `swift test`, no Xcode, no simulator
App/Backlist/              the iOS app: SwiftUI, SwiftData, AVFoundation,
                           App Intents, CarPlay
App/BacklistWidget/        Home Screen and Lock Screen widget extension
project.yml                XcodeGen spec for both targets
.github/workflows/ci.yml   Linux tests + macOS app build on every push
```

`BacklistCore` imports **nothing but Foundation**, and every decision worth arguing
about lives there — identification, duplicate resolution, Goodreads parsing, which
scanned book is which imported book, what stays on the phone — so it is covered by
tests that run in seconds. The app layer is kept thin on purpose.

## Building the app

```sh
brew install xcodegen
xcodegen generate
open Backlist.xcodeproj
```

Before the first build on a device, set `DEVELOPMENT_TEAM` for both targets in
`project.yml`. The paid
Apple Developer Program is effectively required: on a free account provisioning
expires every seven days and the app stops launching, which is not acceptable for
something holding your listening position.

## The one principle everything follows

**The folder is the contract.** Backlist watches a folder. Anything that puts a
playable audio file there is a valid source. The app does not integrate with stores,
hold store credentials, or care how a file arrived — which is what makes switching
audiobook stores free, and why the app has no DRM surface at all.

The `Title [ID]` naming convention is a **hint, never a requirement**, because files
from other stores will not follow it. Identification cascades from embedded MP4 tags
to the name pattern to title-and-author matching.

## The Drive library

Cleaned up on 2026-09-22. `Books (Last Download)` held a second copy of 98 books;
every one was verified to have a same-size twin elsewhere before the folder was moved
to Drive's trash (recoverable for 30 days), freeing 48.2 GiB. 106 books remain, one
copy each: 76 in `_Read`, 28 in `_Too Read`, 2 in `KRL`.

If Libation is still in use, its output folder will reappear inside `_Read`. The app
treats that folder as unfiled rather than read, so new downloads still land in
Waiting to Read — but pointing Libation's output somewhere outside `_Read` avoids the
clutter.

## Known open risks

- **Google Drive through Files.** Untested on a device; see step 3 above. iCloud
  Drive is the safe choice.

- **Google OAuth scope.** Scanning a Drive folder tree needs `drive.readonly`, a
  *restricted* scope; an unverified client in Testing mode expires refresh tokens
  every 7 days. A Files or iCloud Drive folder avoids OAuth entirely and is the
  recommended setup.
- **CarPlay entitlement.** Normally granted to App Store apps; a personal app may be
  declined. The app is complete without it — Now Playing needs no entitlement and
  covers the driving experience except browsing the library on the car's screen.
