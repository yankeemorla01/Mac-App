# Demo Video Script — for Apple App Review

## Requirements from Apple

- Recorded on a **physical device** (not a simulator). Just your Mac.
- Running the **latest macOS** (macOS 26.4 / Tahoe — you have it).
- Begin with **launching the app**.
- Show the **typical user flow** through core features.
- Show any **permission prompts** triggered.
- Format: `.mov`, `.mp4`. Max ~500MB.
- Duration: 30-90 seconds is ideal.

## Recording — step by step

### Option A: macOS Screenshot tool (recommended — free, built-in)

1. Press **Cmd+Shift+5**
2. From the toolbar at bottom, choose **"Record Entire Screen"** (or "Record Selected Portion" if you want just the area we'll demo)
3. Click **Record** button on the right side
4. Now perform the demo script below
5. When done, click the **stop button** in the menu bar (small circle/square)
6. The video saves to your Desktop as `Screen Recording YYYY-MM-DD at HH-MM-SS.mov`

### Option B: QuickTime Player

1. Open QuickTime Player (Spotlight: `Cmd+Space` → "QuickTime")
2. Menu: **File → New Screen Recording**
3. Click **Record**
4. Perform demo script
5. Stop → save

## Demo script — what to do during recording

**Before pressing Record**: prepare:
- Close all other apps to keep the screen clean
- Have a Safari window or Notes open in the background (you'll need a target for paste)
- Make sure ClipShot is currently **NOT** running (right-click menu bar icon → Quit if it is)
- Optionally reset the welcome: open Terminal and run `defaults delete com.jcmorla.clipshot clipshot.hasSeenIntro` (so the welcome appears)

**Now press Record and follow this script (60-80 seconds total):**

```
[0:00 – 0:05]  Show empty menu bar. Open /Applications, double-click ClipShot.
[0:05 – 0:25]  Welcome window appears. Click through the 7 steps:
                1. Welcome  → Next
                2. How saving works → Next
                3. Choose your folder → Pick Desktop → Next
                4. Floating thumbnail → leave ON → Next
                5. Open at login → leave OFF → Next
                6. Privacy → Next
                7. All set → Get Started

[0:25 – 0:30]  Welcome closes. Point at the menu bar — show the small camera icon.

[0:30 – 0:40]  Press Cmd+Shift+4 (region select). Drag a rectangle on screen.
                Release. The floating thumbnail appears bottom-right.

[0:40 – 0:50]  Click the menu bar camera icon. The dropdown shows the
                screenshot you just took at the top, with timestamp.
                Click on it — visually nothing changes but the screenshot
                is now on the clipboard.

[0:50 – 0:60]  Open Safari or Notes. Press Cmd+V. The screenshot pastes.

[0:60 – 0:75]  Click the menu bar icon again. Hover "Preferences" — submenu
                shows: Saving mode, Show floating thumbnail, Open at login,
                Change screenshot folder, Show welcome again.

[0:75 – 0:80]  Click "Quit" at the bottom of the menu. App closes.
```

## After recording

1. The video saves to your Desktop
2. Open it in QuickTime (double-click). Check duration is 60-90 seconds and quality is good.
3. (Optional) Trim with QuickTime: Edit → Trim → drag the yellow handles → Trim → File → Save.
4. Upload to App Store Connect:
   - In the same **App Review Information** section where the Notes text goes
   - Find the **App Review Attachment** area
   - Click **+** → choose your `.mov` file
   - Save changes

## After uploading the notes + video

1. In the rejection screen / current review, click **"Submit for Review"** again (or **"Resolution Center"** → reply with the same notes if Apple wants them there)
2. The build status changes to "Waiting for Review"
3. Apple typically responds within 24-48 hours for Mac apps

## Pro tips for the video

- **Move slowly**. Reviewers watch in real-time. Don't rush.
- **No music, no narration needed**. Apple just wants to see the flow.
- **Show the keyboard shortcuts you press** — there's a macOS setting under System Settings → Keyboard → Show keyboard shortcuts on screen (or use an app like KeyCastr) — optional but helpful.
- **Stay in English** if possible — change your Mac's language to English temporarily so the menu shows English text, since you set English as the primary App Store language.
   - Quick way: System Settings → General → Language & Region → Add English → drag to top → log out / back in.
   - Or skip this and leave Spanish — Apple won't reject for that, but English is safer for the primary listing.
