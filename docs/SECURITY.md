# ClipShot — Security & Privacy Review

Reviewed build: ClipShot 1.0 (single-file Swift, ad-hoc signed, not sandboxed)
Reviewer scope: `src/main.swift`, `Resources/Info.plist`, `scripts/build.sh`
Date: 2026-05-23

---

## Executive summary

ClipShot is a small, local-only utility with no networking and no credential
handling, so the **blast radius is intrinsically small**: the worst realistic
outcome for an end user is a noisy log, broken Apple screenshot thumbnails left
behind on uninstall, or another local process tricking the folder watcher into
copying an arbitrary image to the clipboard. There are **no critical or high
findings** — the app does not shell out with attacker-controllable data, does
not parse untrusted formats unsafely, and does not transmit anything off-device,
matching the privacy promise shown in the welcome screen.

It is **safe to ship as a personal-use utility**, but there are a handful of
medium-severity rough edges that should be addressed before a public release:
ad-hoc signing (Gatekeeper will scare users), an unbounded log file, polling
loops that touch `~/Desktop` 10× per second, missing TCC strings for Pictures
and (likely) Screen Recording / Pasteboard implications, and a bug in
`loadHistory` that misses screenshots after the first directory level.

---

## Findings table (critical → low)

| # | Severity | Location | Issue | Fix |
|---|----------|----------|-------|-----|
| 1 | Medium | `build.sh:28` + missing notarization | Ad-hoc signing only; Gatekeeper will reject the first launch and the user must right-click → Open. Distributing this way trains users to bypass Gatekeeper. | Sign with a Developer ID Application cert, notarize, and staple. |
| 2 | Medium | `main.swift:61-73` (`clog`) and `logURL` | Log file grows unbounded; no rotation, no size cap. Log lines are written without locking, so concurrent timer callbacks can interleave. | Add a size cap (e.g. truncate / rotate at 1 MB), serialize writes through a queue, prefer `os_log` / `Logger` (which the system rotates and privacy-redacts). |
| 3 | Medium | `main.swift:952` and `main.swift:967` (polling timers) | Two `Timer.scheduledTimer` instances fire every 100 ms forever — they enumerate `~/Desktop` and read the pasteboard `changeCount` 10× per second. Battery drain, wakes, and constant Desktop reads will show up in privacy reports. A symlinked Desktop or a very large Desktop makes this O(N) on every tick. | Switch the folder watch to `DispatchSource.makeFileSystemObjectSource` / `NSFilePresenter` / `FSEvents`; switch pasteboard watch to a longer interval (1–2 s) or `NSPasteboard` change notifications via `pasteboardChangedNotification`. |
| 4 | Medium | `main.swift:733-744` (`runDefaults`) and `applicationWillTerminate` | App mutates another app's preference domain (`com.apple.screencapture`) and `killall SystemUIServer`. This will silently stop working once the app is sandboxed for the App Store, and it leaves the user's screencapture state changed if the app crashes (cleanup only runs on graceful `applicationWillTerminate`). | Document the side effect prominently; back up the previous value before writing and restore it; consider using `CFPreferencesSetAppValue("show-thumbnail", … , "com.apple.screencapture")` + `CFPreferencesAppSynchronize` instead of shelling out; gate behavior so the app does the right thing if the write silently fails (which it will when sandboxed). |
| 5 | Medium | `main.swift:972-997` (`checkScreenshotFolder`) | Any local process / app that drops a file matching `Screenshot*.png` / `Captura*.png` / `Screen Shot*.png` into `~/Desktop` will have its bytes (a) copied to the clipboard and (b) persisted into ClipShot history without user interaction. There is no check that the file was actually created by `screencaptureagent`. | Validate provenance: check the `com.apple.metadata:_kMDItemUserTags` / quarantine xattr, verify the file is a real PNG via header magic, and ideally compare against the most recent `screencapture` PID / process via `MDItemRef`. At minimum, only trigger when the changed file's `creationDate` is within the last few seconds. |
| 6 | Medium | `main.swift:746-754` (`detectScreenshotLocation`) | The app reads `com.apple.screencapture`'s `location` and trusts it as a filesystem path. If that value is set to `/` or a huge directory, the 100 ms folder enumeration becomes a serious resource hog and exposes the contents of unrelated directories to the prefix match. | Resolve the value to a real URL with `URL(fileURLWithPath:isDirectory:)`, `realpath`, and refuse anything that isn't under the user's home directory. |
| 7 | Medium | `Info.plist` | Declares Desktop/Downloads/Documents usage strings but **not** `NSPicturesFolderUsageDescription` (users frequently set the screenshot location there) and not `NSAppleEventsUsageDescription`. If sandboxed in the future, no `com.apple.security.files.user-selected.read-write` / `read-only` entitlements either. | Add `NSPicturesFolderUsageDescription`; when adopting the App Sandbox, add scoped-folder entitlements and replace `defaults`/`killall` (sandbox forbids both). |
| 8 | Low | `main.swift:1037-1065` (`loadHistory`) | Only walks **one** level deep into `storeDir`, but new screenshots are written into `storeDir/<Month Year>/file.png`. On first launch of a new month with old months on disk, the prior month's history is picked up; but if a user ever creates nested folders (e.g. by sync tools, Time Machine restore, iCloud), entries are silently dropped. Also `HistoryItem.id = url.lastPathComponent` here vs a fresh UUID elsewhere → IDs are inconsistent and can collide. | Recurse with `FileManager.default.enumerator(at:…)`; derive `id` from the filename consistently. |
| 9 | Low | `main.swift:919-932` (`clearHistory`) | Deletes only files currently in the in-memory `history` array (capped at `maxHistory = 30`). Anything else under `~/Library/Application Support/ClipShot/history/` (older months, leftovers from previous sessions) is left behind, contradicting the "se borrarán todos" UX expectation. There is no `rm -rf`-style traversal risk because URLs are constructed from controlled state. | Walk `storeDir` and remove all `.png` files under it (or remove and recreate the directory). |
| 10 | Low | `main.swift:118-131` (`DraggableThumbnailView.startDrag`) | The dragged item is whatever `fileURL` was set when the overlay was shown. If `saveScreenshot` succeeds but the file is later deleted (e.g. `clearHistory` between overlay show and drag), the drop target receives a stale URL. Low impact — drop just fails — but worth noting. The URL is always one ClipShot itself wrote into its own Application Support tree, so a malicious actor cannot substitute it. | Re-check `FileManager.fileExists` at drag time and abort if missing. |
| 11 | Low | `main.swift:962` (`checkPasteboard`) | Anything on the system clipboard that decodes as an image — even one another app just put there, with no screenshot involvement — gets persisted to disk and shown in the floating overlay. This includes images copied from a browser, Messages, etc. The privacy step promises only "screenshots", so this is a mismatch between behavior and the user-visible promise. | Either (a) gate this path so it only triggers when the source is `screencapture` (hard to know reliably from the pasteboard), or (b) update the welcome screen's privacy step to say "screenshots and copied images". |
| 12 | Low | `main.swift:751` (`contentsOfDirectory(atPath:)` in `detectScreenshotLocation`) and `main.swift:973` | `contentsOfDirectory(atPath:)` resolves symlinks per-entry; a symlink under `~/Desktop` named `Screenshot-evil.png` pointing at a JPEG outside the home directory would be picked up, persisted into history, and put on the clipboard. The blast radius is "user-readable images get re-saved as PNG into ClipShot's history" — not a privilege escalation, but a small disclosure. | Use `URL` enumeration with `.skipsHiddenFiles` + `.producesRelativePathURLs`, then check `resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])` and skip symlinks. |
| 13 | Low | `main.swift:868-883` (`thumbnail`) | A pathological pasteboard image (e.g. 30 000 × 30 000 px) is decoded into an `NSImage`, then `lockFocus()`-blitted to a thumbnail. `NSImage(pasteboard:)` and `NSImage(contentsOf:)` will happily allocate hundreds of MB. A local prankster who controls the clipboard can OOM the app. Not a security boundary issue. | Check `image.size` and reject anything above a sane bound (e.g. 16 384 × 16 384 px), or use `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceThumbnailMaxPixelSize`. |
| 14 | Low | `main.swift:55-59` | Log directory is created with default permissions (currently 0755 on macOS user dirs, but inherits umask). On a multi-user Mac, another local user can read the log. | Create with `withIntermediateDirectories` and then `chmod(700)` the directory, `chmod(600)` the file. |
| 15 | Informational | `main.swift:733-744` | Subprocess inputs are **fully hard-coded string literals** (`"com.apple.screencapture"`, `"show-thumbnail"`, `"-bool"`, `"true"`/`"false"`, `"SystemUIServer"`). No attacker-controlled data is concatenated into `task.arguments`. `Process` with explicit `launchPath` + `arguments` array does **not** invoke a shell, so even hostile pasteboard / filename content cannot reach a shell here. Audited and clean. | (No change.) Worth keeping a regression test that asserts no string formatting is ever added to these arrays. |
| 16 | Informational | `main.swift:736` | `task.launchPath` is deprecated in macOS 13+; prefer `task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")`. Cosmetic. | Migrate to `executableURL`. |
| 17 | Informational | `main.swift:1016-1023` | `saveScreenshot` silently swallows `image.tiffRepresentation` failure and write errors. A user whose disk is full or whose Application Support is read-only sees nothing. | Surface a one-time user-facing alert or `clog`. |
| 18 | Informational | `Info.plist:23` | `LSMinimumSystemVersion` is 12.0 but `Settings.applyOpenAtLogin` requires macOS 13.0 for `SMAppService`. On macOS 12 the toggle silently does nothing. | Either bump the minimum or fall back to `SMLoginItemSetEnabled` / a `LaunchAgent`. |

---

## Detailed findings

### 1. Ad-hoc signing only — Medium

**Where:** `scripts/build.sh:28` (`codesign --force --deep --sign -`)

**Impact:** Ad-hoc signed apps trigger Gatekeeper's "ClipShot can't be opened
because it is from an unidentified developer" on first launch on every user's
Mac. Users must right-click → Open, which (a) creates friction and (b) is
exactly the workflow used to bypass malware warnings — distributing this way
normalizes that behavior. The signature also won't survive copy through
quarantine-aware transports (AirDrop, browsers, Mail) without re-validating, and
there is no notarization ticket, so Apple cannot revoke the build if it later
turns out to be malicious.

**Fix:** Acquire a Developer ID Application certificate (paid Apple Developer
account), sign with `codesign --options runtime --timestamp --sign "Developer ID
Application: <name> (<TEAMID>)"`, submit to `notarytool`, and `stapler staple`.
Update `build.sh` to take the identity as an env var so CI can sign without
checking in the team ID.

---

### 2. Unbounded log file & non-thread-safe writes — Medium

**Where:** `main.swift:55-73`

```swift
func clog(_ s: String) {
    let line = "[\(ts)] \(s)\n"
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    } else {
        try? data.write(to: logURL)
    }
}
```

**Impact:** With two 100 ms timers running indefinitely, even one occasional log
line per minute fills the file slowly but never trims. More importantly,
`FileHandle.seekToEndOfFile()` / `write` / `close` is not atomic across
concurrent callers, so log lines can interleave or corrupt. Today `clog` is
only called from `Settings.applyOpenAtLogin`'s catch block, so contention is
unlikely — but the helper is set up to be reused, and a future caller from a
background queue would silently corrupt the log.

**Fix:** Use `os.Logger` with a subsystem of `com.josecasadogenao.clipshot`
(macOS rotates it, privacy-redacts by default, and surfaces in Console.app).
If you must keep the file, route writes through a serial `DispatchQueue` and
rotate when `attributesOfItem(.size)` exceeds 1 MB.

---

### 3. 10 Hz polling for both pasteboard and Desktop — Medium

**Where:** `main.swift:950-969`

**Impact:** Two repeating timers wake the app 10 times per second, forever, in
order to (a) read `NSPasteboard.changeCount` and (b) call
`contentsOfDirectory(atPath: ~/Desktop)`. Reading the changeCount is cheap;
enumerating `~/Desktop` is not — on a Desktop with thousands of files (common
on developer Macs) each tick stats every entry, and the operation also shows up
in macOS's privacy telemetry as repeated reads of a TCC-protected folder. On
laptops this measurably impacts battery (App Nap is defeated by the timer
keeping the run loop hot).

**Fix:**

- Folder watch → `DispatchSource.makeFileSystemObjectSource(fileDescriptor:
  open(path, O_EVTONLY), eventMask: .write, queue: …)` or `FSEventStreamCreate`
  scoped to the screenshot location only.
- Pasteboard watch → either poll every 1 s (still feels instant for a clipboard
  history tool) or use `NSPasteboard`'s `changeCount` only on app activation /
  menu open.

---

### 4. Mutating another app's defaults + `killall SystemUIServer` — Medium

**Where:** `main.swift:725-744`, `applicationWillTerminate` at `:721-723`

**Impact:**

1. **Cleanup only on graceful exit.** If ClipShot crashes, is force-quit, or is
   killed by the system (out of memory, user pressed `Cmd-Opt-Esc`),
   `applicationWillTerminate` never runs. The user is left with
   `show-thumbnail = false` on `com.apple.screencapture` and is mystified by
   the missing Apple thumbnail forever after ClipShot is gone.
2. **Sandbox incompatibility.** Once the app is sandboxed (App Store or simply
   to qualify for "Apple-grade" trust), `/usr/bin/defaults` and `/usr/bin/killall`
   cannot be launched, and writing into another bundle ID's `CFPreferences`
   domain is denied by the sandbox. The same is true for App Sandbox-with-
   hardened-runtime distribution. This is a hard ceiling on future
   distribution.
3. **`killall SystemUIServer`** is a heavy hammer — it briefly flashes the menu
   bar, kills any in-progress menu interaction, and can race with other apps
   that have just begun a menu extra registration.

**Fix:**

- Before writing, read and stash the previous value in `UserDefaults.standard`
  (e.g. `clipshot.previousShowThumbnail`); on launch, if a stashed value
  exists, treat that as the user's true value and only flip it back on a clean
  exit.
- Use `CFPreferencesSetAppValue("show-thumbnail" as CFString, value,
  "com.apple.screencapture" as CFString); CFPreferencesAppSynchronize(…)` —
  same effect, no subprocess. (Note: still blocked by sandbox.)
- Replace `killall SystemUIServer` with a posted distributed notification if
  one exists; if not, accept that the change takes effect on the next
  screencapture invocation (it does; the `killall` is purely cosmetic so the
  menu bar's screenshot HUD refreshes).
- Add a "Restore Apple thumbnail" menu item that the user can hit manually if
  state ever gets stuck.

---

### 5. Folder watcher copies any matching file to clipboard — Medium

**Where:** `main.swift:972-997`

**Impact:** Any process running as the user — including a sandbox-escaped Mac
App Store app that has Desktop access, a malicious Electron app, a synced
cloud-drive folder mounted at `~/Desktop`, or a shell command — can drop a file
named `Screenshot 2026-05-23.png` into `~/Desktop` and ClipShot will silently:

1. Read it (`NSImage(contentsOf: url)`).
2. Put its bytes on the system clipboard, **clearing whatever the user had
   there before** (`pb.clearContents(); pb.writeObjects([img])`).
3. Persist a copy under Application Support.
4. Show the floating overlay.

This is not a privilege escalation, but it **is** a primitive that a local
attacker can use to (a) wipe the user's clipboard at chosen moments (DoS), (b)
inject arbitrary image content into the user's clipboard right before they
paste, and (c) cause the user to drag-and-drop an attacker-controlled PNG
believing it's a screenshot they just took.

**Fix:** Before treating a new file as a screenshot, verify it actually came
from `screencapture`. Cheap checks:

- File creation time must be within the last ~3 seconds.
- File must have the `com.apple.metadata:kMDItemIsScreenCapture` xattr (this is
  the canonical Spotlight marker macOS sets on real screenshots).
- File must have a `screencapture` quarantine origin (`com.apple.quarantine`
  not set — screenshots are not quarantined).
- Reject symlinks (`URLResourceKey.isSymbolicLinkKey`).

The `kMDItemIsScreenCapture` Spotlight attribute is the strongest single signal
here.

---

### 6. Trusting `com.apple.screencapture`'s `location` value — Medium

**Where:** `main.swift:746-754`

**Impact:** The `location` user default is itself writable by any process
running as the user (it's not TCC-protected). Setting it to `/` or `/Users` or
`/Volumes/SomeOtherUser` makes ClipShot enumerate that directory 10× per
second, surfacing whatever the prefix match catches into the clipboard and
history. Even without an attacker, a typo in the user's `defaults write` can
point ClipShot at an enormous directory.

**Fix:**

- After expanding `~`, resolve the URL with `URL(fileURLWithPath:).standardized`
  and `URL.resolvingSymlinksInPath()`.
- Reject the path if it isn't a descendant of `FileManager.default
  .homeDirectoryForCurrentUser`.
- Reject the path if `contentsOfDirectory` returns more than (say) 5 000
  entries — fall back to `~/Desktop` and surface a one-time warning.

---

### 7. Missing TCC strings & sandbox entitlements — Medium

**Where:** `Resources/Info.plist`

**Impact:** Users who change the screenshot location to `~/Pictures` (a common
choice) will trigger a TCC prompt that doesn't currently have a usage string,
which on macOS 14+ shows the generic system text instead of the app's
explanation — degrading trust. If you ever sandbox the app, you'll need
file-access entitlements (and to drop the `defaults`/`killall` calls).

**Fix:** Add `NSPicturesFolderUsageDescription`. When ready for sandboxing, add:

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
<!-- + entitlements for the specific screenshot location chosen by the user -->
```

…and migrate the screenshot-location detection to a one-time
`NSOpenPanel`-confirmed bookmark (security-scoped bookmark) the first time
ClipShot detects a non-Desktop location.

---

### 8. `loadHistory` only walks one level — Low

**Where:** `main.swift:1037-1065`

**Impact:** `saveScreenshot` writes into `storeDir/<Month Year>/`, but
`loadHistory` walks `storeDir` and only recurses into immediate children. That
happens to match today's layout, but if a user nests folders (e.g., they sync
the Application Support folder via Dropbox/iCloud which creates `.tmp.drivedownload`
subdirs, or a Time Machine restore changes the structure), screenshots are
silently absent from history. Also `HistoryItem.id` is `url.lastPathComponent`
on load but a UUID on save, so the same item has two different `id`s in the
same session — not currently used as a key but a footgun.

**Fix:**

```swift
let enumerator = fm.enumerator(at: storeDir,
    includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey],
    options: [.skipsHiddenFiles])
```

Filter for `isRegularFile && pathExtension == "png"`. Derive `id` consistently
(e.g., strip the `.png` extension off the filename).

---

### 9. `clearHistory` only deletes in-memory items — Low

**Where:** `main.swift:919-932`

**Impact:** The user is told *"Se borrarán los N screenshots guardados"*, but
the loop only iterates `history` — capped at `maxHistory = 30`. Old months and
any files that weren't loaded are kept on disk forever. There is **no
path-traversal risk** because every `imagePath` is a URL ClipShot itself
constructed under `storeDir`; the call is `removeItem(at:)`, not a shell `rm`,
so there is no glob/escaping concern.

**Fix:**

```swift
if let entries = try? FileManager.default.contentsOfDirectory(
    at: storeDir, includingPropertiesForKeys: nil) {
    for entry in entries { try? FileManager.default.removeItem(at: entry) }
}
```

—and confirm `storeDir == applicationSupport + "ClipShot/history"` before
deleting (defense in depth).

---

### 10. Stale `fileURL` on drag — Low

**Where:** `main.swift:118-131`

**Impact:** `DraggableThumbnailView.startDrag` writes
`url.absoluteString` to a pasteboard item. The URL is always one ClipShot
created under its own Application Support tree, so an attacker cannot
substitute it. But if `clearHistory` ran between the overlay being shown and
the user starting a drag, the drop target receives a `file://…` URL pointing
at a now-deleted file. Drag drop fails silently in the destination app.

**Fix:** Inside `startDrag`, re-check `FileManager.default.fileExists(atPath:
url.path)` and abort the drag if missing.

---

### 11. Pasteboard monitor saves *anything* image-shaped — Low (privacy mismatch)

**Where:** `main.swift:957-964`

**Impact:** The welcome screen's privacy step (lines 537-573) promises:

> Todos los **screenshots** se guardan localmente en tu carpeta de Aplicación
> de ClipShot.

But `checkPasteboard` saves any TIFF/PNG that lands on the clipboard — copying
an image from Safari, dragging from Messages, exporting from Photos — all of
those end up in ClipShot's history. Functionally this is a feature (clipboard
history of images), but it is materially different from what the privacy step
promises.

**Fix:** Pick one:

- **Match the promise:** disable the pasteboard monitor entirely; rely solely
  on the folder watcher (after applying finding #5).
- **Match the behavior:** change the welcome screen text to "screenshots y
  cualquier imagen que copies al portapapeles", and update App Store /
  marketing copy accordingly.

---

### 12. Symlinks under the screenshot folder — Low

**Where:** `main.swift:751, 973`

**Impact:** `contentsOfDirectory(atPath:)` follows symlinks transparently. A
file `~/Desktop/Screenshot-evil.png` that is actually a symlink to
`/Users/Other/secret.png` (or any user-readable file) would be slurped into
ClipShot's history and put on the clipboard. Worth flagging because it lets a
local attacker exfiltrate the *content* of files the user can read into a
location (Application Support) that another shell action might later grep. It
is **not** a privilege escalation — everything happens with the user's own
permissions.

**Fix:** Switch enumeration to URL-based:

```swift
let urls = try fm.contentsOfDirectory(at: screenshotLocation,
    includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey],
    options: [.skipsHiddenFiles])
for u in urls {
    let v = try u.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
    guard v.isRegularFile == true, v.isSymbolicLink != true else { continue }
    …
}
```

---

### 13. No size cap on decoded images — Low

**Where:** `main.swift:868-883`, `957-964`

**Impact:** `NSImage(pasteboard:)` and `NSImage(contentsOf:)` decode the full
image into memory before `thumbnail` resizes. A 30 000 × 30 000 px PNG ≈ 3.6 GB
RGBA. A user (or local prankster) putting a malformed-but-valid PNG on the
clipboard can OOM the menu-bar process. Not a security boundary — just an
availability bug.

**Fix:**

```swift
guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
let opts: [CFString: Any] = [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceThumbnailMaxPixelSize: 2048,
    kCGImageSourceShouldCacheImmediately: true
]
guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
else { return }
```

…and reject images with `image.size.width * image.size.height > 100_000_000`.

---

### 14. Log directory permissions — Low

**Where:** `main.swift:55-59`

**Impact:** On a multi-user Mac, the default user-domain `Library/Logs`
directory is `0755` (group/other readable). Today the log mostly contains
benign timer error strings, but anything you log in the future (file paths,
which can be PII) becomes visible to other local users.

**Fix:** After creating the log directory, `chmod(700)` it and `chmod(600)` the
file.

---

### 15-18. Informational

See the table above. Items 15 and 16 are about confirming the subprocess
surface is clean (it is) and modernizing the API; item 17 is about silent
failure modes; item 18 is a `LSMinimumSystemVersion` mismatch with the
`SMAppService` API.

---

## Privacy notes

### Where user data lives

| What | Where | Lifetime |
|------|-------|----------|
| Pasteboard images (last 30) | `~/Library/Application Support/ClipShot/history/<Month Year>/Captura YYYY-MM-DD a las HH-mm-ss_xxxxxx.png` | Until cleared by user (oldest evicted at 30 items) |
| User preferences | `UserDefaults.standard` (i.e. `~/Library/Preferences/com.josecasadogenao.clipshot.plist`) — keys `clipshot.hasSeenIntro`, `clipshot.savingMode`, `clipshot.showOverlay`, `clipshot.openAtLogin` | Until app removed |
| Log file | `~/Library/Logs/ClipShot.log` | Forever (no rotation) |
| System default mutated | `com.apple.screencapture / show-thumbnail` | Restored only on graceful quit |
| Login-item registration | `SMAppService` (system-managed) | Until user disables in System Settings |

### What is sent to the network

**Nothing.** No URLSession, no NSURLConnection, no socket APIs, no analytics
SDKs, no third-party frameworks, no `URLSession.shared.dataTask`. The privacy
promise in the welcome screen ("Nada se envía a internet. Nunca.") is accurate.

### What is captured but never persisted as plaintext credentials

- The clipboard is **read** every 100 ms, but only `.tiff`/`.png` types are
  inspected. Text, files, RTF, etc. are ignored. Passwords copied from a
  password manager are *not* read because they're not image types.
- However: any image on the clipboard is decoded and persisted (see finding
  #11). If a user screenshots a password field or an MFA code, the screenshot
  goes to disk in plaintext PNG. There is no encryption at rest. This is true
  of macOS's own screenshot folder as well, but the welcome screen does not
  warn the user that their screenshot history persists across reboots.

### Mismatch with the welcome screen's privacy promise

The privacy step says:

1. "Todos los screenshots se guardan localmente en tu carpeta de Aplicación de
   ClipShot." → **True**, but it's actually `~/Library/Application Support`,
   which is hidden by default. Surfacing the path (e.g. via the "Open History
   Folder" menu item — which exists, good) is the right call.
2. "Nada se envía a internet. Nunca." → **True**.
3. "Los desarrolladores no tienen ningún acceso a tus imágenes ni a tu
   actividad." → **True** (no telemetry, no crash reporting).
4. "Sin cuentas, sin servidores, sin telemetría." → **True**.

The one omission is **finding #11**: the privacy step talks about screenshots
only, but the pasteboard watcher captures any image. Either disclose it or
gate the watcher.

---

## Pre-ship checklist

Before public release, address at minimum:

- [ ] **Sign with a Developer ID Application certificate** and notarize
      (finding #1). Without this, the first-launch experience is broken for
      every user.
- [ ] **Document or fix the `defaults` / `killall` side effect** (finding #4):
      back up the previous `show-thumbnail` value before writing it; restore on
      next launch even if the prior quit was unclean; add a manual "Restore
      Apple thumbnail" menu item.
- [ ] **Replace the 100 ms folder polling** with `DispatchSource` / `FSEvents`
      (finding #3). This is the single biggest battery/UX win.
- [ ] **Validate that new files in the screenshot folder are real
      screenshots** (finding #5) — at minimum check
      `kMDItemIsScreenCapture` and creation time.
- [ ] **Bound the log file** and switch to `os.Logger` (finding #2).
- [ ] **Reconcile the privacy promise with the pasteboard monitor's behavior**
      (finding #11) — either change the copy or change the behavior.
- [ ] **Add `NSPicturesFolderUsageDescription`** to `Info.plist` (finding #7).
- [ ] **Fix `loadHistory` recursion** and `clearHistory` completeness
      (findings #8, #9).
- [ ] **Reject symlinks** in `checkScreenshotFolder` (finding #12).
- [ ] **Cap decoded image size** to avoid OOM on hostile PNGs (finding #13).
- [ ] **Bump `LSMinimumSystemVersion` to 13.0** (or implement a macOS 12
      fallback for the login item) — finding #18.

After those, ClipShot is fit for general release as a personal-use utility.
None of the remaining items would harm a user; they are quality-of-life
improvements.
