# ClipShot — App Store conversion notes

Companion document to `docs/APPSTORE.md`. Describes every concrete delta
between the notarized DMG build (`src/main.swift`) and the Mac App Store
build (`appstore/src/main.swift`), and the exact Xcode project settings
needed to ship the result.

---

## 1. Behavior changes vs the DMG build

### Removed entirely

- **"Instant" saving mode.** The whole `SavingMode` enum is gone. The Store
  build only ever operates in what used to be `.appleNative`. There is no
  user-facing mode switcher.
- **`disableSystemThumbnail()` / `restoreSystemThumbnail()` / `runDefaults()`.**
  Gone. The App Store sandbox blocks `Process()` spawning
  `/usr/bin/defaults` against another bundle's prefs domain, and Apple
  rejects the feature under guidelines 2.5.1 and 2.5.9 regardless.
- **`applyCurrentSavingMode()` and `applicationWillTerminate`'s call to
  `restoreSystemThumbnail()`**. `applicationWillTerminate` now only releases
  the security-scoped resource (no system state to restore).
- **`Settings.savingMode`** and **`Settings.originalShowThumbnail`** keys —
  no longer read, no longer written. (Old keys in user defaults are
  harmless; ignored.)
- **"Modo de guardado" preferences submenu items.** Removed.
- **Reading `com.apple.screencapture` UserDefaults** to detect the
  screenshot location. Under sandbox, cross-domain UserDefaults reads
  return nil. Replaced with security-scoped bookmark flow (see below).
- **`NS*FolderUsageDescription` Info.plist keys** (Desktop, Downloads,
  Documents, Pictures). Sandbox replaces these with entitlements + the
  user-selected security-scoped bookmark grant.
- **Timer-based folder polling fallback.** Previously the DMG build fell
  back to a 1-second `Timer` if `open(O_EVTONLY)` failed. Removed —
  polling a sandbox-blocked path just burns energy with no events. If the
  user hasn't granted access yet via the welcome flow, the watcher is
  simply not installed; the pasteboard path still catches
  Cmd-Shift-Ctrl-3/4 captures.

### Added

- **Security-scoped bookmark flow** for the screenshot folder
  (`Settings.screenshotFolderBookmark`). On first launch the user picks a
  folder via `NSOpenPanel` (defaults to Desktop); ClipShot persists a
  bookmark with `[.withSecurityScope]` and resolves +
  `startAccessingSecurityScopedResource()` it on every subsequent launch.
- **"Cambiar carpeta de screenshots…" menu item** under Preferences, which
  re-opens the `NSOpenPanel` and re-installs the folder watcher on the new
  path.
- **New welcome step "Selecciona tu carpeta de screenshots"** between
  Welcome and Overlay. Shows a "Elegir carpeta…" button that drives the
  open panel. The status label below updates after the user picks.
- **New welcome step "Cómo funciona el guardado"** replaces the old
  two-card saving-mode chooser. Single explanatory page: "ClipShot guarda
  tus screenshots ~5 segundos después de que los tomas (cuando la
  miniatura de Apple desaparece). No modifica nada del sistema."

### Changed

- **Pasteboard polling**: bumped from 0.5s → **2.0s**. App Review
  scrutinizes sub-second clipboard polling for energy impact. Note this in
  App Review Notes when submitting.
- **`loginChoice` default**: now `false` on first run (was `true`). App
  Review guideline 2.4.5(iii) wants login-item registration to be an
  explicit user opt-in.
- **Welcome flow now has 7 steps** (was 6): Welcome → Saving explanation →
  Folder picker → Overlay → Login → Privacy → Done.
- **`CFBundleShortVersionString`**: `1.0` → **`2.0`**. App Store track is
  versioned separately from the DMG track; starting at 2.0 makes the
  separation obvious in App Store Connect and in the About dialog.
- **`CFBundleVersion`**: `1.0` → **`1`** (build number; monotonically
  increases across submissions).
- **About dialog**: now shows "ClipShot 2.0".
- **`CFBundleSignature`** removed (legacy, Xcode no longer emits it).

### Unchanged behavior

- Screenshot history persists in
  `~/Library/Containers/com.josecasadogenao.clipshot/Data/Library/Application Support/ClipShot/history/`
  (sandbox container, same `.applicationSupportDirectory` API).
- Logs persist in
  `~/Library/Containers/com.josecasadogenao.clipshot/Data/Library/Logs/ClipShot.log`.
- `SMAppService.mainApp` open-at-login flow is sandbox-compatible and
  unchanged.
- Pasteboard reads (`NSPasteboard.general`) require no entitlement and are
  unchanged.
- Overlay window, drag-from-overlay, history menu, clear-history flow,
  about dialog text (except version), all unchanged.

---

## 2. Files in this directory

```
appstore/
├── CONVERSION_NOTES.md            (this file)
├── Resources/
│   ├── AppIcon.icns               (copied from DMG; replace with asset catalog before submitting)
│   ├── ClipShot.entitlements      (NEW — sandbox + user-selected files + app-scope bookmarks)
│   ├── Info.plist                 (UPDATED — version 2.0, removed NS*FolderUsageDescription)
│   └── PrivacyInfo.xcprivacy      (NEW — required for App Store since May 2024)
└── src/
    └── main.swift                 (UPDATED — all sandbox-blocking code removed)
```

The entitlements file contains exactly:

- `com.apple.security.app-sandbox = true`
- `com.apple.security.files.user-selected.read-only = true`
- `com.apple.security.files.bookmarks.app-scope = true`

Nothing else. No `network.client`, no `cs.allow-*`, no Desktop/Downloads
shortcut entitlements — the user-selected bookmark covers all cases.

---

## 3. Xcode project settings (target = `ClipShot`)

| Setting                                | Value                                                                             |
|----------------------------------------|-----------------------------------------------------------------------------------|
| Product Name                           | `ClipShot`                                                                        |
| Bundle Identifier                      | `com.josecasadogenao.clipshot` (see §5 for alternative)                           |
| Display Name                           | `ClipShot`                                                                        |
| Version (`CFBundleShortVersionString`) | `2.0`                                                                             |
| Build (`CFBundleVersion`)              | `1`                                                                               |
| Deployment Target                      | macOS 13.0                                                                        |
| Category                               | Productivity (`public.app-category.productivity`)                                 |
| App Icon Source                        | `AppIcon` (asset catalog — see step 4)                                            |
| Signing                                | Automatically manage signing, team `EC9VSP9V96` (Jean Carlos Morla Genao)         |
| Signing Certificate                    | `Apple Distribution`                                                              |
| Capabilities                           | **App Sandbox** + **Hardened Runtime**                                            |
| `CODE_SIGN_ENTITLEMENTS`               | `ClipShot/ClipShot.entitlements` (this file from `appstore/Resources/`)           |
| `ENABLE_HARDENED_RUNTIME`              | `YES`                                                                             |
| `ARCHS`                                | `$(ARCHS_STANDARD)` (Universal: arm64 + x86_64)                                   |
| `SWIFT_VERSION`                        | 5.0 or higher                                                                     |
| `DEBUG_INFORMATION_FORMAT` (Release)   | `dwarf-with-dsym`                                                                 |
| `LSUIElement`                          | true (menu-bar only, no Dock icon)                                                |
| Storyboard / SwiftUI                   | None — pure AppKit, single `main.swift` is the entry point                        |
| Privacy manifest path                  | `ClipShot/PrivacyInfo.xcprivacy` in Copy Bundle Resources                         |

---

## 4. Five-step submission flow

Do these in order. Assumes Apple Developer Program enrollment is already
done and the App ID `com.josecasadogenao.clipshot` exists in
`developer.apple.com → Identifiers`.

### Step 1: Create the Xcode project

1. Xcode → File → New → Project → macOS → **App**.
2. Product Name: `ClipShot`. Team: `EC9VSP9V96`. Organization Identifier:
   `com.josecasadogenao`. Interface: **AppKit App Delegate**. Language:
   Swift. Storyboard: **None**. Tests: uncheck both.
3. Save the `.xcodeproj` at `/Users/josecasadogenao/Mac App/ClipShot.xcodeproj`.
4. Delete the auto-generated `AppDelegate.swift`, `ViewController.swift`,
   `Main.storyboard`, and the empty `Assets.xcassets`/`Info.plist` — you'll
   replace each.

### Step 2: Wire in the App Store source + resources

1. Drag `appstore/src/main.swift` into the project (Create groups; target
   membership `ClipShot`). Confirm Build Phases → Compile Sources has only
   `main.swift`.
2. Drag `appstore/Resources/Info.plist` into the project; in Target →
   Build Settings set `INFOPLIST_FILE = ClipShot/Info.plist`.
3. Drag `appstore/Resources/ClipShot.entitlements` into the project. In
   Build Settings set `CODE_SIGN_ENTITLEMENTS = ClipShot/ClipShot.entitlements`.
4. Drag `appstore/Resources/PrivacyInfo.xcprivacy` into the project; verify
   it appears in Build Phases → Copy Bundle Resources.
5. Create `Assets.xcassets`; New → AppIcon set named `AppIcon`. Generate
   16/32/64/128/256/512/1024 @1x and @2x PNGs from a 1024×1024 master
   (`iconutil`, Bakery, or Icon Composer). Drop them into the AppIcon
   slots. Remove the legacy `CFBundleIconFile` key from Info.plist once the
   asset catalog is wired up.

### Step 3: Configure signing + capabilities

1. Target → Signing & Capabilities. Toggle **Automatically manage signing**
   on. Team: `EC9VSP9V96`. Signing Certificate: `Apple Distribution`.
2. Click `+ Capability` → add **App Sandbox**. Xcode will offer to merge
   into the existing entitlements file you wired up. Accept. Verify the
   three keys above are present and nothing else.
3. Click `+ Capability` → add **Hardened Runtime**. Verify `Build
   Settings → ENABLE_HARDENED_RUNTIME = YES`.

### Step 4: Run locally + validate

1. Product → Run (Cmd-R). The app should launch, show the welcome window,
   walk through the seven steps, and end in the menu bar with the camera
   icon. The folder picker step is where the sandbox opens up.
2. Take a Cmd-Shift-3. After ~5 seconds the screenshot should appear in
   the floating overlay and in the menu-bar history.
3. Product → Archive (release build). Organizer opens → click **Validate
   App** → fix any warnings. Common ones:
   - Missing icon size: complete the asset catalog.
   - Privacy manifest missing reason: this should already pass since
     `PrivacyInfo.xcprivacy` declares both required-reason categories.
   - Entitlement com.apple.security.app-sandbox required: this should
     already pass since the entitlements file has it.

### Step 5: Distribute → App Store Connect

1. In Organizer, with the archive selected, click **Distribute App** →
   **App Store Connect** → **Upload** → use automatic signing → next →
   next → Upload.
2. Wait ~10 minutes for App Store Connect to finish processing the build
   (you get an email).
3. In App Store Connect → Apps → ClipShot → 2.0 Prepare for Submission,
   attach the uploaded build, fill in description/keywords/screenshots
   (see `docs/APPSTORE.md` §7), answer the App Privacy questionnaire
   ("Data Not Collected" for everything), set pricing, and click **Add
   for Review**.

---

## 5. Note on bundle ID

The bundle ID `com.josecasadogenao.clipshot` is kept here so any existing
test users' UserDefaults / `~/Library/Containers/...clipshot/` data still
applies on upgrade.

For the very first App Store submission, however, switching to a fresh
bundle ID like `com.morlagenao.clipshot` may be preferable because:

- The current team on the developer account is **Jean Carlos Morla Genao
  (`EC9VSP9V96`)**, not "José Casado Genao". App Store Connect ties
  bundle IDs to the team; mismatched legal-name/identifier prefixes do
  not block submission but look odd in the developer portal.
- A clean bundle ID has no risk of inheriting any unexpected state from
  the DMG track.

To switch: change `CFBundleIdentifier` in `appstore/Resources/Info.plist`,
register the new App ID in `developer.apple.com → Identifiers`, and
update any references in `main.swift` (currently the only hardcoded
references are in the log path and `deleteAllHistory()` guard, both of
which derive from `applicationSupportDirectory` and will adapt
automatically). The container path will change to
`~/Library/Containers/com.morlagenao.clipshot/...`.

Decide before Step 1 above — once the App ID is created and the first
build is uploaded, changing the bundle ID requires a brand-new app record
in App Store Connect.

---

## 6. Next concrete action

Open Xcode → File → New → Project → macOS → App → follow §3 / §4 above.
The whole conversion from "swiftc binary" to "Validate App passes" is
typically 1–2 hours of focused work in Xcode once these source/resource
files are in place.
