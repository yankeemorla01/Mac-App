import Cocoa
import QuartzCore
import ApplicationServices
import ServiceManagement
import Sparkle

enum SavingMode: String {
    case appleNative = "apple"
    case instant = "instant"
}

enum Settings {
    private static let d = UserDefaults.standard
    private static let kIntro = "clipshot.hasSeenIntro"
    private static let kMode = "clipshot.savingMode"
    private static let kOverlay = "clipshot.showOverlay"
    private static let kLogin = "clipshot.openAtLogin"

    static var hasSeenIntro: Bool {
        get { d.bool(forKey: kIntro) }
        set { d.set(newValue, forKey: kIntro) }
    }
    static var savingMode: SavingMode {
        get { SavingMode(rawValue: d.string(forKey: kMode) ?? "instant") ?? .instant }
        set { d.set(newValue.rawValue, forKey: kMode) }
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

    private static let kOriginalThumb = "clipshot.originalShowThumbnail"
    static var originalShowThumbnail: Bool? {
        get {
            guard d.object(forKey: kOriginalThumb) != nil else { return nil }
            return d.bool(forKey: kOriginalThumb)
        }
        set {
            if let v = newValue { d.set(v, forKey: kOriginalThumb) }
            else { d.removeObject(forKey: kOriginalThumb) }
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

func clog(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(s)\n"
    guard let data = line.data(using: .utf8) else { return }

    // Rota el log cuando supera 1 MB para no llenar el disco
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
        // Captura todos los clics aunque caigan sobre el NSImageView interno
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
        // Si el archivo ya no existe (por ejemplo, clearHistory corrió entre mostrar
        // la miniatura y arrastrar), aborta limpiamente en vez de pasar un URL muerto.
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

final class WelcomeWindowController: NSWindowController {
    private var currentStep = 0
    private let totalSteps = 6
    private var contentBox: NSView!
    private var backButton: NSButton!
    private var nextButton: NSButton!
    private var skipButton: NSButton!
    private var dotsRow: NSStackView!
    var onFinish: (() -> Void)?

    // Selections
    var savingChoice: SavingMode = .instant
    var overlayChoice: Bool = true
    var loginChoice: Bool = true

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
        win.title = "Bienvenido a ClipShot"
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
        skipButton = NSButton(title: "Saltar", target: self, action: #selector(skipAll))
        skipButton.bezelStyle = .accessoryBarAction
        skipButton.isBordered = false
        skipButton.frame = NSRect(x: 30, y: 24, width: 70, height: 28)
        content.addSubview(skipButton)

        backButton = NSButton(title: "Atrás", target: self, action: #selector(goBack))
        backButton.bezelStyle = .rounded
        backButton.frame = NSRect(x: 360, y: 24, width: 80, height: 28)
        content.addSubview(backButton)

        nextButton = NSButton(title: "Siguiente", target: self, action: #selector(goNext))
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
        case 1: view = buildSavingMode()
        case 2: view = buildOverlay()
        case 3: view = buildLogin()
        case 4: view = buildPrivacy()
        default: view = buildDone()
        }
        view.frame = contentBox.bounds
        view.autoresizingMask = [.width, .height]
        contentBox.addSubview(view)

        backButton.isHidden = currentStep == 0
        nextButton.title = currentStep == totalSteps - 1 ? "Empezar" : "Siguiente"
        skipButton.isHidden = currentStep == totalSteps - 1

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

        let title = label("Bienvenido a ClipShot", size: 28, weight: .bold)
        let subtitle = label("Tu historial de screenshots, siempre listo en el portapapeles.",
                              size: 14, weight: .regular, color: .secondaryLabelColor, multiline: true)
        let body = label("ClipShot guarda automáticamente cada screenshot que tomas. Click en el icono de la barra de menú para ver el historial. Click en cualquier captura para volverla a copiar al portapapeles.",
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

    private func buildSavingMode() -> NSView {
        let v = NSView()
        let title = label("¿Cómo quieres que funcione?", size: 22, weight: .bold)
        let sub = label("Puedes cambiarlo en cualquier momento desde el menú.",
                         size: 12, weight: .regular, color: .secondaryLabelColor, multiline: true)
        v.addSubview(title); v.addSubview(sub)
        title.translatesAutoresizingMaskIntoConstraints = false
        sub.translatesAutoresizingMaskIntoConstraints = false

        let card1 = makeCard(
            tag: 0,
            title: "Mantener experiencia de Apple",
            body: "ClipShot espera ~5 segundos después de que tomas el screenshot (cuando la miniatura de Apple desaparece). El portapapeles e historial se actualizan al final. Ideal si quieres dejar macOS exactamente como viene."
        )
        let card2 = makeCard(
            tag: 1,
            title: "Guardado instantáneo (recomendado)",
            body: "ClipShot reemplaza la miniatura de Apple con una propia idéntica visualmente. El portapapeles e historial se actualizan al instante. Puedes pegar de inmediato. Mejor experiencia."
        )
        v.addSubview(card1); v.addSubview(card2)
        card1.translatesAutoresizingMaskIntoConstraints = false
        card2.translatesAutoresizingMaskIntoConstraints = false

        // Initial state reflects savingChoice
        updateCardSelection(card1, card2)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: v.topAnchor, constant: 6),
            title.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            sub.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            card1.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 22),
            card1.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            card1.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -20),
            card1.heightAnchor.constraint(equalToConstant: 100),
            card2.topAnchor.constraint(equalTo: card1.bottomAnchor, constant: 14),
            card2.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            card2.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -20),
            card2.heightAnchor.constraint(equalToConstant: 110),
        ])
        return v
    }

    private func makeCard(tag: Int, title cardTitle: String, body: String) -> NSButton {
        let b = NSButton(frame: .zero)
        b.tag = tag
        b.title = ""
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 10
        b.layer?.borderWidth = 2
        b.target = self
        b.action = #selector(selectCard(_:))

        let t = label(cardTitle, size: 14, weight: .semibold)
        t.translatesAutoresizingMaskIntoConstraints = false
        let body = label(body, size: 12, weight: .regular, color: .secondaryLabelColor, multiline: true)
        body.translatesAutoresizingMaskIntoConstraints = false
        b.addSubview(t); b.addSubview(body)
        NSLayoutConstraint.activate([
            t.topAnchor.constraint(equalTo: b.topAnchor, constant: 12),
            t.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 16),
            t.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -16),
            body.topAnchor.constraint(equalTo: t.bottomAnchor, constant: 4),
            body.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -16),
            body.bottomAnchor.constraint(lessThanOrEqualTo: b.bottomAnchor, constant: -12),
        ])
        return b
    }

    @objc private func selectCard(_ sender: NSButton) {
        savingChoice = (sender.tag == 0) ? .appleNative : .instant
        if let parent = sender.superview, parent.subviews.count >= 2,
           let c1 = parent.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.tag == 0 }),
           let c2 = parent.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.tag == 1 }) {
            updateCardSelection(c1, c2)
        }
    }

    private func updateCardSelection(_ c1: NSButton, _ c2: NSButton) {
        let sel = NSColor.controlAccentColor.cgColor
        let unsel = NSColor.separatorColor.cgColor
        c1.layer?.borderColor = savingChoice == .appleNative ? sel : unsel
        c1.layer?.backgroundColor = savingChoice == .appleNative
            ? NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
            : NSColor.controlBackgroundColor.cgColor
        c2.layer?.borderColor = savingChoice == .instant ? sel : unsel
        c2.layer?.backgroundColor = savingChoice == .instant
            ? NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
            : NSColor.controlBackgroundColor.cgColor
    }

    private func buildOverlay() -> NSView {
        let v = NSView()
        let title = label("Mostrar miniatura flotante", size: 22, weight: .bold)
        let body = label("Cuando tomes un screenshot, ClipShot mostrará una miniatura abajo a la derecha por unos segundos. Puedes hacer click para editarla o arrastrarla a otra app, igual que con la de Apple.",
                          size: 13, weight: .regular, color: .secondaryLabelColor, multiline: true)
        let toggle = NSSwitch()
        toggle.state = overlayChoice ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggleOverlay(_:))
        let toggleLabel = label("Mostrar miniatura cuando capture un screenshot",
                                  size: 13, weight: .medium)

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
        let title = label("Abrir al iniciar sesión", size: 22, weight: .bold)
        let body = label("Para que ClipShot siempre esté listo, puede abrirse automáticamente cuando inicies tu Mac. Vive silenciosamente en la barra de menú.",
                          size: 13, weight: .regular, color: .secondaryLabelColor, multiline: true)
        let toggle = NSSwitch()
        toggle.state = loginChoice ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggleLogin(_:))
        let toggleLabel = label("Abrir ClipShot automáticamente al iniciar sesión",
                                  size: 13, weight: .medium)
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
        icon.image = NSImage(systemSymbolName: "lock.shield.fill",
                              accessibilityDescription: "Privacidad")
        icon.contentTintColor = .systemGreen
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = label("Tu privacidad", size: 22, weight: .bold)
        let body = label("""
        ClipShot funciona 100% en tu Mac.

        • Tus screenshots y cualquier imagen que copies al portapapeles se guardan localmente en tu carpeta de Aplicación de ClipShot.
        • Nada se envía a internet. Nunca.
        • Los desarrolladores no tienen ningún acceso a tus imágenes ni a tu actividad.
        • Sin cuentas, sin servidores, sin telemetría.
        • Puedes borrar tu historial en cualquier momento desde el menú.

        Es tuya, y solo tuya.
        """, size: 13, weight: .regular, color: .labelColor, multiline: true)

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

        let title = label("¡Todo listo!", size: 28, weight: .bold)
        let body = label("ClipShot vive en tu barra de menú (icono de cámara). Toma un screenshot cuando quieras y aparecerá listo en el portapapeles. Puedes cambiar tus preferencias en cualquier momento desde el menú.",
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
        Settings.savingMode = savingChoice
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
    var folderTimer: Timer?
    let storeDir: URL
    let textStoreDir: URL
    var screenshotLocation: URL = URL(fileURLWithPath: (NSString("~/Desktop").expandingTildeInPath))
    var processedFiles: Set<String> = []
    let screenshotPrefixes = ["Screenshot", "Screen Shot", "Captura"]
    let overlay = ThumbnailOverlay()
    var welcomeWC: WelcomeWindowController?

    /// Sparkle auto-updater. `startingUpdater: true` makes Sparkle begin its
    /// background check cadence using `SUScheduledCheckInterval` from Info.plist.
    /// We retain this controller for the lifetime of the app — releasing it would
    /// stop the background checks.
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

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
        applyCurrentSavingMode()
        detectScreenshotLocation()
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
        wc.savingChoice = Settings.savingMode
        wc.overlayChoice = Settings.showOverlay
        wc.loginChoice = Settings.openAtLogin || !Settings.hasSeenIntro
        wc.onFinish = { [weak self] in
            self?.applyCurrentSavingMode()
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

    func applyCurrentSavingMode() {
        switch Settings.savingMode {
        case .instant:
            disableSystemThumbnail()
        case .appleNative:
            restoreSystemThumbnail()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        restoreSystemThumbnail()
    }

    func disableSystemThumbnail() {
        // Captura el valor original SOLO la primera vez. Si actualmente está en false,
        // casi seguro es residuo de una sesión nuestra que no salió limpia — asumimos
        // que el valor real del usuario era true (default de Apple). Si era genuino
        // false, el usuario puede desactivar la miniatura otra vez en Ajustes.
        if Settings.originalShowThumbnail == nil {
            let current = UserDefaults(suiteName: "com.apple.screencapture")?
                .object(forKey: "show-thumbnail") as? Bool ?? true
            let assumed = current == false ? true : current
            Settings.originalShowThumbnail = assumed
            clog("Captured show-thumbnail=\(current), storing original=\(assumed)")
        }
        runDefaults(value: "false")
    }

    func restoreSystemThumbnail() {
        // Restaura el valor original del usuario, no asume "true"
        let original = Settings.originalShowThumbnail ?? true
        runDefaults(value: original ? "true" : "false")
        Settings.originalShowThumbnail = nil
        clog("Restored show-thumbnail=\(original)")
    }

    private func runDefaults(value: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["write", "com.apple.screencapture", "show-thumbnail", "-bool", value]
        try? task.run()
        task.waitUntilExit()
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["SystemUIServer"]
        try? kill.run()
        kill.waitUntilExit()
    }

    func detectScreenshotLocation() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let desktop = home.appendingPathComponent("Desktop")
        var candidate: URL = desktop

        if let loc = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !loc.isEmpty {
            let expanded = NSString(string: loc).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
            // Solo aceptamos ubicaciones dentro del home del usuario
            if url.path.hasPrefix(home.path + "/") || url.path == home.path {
                candidate = url
            } else {
                clog("Ignoring screenshot location outside home: \(url.path); falling back to Desktop")
            }
        }
        screenshotLocation = candidate
        if let files = try? FileManager.default.contentsOfDirectory(atPath: screenshotLocation.path) {
            processedFiles = Set(files)
        }
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "ClipShot")
            img?.isTemplate = true
            button.image = img
        }
        rebuildMenu()
    }

    func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: "ClipShot — historial", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // Lista unificada: capturas y textos intercalados por fecha (más reciente arriba).
        // Cada uno se ve distinto: las capturas muestran su thumbnail real, los textos
        // se renderizan como una tarjetita con el preview adentro.
        let merged = mergedHistoryEntries()
        if merged.isEmpty {
            let empty = NSMenuItem(title: "  Aún no hay historial", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
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
        let openFolder = NSMenuItem(title: "Abrir carpeta de capturas", action: #selector(openHistoryFolder), keyEquivalent: "o")
        openFolder.target = self
        menu.addItem(openFolder)

        let openTextFolder = NSMenuItem(title: "Abrir carpeta de texto", action: #selector(openTextHistoryFolder), keyEquivalent: "")
        openTextFolder.target = self
        menu.addItem(openTextFolder)

        let clear = NSMenuItem(title: "Limpiar historial", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())
        let prefs = NSMenuItem(title: "Preferencias", action: nil, keyEquivalent: "")
        let prefsMenu = NSMenu()
        let modeHeader = NSMenuItem(title: "Modo de guardado", action: nil, keyEquivalent: "")
        modeHeader.isEnabled = false
        prefsMenu.addItem(modeHeader)
        let modeApple = NSMenuItem(title: "  Mantener experiencia de Apple (~5s)",
                                     action: #selector(setModeApple), keyEquivalent: "")
        modeApple.target = self
        modeApple.state = Settings.savingMode == .appleNative ? .on : .off
        prefsMenu.addItem(modeApple)
        let modeInstant = NSMenuItem(title: "  Guardado instantáneo",
                                       action: #selector(setModeInstant), keyEquivalent: "")
        modeInstant.target = self
        modeInstant.state = Settings.savingMode == .instant ? .on : .off
        prefsMenu.addItem(modeInstant)
        prefsMenu.addItem(.separator())
        let overlayItem = NSMenuItem(title: "Mostrar miniatura flotante",
                                       action: #selector(toggleOverlayPref), keyEquivalent: "")
        overlayItem.target = self
        overlayItem.state = Settings.showOverlay ? .on : .off
        prefsMenu.addItem(overlayItem)
        let loginItem = NSMenuItem(title: "Abrir al iniciar sesión",
                                     action: #selector(toggleLoginPref), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = Settings.openAtLogin ? .on : .off
        prefsMenu.addItem(loginItem)
        let textHistoryItem = NSMenuItem(title: "Guardar texto copiado",
                                           action: #selector(toggleTextHistoryPref), keyEquivalent: "")
        textHistoryItem.target = self
        textHistoryItem.state = Settings.saveTextHistory ? .on : .off
        prefsMenu.addItem(textHistoryItem)
        prefsMenu.addItem(.separator())

        // Sparkle auto-update: the action selector lives on the updater controller
        // itself, NOT on AppDelegate. Targeting the controller is what makes the
        // "Check for Updates…" item enabled and clickable.
        let checkUpdates = NSMenuItem(
            title: "Buscar actualizaciones…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkUpdates.target = updaterController
        prefsMenu.addItem(checkUpdates)
        prefsMenu.addItem(.separator())
        let showIntro = NSMenuItem(title: "Ver bienvenida otra vez…",
                                     action: #selector(reopenWelcome), keyEquivalent: "")
        showIntro.target = self
        prefsMenu.addItem(showIntro)
        prefs.submenu = prefsMenu
        menu.addItem(prefs)

        let about = NSMenuItem(title: "Acerca de ClipShot", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc func setModeApple() {
        Settings.savingMode = .appleNative
        applyCurrentSavingMode()
        rebuildMenu()
    }
    @objc func setModeInstant() {
        Settings.savingMode = .instant
        applyCurrentSavingMode()
        rebuildMenu()
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
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
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
        alert.messageText = "¿Limpiar historial?"
        alert.informativeText = """
        Capturas guardadas: \(counts.total)
          • Últimos 30 días: \(counts.recent)
          • Anteriores: \(counts.old)

        Textos guardados: \(textCounts.total)
          • Últimos 30 días: \(textCounts.recent)
          • Anteriores: \(textCounts.old)

        ¿Qué quieres borrar?
        """
        alert.addButton(withTitle: "Borrar TODO")
        alert.addButton(withTitle: "Solo lo de más de 30 días")
        alert.addButton(withTitle: "Cancelar")
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
        // Defensa en profundidad: solo borramos si storeDir es exactamente nuestro path conocido.
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
        // Limpia subcarpetas vacías (meses sin capturas restantes)
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
        alert.messageText = "ClipShot 1.3"
        alert.informativeText = """
        Guarda automáticamente cada screenshot y, opcionalmente, cada texto que copias.
        Mantiene un historial al que puedes volver con un solo clic.

        Cómo capturar:
          • Cmd+Shift+Ctrl+3/4 — directo al portapapeles
          • Cmd+Shift+3/4 — guarda en \(screenshotLocation.path)
          • Cmd+C — guarda el texto en el historial (si está activado en Preferencias)

        Historial guardado en:
          \(storeDir.path)
          \(textStoreDir.path)

        © 2026 Jean Carlos Morla Genao. Licencia MIT.
        Este software se distribuye "tal cual", sin garantías expresas o implícitas. El autor no se hace responsable de pérdida de datos o daños derivados del uso.
        """
        alert.runModal()
    }

    func startPasteboardMonitor() {
        lastChangeCount = NSPasteboard.general.changeCount
        // 0.5s es imperceptible para el usuario y ahorra mucha energía vs 0.1s
        pbTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
    }

    // Tope de imagen: ~100M pixels (10000x10000). Más arriba podría OOM-ear el menubar.
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

    // Tope conservador para no llenar disco con un copy gigante (ej. log completo)
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

        // Respeta convención nspasteboard.com: apps marcan contenido sensible
        // (contraseñas, datos de password managers) y debemos ignorarlos.
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
        // Evita duplicado del último entry (copiar dos veces lo mismo)
        if let last = textHistory.first, last.content == trimmed { return }

        saveText(trimmed)
    }

    func saveText(_ text: String) {
        let now = Date()
        let id = UUID().uuidString
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

    func startFolderMonitor() {
        // Usa DispatchSource sobre el FD de la carpeta: solo dispara cuando hay cambios,
        // en lugar de pollear 10×/seg. Es muchísimo más eficiente y respetuoso con la batería.
        installFolderDispatchSource()
    }

    private var folderFD: Int32 = -1
    private var folderSource: DispatchSourceFileSystemObject?

    private func installFolderDispatchSource() {
        teardownFolderDispatchSource()
        let path = screenshotLocation.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            clog("Failed to open folder for monitoring: \(path)")
            // Fallback al polling lento si no podemos abrir el FD
            folderTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.checkScreenshotFolder()
            }
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
        // Escaneo inicial
        checkScreenshotFolder()
    }

    private func teardownFolderDispatchSource() {
        folderSource?.cancel()
        folderSource = nil
        folderTimer?.invalidate()
        folderTimer = nil
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
            // Rechaza symlinks: pueden apuntar fuera del home y exfiltrar contenido
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
