import Cocoa
import QuartzCore
import ApplicationServices
import ServiceManagement
import Quartz   // Quick Look
import Vision   // OCR
import Carbon.HIToolbox  // global hotkey
import StoreKit   // IAP para ClipShot Pro

// NOTE: This is the App Store build of ClipShot.
// All Mac App Store sandbox restrictions apply. The "instant" saving mode that
// existed in the notarized DMG build has been removed; this build only ever
// operates in the Apple-native saving flow (i.e. it waits for Apple's standard
// ~5-second screenshot thumbnail to disappear before saving to history).
//
// See ../docs/APPSTORE.md and ../appstore/CONVERSION_NOTES.md.
//
// LOCALIZATION NOTES
// ------------------
// All user-facing strings live in Localizable.strings under each *.lproj folder.
// Base / development language is Spanish (es.lproj).
//
// Two things that are intentionally NOT localized, by design:
//
//   1. Saved-file names (e.g. "Captura 2026-05-23 a las 14-30-12_a1b2c3.png").
//      Localizing filenames is a known anti-pattern: it makes files harder for
//      the user to share across systems, breaks shell completion, and produces
//      mixed-language directory listings when the user changes UI language.
//      We keep them in Spanish forever; the user's filesystem is not a UI.
//
//   2. Month folder names (e.g. "Enero 2026"). Same reasoning — these are
//      on-disk artifacts the user may browse in Finder long after changing
//      languages. Stability beats translation.
//
// Anything actually displayed in the UI (menu titles, alerts, welcome window,
// open-panel prompts, accessibility labels) IS localized via NSLocalizedString.

enum Settings {
    private static let d = UserDefaults.standard
    private static let kIntro = "clipshot.hasSeenIntro"
    private static let kOverlay = "clipshot.showOverlay"
    private static let kLogin = "clipshot.openAtLogin"
    private static let kFolderBookmark = "clipshot.screenshotFolderBookmark"

    static var hasSeenIntro: Bool {
        get { d.bool(forKey: kIntro) }
        set { d.set(newValue, forKey: kIntro) }
    }
    static var showOverlay: Bool {
        get { (d.object(forKey: kOverlay) as? Bool) ?? true }
        set { d.set(newValue, forKey: kOverlay) }
    }
    static var openAtLogin: Bool {
        get { d.bool(forKey: kLogin) }
        set { d.set(newValue, forKey: kLogin) }
    }

    private static let kSaveText = "clipshot.saveTextHistory"
    static var saveTextHistory: Bool {
        get { d.bool(forKey: kSaveText) }
        set { d.set(newValue, forKey: kSaveText) }
    }

    /// IDs de items anclados (sobreviven el cap, en sección "Anclados" arriba).
    private static let kPinned = "clipshot.pinnedHistoryIds"
    static var pinnedHistoryIds: Set<String> {
        get { Set(d.stringArray(forKey: kPinned) ?? []) }
        set { d.set(Array(newValue), forKey: kPinned) }
    }
    static func isPinned(_ id: String) -> Bool { pinnedHistoryIds.contains(id) }
    static func togglePinned(_ id: String) {
        var s = pinnedHistoryIds
        if s.contains(id) { s.remove(id) } else { s.insert(id) }
        pinnedHistoryIds = s
    }

    /// Bundle IDs de apps donde NO debemos capturar texto (password managers, banca).
    private static let kExcludedApps = "clipshot.excludedAppBundleIds"
    static let defaultExcludedApps: [String] = [
        "com.apple.keychainaccess",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword4",
        "com.1password.1password",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.dashlanephonefinal",
    ]
    static var excludedAppBundleIds: [String] {
        get {
            if let stored = d.stringArray(forKey: kExcludedApps) { return stored }
            return defaultExcludedApps
        }
        set { d.set(newValue, forKey: kExcludedApps) }
    }

    /// Global hotkey (default ⌘⇧V).
    private static let kHotkeyKey = "clipshot.globalHotkey.key"
    private static let kHotkeyMods = "clipshot.globalHotkey.mods"
    static var globalHotkey: (key: UInt32, mods: UInt32) {
        get {
            let k = d.object(forKey: kHotkeyKey) as? Int ?? Int(kVK_ANSI_V)
            let m = d.object(forKey: kHotkeyMods) as? Int ?? (cmdKey | shiftKey)
            return (UInt32(k), UInt32(m))
        }
        set {
            d.set(Int(newValue.key), forKey: kHotkeyKey)
            d.set(Int(newValue.mods), forKey: kHotkeyMods)
        }
    }

    /// OCR opt-in (procesa cada captura con Apple Vision en background).
    private static let kEnableOCR = "clipshot.enableOCR"
    static var enableOCR: Bool {
        get { d.bool(forKey: kEnableOCR) }
        set { d.set(newValue, forKey: kEnableOCR) }
    }

    /// ClipShot Pro status — viene de StoreKit 2 (Transaction.currentEntitlements).
    /// `PurchaseManager` mantiene este flag actualizado.
    private static let kIsPro = "clipshot.isPro"
    static var isPro: Bool {
        get { d.bool(forKey: kIsPro) }
        set { d.set(newValue, forKey: kIsPro) }
    }
    /// Product ID configurado en App Store Connect.
    static let proProductID = "com.jcmorla.clipshot.pro"

    /// Security-scoped bookmark of the user-selected screenshot folder.
    /// Required because the sandbox does not let us read ~/Desktop without
    /// explicit user consent via NSOpenPanel.
    static var screenshotFolderBookmark: Data? {
        get { d.data(forKey: kFolderBookmark) }
        set {
            if let v = newValue { d.set(v, forKey: kFolderBookmark) }
            else { d.removeObject(forKey: kFolderBookmark) }
        }
    }

    static func applyOpenAtLogin(_ enable: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enable {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
            } catch {
                clog("openAtLogin error: \(error)")
            }
        }
    }
}


let logURL: URL = {
    let fm = FileManager.default
    // Under the sandbox this resolves to
    // ~/Library/Containers/com.josecasadogenao.clipshot/Data/Library/Logs/
    let dir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first!.appendingPathComponent("Logs")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                             attributes: [.posixPermissions: 0o700])
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    let file = dir.appendingPathComponent("ClipShot.log")
    if fm.fileExists(atPath: file.path) {
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    return file
}()

private let logMaxBytes: UInt64 = 1_048_576  // 1 MB

// clog() writes to a private log file inside the sandbox container. Its output
// is NEVER user-facing (the user does not normally see it), so log lines are
// intentionally kept in English/developer Spanish and are NOT localized.
func clog(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(s)\n"
    guard let data = line.data(using: .utf8) else { return }

    // Rotate the log when it exceeds 1 MB so it does not fill the disk.
    if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
       let size = attrs[.size] as? UInt64, size > logMaxBytes {
        let rotated = logURL.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: logURL, to: rotated)
    }

    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    } else {
        try? data.write(to: logURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: logURL.path)
    }
}




final class DraggableThumbnailView: NSView, NSDraggingSource {
    var image: NSImage?
    var fileURL: URL?
    var onClick: (() -> Void)?
    private var mouseDownLocation: NSPoint?
    private var didDrag = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Capture all clicks even when they fall on the inner NSImageView.
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation else { return }
        let here = event.locationInWindow
        let dist = hypot(here.x - start.x, here.y - start.y)
        guard dist > 4, !didDrag else { return }
        didDrag = true
        startDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil }
        if !didDrag {
            onClick?()
        }
    }

    private func startDrag(with event: NSEvent) {
        guard let url = fileURL, let img = image else { return }
        // If the file no longer exists (e.g. clearHistory ran between showing
        // the thumbnail and dragging it), abort cleanly instead of forwarding
        // a dead URL.
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let dragSize = NSSize(width: bounds.width * 0.7, height: bounds.height * 0.7)
        let dragRect = NSRect(
            x: bounds.midX - dragSize.width / 2,
            y: bounds.midY - dragSize.height / 2,
            width: dragSize.width, height: dragSize.height
        )
        dragItem.setDraggingFrame(dragRect, contents: img)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return [.copy, .generic]
    }
}

final class ThumbnailOverlay {
    private var window: NSWindow?
    private var dismissTimer: Timer?

    func show(image: NSImage, fileURL: URL? = nil) {
        dismiss(animated: false)
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = NSSize(width: 240, height: 152)
        let margin: CGFloat = 20
        let endFrame = NSRect(
            x: visible.maxX - size.width - margin,
            y: visible.minY + margin,
            width: size.width, height: size.height
        )
        let startFrame = NSRect(x: endFrame.minX + 60, y: endFrame.minY,
                                 width: size.width, height: size.height)

        let win = NSWindow(contentRect: startFrame,
                           styleMask: [.borderless],
                           backing: .buffered, defer: false)
        win.level = .floating
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.alphaValue = 0

        let container = DraggableThumbnailView(frame: NSRect(origin: .zero, size: size))
        container.image = image
        container.fileURL = fileURL
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        container.layer?.borderWidth = 1

        let pad: CGFloat = 6
        let iv = NSImageView(frame: NSRect(x: pad, y: pad,
                                            width: size.width - pad * 2,
                                            height: size.height - pad * 2))
        iv.image = image
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.wantsLayer = true
        iv.layer?.cornerRadius = 4
        iv.layer?.masksToBounds = true
        iv.isEditable = false
        container.addSubview(iv)

        container.onClick = { [weak self] in
            guard let url = fileURL else { return }
            NSWorkspace.shared.open(url)
            self?.dismiss(animated: true)
        }

        win.contentView = container
        win.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            win.animator().setFrame(endFrame, display: true)
            win.animator().alphaValue = 1
        })

        self.window = win
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 4.5, repeats: false) { [weak self] _ in
            self?.dismiss(animated: true)
        }
    }

    func dismiss(animated: Bool) {
        guard let win = window else { return }
        dismissTimer?.invalidate()
        dismissTimer = nil
        if !animated {
            win.orderOut(nil)
            window = nil
            return
        }
        let f = win.frame
        let outFrame = NSRect(x: f.maxX + 20, y: f.minY, width: f.width, height: f.height)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            win.animator().setFrame(outFrame, display: true)
            win.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            win.orderOut(nil)
            self?.window = nil
        })
    }
}

private enum Step1Mode {
    case selector
    case guide(subStep: Int)  // 0..3 (open tool, click options, uncheck, done)
}

final class WelcomeWindowController: NSWindowController {
    private var currentStep = 0
    private var step1Mode: Step1Mode = .selector
    // Steps: 0 welcome, 1 saving explanation, 2 folder pick, 3 overlay,
    // 4 login, 5 privacy, 6 done.
    private let totalSteps = 7
    private var contentBox: NSView!
    private var backButton: NSButton!
    private var nextButton: NSButton!
    private var skipButton: NSButton!
    private var dotsRow: NSStackView!
    var onFinish: (() -> Void)?
    var onPickFolder: (() -> Void)?

    // Selections
    var overlayChoice: Bool = true
    var loginChoice: Bool = false  // App Store guideline 2.4.5(iii): default OFF
    var folderChosenLabel: String = NSLocalizedString(
        "folder.default_label",
        comment: "Default friendly label shown for the screenshots folder when the user has not picked one (means ~/Desktop)."
    )

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.center()
        win.title = NSLocalizedString(
            "welcome.window.title",
            comment: "Title of the onboarding / welcome window."
        )
        super.init(window: win)
        setupChrome()
        render()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setupChrome() {
        guard let win = window, let content = win.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        contentBox = NSView(frame: NSRect(x: 40, y: 100, width: 480, height: 320))
        contentBox.autoresizingMask = [.width, .height]
        content.addSubview(contentBox)

        // Bottom controls
        let skipTitle = NSLocalizedString(
            "welcome.button.skip",
            comment: "Welcome window button that closes onboarding using defaults."
        )
        skipButton = NSButton(title: skipTitle, target: self, action: #selector(skipAll))
        skipButton.bezelStyle = .accessoryBarAction
        skipButton.isBordered = false
        skipButton.frame = NSRect(x: 30, y: 24, width: 70, height: 28)
        content.addSubview(skipButton)

        let backTitle = NSLocalizedString(
            "welcome.button.back",
            comment: "Welcome window button that goes to the previous step."
        )
        backButton = NSButton(title: backTitle, target: self, action: #selector(goBack))
        backButton.bezelStyle = .rounded
        backButton.frame = NSRect(x: 360, y: 24, width: 80, height: 28)
        content.addSubview(backButton)

        let nextTitle = NSLocalizedString(
            "welcome.button.next",
            comment: "Welcome window button that advances to the next step."
        )
        nextButton = NSButton(title: nextTitle, target: self, action: #selector(goNext))
        nextButton.bezelStyle = .rounded
        nextButton.keyEquivalent = "\r"
        nextButton.frame = NSRect(x: 450, y: 24, width: 100, height: 28)
        content.addSubview(nextButton)

        dotsRow = NSStackView()
        dotsRow.orientation = .horizontal
        dotsRow.spacing = 8
        for _ in 0..<totalSteps {
            let dot = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 4
            dot.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
            dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
            dotsRow.addArrangedSubview(dot)
        }
        dotsRow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(dotsRow)
        NSLayoutConstraint.activate([
            dotsRow.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            dotsRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -72)
        ])
    }

    private func render() {
        contentBox.subviews.forEach { $0.removeFromSuperview() }
        let view: NSView
        switch currentStep {
        case 0: view = buildWelcome()
        case 1: view = buildSavingExplanation()
        case 2: view = buildFolderPicker()
        case 3: view = buildOverlay()
        case 4: view = buildLogin()
        case 5: view = buildPrivacy()
        default: view = buildDone()
        }
        view.frame = contentBox.bounds
        view.autoresizingMask = [.width, .height]
        contentBox.addSubview(view)

        // On step 1 (saving explanation: selector + guide) the cards / guide
        // handle navigation internally — hide the standard welcome buttons.
        let isStep1 = currentStep == 1
        backButton.isHidden = (currentStep == 0) || isStep1
        nextButton.isHidden = isStep1
        skipButton.isHidden = (currentStep == totalSteps - 1) || isStep1

        if !isStep1 {
            nextButton.title = currentStep == totalSteps - 1
                ? NSLocalizedString(
                    "welcome.button.start",
                    comment: "Welcome window primary button on the last step; finishes onboarding."
                )
                : NSLocalizedString(
                    "welcome.button.next",
                    comment: "Welcome window button that advances to the next step."
                )
        }

        for (idx, dot) in dotsRow.arrangedSubviews.enumerated() {
            dot.layer?.backgroundColor = (idx == currentStep
                ? NSColor.controlAccentColor
                : NSColor.tertiaryLabelColor).cgColor
        }
    }

    // MARK: Step builders

    private func buildWelcome() -> NSView {
        let v = NSView()
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(icon)

        let titleText = NSLocalizedString(
            "welcome.step0.title",
            comment: "Welcome step 0 (hero) large title."
        )
        let subtitleText = NSLocalizedString(
            "welcome.step0.subtitle",
            comment: "Welcome step 0 (hero) one-line subtitle."
        )
        let bodyText = NSLocalizedString(
            "welcome.step0.body",
            comment: "Welcome step 0 (hero) body explaining the click-icon-to-see-history flow."
        )
        let title = label(titleText, size: 28, weight: .bold)
        let subtitle = label(subtitleText,
                              size: 14, weight: .regular, color: .secondaryLabelColor, multiline: true)
        let body = label(bodyText,
                          size: 13, weight: .regular, color: .labelColor, multiline: true)
        for x in [title, subtitle, body] {
            x.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(x)
        }
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            icon.topAnchor.constraint(equalTo: v.topAnchor, constant: 10),
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 18),
            title.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            subtitle.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 30),
            subtitle.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -30),
            body.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 20),
            body.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 30),
            body.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -30),
        ])
        return v
    }

    private func buildSavingExplanation() -> NSView {
        switch step1Mode {
        case .selector:
            return buildStep1Selector()
        case .guide(let subStep):
            return buildStep1Guide(subStep: subStep)
        }
    }

    private func buildStep1Selector() -> NSView {
        let v = NSView()
        let title = label(
            NSLocalizedString("welcome.step1.title", comment: "Step 1 title"),
            size: 22, weight: .bold)
        let intro = label(
            NSLocalizedString("welcome.step1.intro", comment: "Step 1 intro paragraph"),
            size: 12, weight: .regular, color: .secondaryLabelColor, multiline: true)
        intro.alignment = .center

        // Card 1: Easy
        let card1 = makeStep1Card(
            tag: 0,
            emoji: "✓",
            title: NSLocalizedString("welcome.step1.option1.title", comment: "Easy option title"),
            body: NSLocalizedString("welcome.step1.option1.body", comment: "Easy option body"))
        // Card 2: Advanced
        let card2 = makeStep1Card(
            tag: 1,
            emoji: "⚡",
            title: NSLocalizedString("welcome.step1.option2.title", comment: "Advanced option title"),
            body: NSLocalizedString("welcome.step1.option2.short_body", comment: "Advanced option short body for the selector card"))

        for x: NSView in [title, intro, card1, card2] {
            x.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(x)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: v.topAnchor, constant: 6),
            title.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            intro.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            intro.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 30),
            intro.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -30),
            card1.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 18),
            card1.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            card1.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -20),
            card1.heightAnchor.constraint(equalToConstant: 88),
            card2.topAnchor.constraint(equalTo: card1.bottomAnchor, constant: 12),
            card2.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            card2.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -20),
            card2.heightAnchor.constraint(equalToConstant: 88),
        ])
        return v
    }

    private func makeStep1Card(tag: Int, emoji: String, title cardTitle: String, body: String) -> NSButton {
        let b = NSButton(frame: .zero)
        b.tag = tag
        b.title = ""
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 10
        b.layer?.borderWidth = 1
        b.layer?.borderColor = NSColor.separatorColor.cgColor
        b.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        b.target = self
        b.action = #selector(step1CardClicked(_:))

        let emojiLabel = NSTextField(labelWithString: emoji)
        emojiLabel.font = NSFont.systemFont(ofSize: 26)
        emojiLabel.translatesAutoresizingMaskIntoConstraints = false

        let t = label(cardTitle, size: 14, weight: .semibold)
        t.alignment = .left
        t.translatesAutoresizingMaskIntoConstraints = false

        let bodyLabel = label(body, size: 12, weight: .regular, color: .secondaryLabelColor, multiline: true)
        bodyLabel.alignment = .left
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.preferredMaxLayoutWidth = 380

        let arrow = NSTextField(labelWithString: "›")
        arrow.font = NSFont.systemFont(ofSize: 24, weight: .light)
        arrow.textColor = .tertiaryLabelColor
        arrow.translatesAutoresizingMaskIntoConstraints = false

        b.addSubview(emojiLabel)
        b.addSubview(t)
        b.addSubview(bodyLabel)
        b.addSubview(arrow)
        NSLayoutConstraint.activate([
            emojiLabel.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 16),
            emojiLabel.centerYAnchor.constraint(equalTo: b.centerYAnchor),
            t.topAnchor.constraint(equalTo: b.topAnchor, constant: 14),
            t.leadingAnchor.constraint(equalTo: emojiLabel.trailingAnchor, constant: 14),
            t.trailingAnchor.constraint(equalTo: arrow.leadingAnchor, constant: -8),
            bodyLabel.topAnchor.constraint(equalTo: t.bottomAnchor, constant: 2),
            bodyLabel.leadingAnchor.constraint(equalTo: t.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: arrow.leadingAnchor, constant: -8),
            arrow.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -16),
            arrow.centerYAnchor.constraint(equalTo: b.centerYAnchor),
        ])
        return b
    }

    @objc private func step1CardClicked(_ sender: NSButton) {
        if sender.tag == 0 {
            // Easy option: just continue
            currentStep += 1
            step1Mode = .selector  // reset for next time
            render()
        } else {
            // Advanced: enter guide at sub-step 0
            step1Mode = .guide(subStep: 0)
            render()
        }
    }

    private func buildStep1Guide(subStep: Int) -> NSView {
        let v = NSView()

        let stepIndicator = label(
            String(format: NSLocalizedString("welcome.step1.guide.step_indicator", comment: "Sub-step indicator like 'Paso 2 de 4'"),
                   subStep + 1, 4),
            size: 11, weight: .medium, color: .secondaryLabelColor)
        stepIndicator.alignment = .center

        let titleKey: String
        let bodyKey: String
        let needsActionButton: Bool
        let actionButtonKey: String
        switch subStep {
        case 0:
            titleKey = "welcome.step1.guide.sub1.title"
            bodyKey  = "welcome.step1.guide.sub1.body"
            needsActionButton = true
            actionButtonKey = "welcome.step1.guide.sub1.button"
        case 1:
            titleKey = "welcome.step1.guide.sub2.title"
            bodyKey  = "welcome.step1.guide.sub2.body"
            needsActionButton = false
            actionButtonKey = ""
        case 2:
            titleKey = "welcome.step1.guide.sub3.title"
            bodyKey  = "welcome.step1.guide.sub3.body"
            needsActionButton = false
            actionButtonKey = ""
        default:
            titleKey = "welcome.step1.guide.sub4.title"
            bodyKey  = "welcome.step1.guide.sub4.body"
            needsActionButton = false
            actionButtonKey = ""
        }

        let title = label(NSLocalizedString(titleKey, comment: "Sub-step title"),
                           size: 20, weight: .bold)
        let body = label(NSLocalizedString(bodyKey, comment: "Sub-step body"),
                          size: 13, weight: .regular, color: .labelColor, multiline: true)

        let backToSelector = NSButton(
            title: NSLocalizedString("welcome.step1.guide.back_to_selector", comment: "Button to go back to the two-option selector"),
            target: self, action: #selector(guideBackToSelector))
        backToSelector.bezelStyle = .accessoryBarAction
        backToSelector.isBordered = false

        let nextSub = NSButton(
            title: subStep == 3
                ? NSLocalizedString("welcome.step1.guide.done_button", comment: "Final sub-step button: continue welcome flow")
                : NSLocalizedString("welcome.step1.guide.next_button", comment: "Sub-step Next button"),
            target: self, action: #selector(guideAdvance))
        nextSub.bezelStyle = .rounded
        nextSub.keyEquivalent = "\r"

        for x: NSView in [stepIndicator, title, body, backToSelector, nextSub] {
            x.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(x)
        }

        var topAnchor = title.bottomAnchor
        var bottomActionAnchor = body.bottomAnchor

        if needsActionButton {
            let openBtn = NSButton(
                title: NSLocalizedString(actionButtonKey, comment: "Sub-step action button"),
                target: self, action: #selector(openScreenshotSettings))
            openBtn.bezelStyle = .rounded
            openBtn.controlSize = .large
            openBtn.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(openBtn)
            NSLayoutConstraint.activate([
                openBtn.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 16),
                openBtn.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            ])
            bottomActionAnchor = openBtn.bottomAnchor
            _ = topAnchor  // silence unused
        }

        NSLayoutConstraint.activate([
            stepIndicator.topAnchor.constraint(equalTo: v.topAnchor, constant: 4),
            stepIndicator.centerXAnchor.constraint(equalTo: v.centerXAnchor),

            title.topAnchor.constraint(equalTo: stepIndicator.bottomAnchor, constant: 10),
            title.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            title.leadingAnchor.constraint(greaterThanOrEqualTo: v.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -24),

            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            body.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 34),
            body.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -34),

            backToSelector.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -10),
            backToSelector.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),

            nextSub.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -10),
            nextSub.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            nextSub.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        _ = bottomActionAnchor  // already used
        return v
    }

    @objc private func guideBackToSelector() {
        step1Mode = .selector
        render()
    }

    @objc private func guideAdvance() {
        if case .guide(let sub) = step1Mode {
            if sub >= 3 {
                // Done — continue main welcome flow
                step1Mode = .selector
                currentStep += 1
                render()
            } else {
                step1Mode = .guide(subStep: sub + 1)
                render()
            }
        }
    }

    @objc func openScreenshotSettings() {
        // The "Show Floating Thumbnail" option lives in Apple's Screenshot tool
        // (Cmd+Shift+5), inside the bottom toolbar's "Options" menu — NOT in
        // System Settings. So we launch Screenshot.app, which shows the on-screen
        // toolbar where the user can click "Options" and toggle the setting.
        // We NEVER modify any default — the user does it himself in Apple's UI.
        let screenshotApp = URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: screenshotApp, configuration: cfg) { _, error in
            if error != nil {
                // Fallback: try Spotlight by name
                _ = NSWorkspace.shared.launchApplication("Screenshot")
            }
        }
    }

    private var folderStatusLabel: NSTextField?

    private func buildFolderPicker() -> NSView {
        let v = NSView()
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "folder.badge.gearshape",
                              accessibilityDescription: nil)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleText = NSLocalizedString(
            "welcome.step2.title",
            comment: "Welcome step 2 title — asks user to pick screenshots folder."
        )
        let bodyText = NSLocalizedString(
            "welcome.step2.body",
            comment: "Welcome step 2 body — explains the sandbox folder access pattern."
        )
        let pickButtonTitle = NSLocalizedString(
            "welcome.step2.pick_button",
            comment: "Welcome step 2 button label that opens the folder NSOpenPanel."
        )
        let statusFormat = NSLocalizedString(
            "welcome.step2.status.format",
            comment: "Welcome step 2 status line under the pick-folder button. %@ is the folder label."
        )

        let title = label(titleText, size: 20, weight: .bold)
        let body = label(bodyText,
                          size: 13, weight: .regular, color: .secondaryLabelColor, multiline: true)

        let pickButton = NSButton(title: pickButtonTitle, target: self, action: #selector(pickFolderTapped))
        pickButton.bezelStyle = .rounded
        pickButton.translatesAutoresizingMaskIntoConstraints = false

        let status = label(String(format: statusFormat, folderChosenLabel),
                            size: 12, weight: .regular, color: .secondaryLabelColor, multiline: true)
        status.translatesAutoresizingMaskIntoConstraints = false
        folderStatusLabel = status

        v.addSubview(icon); v.addSubview(title); v.addSubview(body); v.addSubview(pickButton); v.addSubview(status)
        title.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: v.topAnchor, constant: 6),
            icon.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 52),
            icon.heightAnchor.constraint(equalToConstant: 52),
            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            title.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            body.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 36),
            body.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -36),
            pickButton.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 22),
            pickButton.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            status.topAnchor.constraint(equalTo: pickButton.bottomAnchor, constant: 14),
            status.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 36),
            status.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -36),
        ])
        return v
    }

    @objc private func pickFolderTapped() {
        onPickFolder?()
        let statusFormat = NSLocalizedString(
            "welcome.step2.status.format",
            comment: "Welcome step 2 status line under the pick-folder button. %@ is the folder label."
        )
        folderStatusLabel?.stringValue = String(format: statusFormat, folderChosenLabel)
    }

    /// Called by the app delegate after the open panel completes so the
    /// welcome window can update its status label.
    func updateFolderLabel(_ label: String) {
        folderChosenLabel = label
        let statusFormat = NSLocalizedString(
            "welcome.step2.status.format",
            comment: "Welcome step 2 status line under the pick-folder button. %@ is the folder label."
        )
        folderStatusLabel?.stringValue = String(format: statusFormat, label)
    }

    private func buildOverlay() -> NSView {
        let v = NSView()
        let titleText = NSLocalizedString(
            "welcome.step3.title",
            comment: "Welcome step 3 title — floating thumbnail toggle."
        )
        let bodyText = NSLocalizedString(
            "welcome.step3.body",
            comment: "Welcome step 3 body — explains what the floating thumbnail does."
        )
        let toggleLabelText = NSLocalizedString(
            "welcome.step3.toggle_label",
            comment: "Welcome step 3 label next to the NSSwitch for the overlay preference."
        )
        let title = label(titleText, size: 22, weight: .bold)
        let body = label(bodyText,
                          size: 13, weight: .regular, color: .secondaryLabelColor, multiline: true)
        let toggle = NSSwitch()
        toggle.state = overlayChoice ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggleOverlay(_:))
        let toggleLabel = label(toggleLabelText, size: 13, weight: .medium)

        for x: NSView in [title, body, toggle, toggleLabel] {
            x.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(x)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: v.topAnchor, constant: 30),
            title.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 18),
            body.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 36),
            body.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -36),
            toggle.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 36),
            toggle.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 60),
            toggleLabel.centerYAnchor.constraint(equalTo: toggle.centerYAnchor),
            toggleLabel.leadingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: 12),
        ])
        return v
    }

    @objc private func toggleOverlay(_ sender: NSSwitch) {
        overlayChoice = (sender.state == .on)
    }

    private func buildLogin() -> NSView {
        let v = NSView()
        let titleText = NSLocalizedString(
            "welcome.step4.title",
            comment: "Welcome step 4 title — open at login preference."
        )
        let bodyText = NSLocalizedString(
            "welcome.step4.body",
            comment: "Welcome step 4 body — explains the open-at-login preference."
        )
        let toggleLabelText = NSLocalizedString(
            "welcome.step4.toggle_label",
            comment: "Welcome step 4 label next to the NSSwitch for the open-at-login preference."
        )
        let title = label(titleText, size: 22, weight: .bold)
        let body = label(bodyText,
                          size: 13, weight: .regular, color: .secondaryLabelColor, multiline: true)
        let toggle = NSSwitch()
        toggle.state = loginChoice ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggleLogin(_:))
        let toggleLabel = label(toggleLabelText, size: 13, weight: .medium)
        for x: NSView in [title, body, toggle, toggleLabel] {
            x.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(x)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: v.topAnchor, constant: 30),
            title.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 18),
            body.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 36),
            body.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -36),
            toggle.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 36),
            toggle.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 60),
            toggleLabel.centerYAnchor.constraint(equalTo: toggle.centerYAnchor),
            toggleLabel.leadingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: 12),
        ])
        return v
    }

    @objc private func toggleLogin(_ sender: NSSwitch) {
        loginChoice = (sender.state == .on)
    }

    private func buildPrivacy() -> NSView {
        let v = NSView()
        let icon = NSImageView()
        let iconA11y = NSLocalizedString(
            "welcome.step5.icon_accessibility",
            comment: "VoiceOver description for the green privacy-shield icon on welcome step 5."
        )
        icon.image = NSImage(systemSymbolName: "lock.shield.fill",
                              accessibilityDescription: iconA11y)
        icon.contentTintColor = .systemGreen
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleText = NSLocalizedString(
            "welcome.step5.title",
            comment: "Welcome step 5 title — privacy summary."
        )
        let bodyText = NSLocalizedString(
            "welcome.step5.body",
            comment: "Welcome step 5 body — multi-line block with bullets describing privacy guarantees. Keep the bullet character and line breaks."
        )
        let title = label(titleText, size: 22, weight: .bold)
        let body = label(bodyText, size: 13, weight: .regular, color: .labelColor, multiline: true)

        v.addSubview(icon); v.addSubview(title); v.addSubview(body)
        title.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: v.topAnchor, constant: 6),
            icon.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),
            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            title.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            body.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 40),
            body.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -40),
        ])
        return v
    }

    private func buildDone() -> NSView {
        let v = NSView()
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                              accessibilityDescription: nil)
        icon.contentTintColor = .systemGreen
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleText = NSLocalizedString(
            "welcome.step6.title",
            comment: "Welcome step 6 title — onboarding finished."
        )
        let bodyText = NSLocalizedString(
            "welcome.step6.body",
            comment: "Welcome step 6 body — summary of where to find ClipShot afterwards."
        )
        let title = label(titleText, size: 28, weight: .bold)
        let body = label(bodyText,
                          size: 13, weight: .regular, color: .secondaryLabelColor, multiline: true)
        v.addSubview(icon); v.addSubview(title); v.addSubview(body)
        title.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: v.topAnchor, constant: 30),
            icon.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 80),
            icon.heightAnchor.constraint(equalToConstant: 80),
            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 18),
            title.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            body.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 40),
            body.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -40),
        ])
        return v
    }

    // MARK: Helpers
    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                       color: NSColor = .labelColor, multiline: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.alignment = multiline ? .center : .center
        if multiline {
            l.lineBreakMode = .byWordWrapping
            l.maximumNumberOfLines = 0
            l.preferredMaxLayoutWidth = 460
        }
        return l
    }

    // MARK: Navigation
    @objc private func goNext() {
        if currentStep == totalSteps - 1 {
            commitAndClose()
        } else {
            currentStep += 1
            render()
        }
    }
    @objc private func goBack() {
        if currentStep > 0 {
            currentStep -= 1
            render()
        }
    }
    @objc private func skipAll() {
        // Skipping uses defaults
        commitAndClose()
    }
    private func commitAndClose() {
        Settings.showOverlay = overlayChoice
        Settings.openAtLogin = loginChoice
        Settings.applyOpenAtLogin(loginChoice)
        Settings.hasSeenIntro = true
        onFinish?()
        window?.close()
    }
}

struct HistoryItem {
    let id: String
    let date: Date
    let imagePath: URL
    var image: NSImage? { NSImage(contentsOf: imagePath) }
    var isPinned: Bool { Settings.isPinned(id) }
    var ocrText: String? {
        let sidecar = imagePath.deletingPathExtension().appendingPathExtension("ocr.txt")
        return try? String(contentsOf: sidecar, encoding: .utf8)
    }
}

struct TextItem {
    let id: String
    let date: Date
    let textPath: URL
    var content: String? { try? String(contentsOf: textPath, encoding: .utf8) }
    var isPinned: Bool { Settings.isPinned(id) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var history: [HistoryItem] = []
    var textHistory: [TextItem] = []
    let maxHistory = 500
    let maxTextHistory = 500

    /// History browser, color picker, hotkey config — ventanas on-demand.
    var browserWC: HistoryBrowserWindowController?
    var colorPickerWC: ColorPickerWindowController?
    var hotkeyWC: HotkeySettingsWindowController?
    var globalHotkey: GlobalHotkey?
    var lastChangeCount: Int = -1
    var pbTimer: Timer?
    let storeDir: URL
    let textStoreDir: URL
    var screenshotLocation: URL = URL(fileURLWithPath: (NSString("~/Desktop").expandingTildeInPath))
    /// True once we have a security-scoped resource open on `screenshotLocation`.
    /// We must call stopAccessingSecurityScopedResource() on the matching URL before
    /// opening a new one.
    private var accessingSecurityScope: URL?
    var processedFiles: Set<String> = []
    let screenshotPrefixes = ["Screenshot", "Screen Shot", "Captura"]
    let overlay = ThumbnailOverlay()
    var welcomeWC: WelcomeWindowController?

    override init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        storeDir = appSupport.appendingPathComponent("ClipShot/history")
        textStoreDir = appSupport.appendingPathComponent("ClipShot/text")
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: textStoreDir, withIntermediateDirectories: true)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        resolveScreenshotFolderBookmark()
        loadHistory()
        loadTextHistory()
        setupStatusItem()
        startPasteboardMonitor()
        startFolderMonitor()
        registerGlobalHotkey()
        if #available(macOS 12.0, *) {
            PurchaseManager.shared.start()
            NotificationCenter.default.addObserver(forName: .clipShotProStatusChanged,
                                                     object: nil, queue: .main) { [weak self] _ in
                self?.rebuildMenu()
            }
        }

        if !Settings.hasSeenIntro {
            showWelcome()
        }
    }

    func showWelcome() {
        let wc = WelcomeWindowController()
        // Pre-populate from current settings (in case re-shown later)
        wc.overlayChoice = Settings.showOverlay
        // Default loginChoice = false (App Review guideline 2.4.5(iii)).
        wc.loginChoice = Settings.openAtLogin
        wc.folderChosenLabel = describeCurrentFolder()
        wc.onPickFolder = { [weak self, weak wc] in
            self?.promptForScreenshotFolder { picked in
                if picked != nil, let w = wc {
                    let fallback = NSLocalizedString(
                        "folder.default_short",
                        comment: "Short fallback name for the Desktop folder; used when refreshing the welcome window after picking a folder."
                    )
                    w.updateFolderLabel(self?.describeCurrentFolder() ?? fallback)
                }
            }
        }
        wc.onFinish = { [weak self] in
            self?.rebuildMenu()
        }
        welcomeWC = wc
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                object: wc.window, queue: .main) { [weak self] _ in
            NSApp.setActivationPolicy(.accessory)
            self?.welcomeWC = nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // App Store build: nothing to restore. No system state was modified.
        // Just release any security-scoped resource we held.
        if let url = accessingSecurityScope {
            url.stopAccessingSecurityScopedResource()
            accessingSecurityScope = nil
        }
    }

    // MARK: Security-scoped bookmark flow

    /// Returns a user-friendly label for the current screenshot folder, suitable
    /// for showing in the welcome flow.
    private func describeCurrentFolder() -> String {
        let p = screenshotLocation.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if p == home + "/Desktop" {
            return NSLocalizedString(
                "folder.default_label",
                comment: "Default friendly label shown for the screenshots folder when the user has not picked one (means ~/Desktop)."
            )
        }
        if p.hasPrefix(home + "/") {
            return "~" + p.dropFirst(home.count)
        }
        return p
    }

    /// On launch, if we have a saved security-scoped bookmark, resolve it and
    /// start accessing. If not, we keep the default ~/Desktop URL — the user
    /// will be walked through picking the real folder during the welcome flow.
    private func resolveScreenshotFolderBookmark() {
        guard let data = Settings.screenshotFolderBookmark else {
            screenshotLocation = URL(fileURLWithPath:
                (NSString("~/Desktop").expandingTildeInPath))
            return
        }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if url.startAccessingSecurityScopedResource() {
                accessingSecurityScope = url
                screenshotLocation = url
                clog("Resolved screenshot folder bookmark: \(url.path) (stale=\(isStale))")
                if isStale {
                    // Re-create the bookmark so it stops being stale.
                    if let fresh = try? url.bookmarkData(
                        options: [.withSecurityScope],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    ) {
                        Settings.screenshotFolderBookmark = fresh
                    }
                }
            } else {
                clog("startAccessingSecurityScopedResource failed for \(url.path); falling back to Desktop")
                screenshotLocation = URL(fileURLWithPath:
                    (NSString("~/Desktop").expandingTildeInPath))
            }
        } catch {
            clog("Bookmark resolution failed: \(error); clearing and falling back to Desktop")
            Settings.screenshotFolderBookmark = nil
            screenshotLocation = URL(fileURLWithPath:
                (NSString("~/Desktop").expandingTildeInPath))
        }
    }

    /// Shows an NSOpenPanel to pick the screenshot folder, then persists a
    /// security-scoped bookmark and re-installs the folder watcher.
    func promptForScreenshotFolder(completion: ((URL?) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString(
            "folderpicker.title",
            comment: "Title of the folder-picker NSOpenPanel."
        )
        panel.message = NSLocalizedString(
            "folderpicker.message",
            comment: "Helper message shown above the file browser in the folder-picker NSOpenPanel."
        )
        panel.prompt = NSLocalizedString(
            "folderpicker.prompt",
            comment: "Confirm-button label inside the folder-picker NSOpenPanel."
        )
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath:
            (NSString("~/Desktop").expandingTildeInPath))

        // Run modally so the user sees it inline with the welcome flow.
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            completion?(nil)
            return
        }
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            Settings.screenshotFolderBookmark = data
            // Swap accessing scope.
            if let prev = accessingSecurityScope {
                prev.stopAccessingSecurityScopedResource()
                accessingSecurityScope = nil
            }
            if url.startAccessingSecurityScopedResource() {
                accessingSecurityScope = url
            }
            screenshotLocation = url
            clog("User picked screenshot folder: \(url.path)")
            // Re-seed processedFiles and restart the watcher on the new path.
            if let files = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
                processedFiles = Set(files)
            }
            installFolderDispatchSource()
            completion?(url)
        } catch {
            clog("Failed to create security-scoped bookmark: \(error)")
            completion?(nil)
        }
    }

    @objc func changeScreenshotFolder() {
        promptForScreenshotFolder { _ in }
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let a11y = NSLocalizedString(
                "statusitem.accessibility",
                comment: "Accessibility label for the menu-bar status item (the camera icon)."
            )
            let img = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: a11y)
            img?.isTemplate = true
            button.image = img
        }
        rebuildMenu()
    }

    func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let headerTitle = NSLocalizedString(
            "menu.header.title",
            comment: "Disabled header row at the top of the status-bar menu."
        )
        let header = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // Pinned section appears above regular history when there are pinned items.
        let pinned = pinnedEntries()
        if !pinned.isEmpty {
            let pinHeaderTitle = NSLocalizedString("menu.section.pinned",
                                                     comment: "Section header for pinned history entries.")
            let pinHeader = NSMenuItem(title: pinHeaderTitle, action: nil, keyEquivalent: "")
            pinHeader.isEnabled = false
            menu.addItem(pinHeader)
            for entry in pinned { addEntryMenuItem(entry, to: menu) }
            menu.addItem(.separator())
            let recentHeaderTitle = NSLocalizedString("menu.section.recent",
                                                        comment: "Section header for recent (unpinned) history.")
            let recentHeader = NSMenuItem(title: recentHeaderTitle, action: nil, keyEquivalent: "")
            recentHeader.isEnabled = false
            menu.addItem(recentHeader)
        }

        // Unified history list: screenshots and copied text interleaved by date.
        let merged = mergedHistoryEntries()
        if merged.isEmpty && pinned.isEmpty {
            let emptyTitle = NSLocalizedString(
                "menu.history.empty",
                comment: "Disabled placeholder shown in the menu when there is no history yet."
            )
            let item = NSMenuItem(title: "  " + emptyTitle, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for entry in merged { addEntryMenuItem(entry, to: menu) }
        }

        menu.addItem(.separator())
        let browseTitle = NSLocalizedString("menu.action.search_history",
                                              comment: "Menu item that opens the searchable history browser.")
        let browseItem = NSMenuItem(title: browseTitle,
                                      action: #selector(openHistoryBrowser), keyEquivalent: "f")
        browseItem.target = self
        menu.addItem(browseItem)

        let openFolderTitle = NSLocalizedString(
            "menu.action.open_history_folder",
            comment: "Menu item that opens the saved-history folder in Finder."
        )
        let openFolder = NSMenuItem(title: openFolderTitle, action: #selector(openHistoryFolder), keyEquivalent: "o")
        openFolder.target = self
        menu.addItem(openFolder)

        let openTextFolderTitle = NSLocalizedString(
            "menu.action.open_text_folder",
            comment: "Menu item that opens the saved-text folder in Finder."
        )
        let openTextFolder = NSMenuItem(title: openTextFolderTitle, action: #selector(openTextHistoryFolder), keyEquivalent: "")
        openTextFolder.target = self
        menu.addItem(openTextFolder)

        let clearTitle = NSLocalizedString(
            "menu.action.clear_history",
            comment: "Menu item that opens the clear-history confirmation alert."
        )
        let clear = NSMenuItem(title: clearTitle, action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())
        let prefsTitle = NSLocalizedString(
            "menu.preferences.title",
            comment: "Parent menu item for the Preferences submenu."
        )
        let prefs = NSMenuItem(title: prefsTitle, action: nil, keyEquivalent: "")
        let prefsMenu = NSMenu()

        let overlayItemTitle = NSLocalizedString(
            "menu.preferences.show_overlay",
            comment: "Preferences submenu item that toggles the floating-thumbnail overlay."
        )
        let overlayItem = NSMenuItem(title: overlayItemTitle,
                                       action: #selector(toggleOverlayPref), keyEquivalent: "")
        overlayItem.target = self
        overlayItem.state = Settings.showOverlay ? .on : .off
        prefsMenu.addItem(overlayItem)

        let loginItemTitle = NSLocalizedString(
            "menu.preferences.open_at_login",
            comment: "Preferences submenu item that toggles open-at-login."
        )
        let loginItem = NSMenuItem(title: loginItemTitle,
                                     action: #selector(toggleLoginPref), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = Settings.openAtLogin ? .on : .off
        prefsMenu.addItem(loginItem)

        let textHistoryTitle = NSLocalizedString(
            "menu.preferences.save_text",
            comment: "Preferences submenu toggle that enables saving clipboard text into history."
        )
        let textHistoryItem = NSMenuItem(title: textHistoryTitle,
                                           action: #selector(toggleTextHistoryPref), keyEquivalent: "")
        textHistoryItem.target = self
        textHistoryItem.state = Settings.saveTextHistory ? .on : .off
        prefsMenu.addItem(textHistoryItem)

        let ocrTitle = Settings.isPro
            ? NSLocalizedString("menu.preferences.ocr",
                                  comment: "Preferences toggle for OCR text extraction.")
            : NSLocalizedString("menu.preferences.ocr_pro",
                                  comment: "Preferences toggle for OCR text extraction (Pro version).")
        let ocrItem = NSMenuItem(title: ocrTitle, action: #selector(toggleOCRPref), keyEquivalent: "")
        ocrItem.target = self
        ocrItem.state = (Settings.enableOCR && Settings.isPro) ? .on : .off
        prefsMenu.addItem(ocrItem)

        let (hkKey, hkMods) = Settings.globalHotkey
        let hkLabelFormat = NSLocalizedString("menu.preferences.global_hotkey",
                                                comment: "Preferences entry showing the global hotkey, with the current binding as %@.")
        let hkLabel = String(format: hkLabelFormat, HotkeyRecorderView.describe(key: hkKey, mods: hkMods))
        let hkItem = NSMenuItem(title: hkLabel,
                                  action: #selector(openHotkeySettings), keyEquivalent: "")
        hkItem.target = self
        prefsMenu.addItem(hkItem)
        prefsMenu.addItem(.separator())

        let changeFolderTitle = NSLocalizedString(
            "menu.preferences.change_folder",
            comment: "Preferences submenu item that opens the folder picker. Ends with ellipsis per Apple HIG."
        )
        let changeFolder = NSMenuItem(title: changeFolderTitle,
                                        action: #selector(changeScreenshotFolder), keyEquivalent: "")
        changeFolder.target = self
        prefsMenu.addItem(changeFolder)
        prefsMenu.addItem(.separator())

        let showIntroTitle = NSLocalizedString(
            "menu.preferences.show_welcome",
            comment: "Preferences submenu item that re-opens the welcome / onboarding window."
        )
        let showIntro = NSMenuItem(title: showIntroTitle,
                                     action: #selector(reopenWelcome), keyEquivalent: "")
        showIntro.target = self
        prefsMenu.addItem(showIntro)
        prefs.submenu = prefsMenu
        menu.addItem(prefs)

        let proLabel = Settings.isPro
            ? NSLocalizedString("menu.pro.active", comment: "Pro is active")
            : NSLocalizedString("menu.pro.unlock", comment: "Unlock Pro")
        let proItem = NSMenuItem(title: proLabel, action: #selector(openPaywall), keyEquivalent: "")
        proItem.target = self
        menu.addItem(proItem)

        let aboutTitle = NSLocalizedString(
            "menu.action.about",
            comment: "Menu item that opens the About ClipShot alert."
        )
        let about = NSMenuItem(title: aboutTitle, action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quitTitle = NSLocalizedString(
            "menu.action.quit",
            comment: "Menu item that quits the app."
        )
        let quit = NSMenuItem(title: quitTitle, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc func toggleOverlayPref() {
        Settings.showOverlay.toggle()
        rebuildMenu()
    }
    @objc func toggleLoginPref() {
        Settings.openAtLogin.toggle()
        Settings.applyOpenAtLogin(Settings.openAtLogin)
        rebuildMenu()
    }
    @objc func toggleTextHistoryPref() {
        Settings.saveTextHistory.toggle()
        rebuildMenu()
    }
    @objc func reopenWelcome() {
        showWelcome()
    }

    func textPreview(_ text: String, limit: Int = 60) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
                          .replacingOccurrences(of: "\r", with: " ")
                          .replacingOccurrences(of: "\t", with: " ")
        let collapsed = oneLine.components(separatedBy: .whitespaces)
                                .filter { !$0.isEmpty }
                                .joined(separator: " ")
        if collapsed.count <= limit { return collapsed }
        let idx = collapsed.index(collapsed.startIndex, offsetBy: limit)
        return String(collapsed[..<idx]) + "…"
    }

    enum MergedEntry {
        case image(Int, HistoryItem)
        case text(Int, TextItem)
        var date: Date {
            switch self {
            case .image(_, let h): return h.date
            case .text(_, let t): return t.date
            }
        }
        var isPinned: Bool {
            switch self {
            case .image(_, let h): return h.isPinned
            case .text(_, let t): return t.isPinned
            }
        }
        var id: String {
            switch self {
            case .image(_, let h): return h.id
            case .text(_, let t): return t.id
            }
        }
    }

    /// Devuelve los items no anclados, ordenados por fecha. Los anclados
    /// se muestran arriba en su propia sección via pinnedEntries().
    func mergedHistoryEntries(limit: Int = 20) -> [MergedEntry] {
        Array(allMergedEntries().filter { !$0.isPinned }.prefix(limit))
    }

    /// Renders a small rounded "card" image for a copied-text entry so it can
    /// hang on the menu item the same way an image thumbnail does. The visual
    /// styling (control background + separator border + secondary-label icon)
    /// is intentionally drawn from system colors so it adapts to light/dark
    /// mode without any extra branching.
    func textCard(preview: String, size: NSSize) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        defer { img.unlockFocus() }

        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let iconSize: CGFloat = 13
        let iconPadding: CGFloat = 6
        if let raw = NSImage(systemSymbolName: "text.quote", accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .medium)
            let symbol = raw.withSymbolConfiguration(cfg) ?? raw
            let tinted = NSImage(size: NSSize(width: iconSize, height: iconSize))
            tinted.lockFocus()
            NSColor.secondaryLabelColor.set()
            let drawRect = NSRect(origin: .zero, size: tinted.size)
            symbol.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
            drawRect.fill(using: .sourceIn)
            tinted.unlockFocus()
            tinted.draw(in: NSRect(x: iconPadding,
                                     y: size.height - iconPadding - iconSize,
                                     width: iconSize,
                                     height: iconSize),
                          from: .zero, operation: .sourceOver, fraction: 1)
        }

        let textRect = NSRect(x: iconPadding,
                                y: iconPadding,
                                width: size.width - iconPadding * 2,
                                height: size.height - iconSize - iconPadding * 2)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        para.alignment = .left
        para.lineSpacing = 1
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para,
        ]
        let attr = NSAttributedString(string: preview, attributes: attrs)
        attr.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)

        return img
    }

    func thumbnail(from image: NSImage, maxSize: NSSize) -> NSImage {
        let aspect = image.size.width > 0 ? image.size.height / image.size.width : 1
        var w = maxSize.width
        var h = w * aspect
        if h > maxSize.height {
            h = maxSize.height
            w = h / max(aspect, 0.0001)
        }
        let target = NSSize(width: w, height: h)
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: .zero, operation: .copy, fraction: 1.0)
        thumb.unlockFocus()
        return thumb
    }

    func formatDate(_ d: Date) -> String {
        // Formats the per-item timestamp shown in the status-bar menu.
        // We use the user's current locale here (rather than forcing es_ES) so
        // dates look native to whatever UI language is active.
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateStyle = .short
        f.timeStyle = .medium
        return f.string(from: d)
    }

    @objc func copyHistoryItem(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx >= 0 && idx < history.count else { return }
        guard let img = history[idx].image else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
        lastChangeCount = pb.changeCount
        flashStatusIcon(symbol: "checkmark.circle.fill")
    }

    func flashStatusIcon(symbol: String) {
        guard let button = statusItem.button else { return }
        let original = button.image
        let flash = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        flash?.isTemplate = true
        button.image = flash
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            button.image = original
        }
    }

    // MARK: - Pin + submenu actions (ported from 1.5)

    func allMergedEntries() -> [MergedEntry] {
        var entries: [MergedEntry] = history.enumerated().map { .image($0.offset, $0.element) }
        if Settings.saveTextHistory {
            entries.append(contentsOf: textHistory.enumerated().map { .text($0.offset, $0.element) })
        }
        entries.sort { $0.date > $1.date }
        return entries
    }

    func pinnedEntries() -> [MergedEntry] {
        allMergedEntries().filter { $0.isPinned }
    }

    func addEntryMenuItem(_ entry: MergedEntry, to menu: NSMenu) {
        switch entry {
        case .image(let idx, let h):
            let item = NSMenuItem(title: "  " + formatDate(h.date),
                                    action: #selector(copyHistoryItem(_:)), keyEquivalent: "")
            item.target = self
            item.tag = idx
            if let img = h.image {
                item.image = thumbnail(from: img, maxSize: NSSize(width: 140, height: 90))
            }
            item.submenu = buildEntrySubmenu(id: h.id, fileURL: h.imagePath, isImage: true)
            menu.addItem(item)
        case .text(let idx, let t):
            let body = textPreview(t.content ?? "", limit: 120)
            let item = NSMenuItem(title: "  " + formatDate(t.date),
                                    action: #selector(copyTextHistoryItem(_:)), keyEquivalent: "")
            item.target = self
            item.tag = idx
            item.image = textCard(preview: body, size: NSSize(width: 140, height: 90))
            item.toolTip = t.content
            item.submenu = buildEntrySubmenu(id: t.id, fileURL: t.textPath, isImage: false)
            menu.addItem(item)
        }
    }

    func buildEntrySubmenu(id: String, fileURL: URL, isImage: Bool) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false

        let pinTitle = Settings.isPinned(id)
            ? NSLocalizedString("menu.action.unpin", comment: "Unpin a history entry")
            : NSLocalizedString("menu.action.pin", comment: "Pin a history entry")
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(togglePinEntry(_:)), keyEquivalent: "")
        pinItem.target = self
        pinItem.representedObject = id
        sub.addItem(pinItem)

        if isImage {
            let sidecar = fileURL.deletingPathExtension().appendingPathExtension("ocr.txt")
            if FileManager.default.fileExists(atPath: sidecar.path) {
                let ocrTitle = NSLocalizedString("menu.action.copy_ocr_text",
                                                   comment: "Copy OCR-extracted text from an image")
                let ocrItem = NSMenuItem(title: ocrTitle,
                                           action: #selector(copyOCRTextFromImage(_:)), keyEquivalent: "")
                ocrItem.target = self
                ocrItem.representedObject = fileURL
                sub.addItem(ocrItem)
            }
            let pickerTitle = Settings.isPro
                ? NSLocalizedString("menu.action.color_picker",
                                      comment: "Open color picker on a captured image")
                : NSLocalizedString("menu.action.color_picker_pro",
                                      comment: "Open color picker (Pro version)")
            let pickerItem = NSMenuItem(title: pickerTitle,
                                          action: #selector(openColorPicker(_:)), keyEquivalent: "")
            pickerItem.target = self
            pickerItem.representedObject = fileURL
            sub.addItem(pickerItem)
        }

        sub.addItem(.separator())

        let revealTitle = NSLocalizedString("menu.action.reveal_in_finder",
                                              comment: "Reveal a saved item in Finder")
        let revealItem = NSMenuItem(title: revealTitle, action: #selector(revealEntry(_:)), keyEquivalent: "")
        revealItem.target = self
        revealItem.representedObject = fileURL
        sub.addItem(revealItem)

        let deleteTitle = NSLocalizedString("menu.action.delete",
                                              comment: "Delete a single history entry")
        let deleteItem = NSMenuItem(title: deleteTitle, action: #selector(deleteEntry(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = ["id": id, "fileURL": fileURL, "isImage": isImage] as [String: Any]
        sub.addItem(deleteItem)

        return sub
    }

    @objc func togglePinEntry(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.togglePinned(id)
        rebuildMenu()
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            self?.statusItem.button?.performClick(nil)
        }
    }

    @objc func revealEntry(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func deleteEntry(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let url = info["fileURL"] as? URL,
              let id = info["id"] as? String,
              let isImage = info["isImage"] as? Bool else { return }
        try? FileManager.default.removeItem(at: url)
        if isImage {
            let sidecar = url.deletingPathExtension().appendingPathExtension("ocr.txt")
            try? FileManager.default.removeItem(at: sidecar)
        }
        if Settings.isPinned(id) { Settings.togglePinned(id) }
        if isImage { loadHistory() } else { loadTextHistory() }
        rebuildMenu()
    }

    @objc func copyOCRTextFromImage(_ sender: NSMenuItem) {
        guard let imageURL = sender.representedObject as? URL else { return }
        let sidecar = imageURL.deletingPathExtension().appendingPathExtension("ocr.txt")
        guard let text = try? String(contentsOf: sidecar, encoding: .utf8) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastChangeCount = pb.changeCount
        flashStatusIcon(symbol: "text.viewfinder")
    }

    @objc func openColorPicker(_ sender: NSMenuItem) {
        guard Settings.isPro else {
            if #available(macOS 12.0, *) { PaywallWindowController.presentModal() }
            return
        }
        guard let imageURL = sender.representedObject as? URL else { return }
        colorPickerWC = ColorPickerWindowController(imageURL: imageURL)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        colorPickerWC?.showWindow(nil)
        colorPickerWC?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func openHistoryBrowser() {
        if browserWC == nil {
            browserWC = HistoryBrowserWindowController(owner: self)
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                     object: browserWC?.window, queue: .main) { [weak self] _ in
                NSApp.setActivationPolicy(.accessory)
                self?.browserWC = nil
            }
        }
        browserWC?.reloadFromOwner()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        browserWC?.showWindow(nil)
        browserWC?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func openHotkeySettings() {
        if hotkeyWC == nil {
            hotkeyWC = HotkeySettingsWindowController(owner: self)
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                     object: hotkeyWC?.window, queue: .main) { [weak self] _ in
                NSApp.setActivationPolicy(.accessory)
                self?.hotkeyWC = nil
                self?.rebuildMenu()
            }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        hotkeyWC?.showWindow(nil)
        hotkeyWC?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func toggleOCRPref() {
        guard Settings.isPro else {
            if #available(macOS 12.0, *) { PaywallWindowController.presentModal() }
            return
        }
        Settings.enableOCR.toggle()
        rebuildMenu()
    }

    @objc func openPaywall() {
        if #available(macOS 12.0, *) {
            PaywallWindowController.presentModal()
        }
    }

    func registerGlobalHotkey() {
        let (key, mods) = Settings.globalHotkey
        globalHotkey = GlobalHotkey { [weak self] in
            self?.openHistoryBrowser()
        }
        globalHotkey?.register(keyCode: key, modifiers: mods)
    }

    /// Extrae el sufijo de 6 chars del filename (después del último `_`).
    /// Es el ID estable que se usa para anclar entre runs.
    func extractId(from url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        if let u = stem.lastIndex(of: "_") {
            return String(stem[stem.index(after: u)...])
        }
        return stem
    }

    /// Corre Vision para extraer texto en background. Guarda el resultado como
    /// sidecar `<file>.ocr.txt` y refresca el menú al completar.
    func runOCRIfEnabled(imagePath: URL, nsImage: NSImage) {
        guard Settings.enableOCR else { return }
        guard let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let req = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                let combined = lines.joined(separator: "\n")
                guard !combined.isEmpty else { return }
                let sidecar = imagePath.deletingPathExtension().appendingPathExtension("ocr.txt")
                try? combined.data(using: .utf8)?.write(to: sidecar, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar.path)
                DispatchQueue.main.async { self?.rebuildMenu() }
            }
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            req.recognitionLanguages = ["es-ES", "en-US"]
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            try? handler.perform([req])
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        // No-op por ahora — el rebuildMenu se hace al cambiar estado de pin/OCR.
    }

    @objc func openHistoryFolder() {
        NSWorkspace.shared.open(storeDir)
    }

    @objc func openTextHistoryFolder() {
        NSWorkspace.shared.open(textStoreDir)
    }

    @objc func copyTextHistoryItem(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx >= 0 && idx < textHistory.count else { return }
        guard let text = textHistory[idx].content else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastChangeCount = pb.changeCount
        flashStatusIcon(symbol: "checkmark.circle.fill")
    }

    @objc func clearHistory() {
        let counts = countHistoryOnDisk()
        let textCounts = countTextOnDisk()
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(
            "alert.clear_history.title",
            comment: "Title of the clear-history confirmation alert."
        )
        let bodyFormat = NSLocalizedString(
            "alert.clear_history.body.format",
            comment: "Clear-history alert body. Captures totals: %1$d total / %2$d recent / %3$d old. Text totals: %4$d / %5$d / %6$d."
        )
        alert.informativeText = String(format: bodyFormat,
                                         counts.total, counts.recent, counts.old,
                                         textCounts.total, textCounts.recent, textCounts.old)
        alert.addButton(withTitle: NSLocalizedString(
            "alert.clear_history.button.delete_all",
            comment: "Destructive primary button in the clear-history alert; deletes every capture."
        ))
        alert.addButton(withTitle: NSLocalizedString(
            "alert.clear_history.button.delete_old",
            comment: "Secondary button in the clear-history alert; deletes only captures older than 30 days."
        ))
        alert.addButton(withTitle: NSLocalizedString(
            "alert.clear_history.button.cancel",
            comment: "Cancel button in the clear-history alert."
        ))
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            deleteAllHistory()
            deleteAllText()
        case .alertSecondButtonReturn:
            deleteHistoryOlderThan(days: 30)
            deleteTextOlderThan(days: 30)
        default:
            return
        }
        loadHistory()
        loadTextHistory()
        rebuildMenu()
    }

    private func countTextOnDisk() -> (total: Int, recent: Int, old: Int) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: textStoreDir,
                                               includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey],
                                               options: [.skipsHiddenFiles]) else {
            return (0, 0, 0)
        }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        var total = 0, recent = 0, old = 0
        for case let url as URL in enumerator {
            let vals = try? url.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey])
            guard vals?.isRegularFile == true, url.pathExtension.lowercased() == "txt" else { continue }
            total += 1
            let date = vals?.creationDate ?? Date.distantPast
            if date >= cutoff { recent += 1 } else { old += 1 }
        }
        return (total, recent, old)
    }

    private func deleteAllText() {
        let fm = FileManager.default
        let expected = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ClipShot/text")
        guard textStoreDir.standardizedFileURL == expected?.standardizedFileURL else {
            clog("Refused deleteAllText: unexpected textStoreDir \(textStoreDir.path)")
            return
        }
        if let entries = try? fm.contentsOfDirectory(at: textStoreDir, includingPropertiesForKeys: nil) {
            for e in entries { try? fm.removeItem(at: e) }
        }
        textHistory.removeAll()
    }

    private func deleteTextOlderThan(days: Int) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        guard let enumerator = fm.enumerator(at: textStoreDir,
                                               includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey],
                                               options: [.skipsHiddenFiles]) else { return }
        var emptiedDirs: [URL] = []
        for case let url as URL in enumerator {
            let vals = try? url.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey])
            guard vals?.isRegularFile == true, url.pathExtension.lowercased() == "txt" else { continue }
            let date = vals?.creationDate ?? Date.distantPast
            if date < cutoff {
                try? fm.removeItem(at: url)
            }
        }
        if let monthDirs = try? fm.contentsOfDirectory(at: textStoreDir, includingPropertiesForKeys: nil) {
            for dir in monthDirs {
                var isDir: ObjCBool = false
                fm.fileExists(atPath: dir.path, isDirectory: &isDir)
                if isDir.boolValue,
                   let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
                   contents.isEmpty {
                    emptiedDirs.append(dir)
                }
            }
        }
        for d in emptiedDirs { try? fm.removeItem(at: d) }
    }

    private func countHistoryOnDisk() -> (total: Int, recent: Int, old: Int) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: storeDir,
                                               includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey],
                                               options: [.skipsHiddenFiles]) else {
            return (0, 0, 0)
        }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        var total = 0, recent = 0, old = 0
        for case let url as URL in enumerator {
            let vals = try? url.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey])
            guard vals?.isRegularFile == true, url.pathExtension.lowercased() == "png" else { continue }
            total += 1
            let date = vals?.creationDate ?? Date.distantPast
            if date >= cutoff { recent += 1 } else { old += 1 }
        }
        return (total, recent, old)
    }

    private func deleteAllHistory() {
        let fm = FileManager.default
        // Defense in depth: only delete if storeDir is exactly our known path.
        let expected = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ClipShot/history")
        guard storeDir.standardizedFileURL == expected?.standardizedFileURL else {
            clog("Refused deleteAllHistory: unexpected storeDir \(storeDir.path)")
            return
        }
        if let entries = try? fm.contentsOfDirectory(at: storeDir, includingPropertiesForKeys: nil) {
            for e in entries {
                try? fm.removeItem(at: e)
            }
        }
        history.removeAll()
    }

    private func deleteHistoryOlderThan(days: Int) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        guard let enumerator = fm.enumerator(at: storeDir,
                                               includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey],
                                               options: [.skipsHiddenFiles]) else { return }
        var emptiedDirs: [URL] = []
        for case let url as URL in enumerator {
            let vals = try? url.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey])
            guard vals?.isRegularFile == true, url.pathExtension.lowercased() == "png" else { continue }
            let date = vals?.creationDate ?? Date.distantPast
            if date < cutoff {
                try? fm.removeItem(at: url)
            }
        }
        // Clean up empty subfolders (months with no remaining captures).
        if let monthDirs = try? fm.contentsOfDirectory(at: storeDir, includingPropertiesForKeys: nil) {
            for dir in monthDirs {
                var isDir: ObjCBool = false
                fm.fileExists(atPath: dir.path, isDirectory: &isDir)
                if isDir.boolValue,
                   let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
                   contents.isEmpty {
                    emptiedDirs.append(dir)
                }
            }
        }
        for d in emptiedDirs { try? fm.removeItem(at: d) }
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(
            "about.title",
            comment: "Title of the About ClipShot alert; includes the version number."
        )
        let bodyFormat = NSLocalizedString(
            "about.body.format",
            comment: "Body of the About alert. %1$@ is the screenshots-folder path, %2$@ is the saved-history folder path."
        )
        alert.informativeText = String(format: bodyFormat, screenshotLocation.path, storeDir.path)
        alert.runModal()
    }

    func startPasteboardMonitor() {
        lastChangeCount = NSPasteboard.general.changeCount
        // 2.0s per Mac App Store App Review guidance — clipboard polling at a
        // sub-second cadence raises energy-impact concerns. Documented in App
        // Review Notes. We still catch Cmd-Shift-Ctrl-3/4 screenshots; the
        // user just won't see them in history for up to 2s, which is fine.
        pbTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
    }

    // Image cap: ~100M pixels (10000x10000). Anything bigger could OOM the menubar.
    static let maxPixelArea: Int = 100_000_000
    static let maxPixelDimension: CGFloat = 16384

    private func imageIsWithinSafeBounds(_ image: NSImage) -> Bool {
        let w = image.size.width
        let h = image.size.height
        guard w > 0, h > 0 else { return false }
        guard w <= AppDelegate.maxPixelDimension, h <= AppDelegate.maxPixelDimension else { return false }
        let area = Int(w * h)
        return area <= AppDelegate.maxPixelArea
    }

    // Conservative cap so a giant clipboard payload can't fill the user's disk
    // (e.g. someone copies an entire log file).
    static let maxTextBytes: Int = 200_000

    func checkPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard let types = pb.types else { return }

        if types.contains(.tiff) || types.contains(.png) {
            guard let img = NSImage(pasteboard: pb) else { return }
            guard imageIsWithinSafeBounds(img) else {
                clog("Pasteboard image too large; ignoring: \(Int(img.size.width))x\(Int(img.size.height))")
                return
            }
            saveScreenshot(image: img, showOverlay: true)
            return
        }

        guard Settings.saveTextHistory else { return }

        // Apps explícitamente excluidas (password managers, banca, etc.).
        if let frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           Settings.excludedAppBundleIds.contains(frontApp) {
            return
        }

        // Respect the nspasteboard.com convention: password managers and other
        // apps tag sensitive content with these types so clipboard managers can
        // skip it. We honor all three (concealed / auto-generated / transient).
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let autoGen = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        if types.contains(concealed) || types.contains(autoGen) || types.contains(transient) {
            return
        }

        guard types.contains(.string) else { return }
        guard let str = pb.string(forType: .string) else { return }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        let byteCount = trimmed.lengthOfBytes(using: .utf8)
        guard byteCount > 0, byteCount <= AppDelegate.maxTextBytes else { return }
        // Skip immediate duplicate of the most recent entry.
        if let last = textHistory.first, last.content == trimmed { return }

        saveText(trimmed)
    }

    func saveText(_ text: String) {
        let now = Date()
        let id = UUID().uuidString

        // INTENTIONALLY NOT LOCALIZED — on-disk artifacts. Same reasoning as
        // saveScreenshot: filenames and month folder names live on disk and
        // must stay stable regardless of UI language.
        let monthFmt = DateFormatter()
        monthFmt.locale = Locale(identifier: "es_ES")
        monthFmt.dateFormat = "MMMM yyyy"
        var monthName = monthFmt.string(from: now)
        monthName = monthName.prefix(1).uppercased() + monthName.dropFirst()
        let monthDir = textStoreDir.appendingPathComponent(monthName)
        try? FileManager.default.createDirectory(at: monthDir, withIntermediateDirectories: true)

        let nameFmt = DateFormatter()
        nameFmt.locale = Locale(identifier: "es_ES")
        nameFmt.dateFormat = "yyyy-MM-dd 'a las' HH-mm-ss"
        let filename = "Texto \(nameFmt.string(from: now))_\(id.prefix(6)).txt"
        let url = monthDir.appendingPathComponent(filename)

        guard let data = text.data(using: .utf8) else { return }
        do {
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            clog("Failed to save text to \(url.path): \(error)")
            return
        }
        let item = TextItem(id: String(id.prefix(6)), date: now, textPath: url)
        textHistory.insert(item, at: 0)
        pruneTextHistory()
        rebuildMenu()
        flashStatusIcon(symbol: "doc.on.clipboard.fill")
    }

    private func pruneTextHistory() {
        var unpinnedCount = textHistory.filter { !$0.isPinned }.count
        var idx = textHistory.count - 1
        while unpinnedCount > maxTextHistory && idx >= 0 {
            if !textHistory[idx].isPinned {
                let removed = textHistory.remove(at: idx)
                try? FileManager.default.removeItem(at: removed.textPath)
                unpinnedCount -= 1
            }
            idx -= 1
        }
    }

    func loadTextHistory() {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: textStoreDir,
                                               includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey, .isSymbolicLinkKey],
                                               options: [.skipsHiddenFiles]) else {
            textHistory = []
            return
        }
        var txts: [URL] = []
        for case let url as URL in enumerator {
            let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard v?.isRegularFile == true, v?.isSymbolicLink != true else { continue }
            guard url.pathExtension.lowercased() == "txt" else { continue }
            txts.append(url)
        }
        let sorted = txts.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            return da > db
        }
        var loaded: [TextItem] = []
        var unpinnedTaken = 0
        for url in sorted {
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let id = extractId(from: url)
            let item = TextItem(id: id, date: date, textPath: url)
            if item.isPinned {
                loaded.append(item)
            } else if unpinnedTaken < maxTextHistory {
                loaded.append(item)
                unpinnedTaken += 1
            }
        }
        textHistory = loaded
    }

    // MARK: Folder watching (sandbox-safe, no Timer fallback)

    func startFolderMonitor() {
        // DispatchSource.makeFileSystemObjectSource is sandbox-compatible
        // PROVIDED the file descriptor was opened on a URL we have access
        // to — either via security-scoped bookmark or via an entitlement.
        // Per the App Store plan, we rely exclusively on a user-selected
        // security-scoped bookmark, so this works as long as that bookmark
        // exists. If no bookmark is present we silently skip watching;
        // saveScreenshot still works via the pasteboard path.
        installFolderDispatchSource()
    }

    private var folderFD: Int32 = -1
    private var folderSource: DispatchSourceFileSystemObject?

    private func installFolderDispatchSource() {
        teardownFolderDispatchSource()
        let path = screenshotLocation.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // Under sandbox this is the expected path until the user grants
            // access via the welcome flow's NSOpenPanel. Do NOT fall back to
            // Timer polling — polling a sandbox-blocked path just burns
            // energy with no events. The user will be walked through the
            // open panel on first launch.
            clog("Folder open(O_EVTONLY) failed for \(path) — likely no security-scoped access yet. Skipping watcher.")
            return
        }
        folderFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            self?.checkScreenshotFolder()
        }
        src.setCancelHandler { [weak self] in
            if let f = self?.folderFD, f >= 0 { close(f) }
            self?.folderFD = -1
        }
        src.resume()
        folderSource = src
        // Initial scan.
        checkScreenshotFolder()
    }

    private func teardownFolderDispatchSource() {
        folderSource?.cancel()
        folderSource = nil
    }

    func checkScreenshotFolder() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: screenshotLocation,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let exts = ["png", "jpg", "jpeg", "tiff"]
        for url in urls {
            let name = url.lastPathComponent
            guard !processedFiles.contains(name) else { continue }
            // Reject symlinks: they can point outside $HOME and exfiltrate content.
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .fileSizeKey])
            guard vals?.isSymbolicLink != true, vals?.isRegularFile == true else {
                processedFiles.insert(name)
                continue
            }
            guard exts.contains(url.pathExtension.lowercased()) else {
                processedFiles.insert(name)
                continue
            }
            guard screenshotPrefixes.contains(where: { name.hasPrefix($0) }) else {
                processedFiles.insert(name)
                continue
            }
            guard let size = vals?.fileSize, size > 1024 else { continue }
            let creationDate = vals?.creationDate ?? Date.distantPast
            let isRecent = Date().timeIntervalSince(creationDate) < 10
            let mdItem = NSMetadataItem(url: url)
            let isMDScreenshot = (mdItem?.value(forAttribute: "kMDItemIsScreenCapture") as? Bool) ?? false
            guard isRecent || isMDScreenshot else {
                processedFiles.insert(name)
                continue
            }
            guard let img = NSImage(contentsOf: url), imageIsWithinSafeBounds(img) else {
                if let img = NSImage(contentsOf: url) {
                    clog("Skipping oversize screenshot \(Int(img.size.width))x\(Int(img.size.height)): \(name)")
                }
                processedFiles.insert(name)
                continue
            }
            processedFiles.insert(name)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([img])
            lastChangeCount = pb.changeCount
            saveScreenshot(image: img, showOverlay: true)
        }
    }

    func saveScreenshot(image: NSImage, showOverlay: Bool = false) {
        let now = Date()
        let id = UUID().uuidString

        // INTENTIONALLY NOT LOCALIZED — on-disk artifacts.
        //
        // The month folder name (e.g. "Enero 2026") and the saved file name
        // (e.g. "Captura 2026-05-23 a las 14-30-12_a1b2c3.png") are written to
        // the user's filesystem. We deliberately keep them in Spanish forever,
        // even when the UI language is English or French, because:
        //
        //   - Filenames are not UI. Users may keep these files for years and
        //     browse them in Finder long after changing their system language.
        //   - Stable names are easier to share, search, and reference in
        //     scripts / shell.
        //   - A folder that contains a mix of "Captura …", "Screenshot …" and
        //     "Capture …" because the user toggled languages would be a mess.
        //
        // The es_ES locale is therefore hard-coded here on purpose. Do NOT
        // replace with Locale.current.
        let monthFmt = DateFormatter()
        monthFmt.locale = Locale(identifier: "es_ES")
        monthFmt.dateFormat = "MMMM yyyy"
        var monthName = monthFmt.string(from: now)
        monthName = monthName.prefix(1).uppercased() + monthName.dropFirst()
        let monthDir = storeDir.appendingPathComponent(monthName)
        try? FileManager.default.createDirectory(at: monthDir, withIntermediateDirectories: true)

        let nameFmt = DateFormatter()
        nameFmt.locale = Locale(identifier: "es_ES")
        nameFmt.dateFormat = "yyyy-MM-dd 'a las' HH-mm-ss"
        let filename = "Captura \(nameFmt.string(from: now))_\(id.prefix(6)).png"
        let url = monthDir.appendingPathComponent(filename)

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            clog("Failed to encode screenshot for saving")
            return
        }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            clog("Failed to save screenshot to \(url.path): \(error)")
            return
        }
        let item = HistoryItem(id: String(id.prefix(6)), date: Date(), imagePath: url)
        history.insert(item, at: 0)
        pruneHistory()
        rebuildMenu()
        flashStatusIcon(symbol: "camera.fill")
        if showOverlay && Settings.showOverlay {
            overlay.show(image: image, fileURL: url)
        }
        runOCRIfEnabled(imagePath: url, nsImage: image)
    }

    private func pruneHistory() {
        var unpinnedCount = history.filter { !$0.isPinned }.count
        var idx = history.count - 1
        while unpinnedCount > maxHistory && idx >= 0 {
            if !history[idx].isPinned {
                let removed = history.remove(at: idx)
                try? FileManager.default.removeItem(at: removed.imagePath)
                let sidecar = removed.imagePath.deletingPathExtension().appendingPathExtension("ocr.txt")
                try? FileManager.default.removeItem(at: sidecar)
                unpinnedCount -= 1
            }
            idx -= 1
        }
    }

    func loadHistory() {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: storeDir,
                                               includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey, .isSymbolicLinkKey],
                                               options: [.skipsHiddenFiles]) else {
            history = []
            return
        }
        var pngs: [URL] = []
        for case let url as URL in enumerator {
            let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard v?.isRegularFile == true, v?.isSymbolicLink != true else { continue }
            guard url.pathExtension.lowercased() == "png" else { continue }
            pngs.append(url)
        }
        let sorted = pngs.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            return da > db
        }
        var loaded: [HistoryItem] = []
        var unpinnedTaken = 0
        for url in sorted {
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let id = extractId(from: url)
            let item = HistoryItem(id: id, date: date, imagePath: url)
            if item.isPinned {
                loaded.append(item)
            } else if unpinnedTaken < maxHistory {
                loaded.append(item)
                unpinnedTaken += 1
            }
        }
        history = loaded
    }
}

// MARK: - StoreKit 2 (In-App Purchase para ClipShot Pro)
//
// API moderna de StoreKit 2 (macOS 12+). No requiere callbacks ni delegates —
// todo es async/await. Maneja: fetch del producto desde App Store Connect,
// purchase, restore, transaction listener para revocar entitlement si Apple
// detecta refund.
@available(macOS 12.0, *)
final class PurchaseManager {
    static let shared = PurchaseManager()

    private(set) var product: Product?
    private var updatesTask: Task<Void, Never>?

    /// Arranca el listener de transacciones en background. Llamar en
    /// applicationDidFinishLaunching.
    func start() {
        updatesTask = Task.detached { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update {
                    await self?.handleTransaction(transaction)
                    await transaction.finish()
                }
            }
        }
        Task { await refreshProduct() }
        Task { await syncEntitlements() }
    }

    deinit { updatesTask?.cancel() }

    func refreshProduct() async {
        do {
            let products = try await Product.products(for: [Settings.proProductID])
            self.product = products.first
        } catch {
            clog("StoreKit: error fetching product: \(error)")
        }
    }

    /// Dispara la compra. Devuelve true si fue exitosa.
    @discardableResult
    func purchase() async -> Bool {
        guard let product = self.product else { return false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await handleTransaction(transaction)
                    await transaction.finish()
                    return true
                }
                return false
            case .userCancelled, .pending:
                return false
            @unknown default:
                return false
            }
        } catch {
            clog("StoreKit purchase error: \(error)")
            return false
        }
    }

    /// Restaura compras (caso de re-instalación o cambio de Mac).
    func restore() async {
        try? await AppStore.sync()
        await syncEntitlements()
    }

    /// Sincroniza el flag isPro contra currentEntitlements. Si el user ya compró
    /// (en este Mac o en otro con el mismo Apple ID), marca isPro=true.
    func syncEntitlements() async {
        var hasPro = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Settings.proProductID,
               transaction.revocationDate == nil {
                hasPro = true
            }
        }
        await MainActor.run {
            Settings.isPro = hasPro
            NotificationCenter.default.post(name: .clipShotProStatusChanged, object: nil)
        }
    }

    private func handleTransaction(_ transaction: Transaction) async {
        guard transaction.productID == Settings.proProductID else { return }
        await MainActor.run {
            Settings.isPro = transaction.revocationDate == nil
            NotificationCenter.default.post(name: .clipShotProStatusChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let clipShotProStatusChanged = Notification.Name("clipshot.proStatusChanged")
}

// MARK: - Paywall Window (App Store version)
@available(macOS 12.0, *)
final class PaywallWindowController: NSWindowController {
    static func presentModal() {
        let wc = PaywallWindowController()
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    convenience init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "ClipShot Pro"
        w.center()
        self.init(window: w)
        buildContent()
        // Refresh price cuando el producto carga
        Task { @MainActor in
            await PurchaseManager.shared.refreshProduct()
            self.refreshPriceLabel()
        }
    }

    private var priceLabel: NSTextField?
    private var statusLabel: NSTextField?

    private func buildContent() {
        guard let cv = window?.contentView else { return }
        cv.wantsLayer = true

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 48, weight: .regular)
        icon.contentTintColor = .systemBlue
        icon.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(icon)

        let title = NSTextField(labelWithString: "ClipShot Pro")
        title.font = .systemFont(ofSize: 28, weight: .bold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(title)

        let subtitle = NSTextField(labelWithString: NSLocalizedString("paywall.subtitle",
                                                                        comment: "Paywall subtitle"))
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(subtitle)

        let features = makeFeatureList()
        features.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(features)

        let p = NSTextField(labelWithString: "—")
        p.font = .systemFont(ofSize: 13, weight: .semibold)
        p.alignment = .center
        p.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(p)
        self.priceLabel = p

        let buyButton = NSButton(title: NSLocalizedString("paywall.button.buy",
                                                            comment: "Buy button"),
                                  target: self, action: #selector(buyPro))
        buyButton.bezelStyle = .rounded
        buyButton.keyEquivalent = "\r"
        buyButton.controlSize = .large
        buyButton.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(buyButton)

        let restoreButton = NSButton(title: NSLocalizedString("paywall.button.restore",
                                                                 comment: "Restore purchases button"),
                                       target: self, action: #selector(restoreProAction))
        restoreButton.bezelStyle = .accessoryBarAction
        restoreButton.isBordered = false
        restoreButton.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(restoreButton)

        let s = NSTextField(labelWithString: "")
        s.font = .systemFont(ofSize: 11)
        s.textColor = .tertiaryLabelColor
        s.alignment = .center
        s.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(s)
        self.statusLabel = s

        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: cv.topAnchor, constant: 24),
            icon.centerXAnchor.constraint(equalTo: cv.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),
            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 8),
            title.centerXAnchor.constraint(equalTo: cv.centerXAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 24),
            subtitle.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -24),
            features.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 20),
            features.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 40),
            features.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -40),
            p.topAnchor.constraint(equalTo: features.bottomAnchor, constant: 16),
            p.centerXAnchor.constraint(equalTo: cv.centerXAnchor),
            buyButton.topAnchor.constraint(equalTo: p.bottomAnchor, constant: 12),
            buyButton.centerXAnchor.constraint(equalTo: cv.centerXAnchor),
            buyButton.widthAnchor.constraint(equalToConstant: 220),
            restoreButton.topAnchor.constraint(equalTo: buyButton.bottomAnchor, constant: 8),
            restoreButton.centerXAnchor.constraint(equalTo: cv.centerXAnchor),
            s.topAnchor.constraint(equalTo: restoreButton.bottomAnchor, constant: 4),
            s.centerXAnchor.constraint(equalTo: cv.centerXAnchor),
            s.bottomAnchor.constraint(lessThanOrEqualTo: cv.bottomAnchor, constant: -16),
        ])
    }

    private func makeFeatureList() -> NSStackView {
        let items: [(String, String)] = [
            ("doc.text.viewfinder",
             NSLocalizedString("paywall.feature.ocr", comment: "Paywall feature OCR")),
            ("infinity",
             NSLocalizedString("paywall.feature.unlimited", comment: "Paywall feature unlimited history")),
            ("eyedropper",
             NSLocalizedString("paywall.feature.color_picker", comment: "Paywall feature color picker")),
            ("heart.fill",
             NSLocalizedString("paywall.feature.support", comment: "Paywall feature supports dev")),
        ]
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        for (sym, text) in items {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            let img = NSImageView()
            img.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
            img.symbolConfiguration = .init(pointSize: 16, weight: .medium)
            img.contentTintColor = .systemBlue
            img.translatesAutoresizingMaskIntoConstraints = false
            img.widthAnchor.constraint(equalToConstant: 22).isActive = true
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 13)
            row.addArrangedSubview(img)
            row.addArrangedSubview(label)
            stack.addArrangedSubview(row)
        }
        return stack
    }

    private func refreshPriceLabel() {
        guard let product = PurchaseManager.shared.product else {
            priceLabel?.stringValue = NSLocalizedString("paywall.price.unavailable",
                                                          comment: "When product is not yet loaded")
            return
        }
        let priceFormat = NSLocalizedString("paywall.price.format",
                                              comment: "Pro one-time pricing format with %@ = displayPrice")
        priceLabel?.stringValue = String(format: priceFormat, product.displayPrice)
    }

    @objc private func buyPro() {
        statusLabel?.stringValue = NSLocalizedString("paywall.status.purchasing",
                                                       comment: "Status: purchasing")
        Task { @MainActor in
            let ok = await PurchaseManager.shared.purchase()
            if ok {
                statusLabel?.stringValue = NSLocalizedString("paywall.status.success",
                                                               comment: "Status: success")
                window?.close()
            } else {
                statusLabel?.stringValue = NSLocalizedString("paywall.status.cancelled",
                                                               comment: "Status: cancelled")
            }
        }
    }

    @objc private func restoreProAction() {
        statusLabel?.stringValue = NSLocalizedString("paywall.status.restoring",
                                                       comment: "Status: restoring purchases")
        Task { @MainActor in
            await PurchaseManager.shared.restore()
            if Settings.isPro {
                statusLabel?.stringValue = NSLocalizedString("paywall.status.restored",
                                                               comment: "Status: restored")
                window?.close()
            } else {
                statusLabel?.stringValue = NSLocalizedString("paywall.status.no_purchase",
                                                               comment: "Status: no purchase found")
            }
        }
    }
}

// MARK: - Global Hotkey (Carbon)
final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let onTrigger: () -> Void
    private static var instances: [UInt32: GlobalHotkey] = [:]
    private static var nextID: UInt32 = 1

    init(onTrigger: @escaping () -> Void) { self.onTrigger = onTrigger }

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()
        let id = GlobalHotkey.nextID
        GlobalHotkey.nextID += 1
        GlobalHotkey.instances[id] = self
        let hotKeyID = EventHotKeyID(signature: OSType(0x434C5350), id: id)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        hotKeyRef = ref
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                   eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),
                              { (_, event, _) -> OSStatus in
            var receivedID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                EventParamType(typeEventHotKeyID), nil,
                                MemoryLayout<EventHotKeyID>.size, nil, &receivedID)
            if let inst = GlobalHotkey.instances[receivedID.id] { inst.onTrigger() }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let h = eventHandler { RemoveEventHandler(h); eventHandler = nil }
    }
    deinit { unregister() }
}

// MARK: - History Browser

final class HistoryBrowserWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    weak var ownerDelegate: AppDelegate?
    private var searchField: NSSearchField!
    private var tableView: NSTableView!
    private var allEntries: [AppDelegate.MergedEntry] = []
    private var filteredEntries: [AppDelegate.MergedEntry] = []

    init(owner: AppDelegate) {
        self.ownerDelegate = owner
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        w.title = NSLocalizedString("browser.window.title", comment: "Search-in-history window title")
        w.minSize = NSSize(width: 380, height: 360)
        w.center()
        super.init(window: w)
        w.delegate = self
        setupUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        guard let cv = window?.contentView else { return }
        searchField = NSSearchField()
        searchField.placeholderString = NSLocalizedString("browser.search.placeholder",
                                                            comment: "Placeholder of the search field in the history browser.")
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        cv.addSubview(searchField)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(scroll)

        tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 72
        tableView.headerView = nil
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.style = .inset
        tableView.allowsMultipleSelection = false
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        col.resizingMask = [.autoresizingMask]
        col.width = 500
        tableView.addTableColumn(col)
        scroll.documentView = tableView

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: cv.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
        ])
    }

    func reloadFromOwner() {
        allEntries = ownerDelegate?.allMergedEntries() ?? []
        applyFilter()
    }

    private func applyFilter() {
        let q = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            filteredEntries = allEntries
        } else {
            filteredEntries = allEntries.filter { entry in
                let dateStr = ownerDelegate?.formatDate(entry.date).lowercased() ?? ""
                if dateStr.contains(q) { return true }
                switch entry {
                case .image(_, let h): return (h.ocrText?.lowercased().contains(q)) ?? false
                case .text(_, let t): return (t.content?.lowercased().contains(q)) ?? false
                }
            }
        }
        tableView.reloadData()
        if !filteredEntries.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    func numberOfRows(in tableView: NSTableView) -> Int { filteredEntries.count }
    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let cell = HistoryBrowserCell()
        cell.configure(entry: filteredEntries[row], owner: ownerDelegate)
        return cell
    }

    @objc private func rowDoubleClicked() { copySelectedAndClose(textOnly: false) }

    private func copySelectedAndClose(textOnly: Bool) {
        let row = tableView.selectedRow
        guard row >= 0 && row < filteredEntries.count else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        switch filteredEntries[row] {
        case .image(_, let h):
            if textOnly, let ocr = h.ocrText { pb.setString(ocr, forType: .string) }
            else if let img = h.image { pb.writeObjects([img]) }
        case .text(_, let t):
            if let text = t.content { pb.setString(text, forType: .string) }
        }
        ownerDelegate?.lastChangeCount = pb.changeCount
        window?.close()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        window?.makeFirstResponder(searchField)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: +1); return true
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1); return true
        case #selector(NSResponder.insertNewline(_:)): copySelectedAndClose(textOnly: false); return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)): copySelectedAndClose(textOnly: true); return true
        case #selector(NSResponder.cancelOperation(_:)): window?.close(); return true
        default: return false
        }
    }

    private func moveSelection(by delta: Int) {
        guard !filteredEntries.isEmpty else { return }
        var next = tableView.selectedRow + delta
        next = max(0, min(filteredEntries.count - 1, next))
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }
}

extension HistoryBrowserWindowController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self; panel.delegate = self
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil; panel.delegate = nil
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        let row = tableView?.selectedRow ?? -1
        return (row >= 0 && row < filteredEntries.count) ? 1 : 0
    }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let row = tableView.selectedRow
        guard row >= 0 && row < filteredEntries.count else { return nil }
        switch filteredEntries[row] {
        case .image(_, let h): return h.imagePath as NSURL
        case .text(_, let t): return t.textPath as NSURL
        }
    }
}

final class HistoryBrowserCell: NSTableCellView {
    private let preview = NSImageView()
    private let dateLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private let pinIndicator = NSImageView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 500, height: 72))
        preview.imageScaling = .scaleProportionallyDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 4
        addSubview(preview); addSubview(dateLabel); addSubview(bodyLabel); addSubview(pinIndicator)
        preview.translatesAutoresizingMaskIntoConstraints = false
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        pinIndicator.translatesAutoresizingMaskIntoConstraints = false
        dateLabel.font = .systemFont(ofSize: 13, weight: .medium)
        bodyLabel.font = .systemFont(ofSize: 11)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.maximumNumberOfLines = 2
        bodyLabel.lineBreakMode = .byTruncatingTail
        pinIndicator.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)
        pinIndicator.contentTintColor = .systemBlue
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            preview.centerYAnchor.constraint(equalTo: centerYAnchor),
            preview.widthAnchor.constraint(equalToConstant: 88),
            preview.heightAnchor.constraint(equalToConstant: 56),
            dateLabel.leadingAnchor.constraint(equalTo: preview.trailingAnchor, constant: 12),
            dateLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            dateLabel.trailingAnchor.constraint(equalTo: pinIndicator.leadingAnchor, constant: -8),
            bodyLabel.leadingAnchor.constraint(equalTo: dateLabel.leadingAnchor),
            bodyLabel.topAnchor.constraint(equalTo: dateLabel.bottomAnchor, constant: 4),
            bodyLabel.trailingAnchor.constraint(equalTo: dateLabel.trailingAnchor),
            bodyLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            pinIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            pinIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinIndicator.widthAnchor.constraint(equalToConstant: 14),
            pinIndicator.heightAnchor.constraint(equalToConstant: 14),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(entry: AppDelegate.MergedEntry, owner: AppDelegate?) {
        dateLabel.stringValue = owner?.formatDate(entry.date) ?? ""
        pinIndicator.isHidden = !entry.isPinned
        switch entry {
        case .image(_, let h):
            if let img = h.image {
                preview.image = owner?.thumbnail(from: img, maxSize: NSSize(width: 88, height: 56))
            }
            bodyLabel.stringValue = NSLocalizedString("browser.row.image_label", comment: "Row label for an image entry")
        case .text(_, let t):
            let content = t.content ?? ""
            bodyLabel.stringValue = content.replacingOccurrences(of: "\n", with: " ")
                                            .replacingOccurrences(of: "\t", with: " ")
            preview.image = owner?.textCard(preview: owner?.textPreview(content, limit: 80) ?? "",
                                              size: NSSize(width: 88, height: 56))
        }
    }
}

// MARK: - Color Picker

final class ColorPickerWindowController: NSWindowController, NSWindowDelegate {
    private let imageURL: URL
    private var imageView: ZoomableImageView!
    private var swatch: NSView!
    private var hexLabel: NSTextField!
    private var rgbLabel: NSTextField!
    private var hslLabel: NSTextField!

    init(imageURL: URL) {
        self.imageURL = imageURL
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        w.title = NSLocalizedString("colorpicker.window.title", comment: "Color picker window title")
        w.center()
        super.init(window: w)
        w.delegate = self
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let cv = window?.contentView else { return }
        imageView = ZoomableImageView(frame: .zero)
        imageView.image = NSImage(contentsOf: imageURL)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.onPixelHover = { [weak self] color in self?.updateSwatch(color: color) }
        imageView.onPixelClick = { [weak self] color in self?.copyHex(color: color) }
        imageView.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(imageView)
        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        panel.layer?.cornerRadius = 8
        panel.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(panel)
        swatch = NSView()
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 6
        swatch.layer?.borderWidth = 1
        swatch.layer?.borderColor = NSColor.separatorColor.cgColor
        swatch.layer?.backgroundColor = NSColor.gray.cgColor
        swatch.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(swatch)
        hexLabel = NSTextField(labelWithString: NSLocalizedString("colorpicker.hint.hover",
                                                                     comment: "Hint shown before user hovers a pixel"))
        hexLabel.font = .monospacedSystemFont(ofSize: 16, weight: .bold)
        hexLabel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(hexLabel)
        rgbLabel = NSTextField(labelWithString: "")
        rgbLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        rgbLabel.textColor = .secondaryLabelColor
        rgbLabel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(rgbLabel)
        hslLabel = NSTextField(labelWithString: "")
        hslLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        hslLabel.textColor = .secondaryLabelColor
        hslLabel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(hslLabel)
        let hint = NSTextField(labelWithString: NSLocalizedString("colorpicker.hint.click",
                                                                    comment: "Hint that clicking copies hex"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(hint)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: cv.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: panel.topAnchor, constant: -8),
            panel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 12),
            panel.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -12),
            panel.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -12),
            panel.heightAnchor.constraint(equalToConstant: 80),
            swatch.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            swatch.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 52),
            swatch.heightAnchor.constraint(equalToConstant: 52),
            hexLabel.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: 14),
            hexLabel.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
            rgbLabel.leadingAnchor.constraint(equalTo: hexLabel.leadingAnchor),
            rgbLabel.topAnchor.constraint(equalTo: hexLabel.bottomAnchor, constant: 4),
            hslLabel.leadingAnchor.constraint(equalTo: hexLabel.leadingAnchor),
            hslLabel.topAnchor.constraint(equalTo: rgbLabel.bottomAnchor, constant: 2),
            hint.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            hint.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
        ])
    }

    private func updateSwatch(color: NSColor) {
        swatch.layer?.backgroundColor = color.cgColor
        let r = Int(round(color.redComponent * 255))
        let g = Int(round(color.greenComponent * 255))
        let b = Int(round(color.blueComponent * 255))
        hexLabel.stringValue = String(format: "#%02X%02X%02X", r, g, b)
        rgbLabel.stringValue = "RGB(\(r), \(g), \(b))"
        let (h, s, l) = rgbToHsl(r: color.redComponent, g: color.greenComponent, b: color.blueComponent)
        hslLabel.stringValue = String(format: "HSL(%.0f°, %.0f%%, %.0f%%)", h * 360, s * 100, l * 100)
    }

    private func copyHex(color: NSColor) {
        let r = Int(round(color.redComponent * 255))
        let g = Int(round(color.greenComponent * 255))
        let b = Int(round(color.blueComponent * 255))
        let hex = String(format: "#%02X%02X%02X", r, g, b)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(hex, forType: .string)
        swatch.layer?.borderColor = NSColor.systemBlue.cgColor
        swatch.layer?.borderWidth = 3
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.swatch.layer?.borderColor = NSColor.separatorColor.cgColor
            self?.swatch.layer?.borderWidth = 1
        }
    }

    private func rgbToHsl(r: CGFloat, g: CGFloat, b: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        if mx == mn { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: CGFloat
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) }
        else if mx == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        h /= 6
        return (h, s, l)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

final class ZoomableImageView: NSImageView {
    var onPixelHover: ((NSColor) -> Void)?
    var onPixelClick: ((NSColor) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let area = NSTrackingArea(rect: bounds,
                                    options: [.mouseMoved, .mouseEnteredAndExited,
                                              .activeInKeyWindow, .inVisibleRect],
                                    owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func pixelColorAt(viewPoint: NSPoint) -> NSColor? {
        guard let image = self.image else { return nil }
        let imgSize = image.size
        guard imgSize.width > 0 && imgSize.height > 0 else { return nil }
        let viewAspect = bounds.width / bounds.height
        let imgAspect = imgSize.width / imgSize.height
        var drawRect = bounds
        if imgAspect > viewAspect {
            drawRect.size.height = bounds.width / imgAspect
            drawRect.origin.y = (bounds.height - drawRect.size.height) / 2
        } else {
            drawRect.size.width = bounds.height * imgAspect
            drawRect.origin.x = (bounds.width - drawRect.size.width) / 2
        }
        guard drawRect.contains(viewPoint) else { return nil }
        let normX = (viewPoint.x - drawRect.origin.x) / drawRect.size.width
        let normY = 1 - (viewPoint.y - drawRect.origin.y) / drawRect.size.height
        guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first
                ?? (image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }) else { return nil }
        let px = Int(normX * CGFloat(rep.pixelsWide))
        let py = Int(normY * CGFloat(rep.pixelsHigh))
        guard px >= 0 && px < rep.pixelsWide && py >= 0 && py < rep.pixelsHigh else { return nil }
        return rep.colorAt(x: px, y: py)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let color = pixelColorAt(viewPoint: p) { onPixelHover?(color) }
    }
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let color = pixelColorAt(viewPoint: p) { onPixelClick?(color) }
    }
}

// MARK: - Hotkey Recorder

final class HotkeyRecorderView: NSView {
    var onCapture: ((UInt32, UInt32) -> Void)?
    private let label = NSTextField(labelWithString: "")
    private var isRecording = false
    private var currentKey: UInt32
    private var currentMods: UInt32

    init(initialKey: UInt32, initialMods: UInt32) {
        self.currentKey = initialKey; self.currentMods = initialMods
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        label.frame = NSRect(x: 12, y: 4, width: 216, height: 20)
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.refusesFirstResponder = true
        addSubview(label)
        updateLabel()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        label.stringValue = NSLocalizedString("hotkey.recording", comment: "Recording prompt")
        label.textColor = .systemBlue
    }
    override func keyDown(with event: NSEvent) {
        guard isRecording else { return }
        if event.keyCode == 53 { isRecording = false; updateLabel(); return }
        let flags = event.modifierFlags
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        guard mods != 0 else {
            label.stringValue = NSLocalizedString("hotkey.error.needs_modifier",
                                                    comment: "Error: needs at least one modifier")
            label.textColor = .systemRed
            return
        }
        currentKey = UInt32(event.keyCode)
        currentMods = mods
        isRecording = false
        updateLabel()
        onCapture?(currentKey, currentMods)
    }

    private func updateLabel() {
        label.textColor = .labelColor
        label.stringValue = HotkeyRecorderView.describe(key: currentKey, mods: currentMods)
    }

    static func describe(key: UInt32, mods: UInt32) -> String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey) != 0 { s += "⌥" }
        if mods & UInt32(shiftKey) != 0 { s += "⇧" }
        if mods & UInt32(cmdKey) != 0 { s += "⌘" }
        s += keyName(key)
        return s
    }

    static func keyName(_ keyCode: UInt32) -> String {
        let map: [UInt32: String] = [
            0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",
            11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",
            31:"O",32:"U",34:"I",35:"P",37:"L",38:"J",40:"K",
            45:"N",46:"M",18:"1",19:"2",20:"3",21:"4",23:"5",22:"6",
            26:"7",28:"8",25:"9",29:"0",36:"⏎",49:"Espacio",51:"⌫",
            53:"⎋",123:"←",124:"→",125:"↓",126:"↑",
        ]
        return map[keyCode] ?? "?"
    }
}

final class HotkeySettingsWindowController: NSWindowController {
    weak var appDelegate: AppDelegate?

    init(owner: AppDelegate) {
        self.appDelegate = owner
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        w.title = NSLocalizedString("hotkey.window.title", comment: "Hotkey settings window title")
        w.center()
        super.init(window: w)
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let cv = window?.contentView else { return }
        let title = NSTextField(labelWithString: NSLocalizedString("hotkey.title",
                                                                     comment: "Hotkey settings title"))
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(title)
        let hint = NSTextField(labelWithString: NSLocalizedString("hotkey.hint",
                                                                    comment: "Click + press combo hint"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(hint)
        let (key, mods) = Settings.globalHotkey
        let recorder = HotkeyRecorderView(initialKey: key, initialMods: mods)
        recorder.translatesAutoresizingMaskIntoConstraints = false
        recorder.onCapture = { [weak self] key, mods in
            Settings.globalHotkey = (key, mods)
            self?.appDelegate?.globalHotkey?.unregister()
            self?.appDelegate?.registerGlobalHotkey()
        }
        cv.addSubview(recorder)
        let resetBtn = NSButton(title: NSLocalizedString("hotkey.reset_default",
                                                            comment: "Reset to default hotkey button"),
                                 target: self, action: #selector(resetDefault))
        resetBtn.bezelStyle = .accessoryBarAction
        resetBtn.isBordered = false
        resetBtn.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(resetBtn)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: cv.topAnchor, constant: 24),
            title.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            hint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            recorder.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 16),
            recorder.centerXAnchor.constraint(equalTo: cv.centerXAnchor),
            recorder.widthAnchor.constraint(equalToConstant: 240),
            recorder.heightAnchor.constraint(equalToConstant: 28),
            resetBtn.topAnchor.constraint(equalTo: recorder.bottomAnchor, constant: 12),
            resetBtn.centerXAnchor.constraint(equalTo: cv.centerXAnchor),
        ])
    }

    @objc func resetDefault() {
        Settings.globalHotkey = (UInt32(kVK_ANSI_V), UInt32(cmdKey | shiftKey))
        appDelegate?.globalHotkey?.unregister()
        appDelegate?.registerGlobalHotkey()
        window?.close()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
