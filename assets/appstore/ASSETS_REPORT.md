# ClipShot — Mac App Store Assets Report

Generated 2026-05-23. Submission target: Mac App Store.

## Required asset matrix

| Asset                          | Required dims        | Status     | Path |
|--------------------------------|----------------------|------------|------|
| App icon (no alpha, flat square) | 1024x1024          | DONE (regenerated) | `found/appstore_icon_1024_appstore_ready.png` |
| macOS screenshot 1 (menu)      | 2880x1800            | TODO (Gemini prompt ready) | `needed/appstore_screenshot_01_menu_history.png` |
| macOS screenshot 2 (floating thumbnail) | 2880x1800   | TODO (Gemini prompt ready) | `needed/appstore_screenshot_02_floating_thumbnail.png` |
| macOS screenshot 3 (preferences) | 2880x1800          | TODO (Gemini prompt ready) | `needed/appstore_screenshot_03_preferences.png` |
| Hero marketing image           | 2880x1800            | TODO (Gemini prompt ready) | `needed/appstore_hero_marketing_1.png` |
| App Store preview frame        | 1920x1080            | TODO (Gemini prompt ready) | `needed/appstore_preview_frame_1.png` |

## Found and reused

| File | Source | Dimensions | Reuse as |
|------|--------|------------|----------|
| `found/appstore_icon_1024_appstore_ready.png` | regenerated from `Resources/icon.svg` (rect made full-bleed, rounded corners removed, alpha flattened to RGB over black) | 1024x1024 RGB no-alpha | **App Store icon** (submit this one) |
| `found/appstore_icon_source.svg` | `Resources/icon.svg` | vector | Master source for icon |
| `found/appstore_icon_source_flat.svg` | derived (full-bleed square variant for App Store) | vector | Master source for App Store icon |
| `found/appstore_icon_1024_with_alpha.png` | `Resources/AppIcon.iconset/icon_512x512@2x.png` | 1024x1024 RGBA | Original macOS-style icon (has rounded corners + padding — keep for in-app/dock use, NOT for submission) |
| `found/appstore_icon_512.png` | `Resources/AppIcon.iconset/icon_512x512.png` | 512x512 | Marketing / web |
| `found/appstore_icon_256.png` | `Resources/AppIcon.iconset/icon_256x256.png` | 256x256 | Marketing / web |
| `found/appstore_icon.icns` | `Resources/AppIcon.icns` | multi-res | The bundled .icns (already in build) |
| `found/marketing_clipshot_in_development_2940x1846.png` | `~/Desktop/Captura de pantalla 2026-05-23 a la(s) 10.38.30 a. m..png` | 2940x1846 | Optional "behind the scenes / built with care" marketing image — shows the ClipShot project open in Cursor with the icon visible. Not for App Store screenshot slots (too meta) but useful for press kit / blog post / GitHub README. |

## Searched and rejected

- `~/Library/Application Support/ClipShot/history/` — 30 PNGs. These are captures *taken by* the user with ClipShot active, so they prove the app works, but the content is unrelated (WhatsApp conversation about a soccer goal, a Gemini chat session, Cursor IDE, System Settings login items, etc.). None of them show ClipShot's own UI (menu, overlay, preferences), so they cannot serve as App Store screenshots without staging fresh captures. They were therefore **not copied** to `found/`.
- `~/Desktop/Captura de pantalla 2026-05-*` — same situation: real captures but of unrelated apps. The only one we kept is the Cursor screenshot that incidentally shows the ClipShot project being developed.
- `~/Downloads/*.png` — third-party screenshots (PayPal, Wix editor, Apple Store, etc.) and Gemini-generated images unrelated to ClipShot. Skipped entirely.
- `~/Pictures` — no recent PNGs in the last 90 days.

## Decisions

1. **The existing AppIcon.icns is not App Store-compliant** as-is. The SVG draws a rounded-rect with padding *inside* the transparent 1024x1024 canvas, which means Apple's squircle mask would clip into empty space. We generated `appstore_icon_1024_appstore_ready.png` by re-rendering the SVG with the gradient filling the entire square (no padding, no inner rounded corners, no inner stroke) and flattening alpha to RGB. **Use that file** for App Store Connect submission. The original .icns stays for the bundle (it looks correct in Finder/Dock because macOS does not re-mask it).
2. **The three required App Store UI screenshots cannot be reliably AI-generated** with pixel-accurate native macOS UI fidelity. The Gemini prompts in `gemini_prompts.json` are provided as a fallback; the strongly preferred approach is:
   - Run ClipShot (`make run` or open the built app).
   - Take real screenshots of: (a) the menu-bar dropdown with several history items, (b) the floating thumbnail overlay after a capture, (c) the welcome window step 2 ("¿Cómo quieres que funcione?").
   - Capture at native retina resolution on a 1440x900-points display (so the PNG is 2880x1800).
   - Save into `assets/appstore/needed/` using the filenames in the JSON.
3. **Hero marketing image and preview-video title frame** are well-suited for Gemini Imagen — those prompts are the priority generative requests.

## Files in this directory

```
assets/appstore/
├── ASSETS_REPORT.md                 (this file)
├── gemini_prompts.json              (prompts for missing assets)
├── found/                           (reusable assets sourced from disk)
│   ├── appstore_icon_1024_appstore_ready.png   ← submit this to App Store Connect
│   ├── appstore_icon_1024_with_alpha.png
│   ├── appstore_icon_512.png
│   ├── appstore_icon_256.png
│   ├── appstore_icon.icns
│   ├── appstore_icon_source.svg
│   ├── appstore_icon_source_flat.svg
│   └── marketing_clipshot_in_development_2940x1846.png
└── needed/                          (will be filled by Gemini or by real captures)
```
