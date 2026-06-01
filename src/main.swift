import Cocoa
import QuartzCore
import ApplicationServices
import ServiceManagement
import Sparkle
import Quartz   // QLPreviewPanel para Quick Look
import Vision   // OCR de screenshots
import Carbon.HIToolbox  // global hotkey via RegisterEventHotKey

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

    /// IDs (short UUID prefix) de items anclados. Sobreviven el cap de 30 y aparecen
    /// en una sección "Anclados" arriba del menú. Persistido como [String] en UserDefaults.
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

    /// Bundle IDs de apps donde NO debemos capturar texto del portapapeles
    /// (password managers, banca, etc.). Defaults razonables: 1Password, Bitwarden,
    /// Keychain Access. El usuario puede agregar más en Preferencias.
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

    /// Global hotkey config: por defecto ⌘⇧V. Codificado como Int (keyCode + modifiers).
    private static let kHotkeyKey = "clipshot.globalHotkey.key"
    private static let kHotkeyMods = "clipshot.globalHotkey.mods"
    /// Returns (keyCode, modifierFlags as carbon modifiers).
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

    /// OCR opt-in: cuando está activo, cada nueva captura se procesa con Apple
    /// Vision para extraer el texto y guardarlo en un .ocr.txt junto al .png,
    /// lo que hace que el History Browser pueda buscar dentro de las imágenes.
    private static let kEnableOCR = "clipshot.enableOCR"
    static var enableOCR: Bool {
        get { d.bool(forKey: kEnableOCR) }
        set { d.set(newValue, forKey: kEnableOCR) }
    }

    /// ClipShot Pro flag.
    ///
    /// En el build Developer ID este se setea via flujo de licencia (futuro
    /// integrarlo con Stripe/Paddle). En el build App Store se sincroniza con
    /// `Transaction.currentEntitlements` de StoreKit 2.
    ///
    /// Por ahora soportamos también una env var `CLIPSHOT_PRO=1` para QA y
    /// un trial de 7 días: al primer arranque se marca `proTrialStart`, y mientras
    /// (now - trialStart) < 7 días, isPro devuelve true automáticamente.
    private static let kIsPro = "clipshot.isPro"
    private static let kTrialStart = "clipshot.proTrialStart"
    static let trialDuration: TimeInterval = 7 * 24 * 3600

    /// En el build Developer ID (DMG distribuido fuera del Mac App Store) todas
    /// las features son GRATIS. La monetización para usuarios técnicos se hace via
    /// tip jar / "Apoyar el desarrollo" link, no via paywall.
    /// El build del App Store usa StoreKit 2 IAP (ver appstore/src/main.swift).
    static var isPro: Bool { true }

    static func setPro(_ value: Bool) {
        d.set(value, forKey: kIsPro)
    }

    static var trialDaysRemaining: Int {
        let start = d.double(forKey: kTrialStart)
        guard start > 0 else { return Int(trialDuration / 86400) }
        let elapsed = Date().timeIntervalSince1970 - start
        let remaining = trialDuration - elapsed
        return max(0, Int(ceil(remaining / 86400)))
    }

    /// Free tier history cap. Pro = ilimitado (sin cap aplicado).
    static let freeHistoryCap = 15

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





/// NSMenuItem con `view` custom — el truco para mantener el menú abierto al
/// click es que el ACTION del click NO sea el del NSMenuItem (NSMenu cierra
/// cuando el item dispara su acción) sino el de un NSButton interno.
///
/// NSButton maneja todo el tracking de mouseDown/up/drag por nosotros, y NSMenu
/// no ve nada — solo ve que su view "consumió" el evento.
final class StayOpenItemView: NSView {
    private let button: NSButton
    private let onClick: () -> Void

    init(initialTitle: String, owner: NSObject?, onClick: @escaping () -> Void) {
        self.onClick = onClick
        // .regularSquare con isBordered=false da una zona clickeable plana
        // con highlight de hover automático y respeta los modos del sistema.
        let b = NSButton(title: initialTitle, target: nil, action: nil)
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.alignment = .left
        b.contentTintColor = .labelColor
        b.font = NSFont.menuFont(ofSize: 0)
        // .momentaryChange evita que se quede "presionado" tras el click
        b.setButtonType(.momentaryChange)
        self.button = b
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        b.frame = NSRect(x: 14, y: 0, width: 206, height: 22)
        addSubview(b)
        b.target = self
        b.action = #selector(handleClick)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setTitle(_ s: String) { button.title = s }

    @objc private func handleClick() {
        onClick()
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
    private let totalSteps = 7
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
        case 1: view = buildFeatures()
        case 2: view = buildSavingMode()
        case 3: view = buildOverlay()
        case 4: view = buildLogin()
        case 5: view = buildPrivacy()
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

    /// Step 2: introduce todas las features nuevas para que el user las descubra
    /// el primer día y no quede en "tengo screenshots y nada más".
    private func buildFeatures() -> NSView {
        let container = NSView()

        let title = label("¿Qué hace ClipShot?", size: 26, weight: .bold,
                            color: .labelColor)
        title.frame = NSRect(x: 20, y: 270, width: 440, height: 40)
        title.autoresizingMask = [.minYMargin, .width]
        container.addSubview(title)

        let subtitle = label("Mucho más que solo guardar capturas:",
                                size: 13, weight: .regular,
                                color: .secondaryLabelColor)
        subtitle.frame = NSRect(x: 20, y: 240, width: 440, height: 22)
        subtitle.autoresizingMask = [.minYMargin, .width]
        container.addSubview(subtitle)

        let features: [(String, String, String)] = [
            ("camera.viewfinder", "Capturas + Texto",
             "Cada captura Y cada texto que copies, guardados en un historial unificado"),
            ("magnifyingglass.circle", "Buscar todo con ⌘⇧V",
             "Ventana de búsqueda desde cualquier app — fechas, contenido, OCR de imágenes"),
            ("text.viewfinder", "OCR en capturas",
             "Vision extrae el texto de cada captura — pegalo después como texto editable"),
            ("eyedropper.halffull", "Picker de color",
             "Click en cualquier pixel de una captura → te copia el hex"),
            ("pin.fill", "Anclar favoritos",
             "Items importantes sobreviven el límite del historial"),
        ]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.frame = NSRect(x: 40, y: 30, width: 400, height: 200)
        stack.autoresizingMask = [.minYMargin, .maxYMargin]
        for (sym, title, body) in features {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = 12
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
            icon.symbolConfiguration = .init(pointSize: 18, weight: .medium)
            icon.contentTintColor = .systemBlue
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 26).isActive = true
            let texts = NSStackView()
            texts.orientation = .vertical
            texts.alignment = .leading
            texts.spacing = 1
            let t = NSTextField(labelWithString: title)
            t.font = .systemFont(ofSize: 13, weight: .semibold)
            let b = NSTextField(labelWithString: body)
            b.font = .systemFont(ofSize: 11)
            b.textColor = .secondaryLabelColor
            b.maximumNumberOfLines = 2
            b.preferredMaxLayoutWidth = 340
            texts.addArrangedSubview(t)
            texts.addArrangedSubview(b)
            row.addArrangedSubview(icon)
            row.addArrangedSubview(texts)
            stack.addArrangedSubview(row)
        }
        container.addSubview(stack)

        return container
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
    var isPinned: Bool { Settings.isPinned(id) }
    /// Texto extraído por OCR (lazy load del sidecar `<file>.ocr.txt`).
    /// Nil si OCR no se corrió o la captura no tiene texto.
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
    /// Free: 15 items, Pro: 500 (un cap razonable para no llenar disco)
    var maxHistory: Int { Settings.isPro ? 500 : Settings.freeHistoryCap }
    var maxTextHistory: Int { Settings.isPro ? 500 : Settings.freeHistoryCap }
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

    /// History browser window — search-as-you-type sobre todo el historial.
    /// Se crea on-demand la primera vez que el user lo abre.
    var browserWC: HistoryBrowserWindowController?

    /// Global hotkey (default ⌘⇧V) — abre el History Browser desde cualquier app.
    var globalHotkey: GlobalHotkey?

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
        cleanupExtendedAttributes()
        applyCurrentSavingMode()
        detectScreenshotLocation()
        loadHistory()
        loadTextHistory()
        setupStatusItem()
        startPasteboardMonitor()
        startFolderMonitor()
        registerGlobalHotkey()

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

    /// Limpia los xattr (com.apple.quarantine, com.apple.macl, etc) del bundle
    /// al arrancar. Resuelve el clásico "no se puede abrir" cuando el user
    /// arrastra una versión nueva encima de la vieja en /Applications, porque
    /// macOS conserva los xattr del binario anterior y rompen la verificación
    /// de firma. Ejecutar `xattr -cr` sobre nuestro propio bundle mientras
    /// estamos corriendo es seguro — solo afecta los metadatos, no el binario.
    func cleanupExtendedAttributes() {
        let bundlePath = Bundle.main.bundlePath
        // Solo limpiamos si estamos en /Applications (instalación), no en /Users
        // donde el dev podría estar ejecutando una build de testing.
        guard bundlePath.hasPrefix("/Applications/") else { return }
        let task = Process()
        task.launchPath = "/usr/bin/xattr"
        task.arguments = ["-cr", bundlePath]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
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

    /// NSMenu delegate: rebuild el menú cada vez que el user lo abre. Esto cubre
    /// el caso de OCR que termina en background — la próxima vez que abran el
    /// menú, las opciones "Copiar solo el texto" aparecen para las capturas
    /// que ya tienen sidecar.
    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
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

        // Sección "Anclados" (si hay items pineados) — sobreviven el cap de 30.
        let pinned = pinnedEntries()
        if !pinned.isEmpty {
            let pinHeader = NSMenuItem(title: "📌 Anclados", action: nil, keyEquivalent: "")
            pinHeader.isEnabled = false
            menu.addItem(pinHeader)
            for entry in pinned {
                addEntryMenuItem(entry, to: menu)
            }
            menu.addItem(.separator())
            let regularHeader = NSMenuItem(title: "Recientes", action: nil, keyEquivalent: "")
            regularHeader.isEnabled = false
            menu.addItem(regularHeader)
        }

        // Lista unificada: capturas y textos intercalados por fecha (más reciente arriba).
        let merged = mergedHistoryEntries()
        if merged.isEmpty && pinned.isEmpty {
            let empty = NSMenuItem(title: "  Aún no hay historial", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else if merged.isEmpty {
            let empty = NSMenuItem(title: "  Sin items recientes", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for entry in merged {
                addEntryMenuItem(entry, to: menu)
            }
        }

        menu.addItem(.separator())
        let browseItem = NSMenuItem(title: "Buscar en historial…",
                                      action: #selector(openHistoryBrowser),
                                      keyEquivalent: "f")
        browseItem.target = self
        menu.addItem(browseItem)

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

        let ocrItem = NSMenuItem(title: "OCR en capturas (texto buscable)",
                                   action: #selector(toggleOCRPref), keyEquivalent: "")
        ocrItem.target = self
        ocrItem.state = Settings.enableOCR ? .on : .off
        prefsMenu.addItem(ocrItem)

        let (hkKey, hkMods) = Settings.globalHotkey
        let hkLabel = "Atajo global: " + HotkeyRecorderView.describe(key: hkKey, mods: hkMods) + "…"
        let hkItem = NSMenuItem(title: hkLabel,
                                  action: #selector(openHotkeySettings), keyEquivalent: "")
        hkItem.target = self
        prefsMenu.addItem(hkItem)
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

        // DMG: todo gratis. Mostramos un "Apoyar el desarrollo" opcional para
        // los que quieran donar — no es paywall, es propina si les gustó.
        let supportItem = NSMenuItem(title: "💙 Apoyar el desarrollo…",
                                       action: #selector(openSupport), keyEquivalent: "")
        supportItem.target = self
        menu.addItem(supportItem)

        let about = NSMenuItem(title: "Acerca de ClipShot", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        menu.delegate = self
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
    @objc func toggleOCRPref() {
        Settings.enableOCR.toggle()
        rebuildMenu()
    }
    @objc func reopenWelcome() {
        showWelcome()
    }

    @objc func openPaywall() {
        PaywallWindowController.presentModal()
    }

    @objc func openSupport() {
        if let url = URL(string: "https://josegcasadogenao.github.io/clipshot/support") {
            NSWorkspace.shared.open(url)
        }
    }

    var hotkeyWC: HotkeySettingsWindowController?
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

    /// Devuelve TODAS las entries (imágenes + textos si saveTextHistory está activo),
    /// ordenadas por fecha descendente. No aplica límite; el corte se hace abajo
    /// según si la entry está anclada o no.
    func allMergedEntries() -> [MergedEntry] {
        var entries: [MergedEntry] = history.enumerated().map { .image($0.offset, $0.element) }
        if Settings.saveTextHistory {
            entries.append(contentsOf: textHistory.enumerated().map { .text($0.offset, $0.element) })
        }
        entries.sort { $0.date > $1.date }
        return entries
    }

    func mergedHistoryEntries(limit: Int = 20) -> [MergedEntry] {
        Array(allMergedEntries().filter { !$0.isPinned }.prefix(limit))
    }

    func pinnedEntries() -> [MergedEntry] {
        allMergedEntries().filter { $0.isPinned }
    }

    /// Crea el NSMenuItem para una entry y lo agrega al menú dado.
    /// El item principal copia al portapapeles cuando se clickea; el submenú permite
    /// anclar/desanclar, mostrar en Finder o borrar individualmente.
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

    /// Crea un submenú de acciones para un item del historial.
    /// El item "Anclar" usa target/action estándar — NSMenu cierra al click y
    /// re-abrimos enseguida vía RunLoop. Es el patrón estándar de Maccy.
    /// macOS no permite actualizar NSMenu durante tracking sin un re-open.
    func buildEntrySubmenu(id: String, fileURL: URL, isImage: Bool) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false

        let pinTitle = Settings.isPinned(id) ? "Quitar anclado" : "📌 Anclar"
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(togglePinEntry(_:)), keyEquivalent: "")
        pinItem.target = self
        pinItem.representedObject = id
        sub.addItem(pinItem)

        if isImage {
            let sidecar = fileURL.deletingPathExtension().appendingPathExtension("ocr.txt")
            if FileManager.default.fileExists(atPath: sidecar.path) {
                let ocrItem = NSMenuItem(title: "📝 Copiar solo el texto",
                                           action: #selector(copyOCRTextFromImage(_:)),
                                           keyEquivalent: "")
                ocrItem.target = self
                ocrItem.representedObject = fileURL
                sub.addItem(ocrItem)
            }
            let pickerItem = NSMenuItem(title: "🎨 Picker de color…",
                                          action: #selector(openColorPicker(_:)),
                                          keyEquivalent: "")
            pickerItem.target = self
            pickerItem.representedObject = fileURL
            sub.addItem(pickerItem)
        }

        sub.addItem(.separator())

        let revealItem = NSMenuItem(title: "Mostrar en Finder",
                                      action: #selector(revealEntry(_:)), keyEquivalent: "")
        revealItem.target = self
        revealItem.representedObject = fileURL
        sub.addItem(revealItem)

        let deleteItem = NSMenuItem(title: "Borrar", action: #selector(deleteEntry(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = ["id": id, "fileURL": fileURL, "isImage": isImage] as [String: Any]
        sub.addItem(deleteItem)

        return sub
    }

    @objc func togglePinEntry(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.togglePinned(id)
        rebuildMenu()
        // Re-open via RunLoop.main.perform en modo .common — más rápido que
        // DispatchQueue.main.async porque corre en el mismo runloop pass al
        // terminar el modo de event tracking. El flicker es mínimo (~16ms).
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

    func registerGlobalHotkey() {
        let (key, mods) = Settings.globalHotkey
        globalHotkey = GlobalHotkey { [weak self] in
            self?.openHistoryBrowser()
        }
        globalHotkey?.register(keyCode: key, modifiers: mods)
    }

    @objc func openHistoryBrowser() {
        // Crea la ventana on-demand para no consumir memoria si nunca se usa.
        if browserWC == nil {
            browserWC = HistoryBrowserWindowController(owner: self)
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                     object: browserWC?.window, queue: .main) { [weak self] _ in
                NSApp.setActivationPolicy(.accessory)
                self?.browserWC = nil
            }
        }
        browserWC?.reloadFromOwner()
        // Cambiamos a regular activation policy para que la ventana tome foco
        // y aparezca en el Dock/cmd-tab; al cerrarla volvemos a accessory.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        browserWC?.showWindow(nil)
        browserWC?.window?.makeKeyAndOrderFront(nil)
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

    /// Lee el sidecar OCR de una imagen del historial y copia su texto al portapapeles
    /// (sin la imagen). Útil cuando capturás un email o código para pegarlo editable.
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

    /// Abre el color picker (feature Pro) sobre una imagen del historial.
    /// Retiene el WC en un slot para que no se libere mientras la ventana está visible.
    var colorPickerWC: ColorPickerWindowController?
    @objc func openColorPicker(_ sender: NSMenuItem) {
        guard let imageURL = sender.representedObject as? URL else { return }
        colorPickerWC = ColorPickerWindowController(imageURL: imageURL)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        colorPickerWC?.showWindow(nil)
        colorPickerWC?.window?.makeKeyAndOrderFront(nil)
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
        alert.messageText = "ClipShot 1.6"
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

        // Apps explícitamente excluidas (password managers, banca, etc.).
        if let frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           Settings.excludedAppBundleIds.contains(frontApp) {
            return
        }

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
        pruneTextHistory()
        rebuildMenu()
        flashStatusIcon(symbol: "doc.on.clipboard.fill")
    }

    /// Trim image history al cap manteniendo los anclados.
    /// También borra el sidecar OCR (.ocr.txt) si existe.
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

    /// Trim text history al cap manteniendo los anclados. Itera desde el final y
    /// borra solo entries no ancladas hasta que el total NO ancladas <= maxTextHistory.
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
        // Carga todos los anclados + los más recientes no anclados hasta maxTextHistory.
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

    /// Extrae el sufijo corto de 6 chars del filename (después del último `_`).
    /// Para "Texto 2026-05-27 a las 14-30-12_a1b2c3.txt" devuelve "a1b2c3".
    /// Es lo que usamos como id estable entre runs (para anclar items, etc.).
    func extractId(from url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        if let u = stem.lastIndex(of: "_") {
            return String(stem[stem.index(after: u)...])
        }
        return stem
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

    /// Corre Vision para extraer texto de una captura y lo guarda como sidecar
    /// `<id>.ocr.txt` junto al .png. El sidecar lo lee `loadHistory` para llenar
    /// `ocrText` en HistoryItem y hacer que el search del browser lo encuentre.
    /// Async, en background — no bloquea el monitor del portapapeles.
    /// Al completar, reconstruye el menú para que aparezca "Copiar solo el texto".
    func runOCRIfEnabled(imagePath: URL, nsImage: NSImage) {
        guard Settings.enableOCR else { return }
        guard Settings.isPro else { return }  // OCR es feature Pro
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
                // Reconstruye el menú en main thread para que aparezca la opción
                // "Copiar solo el texto" la próxima vez que el user lo abra.
                DispatchQueue.main.async { self?.rebuildMenu() }
            }
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            req.recognitionLanguages = ["es-ES", "en-US"]
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            try? handler.perform([req])
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
        pruneHistory()
        rebuildMenu()
        flashStatusIcon(symbol: "camera.fill")
        runOCRIfEnabled(imagePath: url, nsImage: image)
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
        // Carga TODOS los items que están anclados (sin importar cap) + los más recientes
        // no anclados hasta llenar maxHistory.
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

// MARK: - Color Picker
//
// Ventana que muestra una captura a tamaño completo. Al mover el mouse encima,
// muestra el color del pixel debajo + hex/RGB. Click copia el formato actual.
// Pro feature: justifica el precio para diseñadores.
final class ColorPickerWindowController: NSWindowController, NSWindowDelegate {
    private let imageURL: URL
    private var imageView: ZoomableImageView!
    private var swatch: NSView!
    private var hexLabel: NSTextField!
    private var rgbLabel: NSTextField!
    private var hslLabel: NSTextField!
    private var lastColor: NSColor = .clear

    init(imageURL: URL) {
        self.imageURL = imageURL
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Picker de color"
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
        imageView.onPixelHover = { [weak self] color in
            self?.updateSwatch(color: color)
        }
        imageView.onPixelClick = { [weak self] color in
            self?.copyHex(color: color)
        }
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

        hexLabel = NSTextField(labelWithString: "Pasá el mouse sobre la imagen")
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

        let hint = NSTextField(labelWithString: "Click en la imagen para copiar el hex")
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
        lastColor = color
        swatch.layer?.backgroundColor = color.cgColor
        let r = Int(round(color.redComponent * 255))
        let g = Int(round(color.greenComponent * 255))
        let b = Int(round(color.blueComponent * 255))
        let hex = String(format: "#%02X%02X%02X", r, g, b)
        hexLabel.stringValue = hex
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
        // Flash visual rápido en el swatch para confirmar
        swatch.layer?.borderColor = NSColor.systemBlue.cgColor
        swatch.layer?.borderWidth = 3
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.swatch.layer?.borderColor = NSColor.separatorColor.cgColor
            self?.swatch.layer?.borderWidth = 1
        }
    }

    /// Convierte RGB (0-1) a HSL (h: 0-1, s: 0-1, l: 0-1).
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

/// NSImageView que reporta el color del pixel debajo del mouse en cada movimiento.
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

    /// Convierte la posición del mouse (en coords del view) a coords de pixel
    /// del NSImage subyacente, considerando aspect-fit scaling.
    private func pixelColorAt(viewPoint: NSPoint) -> NSColor? {
        guard let image = self.image else { return nil }
        let imgSize = image.size
        guard imgSize.width > 0 && imgSize.height > 0 else { return nil }
        // Calcula el rect donde se dibuja la imagen (aspect-fit dentro de bounds)
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
        // Necesitamos un NSBitmapImageRep para muestrear pixels reales
        guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first
                ?? (image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }) else {
            return nil
        }
        let px = Int(normX * CGFloat(rep.pixelsWide))
        let py = Int(normY * CGFloat(rep.pixelsHigh))
        guard px >= 0 && px < rep.pixelsWide && py >= 0 && py < rep.pixelsHigh else { return nil }
        return rep.colorAt(x: px, y: py)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let color = pixelColorAt(viewPoint: p) {
            onPixelHover?(color)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let color = pixelColorAt(viewPoint: p) {
            onPixelClick?(color)
        }
    }
}

// MARK: - Hotkey Recorder
//
// Campo que captura la próxima combinación de teclas que apretas mientras
// está focused, igual que el panel de Atajos de macOS Settings. Convierte
// la NSEvent a Carbon keyCode+modifiers que es lo que necesita RegisterEventHotKey.
final class HotkeyRecorderView: NSView {
    var onCapture: ((UInt32, UInt32) -> Void)?
    private let label = NSTextField(labelWithString: "")
    private var isRecording = false
    private var currentKey: UInt32
    private var currentMods: UInt32

    init(initialKey: UInt32, initialMods: UInt32) {
        self.currentKey = initialKey
        self.currentMods = initialMods
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        label.frame = NSRect(x: 12, y: 4, width: 216, height: 20)
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
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
        label.stringValue = "Apretá la combinación…"
        label.textColor = .systemBlue
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return }
        // Esc cancela sin cambiar
        if event.keyCode == 53 {
            isRecording = false
            updateLabel()
            return
        }
        // Necesitamos al menos un modificador (sino podría conflictuar con teclas normales)
        let flags = event.modifierFlags
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        guard mods != 0 else {
            label.stringValue = "Necesita un modificador (⌘⌥⌃⇧)"
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

    /// Devuelve "⌘⇧V"-style.
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
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        w.title = "Atajo global"
        w.center()
        super.init(window: w)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let cv = window?.contentView else { return }
        let title = NSTextField(labelWithString: "Atajo para abrir Buscar en historial")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(title)

        let hint = NSTextField(labelWithString: "Click en el campo y apretá la combinación. Esc cancela.")
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

        let resetBtn = NSButton(title: "Volver al default (⌘⇧V)", target: self, action: #selector(resetDefault))
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

// MARK: - Paywall Window
//
// Ventana de upsell que aparece cuando el usuario intenta usar una feature Pro
// (o explícitamente eligen "Upgrade" desde el menú). Por ahora la compra real
// va a un link externo (Stripe Checkout / Paddle). El App Store build usaría
// StoreKit 2 directamente sin esta ventana.
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
    }

    private func buildContent() {
        guard let cv = window?.contentView else { return }
        cv.wantsLayer = true
        cv.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

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

        let trial = Settings.trialDaysRemaining
        let subStr: String
        if Settings.isPro && !Settings.d_isProSet {
            subStr = "Te quedan \(trial) días de prueba gratis"
        } else if Settings.isPro {
            subStr = "Ya tienes ClipShot Pro activo ✓"
        } else {
            subStr = "Tu trial terminó. Desbloquea las features Pro:"
        }
        let subtitle = NSTextField(labelWithString: subStr)
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(subtitle)

        let features = makeFeatureList()
        features.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(features)

        let priceLabel = NSTextField(labelWithString: "Una sola vez · $9.99")
        priceLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        priceLabel.alignment = .center
        priceLabel.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(priceLabel)

        let buyButton = NSButton(title: "Desbloquear Pro", target: self, action: #selector(buyPro))
        buyButton.bezelStyle = .rounded
        buyButton.keyEquivalent = "\r"
        buyButton.controlSize = .large
        buyButton.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(buyButton)

        let restoreButton = NSButton(title: "Restaurar compra", target: self, action: #selector(restorePro))
        restoreButton.bezelStyle = .accessoryBarAction
        restoreButton.isBordered = false
        restoreButton.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(restoreButton)

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

            priceLabel.topAnchor.constraint(equalTo: features.bottomAnchor, constant: 16),
            priceLabel.centerXAnchor.constraint(equalTo: cv.centerXAnchor),

            buyButton.topAnchor.constraint(equalTo: priceLabel.bottomAnchor, constant: 12),
            buyButton.centerXAnchor.constraint(equalTo: cv.centerXAnchor),
            buyButton.widthAnchor.constraint(equalToConstant: 220),

            restoreButton.topAnchor.constraint(equalTo: buyButton.bottomAnchor, constant: 8),
            restoreButton.centerXAnchor.constraint(equalTo: cv.centerXAnchor),
            restoreButton.bottomAnchor.constraint(lessThanOrEqualTo: cv.bottomAnchor, constant: -20),
        ])
    }

    private func makeFeatureList() -> NSStackView {
        let items: [(String, String)] = [
            ("doc.text.viewfinder", "OCR — buscar texto dentro de tus capturas"),
            ("infinity", "Historial ilimitado (Free: 15 items)"),
            ("icloud", "Sincronización entre Macs (próximamente)"),
            ("eyedropper", "Picker de color en capturas"),
            ("pencil.tip.crop.circle", "Markup rápido sobre capturas (próximamente)"),
            ("heart.fill", "Apoyas el desarrollo independiente 💙"),
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

    @objc private func buyPro() {
        // Por ahora abre un link externo (Stripe Checkout). En el App Store build
        // este botón dispararía Product.purchase() de StoreKit 2.
        if let url = URL(string: "https://josegcasadogenao.github.io/clipshot/pro") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func restorePro() {
        let alert = NSAlert()
        alert.messageText = "Pega tu código de licencia"
        alert.informativeText = "Te lo mandamos por email después de la compra."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "CLIPSHOT-XXXX-XXXX-XXXX"
        alert.accessoryView = field
        alert.addButton(withTitle: "Activar")
        alert.addButton(withTitle: "Cancelar")
        if alert.runModal() == .alertFirstButtonReturn {
            let code = field.stringValue.trimmingCharacters(in: .whitespaces)
            // TODO: validación real contra Gumroad/Paddle API. Por ahora cualquier
            // código que empiece con "CLIPSHOT-" se acepta — placeholder.
            if code.hasPrefix("CLIPSHOT-") {
                Settings.setPro(true)
                let ok = NSAlert()
                ok.messageText = "ClipShot Pro activado ✓"
                ok.runModal()
                window?.close()
            } else {
                let err = NSAlert()
                err.messageText = "Código inválido"
                err.informativeText = "Verifica que sea el que recibiste por email."
                err.runModal()
            }
        }
    }
}

// Pequeña extensión interna para saber si la flag isPro fue *seteada* explícitamente
// (vs. estar en periodo de trial). La usa el paywall para cambiar el copy.
extension Settings {
    static var d_isProSet: Bool {
        return UserDefaults.standard.object(forKey: "clipshot.isPro") as? Bool ?? false
    }
}

// MARK: - Global Hotkey
//
// Carbon's RegisterEventHotKey sigue siendo la API más confiable para hotkeys
// globales en macOS (los NSEvent global monitors no funcionan si la app no
// tiene acceso de accesibilidad). Carbon no requiere permisos especiales.
final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let onTrigger: () -> Void
    private static var instances: [UInt32: GlobalHotkey] = [:]
    private static var nextID: UInt32 = 1

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
    }

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()
        let id = GlobalHotkey.nextID
        GlobalHotkey.nextID += 1
        GlobalHotkey.instances[id] = self

        var hotKeyID = EventHotKeyID(signature: OSType(0x434C5350), id: id)  // 'CLSP'
        var ref: EventHotKeyRef?
        RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                              GetApplicationEventTarget(), 0, &ref)
        hotKeyRef = ref

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                   eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),
                              { (_, event, _) -> OSStatus in
            var receivedID = EventHotKeyID()
            GetEventParameter(event,
                                EventParamName(kEventParamDirectObject),
                                EventParamType(typeEventHotKeyID),
                                nil,
                                MemoryLayout<EventHotKeyID>.size,
                                nil,
                                &receivedID)
            if let inst = GlobalHotkey.instances[receivedID.id] {
                inst.onTrigger()
            }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let h = eventHandler {
            RemoveEventHandler(h)
            eventHandler = nil
        }
    }

    deinit { unregister() }
}

// MARK: - History Browser Window
//
// Ventana separada estilo Spotlight: search field arriba + lista filtrada de
// todos los items del historial (capturas + textos). NSMenu no permite hostear
// un text field interactivo, así que esto vive en su propia NSWindow.
//
// Atajos en la ventana:
//   ↑ / ↓     navegar
//   Return    copia el item seleccionado al portapapeles y cierra
//   Escape    cerrar sin copiar
//   ⌘F        re-focus al search field (dentro de la ventana)
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
            backing: .buffered,
            defer: false
        )
        w.title = "Buscar en historial"
        w.minSize = NSSize(width: 380, height: 360)
        w.center()
        w.titlebarAppearsTransparent = false
        super.init(window: w)
        w.delegate = self
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func setupUI() {
        guard let cv = window?.contentView else { return }

        searchField = NSSearchField()
        searchField.placeholderString = "Buscar capturas o texto…"
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
        tableView.selectionHighlightStyle = .regular
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

    /// Llamado por AppDelegate cuando se abre la ventana — refresca data fresca.
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
                case .image(_, let h):
                    // OCR sidecar: si la captura tiene texto extraído, lo buscamos.
                    return (h.ocrText?.lowercased().contains(q)) ?? false
                case .text(_, let t):
                    return (t.content?.lowercased().contains(q)) ?? false
                }
            }
        }
        tableView.reloadData()
        if !filteredEntries.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    // MARK: NSTableView data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { filteredEntries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = filteredEntries[row]
        let cell = HistoryBrowserCell()
        cell.configure(entry: entry, owner: ownerDelegate)
        return cell
    }

    // MARK: Actions

    @objc private func rowDoubleClicked() {
        copySelectedAndClose()
    }

    /// Copia el item seleccionado. Si `textOnly` es true y el item es una imagen
    /// con OCR, copia solo el texto extraído (no la imagen).
    private func copySelectedAndClose(textOnly: Bool = false) {
        let row = tableView.selectedRow
        guard row >= 0 && row < filteredEntries.count else { return }
        let entry = filteredEntries[row]
        let pb = NSPasteboard.general
        pb.clearContents()
        switch entry {
        case .image(_, let h):
            if textOnly, let ocr = h.ocrText {
                pb.setString(ocr, forType: .string)
            } else if let img = h.image {
                pb.writeObjects([img])
            }
        case .text(_, let t):
            if let text = t.content {
                pb.setString(text, forType: .string)
            }
        }
        ownerDelegate?.lastChangeCount = pb.changeCount
        window?.close()
    }

    /// Capturamos teclas a nivel de la ventana para que ↑↓ no las consuma el
    /// search field cuando está focused. Return = copiar, Escape = cerrar.
    func windowDidBecomeKey(_ notification: Notification) {
        window?.makeFirstResponder(searchField)
    }

    override func keyDown(with event: NSEvent) {
        handleKey(event) ? () : super.keyDown(with: event)
    }

    /// Devuelve true si la tecla fue manejada.
    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        let optHeld = event.modifierFlags.contains(.option)
        switch event.keyCode {
        case 36, 76: // Return / Enter — ⌥Return copia solo el OCR text
            copySelectedAndClose(textOnly: optHeld)
            return true
        case 53: // Escape
            window?.close()
            return true
        case 125: // Down arrow
            moveSelection(by: +1)
            return true
        case 126: // Up arrow
            moveSelection(by: -1)
            return true
        case 49: // Space — toggle Quick Look
            toggleQuickLook()
            return true
        default:
            return false
        }
    }

    /// Abre/cierra el panel de Quick Look de macOS para el item seleccionado.
    /// QLPreviewPanel es el mismo que usa Finder cuando presionás espacio.
    func toggleQuickLook() {
        guard tableView.selectedRow >= 0 else { return }
        let panel = QLPreviewPanel.shared()
        if panel?.isVisible == true {
            panel?.orderOut(nil)
        } else {
            panel?.makeKeyAndOrderFront(nil)
        }
    }

    private func moveSelection(by delta: Int) {
        guard !filteredEntries.isEmpty else { return }
        let current = tableView.selectedRow
        var next = current + delta
        if next < 0 { next = 0 }
        if next >= filteredEntries.count { next = filteredEntries.count - 1 }
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }
}

/// Search field también necesita interceptar ↑↓ Return — si no, los consume él
/// (NSSearchField intenta autocompletar con flechas). Usamos commandSelector.
extension HistoryBrowserWindowController {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: +1); return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1); return true
        case #selector(NSResponder.insertNewline(_:)):
            copySelectedAndClose(textOnly: false); return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // ⌥Return desde el search field
            copySelectedAndClose(textOnly: true); return true
        case #selector(NSResponder.cancelOperation(_:)):
            window?.close(); return true
        default:
            return false
        }
    }
}

// MARK: - Quick Look integration

extension HistoryBrowserWindowController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        let row = tableView?.selectedRow ?? -1
        return (row >= 0 && row < filteredEntries.count) ? 1 : 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let row = tableView.selectedRow
        guard row >= 0 && row < filteredEntries.count else { return nil }
        switch filteredEntries[row] {
        case .image(_, let h):
            return h.imagePath as NSURL
        case .text(_, let t):
            return t.textPath as NSURL
        }
    }
}

/// Fila del History Browser. Muestra thumbnail / text card a la izquierda,
/// fecha + preview de contenido en el centro, indicador de pin a la derecha.
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
        addSubview(preview)
        addSubview(dateLabel)
        addSubview(bodyLabel)
        addSubview(pinIndicator)

        preview.translatesAutoresizingMaskIntoConstraints = false
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        pinIndicator.translatesAutoresizingMaskIntoConstraints = false

        dateLabel.font = .systemFont(ofSize: 13, weight: .medium)
        dateLabel.textColor = .labelColor
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

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(entry: AppDelegate.MergedEntry, owner: AppDelegate?) {
        dateLabel.stringValue = owner?.formatDate(entry.date) ?? ""
        pinIndicator.isHidden = !entry.isPinned

        switch entry {
        case .image(_, let h):
            if let img = h.image {
                preview.image = owner?.thumbnail(from: img, maxSize: NSSize(width: 88, height: 56))
            }
            bodyLabel.stringValue = "📸 Captura"
        case .text(_, let t):
            let content = t.content ?? ""
            let oneLine = content
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
            bodyLabel.stringValue = oneLine
            preview.image = owner?.textCard(preview: owner?.textPreview(content, limit: 80) ?? "",
                                              size: NSSize(width: 88, height: 56))
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
