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

| Works now | Not built yet |
|---|---|
| Pick a Files / iCloud Drive books folder; scan, dedupe, read covers and authors from the files | Streaming or downloading from Google Drive |
| Waiting to Read, Want (with Add Book), Read, Book Detail | CarPlay library browsing (needs Apple's entitlement) |
| Playback with chapters, per-book speed, smart rewind, position saved every 15 s | Widgets, Live Activity, Siri |
| Lock screen, AirPods and in-car Now Playing controls | Kindle import |
| Goodreads import as reading history, merged with books you have files for | |

## How the tabs are filled

- **Waiting to Read** — every audiobook in your folder you have not finished.
- **Want** — books you add yourself with the + button.
- **Read** — your Goodreads history, plus anything filed under `_Read`.

The Goodreads export is used **only as reading history**. Its Read shelf fills the
Read tab, with your ratings and reviews; its to-read and currently-reading shelves
are ignored. A book you have both read and kept appears once, matched by ISBN or by
title and author.

## Layout

```
Package.swift              SPM package — Foundation only, builds anywhere
Sources/BacklistCore/      parsing, matching, reconciliation and storage policy
Tests/BacklistCoreTests/   `swift test`, no Xcode, no simulator
App/Backlist/              the iOS app: SwiftUI, SwiftData, AVFoundation
project.yml                XcodeGen spec for the app target
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

Before the first build on a device, set `DEVELOPMENT_TEAM` in `project.yml`. The paid
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

- **Google OAuth scope.** Scanning a Drive folder tree needs `drive.readonly`, a
  *restricted* scope; an unverified client in Testing mode expires refresh tokens
  every 7 days. A Files or iCloud Drive folder avoids OAuth entirely and is the
  recommended setup.
- **CarPlay entitlement.** Normally granted to App Store apps; a personal app may be
  declined. The app is complete without it — Now Playing needs no entitlement and
  covers the driving experience except browsing the library on the car's screen.
