# ClipShot App Store Screenshots — Generation Report

## Path taken: B (programmatic Swift drawing)

I chose Path B because reliably automating the live menu-bar dropdown open via
AppleScript/Accessibility is brittle (it depends on accessibility permissions,
window focus, and unpredictable timing), and capturing the floating thumbnail
requires triggering a real screenshot at exactly the right moment. A pure
Swift + CoreGraphics renderer produces consistent, marketing-quality output
with full layout control to honor Apple's "title above, device below"
screenshot convention.

Generator script: `/Users/josecasadogenao/Mac App/scripts/render_screenshots.swift`
Run with: `swift scripts/render_screenshots.swift`

## What's new in this iteration

- **MacBook frame**: every screenshot now shows the ClipShot UI rendered
  inside a programmatically drawn MacBook Pro (lid + bezel + notch +
  trapezoidal keyboard base + ground shadow). The laptop fills roughly
  65% of the canvas height (~1255pt tall on a 2880×1800 canvas) and is
  the visual centerpiece.
- **Fully English UI**: all in-screen UI strings are in English.
  - Screenshot 1 menu: "ClipShot — Screenshot history", history rows with
    US-locale timestamps ("5/23/26, 4:32:18 PM"), footer items
    "Open History Folder", "Clear History…", "Preferences ▸",
    "About ClipShot", "Quit".
  - Screenshot 3 welcome: "Your privacy" + the English body from
    `en.lproj/Localizable.strings` (`welcome.step5.body`), with
    "Skip"/"Back"/"Next" buttons.
  - Screenshot 2: added a "Copied!" badge near the floating preview.
- **Title overlays unchanged** (already English): "Your history, in the
  menu bar", "A floating preview, exactly when you need it",
  "Private by design". Repositioned to sit above the MacBook.

## Files delivered

All three PNGs are exactly **2880×1800**, **no alpha channel** (App Store
safe), saved to `/Users/josecasadogenao/Mac App/assets/appstore/needed/`.

```
screenshot_1_menu.png       2880 x 1800   hasAlpha: no   3.5 MB
screenshot_2_thumbnail.png  2880 x 1800   hasAlpha: no   3.1 MB
screenshot_3_welcome.png    2880 x 1800   hasAlpha: no   3.1 MB
```

### 1. `screenshot_1_menu.png`
MacBook frame centered on a navy-gradient background. Inside its screen:
a translucent macOS status bar with Apple/Finder/File/Edit/View/Go/Window/
Help on the left, wifi/100%/Fri 12:34 on the right, and the ClipShot
camera icon highlighted. A clean light dropdown menu hangs from the icon
with a small triangle pointer, showing:
- Header "ClipShot — Screenshot history"
- 6 colored thumbnail rows with US-locale timestamps + "Full screen · PNG"
- Footer items: Open History Folder ⌘O, Clear History…, Preferences ▸,
  About ClipShot, Quit

Title overlay: **"Your history, in the menu bar"** /
"Every screenshot, ready to re-copy in one click."

### 2. `screenshot_2_thumbnail.png`
MacBook frame containing a faux document window (titlebar with traffic
lights and grey text-line content) and the floating ClipShot thumbnail
card composited in the lower-right of the screen with rounded corners,
drop shadow, mock inner-window preview, and a pointer cursor. A green
"Copied!" pill sits just below the thumbnail.

Title overlay: **"A floating preview, exactly when you need it"** /
"Click to edit in Markup, or drag straight into any app."

### 3. `screenshot_3_welcome.png`
MacBook frame containing the centered ClipShot Welcome window with
traffic lights, green shield + white lock icon, "Your privacy" heading,
the full English bullet list from `welcome.step5.body`, pagination dots
(step 5 of 6 active), and Skip / Back / Next buttons.

Title overlay: **"Private by design"** /
"100% local. No accounts. No servers. No telemetry."

## MacBook drawing details

- Lid: aluminum gradient (#d9d9dc top → #b8b8bc → #b8b8c0), 22pt rounded
  corners, subtle white specular highlight along the top edge, dark rim
  stroke.
- Bezel: matte black (#1c1c1e), inset ~2.2% of lid width, 14pt rounded.
- Notch: 220×32pt cut into the top center of the bezel, rounded only on
  the bottom corners, with a 8pt camera dot.
- Screen content area: ~6pt inside the bezel; everything (wallpaper,
  status bar, dropdowns, windows) is drawn clipped to a rounded rect.
- Keyboard base: trapezoidal slab (slightly wider at the bottom) with
  its own aluminum gradient and the little front-edge "open the lid"
  indent.
- Ground shadow: large blurred dark ellipse beneath the base for
  realism.

### Tradeoffs / known limitations
- Drawn head-on (no perspective tilt) — keeps the screen content
  perfectly rectangular and crisp.
- No keyboard keys or trackpad rendered (the base is a thin slab); at
  the scale used, the laptop reads clearly as a MacBook because of the
  lid + notch + base proportions, and adding individual keys at this
  scale would have been visually noisy without adding value to a
  marketing screenshot.
- No hinge gap line between lid and base (kept it flush for a cleaner,
  more "press shot" look).

## Visual design decisions

- **Background**: vertical navy → near-black gradient with two radial
  blue glows (upper-right, lower-left) and the existing desktop tint
  layer.
- **Title**: SF Pro Display Bold at 96pt, kerning -1.2, soft drop
  shadow, positioned with top of title near y = CANVAS_H - 120.
- **Subtitle**: SF Pro Text Regular at 38pt in #9aa3b8, centered 20px
  under title.
- **MacBook**: lidWidth = 1900pt, aspect 0.66 → lidHeight ≈ 1254pt,
  lid bottom at y = 220, base extends slightly below.
- All in-screen UI elements use sizes proportional to the screen rect
  (status bar = 56pt, menu/window widths scaled from screen dimensions)
  so visuals scale cleanly if the MacBook is resized.

## Sanity check log

```
$ sips -g pixelWidth -g pixelHeight -g hasAlpha *.png
all three → 2880×1800, hasAlpha: no  ✓

$ grep -i -E 'aún|preferencias|abrir|salir|limpiar|atrás|saltar|\
   siguiente|empezar|miniatura|privacidad|carpeta' \
   scripts/render_screenshots.swift
(no matches)  ✓

$ swift scripts/render_screenshots.swift
DONE  ✓
```
