import Cocoa
import QuartzCore
import ApplicationServices
import ServiceManagement

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
}

struct TextItem {
    let id: String
    let date: Date
    let textPath: URL
    var content: String? { try? String(contentsOf: textPath, encoding: .utf8) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var history: [HistoryItem] = []
    var textHistory: [TextItem] = []
    let maxHistory = 30
    let maxTextHistory = 30
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

        // Unified history list: screenshots and copied text interleaved by date,
        // newest first. Screenshots use their real thumbnail; copied text is
        // rendered into a small rounded card so the two types are visually
        // distinguishable at a glance.
        let merged = mergedHistoryEntries()
        if merged.isEmpty {
            let emptyTitle = NSLocalizedString(
                "menu.history.empty",
                comment: "Disabled placeholder shown in the menu when there is no history yet (no captures and no copied text)."
            )
            let item = NSMenuItem(title: "  " + emptyTitle, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for entry in merged {
                switch entry {
                case .image(let idx, let h):
                    let item = NSMenuItem(title: "  " + formatDate(h.date),
                                            action: #selector(copyHistoryItem(_:)), keyEquivalent: "")
                    item.target = self
                    item.tag = idx
                    if let img = h.image {
                        item.image = thumbnail(from: img, maxSize: NSSize(width: 140, height: 90))
                    }
                    menu.addItem(item)
                case .text(let idx, let t):
                    let body = textPreview(t.content ?? "", limit: 120)
                    let item = NSMenuItem(title: "  " + formatDate(t.date),
                                            action: #selector(copyTextHistoryItem(_:)), keyEquivalent: "")
                    item.target = self
                    item.tag = idx
                    item.image = textCard(preview: body, size: NSSize(width: 140, height: 90))
                    item.toolTip = t.content
                    menu.addItem(item)
                }
            }
        }

        menu.addItem(.separator())
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
    }

    func mergedHistoryEntries(limit: Int = 20) -> [MergedEntry] {
        var entries: [MergedEntry] = history.enumerated().map { .image($0.offset, $0.element) }
        if Settings.saveTextHistory {
            entries.append(contentsOf: textHistory.enumerated().map { .text($0.offset, $0.element) })
        }
        entries.sort { $0.date > $1.date }
        return Array(entries.prefix(limit))
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
        while textHistory.count > maxTextHistory {
            let removed = textHistory.removeLast()
            try? FileManager.default.removeItem(at: removed.textPath)
        }
        rebuildMenu()
        flashStatusIcon(symbol: "doc.on.clipboard.fill")
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
        textHistory = sorted.prefix(maxTextHistory).map { url in
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let id = url.deletingPathExtension().lastPathComponent
            return TextItem(id: id, date: date, textPath: url)
        }
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
        while history.count > maxHistory {
            let removed = history.removeLast()
            try? FileManager.default.removeItem(at: removed.imagePath)
        }
        rebuildMenu()
        flashStatusIcon(symbol: "camera.fill")
        if showOverlay && Settings.showOverlay {
            overlay.show(image: image, fileURL: url)
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
        history = sorted.prefix(maxHistory).map { url in
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            let id = url.deletingPathExtension().lastPathComponent
            return HistoryItem(id: id, date: date, imagePath: url)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
