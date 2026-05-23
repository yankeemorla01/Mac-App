# Shipping ClipShot to the Mac App Store

Status today: ad-hoc signed `.app` built by `scripts/build.sh` via `swiftc`, no
Xcode project, no sandbox, hard dependencies on behaviors that the App Store
sandbox will block. This document is the concrete, ordered plan to get ClipShot
from "ad-hoc binary" to "Ready for Sale" in App Store Connect.

Bundle ID for all of the below: `com.josecasadogenao.clipshot`.

---

## 1. Apple Developer setup

### Accounts and money

- **Apple Developer Program membership**, individual or organization. Cost:
  **USD 99/year**. Pay in App Store Connect at
  `https://developer.apple.com/programs/enroll/`.
- **Apple ID** with two-factor authentication enabled. Use the email you want
  permanently tied to the developer record — you cannot easily change it later.
- If enrolling as an **organization**, you need a D-U-N-S number (free, ~1–2
  weeks to get). For "Jose Casado Genao" as an individual, you can skip this.
- Decide **legal name on the App Store** before enrolling. For individuals it is
  the personal legal name and it shows publicly as the seller. If you do not
  want your full legal name shown, enroll as an LLC / sole proprietor first.

### Timeline

- Individual enrollment: **24–48 hours** for Apple to approve once payment
  clears.
- Organization enrollment with D-U-N-S: **1–3 weeks**.

### Certificates, identifiers, profiles (CIPP)

Done in `https://developer.apple.com/account/resources/`:

1. **Certificates** (you need two, both can be created from Xcode → Settings →
   Accounts → Manage Certificates):
   - `Apple Development` — for local debug builds.
   - `Apple Distribution` — for submitting builds to App Store Connect. This
     single cert covers both Mac App Store and notarization workflows under the
     newer "Apple Distribution" identity (replaces the old
     "3rd Party Mac Developer Application" + "3rd Party Mac Developer
     Installer" pair, though those still work).
   - Optional but recommended for the .pkg installer: **Mac Installer
     Distribution** certificate, used by `productbuild`/`productsign` when
     uploading. Xcode handles this automatically if you use the Organizer.
2. **App ID**: register `com.josecasadogenao.clipshot` as an explicit App ID
   (not a wildcard). Capabilities to leave **off** for now: iCloud, Push, App
   Groups, Sign in with Apple, Game Center, Maps. None apply to ClipShot.
3. **Provisioning profiles**: for Mac App Store distribution Apple now manages
   these automatically when Xcode has "Automatically manage signing" enabled —
   leave it on. If you decide to do it manually, generate a **Mac App Store
   Distribution** profile tied to the App ID and the Apple Distribution cert.

### One-time keys you should also create

- **App Store Connect API key** (App Store Connect → Users and Access → Keys →
  App Store Connect API). Save the `.p8` file. This lets `xcrun altool` /
  `notarytool` upload builds without a password.

---

## 2. Xcode project requirement

The Mac App Store **does not accept bare `.app` bundles uploaded via
`altool`/`Transporter` alone for new app records** — you can technically
`xcrun altool --upload-app` a hand-built `.pkg`, but you will spend more time
fighting signing, asset catalog, and entitlement issues than you'd spend
converting. **Use Xcode.** Apple's review tooling, dSYM symbolication, asset
catalogs, and bitcode/archive flow all assume an Xcode project.

### Convert this swiftc build to an Xcode project

Concrete steps. Do them in order.

1. **Create the project skeleton**:
   - File → New → Project → macOS → **App**.
   - Product Name: `ClipShot`
   - Team: your Apple Developer team.
   - Organization Identifier: `com.josecasadogenao` (so the bundle ID
     auto-fills to `com.josecasadogenao.clipshot`).
   - Interface: **AppKit App Delegate** (not SwiftUI — your code is pure
     AppKit).
   - Language: Swift. Storyboard: **None**. Tests: uncheck both.
   - Save it at `/Users/josecasadogenao/Mac App/ClipShot.xcodeproj` so the
     existing repo stays the project root.
2. **Replace the boilerplate**:
   - Delete the generated `AppDelegate.swift`, `ViewController.swift`,
     `Main.storyboard`, `Assets.xcassets`/`Info.plist` (you will re-add real
     ones).
   - Drag `src/main.swift` into the project — choose "Create groups", target
     membership **ClipShot**. Your file already has `let app =
     NSApplication.shared; app.delegate = delegate; app.run()` at the bottom,
     so you do **not** want Xcode's generated `@main AppDelegate` — keep only
     `src/main.swift`.
3. **Target → General**:
   - Display Name: `ClipShot`
   - Bundle Identifier: `com.josecasadogenao.clipshot`
   - Version: `1.0`
   - Build: `1`
   - Minimum Deployments → macOS: **12.0**
   - Category: **Productivity** (see §6).
   - Identity → App Icon Source: `AppIcon` (asset catalog, see step 6).
4. **Target → Signing & Capabilities**:
   - "Automatically manage signing" **on**.
   - Team: your developer team.
   - Signing Certificate: `Apple Distribution`.
   - Click `+ Capability` → add **App Sandbox** (mandatory, see §3).
   - Click `+ Capability` → add **Hardened Runtime** (mandatory).
5. **Target → Build Settings**:
   - `ARCHS` = `$(ARCHS_STANDARD)` — let Xcode produce a Universal binary
     (arm64 + x86_64). The store accepts arm64-only too, but Universal is the
     standard expectation and tiny in download size.
   - `MACOSX_DEPLOYMENT_TARGET` = `12.0`.
   - `SWIFT_VERSION` = `5.0` or higher.
   - `ENABLE_HARDENED_RUNTIME` = `YES` (set by the capability).
   - `CODE_SIGN_ENTITLEMENTS` = `ClipShot/ClipShot.entitlements` (Xcode creates
     this file when you add the App Sandbox capability — verify the path).
   - `DEVELOPMENT_TEAM` = your team ID.
   - `INFOPLIST_FILE` = `ClipShot/Info.plist` (you will paste in the keys from
     `Resources/Info.plist` plus the additions in §6).
   - Strip the legacy `CFBundleSignature = ????` — Xcode no longer emits it.
6. **Build Phases**:
   - Compile Sources: only `main.swift`. Confirm there is no duplicate
     `AppDelegate.swift`.
   - Copy Bundle Resources: drag your `Resources/AppIcon.icns` only if you
     keep the legacy `CFBundleIconFile` approach. **Preferred**: use an asset
     catalog. Create `Assets.xcassets` → New AppIcon set named `AppIcon`, drop
     in 16, 32, 64, 128, 256, 512, 1024 @1x and @2x PNGs (see §7 for icon
     specs). Then remove `CFBundleIconFile` from Info.plist; Xcode injects
     `CFBundleIconName = AppIcon` automatically.
   - Add a **PrivacyInfo.xcprivacy** file (see §5) to Copy Bundle Resources.
7. **Delete the swiftc build**: keep `scripts/build.sh` only for local
   development if you want, but **never submit a swiftc-built binary to the
   Store**. The Store build must come out of `xcodebuild archive` →
   "Distribute App" → "App Store Connect". Update the Makefile so `make build`
   either runs `xcodebuild` or makes it obvious that the store path is
   different.
8. **Verify**: `Product → Archive` should produce an archive in the Organizer.
   Click "Validate App" — fix every warning before doing the upload.

---

## 3. Sandboxing — exact failure points in current code

App Sandbox is **mandatory** for the Mac App Store (App Review Guideline
**2.4.5(i)**). Without `com.apple.security.app-sandbox = true` your build is
rejected on upload, before a human sees it. Here is every place
`src/main.swift` will fail under the sandbox, line by line, with the fix.

### 3.1 `runDefaults` writes another app's preferences via `/usr/bin/defaults`

**Lines 733–744** (`runDefaults`):

```swift
task.launchPath = "/usr/bin/defaults"
task.arguments = ["write", "com.apple.screencapture", "show-thumbnail", "-bool", value]
...
kill.launchPath = "/usr/bin/killall"
kill.arguments = ["SystemUIServer"]
```

This will **fail twice** under the sandbox **and** is an outright App Review
violation:

1. `Process` / `posix_spawn` of `/usr/bin/defaults` is blocked by the sandbox
   (no `com.apple.security.temporary-exception.files.absolute-path.read-write`
   would cover spawning system binaries to mutate another app's prefs domain).
   Even with a temporary exception, Apple will reject it.
2. Writing to `com.apple.screencapture` is writing to **another app's
   preferences domain**, which the sandbox explicitly denies. The sandbox only
   gives you `~/Library/Containers/com.josecasadogenao.clipshot/Data/Library/
   Preferences/com.josecasadogenao.clipshot.plist`. There is no entitlement
   that opens up `com.apple.screencapture` for you.
3. `killall SystemUIServer` is a hard rejection. It alters system state outside
   your app's container and violates Guideline **2.5.1** ("apps must only use
   public APIs") and **2.5.9** (do not alter system UI behavior). The sandbox
   blocks `kill(2)` against other users' / system processes regardless.

**Fix**: remove the entire "instant mode" feature, or restructure it.
Realistic options:

- **Option A (recommended)**: drop "instant" mode for v1.0 App Store release.
  Keep only `appleNative` mode. The app still has clear value (history of
  screenshots, copy-to-clipboard, drag-to-edit). Remove the `SavingMode` enum,
  `runDefaults`, `disableSystemThumbnail`, `restoreSystemThumbnail`,
  `applyCurrentSavingMode`, and the "Modo de guardado" submenu. Update the
  welcome flow to skip the saving-mode step (drop `buildSavingMode`).
- **Option B**: keep both modes but make "instant" a non-store feature; tell
  users in the welcome that the on-the-Mac-App-Store build only supports the
  Apple-native mode, and ship the full version via direct download +
  notarization (see §8). This bifurcates the codebase — more work.
- **Option C**: rebuild "instant" without touching `com.apple.screencapture`.
  Instead of hiding Apple's thumbnail, **suppress your own overlay when one is
  not desired** and use `CGEvent` / `NSEvent` hot-key monitors to detect
  Cmd-Shift-3/4 and copy to pasteboard yourself. This avoids the system
  preference write entirely. Still risky — Cmd-Shift-3/4 monitoring needs the
  Accessibility permission (`AXIsProcessTrustedWithOptions`), which is itself
  fragile under the sandbox and requires a TCC prompt the user must approve.
  Likely not worth it for v1.0.

Pick **Option A** unless you have a strong reason not to. The rest of this
document assumes Option A.

### 3.2 Reading `com.apple.screencapture` location preference

**Lines 746–754** (`detectScreenshotLocation`):

```swift
if let loc = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), ...
```

Under the sandbox, `UserDefaults(suiteName:)` for a **non-owned** domain
returns `nil` (the sandbox does not grant cross-domain read of arbitrary
preferences). You will silently always fall back to `~/Desktop`.

**Fix**: do not try to read `com.apple.screencapture`'s `location`. Instead:

1. Default to `~/Desktop` (what 99% of macOS users have).
2. Add a menu item "Set screenshots folder…" that opens an `NSOpenPanel`
   restricted to `.canChooseDirectories = true`. The user-picked folder is
   granted to the sandbox via the **user-selected** entitlement; persist the
   URL with a **security-scoped bookmark**:

```swift
let bookmark = try url.bookmarkData(
    options: [.withSecurityScope],
    includingResourceValuesForKeys: nil,
    relativeTo: nil)
UserDefaults.standard.set(bookmark, forKey: "clipshot.screenshotFolderBookmark")
```

On launch, resolve and call `startAccessingSecurityScopedResource()`. This is
the **only** sandbox-compliant way to watch a user folder.

### 3.3 Watching `~/Desktop` (or wherever screenshots land)

**Lines 663, 746–754, 972–997** (`screenshotLocation`,
`checkScreenshotFolder`):

```swift
var screenshotLocation: URL = URL(fileURLWithPath: (NSString("~/Desktop").expandingTildeInPath))
```

The sandbox blocks direct access to `~/Desktop` unless you have either:

- `com.apple.security.files.user-selected.read-write` plus a user-selected
  folder (you got a bookmark — preferred), **or**
- TCC consent for the Desktop folder via the `NSDesktopFolderUsageDescription`
  Info.plist key plus a system prompt. Note: the TCC prompt only fires when you
  *actually try to access* the path — and sandboxed access to standard folders
  is still gated by entitlements like `com.apple.security.files.desktop.
  read-only` / `read-write`.

**Fix**: combine both belts and braces. Add the entitlement
`com.apple.security.files.desktop.read-only` so the most common case (Apple's
default screenshot location) works without bookmarks. Keep the
`NSDesktopFolderUsageDescription` you already have. For users whose screenshot
folder is elsewhere (Downloads, custom), the security-scoped bookmark flow in
§3.2 takes over.

Additional sandbox-friendly cleanup of `checkScreenshotFolder`:

- `Timer` polling at 100ms is wasteful and looks bad in Activity Monitor. Use
  **`DispatchSource.makeFileSystemObjectSource`** or **`NSMetadataQuery`** to
  observe additions. `NSMetadataQuery` works under the sandbox; raw `kqueue`
  on a folder you only have read access to may not. Either is fine; both are
  better than the timer.

### 3.4 Writing the history folder to `~/Library/Application Support/ClipShot/`

**Lines 670–672** (`init`):

```swift
let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
storeDir = appSupport.appendingPathComponent("ClipShot/history")
```

Under the sandbox, `.applicationSupportDirectory` resolves to
`~/Library/Containers/com.josecasadogenao.clipshot/Data/Library/Application
Support/`, **not** `~/Library/Application Support/`. **This is fine** — the
code keeps working, just in a different location. But:

- The path that appears in "Acerca de ClipShot" (`showAbout`, line 945) will
  show users the long container path. Either trim it before display or change
  the "Open history folder" affordance to be the primary discovery method.
- **Migration**: on first sandboxed launch, if the legacy
  `~/Library/Application Support/ClipShot/history` exists (from pre-store
  installs), you cannot read it. Apple's sandbox migration story: the system
  *does* allow your sandboxed app to access files in your own non-sandboxed
  application-support path **only if** the prior unsandboxed version was
  installed before sandboxing was turned on, via a special "migration"
  exception. For a brand-new App Store release this is moot — you have no
  existing user base. Skip migration logic for v1.0.

### 3.5 Log file at `~/Library/Logs/ClipShot.log`

**Lines 55–73** (`logURL`, `clog`):

```swift
let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!.appendingPathComponent("Logs")
```

Same as 3.4 — `.libraryDirectory` becomes the container's `Library/`. Logs
will land at `~/Library/Containers/com.josecasadogenao.clipshot/Data/Library/
Logs/ClipShot.log`. That is correct behavior, no change needed, but users
looking in `~/Library/Logs/` will not find it. Either:

- Switch to `os_log` / `Logger(subsystem: "com.josecasadogenao.clipshot",
  category: "general")`. `Console.app` will show entries under the subsystem
  name. **Preferred** for the Store build.
- Or keep `clog` and add a "Reveal log…" menu item that opens the container
  log directly with `NSWorkspace.shared.activateFileViewerSelecting(...)`.

### 3.6 `NSWorkspace.shared.open(url)` to launch the screenshot file

**Line 192, 916** (overlay click handler, `openHistoryFolder`):

```swift
NSWorkspace.shared.open(url)
NSWorkspace.shared.open(storeDir)
```

`NSWorkspace.shared.open(URL)` for **files your app owns** (inside its
container, or files explicitly granted via NSOpenPanel) works under the
sandbox. Opening `storeDir` (your container) works. Opening a file at the
clipboard's location works because you wrote it. **No change needed.**

### 3.7 `SMAppService.mainApp.register()` (open at login)

**Lines 35–51** (`Settings.applyOpenAtLogin`):

`SMAppService.mainApp` is **fully compatible with the sandbox** — that is the
whole reason it replaced the deprecated `SMLoginItemSetEnabled`. **No
entitlement** beyond `com.apple.security.app-sandbox = true` is needed. Do
**not** add `com.apple.security.system.controls` — that is a legacy /
DriverKit entitlement and has no relation to login items.

One thing to verify: `SMAppService.mainApp` requires the app to live in
`/Applications/` (or be installed by the user via the App Store, which puts
it there). When users run the dev `build/ClipShot.app`, registration will
fail with `kSMErrorAlreadyRegistered` / status `.notFound`. That is OK for
the store build because installed apps will be in `/Applications/`. Your
`do/catch` already swallows the error — leave it.

### 3.8 Reading pasteboard

**Lines 950–963** (`startPasteboardMonitor`, `checkPasteboard`):

`NSPasteboard.general` is **allowed** under the sandbox without any
entitlement. macOS shows a "Allowed pasted from X" indicator in some contexts,
but there is no entitlement requirement. **No change needed.**

However, App Review will scrutinize clipboard polling at 100ms — that is
aggressive. Switch to `NSPasteboard.general.changeCount` checked on an
**`NSApplication.didBecomeActiveNotification`** or every 500ms. The 100ms
polling will draw battery / energy-impact warnings in App Review automation.

### 3.9 Writing to other apps' preferences elsewhere?

`grep`-style audit — the only other UserDefaults usage is `UserDefaults.
standard` (your own domain, fine) and the `com.apple.screencapture` read
already covered in 3.2. **No other domains touched.** Once 3.1 and 3.2 are
fixed you are clean.

---

## 4. Entitlements file

Create `ClipShot/ClipShot.entitlements` with **exactly** these keys for v1.0
(Option A — no instant-mode hacks):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- MANDATORY: turn on App Sandbox -->
    <key>com.apple.security.app-sandbox</key>
    <true/>

    <!-- Read the user-selected screenshot folder via NSOpenPanel + bookmarks -->
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>

    <!-- Read ~/Desktop (Apple's default screenshot location) -->
    <key>com.apple.security.files.desktop.read-only</key>
    <true/>

    <!-- Read ~/Downloads (some users keep screenshots there) -->
    <key>com.apple.security.files.downloads.read-only</key>
    <true/>

    <!-- Read ~/Pictures (some users keep screenshots there) -->
    <key>com.apple.security.files.pictures.read-only</key>
    <true/>

    <!-- Persist security-scoped bookmarks across launches -->
    <key>com.apple.security.files.bookmarks.app-scope</key>
    <true/>
</dict>
</plist>
```

Notes:

- **Do not** add `com.apple.security.network.client` — ClipShot has no
  network access and Apple Review will ask "what is this for?" if it is on.
- **Do not** add `com.apple.security.device.audio-input` or `camera`.
- **Do not** add `com.apple.security.cs.allow-unsigned-executable-memory` /
  `cs.disable-library-validation`. ClipShot is pure Swift.
- For `SMAppService.mainApp` (login item) — **no entitlement needed**.
- Hardened Runtime is a *Build Setting* (`ENABLE_HARDENED_RUNTIME = YES`),
  not an entitlement key. Make sure it is on for the store build.

---

## 5. Privacy manifest (`PrivacyInfo.xcprivacy`)

Apple requires `PrivacyInfo.xcprivacy` for app submissions to App Store
Connect since **May 1, 2024**. Mac apps are included.

Create `ClipShot/PrivacyInfo.xcprivacy`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- 1. Tracking domains: none. -->
    <key>NSPrivacyTracking</key>
    <false/>
    <key>NSPrivacyTrackingDomains</key>
    <array/>

    <!-- 2. Data the app collects: nothing. ClipShot is 100% local. -->
    <key>NSPrivacyCollectedDataTypes</key>
    <array/>

    <!-- 3. Required-reason APIs ClipShot uses. -->
    <key>NSPrivacyAccessedAPITypes</key>
    <array>
        <!-- UserDefaults: storing user preferences (Settings.* in main.swift) -->
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>CA92.1</string>
            </array>
        </dict>
        <!-- File timestamp: NSURL .creationDateKey + FileManager .attributesOfItem -->
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>C617.1</string>
            </array>
        </dict>
        <!-- System boot time: not used. Omit. -->
        <!-- Disk space: not used. Omit. -->
        <!-- Active keyboard: not used. Omit. -->
    </array>
</dict>
</plist>
```

Mapping to actual code:

- `NSPrivacyAccessedAPICategoryUserDefaults` reason **CA92.1** = "Access info
  from same app, per documentation" — covers every `UserDefaults.standard`
  read/write in `Settings` (lines 11–52).
- `NSPrivacyAccessedAPICategoryFileTimestamp` reason **C617.1** = "Files
  managed by the app, for display in the app's UI" — covers
  `URLResourceKey.creationDateKey` lookups in `loadHistory` (lines 1037–1064)
  and `attributesOfItem` in `checkScreenshotFolder` (lines 987–988).

Add the file to Copy Bundle Resources in Xcode. App Store Connect will reject
the upload with **"ITMS-91056: Invalid privacy manifest"** if anything is
missing.

---

## 6. Info.plist additions required for Store

Your current `Resources/Info.plist` is mostly good but missing required keys.
Add or change:

```xml
<!-- REQUIRED for App Store -->
<key>LSApplicationCategoryType</key>
<string>public.app-category.productivity</string>

<key>ITSAppUsesNonExemptEncryption</key>
<false/>

<key>NSHumanReadableCopyright</key>
<string>Copyright © 2026 Jose Casado Genao. All rights reserved.</string>

<!-- CFBundleShortVersionString must be three integers separated by dots
     for the public version, e.g. 1.0.0 (not just 1.0). CFBundleVersion
     is the build number, monotonically increasing across submissions. -->
<key>CFBundleShortVersionString</key>
<string>1.0.0</string>
<key>CFBundleVersion</key>
<string>1</string>

<!-- Localization -->
<key>CFBundleDevelopmentRegion</key>
<string>es</string>
<key>CFBundleLocalizations</key>
<array>
    <string>es</string>
    <string>en</string>
</array>

<!-- KEEP these (already in your plist) -->
<key>LSUIElement</key>
<true/>
<key>NSHighResolutionCapable</key>
<true/>

<!-- KEEP TCC strings; sandbox + entitlement does not replace these. They are
     shown in the prompt the first time TCC gates the folder. Make them
     human and specific. -->
<key>NSDesktopFolderUsageDescription</key>
<string>ClipShot detecta los screenshots que tomas en el Escritorio para añadirlos al historial y copiarlos al portapapeles.</string>
<key>NSDownloadsFolderUsageDescription</key>
<string>Si guardas tus screenshots en Descargas, ClipShot necesita acceso para detectarlos automáticamente.</string>
<key>NSDocumentsFolderUsageDescription</key>
<string>Si guardas tus screenshots en Documentos, ClipShot necesita acceso para detectarlos automáticamente.</string>

<!-- REMOVE (legacy, harmful) -->
<!-- <key>CFBundleSignature</key><string>????</string> -->

<!-- REMOVE CFBundleIconFile if you migrate to asset catalog (recommended) -->
```

Notes:

- **`LSApplicationCategoryType`**: choose `public.app-category.productivity`.
  Alternatives that App Review will also accept for a screenshot history tool:
  `public.app-category.utilities`, `public.app-category.graphics-design`.
  Productivity ranks better in store search.
- **`ITSAppUsesNonExemptEncryption = false`** is the most common path: ClipShot
  does not use crypto beyond OS calls. Setting this correctly **avoids the
  export compliance questionnaire on every upload**. Wrong answer here delays
  every release by ~24 hours while Apple's automated export check runs.
- **`CFBundleShortVersionString` format**: must be 1 to 3 dotted integers
  (e.g. `1.0`, `1.0.0`, `1.2.3`). Your current `1.0` is technically valid but
  `1.0.0` is the convention.
- **`CFBundleVersion`**: must be **unique and monotonically increasing** per
  upload to App Store Connect. If you upload build 1 and have to fix something,
  next upload must be build 2 (or higher). Apple will reject re-uploading the
  same build number.
- **Localization**: your UI strings are Spanish. Declare it
  (`CFBundleDevelopmentRegion = es`) so the store page can be localized in
  Spanish without errors. You will provide en+es metadata in App Store Connect
  (§7). If you do not want to localize the store page, set development region
  to `en` and translate the strings to English in code — but the user-facing
  strings in `main.swift` are all Spanish, so embrace it.

---

## 7. App Store Connect setup

### Create the app record

In `https://appstoreconnect.apple.com/` → Apps → `+` → New App:

- Platforms: **macOS**
- Name: `ClipShot` (this is the user-visible store name; max 30 chars).
- Primary Language: **Spanish (Spain)** or **Spanish (Mexico)**, your call.
- Bundle ID: pick `com.josecasadogenao.clipshot` (must already exist in your
  Developer account, from §1).
- SKU: `clipshot-mac-1` (arbitrary, internal).
- User Access: Full Access.

### Required marketing assets

#### App icon

- **1024 × 1024 PNG, sRGB or P3, no alpha channel, no transparency, no rounded
  corners (Apple applies the mask)**. Uploaded inside the asset catalog and
  also surfaced automatically by the store.
- Asset catalog "AppIcon" set: provide 16, 32, 64, 128, 256, 512, 1024 in @1x
  and @2x where applicable. The store uses the 1024 directly.

#### Screenshots (mandatory: at least 1, max 10)

Mac App Store accepts **only 16:10 aspect ratio**. Allowed pixel sizes:

| Pixels        | Aspect | Notes                                                |
|---------------|--------|------------------------------------------------------|
| 1280 × 800    | 16:10  | Minimum allowed.                                     |
| 1440 × 900    | 16:10  | Common 13" MacBook Air native (scaled).              |
| 2560 × 1600   | 16:10  | 13" MacBook Pro Retina @2x.                          |
| 2880 × 1800   | 16:10  | **Preferred** — 15"/16" Retina. Submit at this size. |

Formats: `.png`, `.jpg`, `.jpeg`. Submit **2880 × 1800 PNG**. You can include
device-frame mockups, annotations, multi-language text on the image — Apple
allows it for Mac. Suggested 5 shots for ClipShot:

1. Menu-bar icon expanded showing the history with thumbnails (the core UX).
2. Floating thumbnail overlay just after taking a screenshot.
3. Drag-from-overlay into an editor (Pages, Mail) to show the drag affordance.
4. Welcome flow step "Mostrar miniatura flotante" (sells the feature).
5. Preferences submenu showing modes / open-at-login (sells the
   customization).

Take them on a Retina display, set wallpaper to something neutral, hide other
menu-bar items via Bartender/Hidden Bar for the screenshot.

#### Description copy

Max 4000 chars. Lead with the value prop, then bullet features, then privacy
statement.

Suggested first paragraph (Spanish):

> ClipShot vive en tu barra de menú y guarda automáticamente cada screenshot
> que tomas. Vuelve a copiar cualquier captura al portapapeles con un click,
> arrástrala directo a Mail o Pages, o ábrela para editar. Todo local. Sin
> cuenta, sin telemetría, sin servidores.

Then a bulleted list of: historial de 30 capturas, miniatura flotante,
arrastre y suelta, abrir al iniciar sesión, 100% en español, 100% privado.

Provide an **English** translation too if you want to reach non-Spanish
markets (recommended — same effort, much wider audience).

#### Keywords (100 chars total, comma-separated)

Example: `screenshot,clipboard,captura,portapapeles,history,historial,
productivity,menu bar,barra menu,utility`

Do **not** include competitor names ("Cleanshot", "Shottr") — App Review
flags trademark abuse under guideline **5.2.1**.

#### Promotional text (170 chars, can be updated without resubmitting)

Example: `Tu historial de capturas, siempre listo. Todo local, todo privado.`

#### What's New (release notes)

For 1.0: `Lanzamiento inicial.` (Spanish) / `Initial release.` (English)

#### URLs

- **Support URL** (mandatory): a real public page where users can contact you.
  GitHub Pages, a Notion page, a `mailto:` is technically rejected — Apple
  wants an HTTP(S) URL. Cheapest path: a GitHub Pages site at
  `https://josegcasadogenao.github.io/clipshot/`.
- **Marketing URL** (optional): same domain works.
- **Privacy Policy URL** (mandatory, even for apps that collect nothing): a
  one-page policy stating "ClipShot does not collect, store, or transmit any
  personal data. All screenshots remain on your device." Host on the same
  GitHub Pages site.

#### App Privacy questionnaire (in App Store Connect → App Privacy)

Answer: **"Data Not Collected"** for every category. This must match what
`PrivacyInfo.xcprivacy` declares (§5) — Apple cross-checks.

#### Age rating

ClipShot has no objectionable content. Rating questionnaire: select "None"
for every category → Age Rating 4+.

#### Pricing & Availability

- Price tier: Free (Tier 0), or pick a paid tier.
- Availability: All territories, or your subset.
- Distribution Method: leave on "App Store" (don't enable TestFlight unless
  you want public beta).

#### Sign in to test (for App Review)

ClipShot has no login. Leave the Sign-in section empty. In the **App Review
Information** section, fill in:

- Contact email: yours.
- Demo account: leave blank.
- **Notes** (this is where you head off the most likely rejection):

  > ClipShot is a menu-bar utility (LSUIElement = true). After launch, look for
  > the camera icon in the menu bar at the top right of the screen. Click it
  > to see the screenshot history menu. To test:
  >
  > 1. Take a screenshot with Cmd-Shift-3 or Cmd-Shift-4.
  > 2. The screenshot will appear in the floating thumbnail overlay and in the
  >    menu-bar history.
  > 3. Click any history entry to copy it back to the clipboard.
  >
  > The app stores all screenshots locally in the app's sandbox container at
  > ~/Library/Containers/com.josecasadogenao.clipshot/Data/Library/
  > Application Support/ClipShot/history/. Nothing is sent to a server.

---

## 8. Notarization vs App Store distribution

The two distribution paths are distinct and you should pick **one** for v1.0:

| Path                   | Where it ships from              | Signing                     | Notarization        | Sandbox required | Updates                  |
|------------------------|----------------------------------|------------------------------|----------------------|------------------|---------------------------|
| **Mac App Store**      | Apple's store (Launchpad, search) | Apple Distribution cert      | Built-in via upload  | **Yes**          | Through App Store         |
| **Direct / Developer ID** | Your website / GitHub Releases | Developer ID Application cert | `xcrun notarytool submit` then `stapler staple` | No (but recommended) | Sparkle / manual download |

This document targets the **Mac App Store path**. The notarized direct
distribution path is faster (no human review, ~5 minutes for notarization)
and lets you keep the "instant" mode and the `defaults`-write hack — but you
lose store discoverability and you must build your own update mechanism.

If you do both: maintain two Xcode schemes / targets. Same code, different
entitlements and Info.plist values. The "App Store" target turns on sandbox
and removes the system-prefs hack; the "Direct" target keeps both. Many
indie macOS apps do this (Bartender, Soulver). It is extra work — skip for
v1.0.

---

## 9. Common review rejections specific to ClipShot

Apple's App Review team is consistent. These are the rejections you will see
if you submit ClipShot as currently written. In order of likelihood:

### 9.1 Writing to `com.apple.screencapture` defaults — Guideline 2.5.1

**Verdict**: hard reject, always. "Apps must only use public APIs." Mutating
another bundle's preferences via spawning `/usr/bin/defaults` is not a public
API, will not pass static analysis on upload (Apple parses your binary for
`/usr/bin/defaults` string usage in some scans), and even if it slipped past
upload, the reviewer will manually catch it because the welcome flow
*advertises* the feature. **Mitigation**: remove the feature for Store
(§3.1 Option A).

### 9.2 `killall SystemUIServer` — Guideline 2.5.1 + 2.5.9

Same as 9.1 but worse. Killing system processes is grounds for permanent
team-account scrutiny. Apple has rejected and *banned* developers for less.
**Mitigation**: remove (`runDefaults` deletion in §3.1).

### 9.3 Menu-bar-only app with no Dock icon — Guideline 2.4.5(iii)

Apple **allows** menu-bar utilities, but reviewers will sometimes mark an
app as "not recognizable / no way to access" if they cannot find the UI. The
welcome window on first launch (`WelcomeWindowController`) solves this — the
reviewer sees a real window, then the menu-bar icon takes over. Make sure
the welcome window is impossible to miss on first launch. Currently
`showWelcome()` only fires on `!Settings.hasSeenIntro`. **Add**: also fire it
if the reviewer somehow dismisses it; add a permanent "Acerca de ClipShot"
menu item (already present at line 835 — good).

In the App Review notes (§7) explicitly instruct the reviewer to look at the
menu bar. This single sentence prevents 70% of "we couldn't find it"
rejections.

### 9.4 Polling clipboard at 100ms — Guideline 2.5.4 + 5.1.2

Aggressive pasteboard polling without justification triggers privacy
scrutiny. Reviewers may ask "why does the app monitor the clipboard?". You
have a legitimate answer (to detect Cmd-Shift-Ctrl-3/4 which goes to
clipboard) but the polling rate is wasteful. **Mitigation**: 500ms timer,
documented in App Review Notes: "Clipboard is polled at 500ms to detect
screenshots taken with Cmd-Shift-Ctrl-3/4, which macOS routes directly to
clipboard. No clipboard content is transmitted or persisted other than
screenshot images, which are saved locally in the app's sandbox container."

### 9.5 Folder polling at 100ms — performance / energy

Same fix: switch to `DispatchSource.makeFileSystemObjectSource` or
`NSMetadataQuery`. Apple's automated energy impact tests will flag a tight
loop. **Mitigation**: use event-driven file watching (see §3.3).

### 9.6 Spanish-only UI in an "English" app record — Guideline 2.3.8

If your App Store Connect primary language is English but your UI is
Spanish, App Review will reject for misleading metadata. **Mitigation**:
either (a) set primary language to Spanish in ASC and provide Spanish
copy, or (b) translate all `NSLocalizedString` strings to English and
provide en/es localizations of `Main.strings`. Recommended: do **(a) + add
English localization later**.

### 9.7 No real privacy policy — Guideline 5.1.1

A `mailto:` or "TBD" URL is rejected. **Mitigation**: ship a real
single-page privacy policy at a stable URL **before** submitting.

### 9.8 `SMAppService` opt-in is not user-consensual enough — Guideline 2.4.5(iii)

Apple requires that login-item registration be **explicitly opted into by the
user**. Your welcome flow does this correctly (the `buildLogin()` step has a
toggle, default ON). **Make the default OFF** in the welcome to be safe. A
reviewer who sees "app auto-installed itself as a login item" without an
unambiguous toggle has caused rejections. Currently
`wc.loginChoice = Settings.openAtLogin || !Settings.hasSeenIntro` defaults to
true on first run — change to:

```swift
wc.loginChoice = Settings.openAtLogin   // default false on first run
```

### 9.9 Screenshot folder TCC prompt language — Guideline 5.1.1(ii)

The TCC strings in your Info.plist mention "screenshots" — accurate. Make
sure they explain **why** the access is needed in one sentence. Yours are
acceptable. No change needed, just keep them human.

### 9.10 Asset catalog missing required icon sizes

If you skip any of 16, 32, 128, 256, 512 in @1x **and** @2x, the upload
fails validation. Use Bakery / IconKit / `iconutil` to produce a complete
set from a single 1024×1024 master.

### 9.11 Hardened Runtime missing

For Mac App Store builds, Hardened Runtime is required as of macOS 11.
Capability checkbox in Xcode handles it. **Mitigation**: verify
`ENABLE_HARDENED_RUNTIME = YES` in Build Settings.

### 9.12 Build uploaded without dSYM

Without symbols, crash reports in App Store Connect are useless and Apple
sometimes nudges (not rejects, but useful). **Mitigation**: in Build
Settings, set `DEBUG_INFORMATION_FORMAT = dwarf-with-dsym` for the **Release**
configuration.

---

## 10. Step-by-step submission flow

Numbered, sequential. "Right now" = this week.

1. **Enroll in Apple Developer Program** ($99). Wait ~24h for approval. Do
   this first — everything else blocks on it.
2. **Register App ID** `com.josecasadogenao.clipshot` (explicit, not wildcard)
   in `developer.apple.com → Identifiers`.
3. **Generate certificates** in Xcode → Settings → Accounts → Manage
   Certificates: `Apple Development`, `Apple Distribution`.
4. **Convert to Xcode project** (§2). Verify `Product → Build` and
   `Product → Run` work locally.
5. **Remove the `runDefaults` / `killall SystemUIServer` / saving-mode code**
   (§3.1 Option A). Update the welcome flow to drop `buildSavingMode`. Verify
   the app still functions: screenshot taken → appears in overlay → appears
   in menu history → click copies back to clipboard.
6. **Add the Sandbox capability** in Xcode. Xcode auto-creates
   `ClipShot.entitlements`. Paste in the keys from §4.
7. **Add the security-scoped bookmark flow** for the screenshot folder
   (§3.2). Add a "Set screenshots folder…" menu item using `NSOpenPanel`.
8. **Replace 100ms timers** with event-driven file/pasteboard observation
   (§3.3, §3.4).
9. **Switch logging to `os_log`** or accept the in-container path (§3.5).
10. **Create the App Icon asset catalog** with all required sizes (§7).
11. **Create `PrivacyInfo.xcprivacy`** (§5) and add to Copy Bundle Resources.
12. **Update `Info.plist`** with the §6 keys (`LSApplicationCategoryType`,
    `ITSAppUsesNonExemptEncryption=false`, `NSHumanReadableCopyright`,
    `CFBundleShortVersionString=1.0.0`, version 1.0.0 / build 1, localization
    keys).
13. **Default `loginChoice` to `false`** in welcome (§9.8).
14. **Build the app once locally**: `Product → Archive`. Open Organizer →
    click "Validate App" → fix every warning. The most common ones:
    - "Missing icon size 32x32@2x" → add to asset catalog.
    - "Privacy manifest missing required reasons" → fix the API reasons.
    - "App uses non-public API" → look for any remaining `_private` strings;
      should be none in pure Swift+AppKit.
    - "Entitlement com.apple.security.app-sandbox required" → you forgot to
      enable App Sandbox capability.
15. **Create the app record in App Store Connect** (§7). Set name, bundle
    ID, primary language, category, age rating, pricing.
16. **Set up Privacy questionnaire** in ASC → App Privacy: "Data Not
    Collected" for everything. Save.
17. **Host privacy policy + support page**. Cheapest: GitHub Pages from a
    `josegcasadogenao.github.io/clipshot` repo. Two pages: `privacy.html`,
    `support.html`. Link from ASC.
18. **Produce 5 screenshots at 2880×1800**. Upload to the macOS app's "1.0
    Prepare for Submission" page in ASC.
19. **Write copy**: description, keywords, promotional text, what's new,
    App Review notes (§7).
20. **Archive again** with the final build number. Organizer → "Distribute
    App" → "App Store Connect" → "Upload" → wait for processing email (~10
    minutes).
21. **In ASC, attach the build** to version 1.0 once Apple processes it.
22. **Answer the export compliance question** if it appears — but you set
    `ITSAppUsesNonExemptEncryption=false` in plist, so it should auto-skip.
23. **Submit for Review**. Pick "Manually release this version" so you
    control launch day.
24. **Wait 24–72h**. Either "Approved" or "Rejected with reasons".
25. **If rejected**: respond in Resolution Center within the day with a
    clear, point-by-point reply. Fix code if needed → rev build number →
    re-upload → re-submit. Typical second review is faster (~24h).
26. **When approved**: click "Release this version" in ASC. Live on the
    store within ~1 hour.

---

## 11. Realistic timeline

| Phase                                                | Time           |
|------------------------------------------------------|----------------|
| Apple Developer enrollment (individual)              | 1–2 days       |
| Apple Developer enrollment (organization with D-U-N-S) | 1–3 weeks    |
| Convert to Xcode + sandbox + remove blocking code    | **1–2 days of focused work** |
| Make icons + screenshots + copy + privacy policy     | 1 day          |
| First upload to ASC + validation                     | 1 hour         |
| ASC build processing (waiting for email)             | 10 min – 2 hr  |
| First review (best case)                             | **24h**        |
| First review (typical for menu-bar utilities)        | 24–72h         |
| First review (worst case, weekend / holiday)         | up to 1 week   |
| One rejection → fix → resubmit cycle                 | +2–4 days      |
| **Expected total for ClipShot, first submission**    | **2–3 weeks from "right now"** |

Expected back-and-forth: **1 rejection is normal** for first submissions. Two
is common. The top two reasons for v1.0 ClipShot will be (a) reviewer cannot
find the menu-bar icon (mitigated by App Review Notes), (b) something about
how the screenshot folder access is justified or how the clipboard polling is
explained. Budget for one round of back-and-forth.

---

## Next concrete actions for THIS app

The week-1 punch list. Do these in order.

1. **Enroll in the Apple Developer Program** today
   (`https://developer.apple.com/programs/enroll/`). Without the team ID
   nothing else can start.
2. **Delete the entire saving-mode "instant" feature** from `src/main.swift`:
   remove `SavingMode` enum (lines 6–9), `Settings.savingMode` (lines 22–25),
   `applyCurrentSavingMode` (lines 712–719), `disableSystemThumbnail`,
   `restoreSystemThumbnail`, `runDefaults` (lines 725–744), the welcome
   `buildSavingMode` step, and the "Modo de guardado" submenu (lines
   803–815). Replace `applicationWillTerminate`'s `restoreSystemThumbnail()`
   call with a no-op.
3. **Default `loginChoice` to `false`** on first run in
   `showWelcome()` (line 695). Change to
   `wc.loginChoice = Settings.openAtLogin`.
4. **Slow the clipboard timer to 500ms** (line 952) and the folder timer to
   500ms (line 967). Better still, replace with
   `DispatchSource.makeFileSystemObjectSource` for the screenshot folder.
5. **Generate a complete AppIcon set** from your 1024×1024 master (use
   `iconutil` or Bakery): 16, 32, 64, 128, 256, 512, 1024 @1x and @2x.
   Drop into `Assets.xcassets`.
6. **Create the Xcode project** at `/Users/josecasadogenao/Mac App/
   ClipShot.xcodeproj` following §2. Get `Product → Run` working.
7. **Add App Sandbox + Hardened Runtime capabilities** in Xcode. Paste the
   entitlements from §4. Verify the app still saves screenshots — they will
   now land in the container path; that is correct.
8. **Write `PrivacyInfo.xcprivacy`** (§5) and add to Copy Bundle Resources.
9. **Stand up a privacy policy + support page** on GitHub Pages. Two static
   HTML files. ~30 minutes.
10. **Take 5 screenshots at 2880×1800** of the working sandboxed app — menu
    expanded, overlay visible, welcome flow, preferences submenu — and save
    them somewhere ready to upload to App Store Connect.

When all 10 are done you are ready for `Product → Archive → Distribute → App
Store Connect → Upload`.
