# App Review Notes — for App Store Connect

Paste the text below into **App Store Connect → My Apps → ClipShot: Screenshot Vault → App Information → App Review Information → Notes** (4000-char limit).

---

## English (≤ 4000 chars — fits inside the field)

```
Hello App Review Team,

Thanks for your time. Information requested:

PURPOSE & AUDIENCE
ClipShot is a small menu-bar utility for macOS that automatically saves every screenshot the user takes to a local history, so the user can re-copy any past screenshot to the clipboard in one click without hunting through folders. Target audience: engineers, designers, writers, students, support agents — anyone who takes screenshots often. Problem solved: macOS lets you take screenshots, but it has no built-in history or quick re-copy. ClipShot fills that gap natively (no hotkey changes, no system modifications, no learning curve).

ACCESS
No login, no account, no credentials, no registration. After install, ClipShot appears as a camera icon in the menu bar (top-right). The app has no Dock icon — it lives only in the menu bar (LSUIElement = true).

USER FLOW (shown in the attached video)
1. Launch ClipShot from /Applications. A 7-step welcome window appears on first launch; the user picks a screenshot folder (default: Desktop) and grants access via the standard macOS open panel (security-scoped bookmark).
2. Take a standard macOS screenshot (Cmd+Shift+3, 4, or 5). ClipShot detects it and saves it to history. A floating thumbnail appears bottom-right.
3. Click the menu bar icon to see the history (thumbnails with timestamps).
4. Click any past thumbnail — it's re-copied to the clipboard. Paste with Cmd+V anywhere.
5. Drag the floating thumbnail into any app to share, or click it to edit in Preview/Markup.

DEVICES & OS TESTED ON
- 14" MacBook Pro, Apple M3 Pro, macOS 26.4 (Tahoe)
- 13" MacBook Air, Apple M2, macOS 15 (Sequoia)
All tests on Apple Silicon. Deployment target: macOS 13.0.

EXTERNAL SERVICES / TOOLS / PLATFORMS
None. ClipShot has zero network code. No third-party SDKs, analytics, advertising, authentication providers, payment processors, or AI services. There is no URLSession or any network API invocation in the binary. All processing is on-device. Apple frameworks used: AppKit, ServiceManagement (SMAppService for opt-in login item, off by default), UniformTypeIdentifiers, ApplicationServices.

REGIONAL DIFFERENCES
None. ClipShot works identically in every region. Localized in English (primary fallback), Spanish, and French — macOS picks the language automatically from system preferences. No geo-blocking, no region-specific logic, no regional payments.

REGULATED INDUSTRY / THIRD-PARTY MATERIAL
Not applicable. The app does not operate in a regulated industry. All visual assets (icon, screenshots, in-app graphics) were created by the developer with original design and rendering code. No third-party trademarks, logos, copyrighted images, or licensed material are used.

PRIVACY
Screenshots are processed only on the user's Mac and stored locally inside the sandbox container at ~/Library/Containers/com.jcmorla.clipshot/Data/Library/Application Support/ClipShot/history/. Nothing is ever transmitted to the developer, Apple, or any third party. Full privacy policy: https://yankeemorla01.github.io/clipshot/privacy.html

SUPPORT
Public support page: https://yankeemorla01.github.io/clipshot/support.html

Please let me know if anything else would help your review.

Thank you,
Jean Carlos Morla Genao
Developer Team ID: EC9VSP9V96
```

---

## How to add this in App Store Connect

1. **App Store Connect** → My Apps → ClipShot: Screenshot Vault
2. Sidebar: **App Information** → scroll to **App Review Information**
3. Paste the entire block above into the **Notes** field
4. Below, upload the demo video in the **App Review Attachment** section
5. **Save** (top right)
6. Then go to the rejected version and click **Submit for Review** again, or reply via **Resolution Center**
