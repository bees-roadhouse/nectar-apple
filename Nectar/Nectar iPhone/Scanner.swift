// The camera scanner behind More's "Scan a code" (#167; first built for the Tauri shell in #149 and #151), to Capping's feel notes on #149:
// VisionKit's own scanner where the device has it, AVFoundation's where it doesn't; gold brackets on a 40 % dim, Cancel
// and a torch at 44 pt, a hit beat before it closes, wrong codes as a quiet line with the camera still running, and a
// sheet with Open Settings when the camera is refused. Frame calls `scan(from:origin:done:)` on the main thread.

import AVFoundation
import UIKit
import VisionKit

@MainActor
enum NectarScanner {
    /// Shows the scanner over `controller`. `done` gets the accepted `/activate?code=` link on `origin`, or nil when
    /// the person cancels; it's called once, on the main thread.
    static func scan(from controller: UIViewController, origin: String, done: @escaping @MainActor (String?) -> Void) {
        let top = topmost(controller)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            present(over: top, origin: origin, done: done)
        case .notDetermined:
            Task { @MainActor in
                let allowed = await AVCaptureDevice.requestAccess(for: .video)
                if allowed { present(over: top, origin: origin, done: done) } else { refused(over: top, done: done) }
            }
        default:
            refused(over: top, done: done)
        }
    }

    private static func present(over top: UIViewController, origin: String, done: @escaping @MainActor (String?) -> Void) {
        let screen = ScannerScreen(origin: origin, done: done)
        screen.modalPresentationStyle = .fullScreen
        top.present(screen, animated: true)
    }

    private static func refused(over top: UIViewController, done: @escaping @MainActor (String?) -> Void) {
        let sheet = RefusedSheet(done: done)
        sheet.modalPresentationStyle = .pageSheet
        if let sizes = sheet.sheetPresentationController {
            sizes.detents = [.medium()]
            sizes.prefersGrabberVisible = true
        }
        top.present(sheet, animated: true)
    }

    private static func topmost(_ controller: UIViewController) -> UIViewController {
        var top = controller.view.window?.rootViewController ?? controller
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}

/// Brand values from the Brand & Visual Identity Standard (KB page 2451), as the shell's launch page uses them.
private enum Brand {
    static let gold = UIColor(red: 0xE8 / 255, green: 0xA0 / 255, blue: 0x3A / 255, alpha: 1)
    static let goldInk = UIColor(red: 0x1A / 255, green: 0x14 / 255, blue: 0x07 / 255, alpha: 1)
    static let card = UIColor(red: 0x1D / 255, green: 0x20 / 255, blue: 0x24 / 255, alpha: 1)
    static let night = UIColor(red: 0x11 / 255, green: 0x12 / 255, blue: 0x14 / 255, alpha: 1)
}

/// What a scanned code is, against the server the shell is signed in to.
enum ScannedCode: Equatable {
    case accepted(String)
    case otherServer
    case notNectar

    init(_ text: String, origin: String) {
        guard let url = URLComponents(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.path == "/activate", url.queryItems?.contains(where: { $0.name == "code" && !($0.value ?? "").isEmpty }) == true
        else { self = .notNectar; return }
        let theirs = "\(scheme)://\(url.host?.lowercased() ?? "")" + (url.port.map { ":\($0)" } ?? "")
        self = theirs == origin.lowercased() ? .accepted(text) : .otherServer
    }
}

/// The full-screen scanner: the camera, the overlay, and the answer.
private final class ScannerScreen: UIViewController {
    private let origin: String
    private var done: (@MainActor (String?) -> Void)?
    private let overlay = Overlay()
    private var camera: Camera?

    init(origin: String, done: @escaping @MainActor (String?) -> Void) {
        self.origin = origin
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        camera = Camera.make(in: self) { [weak self] text in self?.found(text) }
        overlay.frame = view.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(overlay)
        overlay.cancel.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        overlay.torch.addTarget(self, action: #selector(toggleTorch), for: .touchUpInside)
        overlay.torch.isHidden = !Camera.hasTorch
        // A swipe down closes it, as a cover does.
        let down = UISwipeGestureRecognizer(target: self, action: #selector(cancel))
        down.direction = .down
        view.addGestureRecognizer(down)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        camera?.start()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        camera?.layout(in: view.bounds)
    }

    private func found(_ text: String) {
        guard done != nil else { return }
        switch ScannedCode(text, origin: origin) {
        case .accepted(let link):
            // The hit beat: solid brackets and a light tap, then away (never straight from under a live camera).
            camera?.stop()
            overlay.hit()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.finish(link) }
        case .otherServer:
            overlay.say("That code is for a different server.")
        case .notNectar:
            overlay.say("That isn't a nectar sign-in code.")
        }
    }

    @objc private func cancel() { finish(nil) }

    @objc private func toggleTorch() {
        overlay.torchOn(Camera.toggleTorch())
    }

    private func finish(_ link: String?) {
        guard let done else { return }
        self.done = nil
        camera?.stop()
        _ = Camera.setTorch(false)
        dismiss(animated: true) { done(link) }
    }
}

/// The camera, through VisionKit's scanner where it's supported, or AVFoundation's capture session. Main thread only.
@MainActor
private class Camera: NSObject {
    func start() {}
    func stop() {}
    func layout(in bounds: CGRect) {}

    static func make(in screen: UIViewController, found: @escaping (String) -> Void) -> Camera {
        if #available(iOS 16, *), DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
            return SystemScanner(in: screen, found: found)
        }
        return CaptureScanner(in: screen, found: found)
    }

    static var hasTorch: Bool { AVCaptureDevice.default(for: .video)?.hasTorch ?? false }

    /// Turns the torch on or off; answers whether it's now on.
    @discardableResult
    static func setTorch(_ on: Bool) -> Bool {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch, (try? device.lockForConfiguration()) != nil
        else { return false }
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
        return on
    }

    static func toggleTorch() -> Bool {
        setTorch(AVCaptureDevice.default(for: .video)?.torchMode != .on)
    }
}

@available(iOS 16, *)
private final class SystemScanner: Camera, DataScannerViewControllerDelegate {
    private let scanner: DataScannerViewController
    private let found: (String) -> Void

    init(in screen: UIViewController, found: @escaping (String) -> Void) {
        self.found = found
        scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: true, isGuidanceEnabled: false, isHighlightingEnabled: true)
        super.init()
        scanner.delegate = self
        screen.addChild(scanner)
        screen.view.addSubview(scanner.view)
        scanner.didMove(toParent: screen)
    }

    override func start() { try? scanner.startScanning() }
    override func stop() { scanner.stopScanning() }
    override func layout(in bounds: CGRect) { scanner.view.frame = bounds }

    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        for case let .barcode(code) in addedItems {
            if let text = code.payloadStringValue { found(text); return }
        }
    }
}

private final class CaptureScanner: Camera, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let preview: AVCaptureVideoPreviewLayer
    private let found: (String) -> Void

    init(in screen: UIViewController, found: @escaping (String) -> Void) {
        self.found = found
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init()
        preview.videoGravity = .resizeAspectFill
        screen.view.layer.addSublayer(preview)
        let output = AVCaptureMetadataOutput()
        if let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input), session.canAddOutput(output) {
            session.addInput(input)
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }
    }

    // startRunning blocks while the camera spins up, so off the main thread.
    override func start() { DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() } }
    override func stop() { session.stopRunning() }
    override func layout(in bounds: CGRect) { preview.frame = bounds }

    // Delivered on the main queue (set above).
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        let texts = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        MainActor.assumeIsolated {
            if let text = texts.first { found(text) }
        }
    }
}

/// The dim with its window, the gold brackets, the line above, the status below, Cancel and the torch.
private final class Overlay: UIView {
    let cancel = Overlay.round(title: "Cancel", symbol: nil)
    let torch = Overlay.round(title: nil, symbol: "flashlight.off.fill")
    private let dim = CAShapeLayer()
    private let brackets = CAShapeLayer()
    private let hint = UILabel()
    private let status = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        dim.fillRule = .evenOdd
        dim.fillColor = UIColor.black.withAlphaComponent(0.4).cgColor
        layer.addSublayer(dim)
        brackets.strokeColor = Brand.gold.cgColor
        brackets.fillColor = UIColor.clear.cgColor
        brackets.lineWidth = 4
        brackets.lineCap = .round
        layer.addSublayer(brackets)
        for (label, size) in [(hint, 17.0), (status, 15.0)] {
            label.textColor = .white
            label.font = .preferredFont(forTextStyle: size > 16 ? .body : .subheadline)
            label.adjustsFontForContentSizeCategory = true
            label.textAlignment = .center
            label.numberOfLines = 0
            addSubview(label)
        }
        hint.text = "Point at the sign-in code on the other screen"
        status.alpha = 0
        addSubview(cancel)
        addSubview(torch)
    }

    required init?(coder: NSCoder) { nil }

    /// The viewfinder: 70 % of the narrower side, centred.
    private var window_: CGRect {
        let side = min(bounds.width, bounds.height) * 0.7
        return CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let frame = window_
        let cut = UIBezierPath(rect: bounds)
        cut.append(UIBezierPath(roundedRect: frame, cornerRadius: 16))
        dim.path = cut.cgPath
        brackets.path = Overlay.corners(frame).cgPath
        let insets = safeAreaInsets
        hint.frame = CGRect(x: 24, y: frame.minY - 72, width: bounds.width - 48, height: 56)
        status.frame = CGRect(x: 24, y: frame.maxY + 20, width: bounds.width - 48, height: 48)
        cancel.frame = CGRect(x: 16, y: insets.top + 8, width: max(88, cancel.intrinsicContentSize.width + 24), height: 44)
        torch.frame = CGRect(x: bounds.width - 16 - 44, y: bounds.height - insets.bottom - 16 - 44, width: 44, height: 44)
        for button in [cancel, torch] {
            button.subviews.first { $0 is UIVisualEffectView }?.frame = button.bounds
        }
    }

    /// Only the buttons take touches; the rest falls through to the camera, so pinch to zoom works.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    /// A wrong code: said quietly, and the camera keeps looking.
    func say(_ line: String) {
        status.text = line
        UIView.animate(withDuration: 0.2) { self.status.alpha = 1 }
    }

    /// The hit: the brackets close into a solid frame.
    func hit() {
        status.alpha = 0
        brackets.path = UIBezierPath(roundedRect: window_, cornerRadius: 16).cgPath
        brackets.lineWidth = 6
    }

    func torchOn(_ on: Bool) {
        torch.setImage(UIImage(systemName: on ? "flashlight.on.fill" : "flashlight.off.fill"), for: .normal)
        torch.accessibilityValue = on ? "On" : "Off"
    }

    /// The four corners of the frame, each turning on the frame's own 16 pt radius, so the hit reads as the
    /// brackets closing rather than changing shape (Capping, #151).
    private static func corners(_ r: CGRect) -> UIBezierPath {
        let arm = r.width * 0.16, radius: CGFloat = 16, path = UIBezierPath()
        for (corner, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                 (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * radius))
            path.addQuadCurve(to: CGPoint(x: corner.x + dx * radius, y: corner.y), controlPoint: corner)
            path.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
        }
        return path
    }

    /// A 44 pt control on the material.
    private static func round(title: String?, symbol: String?) -> UIButton {
        let button = UIButton(type: .system)
        button.tintColor = .white
        if let title { button.setTitle(title, for: .normal); button.titleLabel?.font = .preferredFont(forTextStyle: .body) }
        if let symbol { button.setImage(UIImage(systemName: symbol), for: .normal); button.accessibilityLabel = "Torch" }
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        blur.isUserInteractionEnabled = false
        blur.layer.cornerRadius = 22
        blur.clipsToBounds = true
        button.insertSubview(blur, at: 0)
        return button
    }
}

/// The camera was refused: say so, and offer Settings, in 48 pt capsules.
private final class RefusedSheet: UIViewController {
    private var done: (@MainActor (String?) -> Void)?

    init(done: @escaping @MainActor (String?) -> Void) {
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Brand.night
        let line = UILabel()
        line.text = "Nectar needs the camera to scan a code."
        line.font = .preferredFont(forTextStyle: .title3)
        line.adjustsFontForContentSizeCategory = true
        line.textColor = .white
        line.numberOfLines = 0
        line.textAlignment = .center
        let settings = capsule("Open Settings", fill: Brand.gold, ink: Brand.goldInk, action: #selector(openSettings))
        let cancel = capsule("Cancel", fill: Brand.card, ink: .white, action: #selector(close))
        let stack = UIStackView(arrangedSubviews: [line, settings, cancel])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            settings.heightAnchor.constraint(equalToConstant: 48),
            cancel.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Dismissed by a swipe, a button or Settings: the scan is over either way.
        if let done { self.done = nil; done(nil) }
    }

    private func capsule(_ title: String, fill: UIColor, ink: UIColor, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.setTitleColor(ink, for: .normal)
        button.backgroundColor = fill
        button.layer.cornerRadius = 24
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        dismiss(animated: true)
    }

    @objc private func close() { dismiss(animated: true) }
}
