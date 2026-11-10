import AppKit
import ONVIFCore

/// Shows a JPEG snapshot fetched from a camera's Snapshot URI.
@MainActor
final class SnapshotWindowController: NSWindowController, NSWindowDelegate {
    private static var openControllers: [SnapshotWindowController] = []

    private let imageView = NSImageView()
    private let messageLabel = NSTextField(labelWithString: "Завантаження…")
    private var url: URL?
    private var credentials: Credentials?

    static func show(title: String, url: URL, credentials: Credentials?) {
        let controller = SnapshotWindowController(title: title, url: url, credentials: credentials)
        openControllers.append(controller)
        controller.showWindow(nil)
        controller.reload(nil)
    }

    convenience init(title: String, url: URL, credentials: Credentials?) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.minSize = NSSize(width: 320, height: 240)
        window.isReleasedWhenClosed = false
        self.init(window: window)
        self.url = url
        self.credentials = credentials
        window.delegate = self
        buildUI()
        window.center()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 0
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        let refresh = NSButton(title: "Оновити", target: self, action: #selector(SnapshotWindowController.reload(_:)))
        let copyURL = NSButton(title: "Копіювати URL", target: self, action: #selector(SnapshotWindowController.copyURL(_:)))
        let buttons = NSStackView(views: [refresh, copyURL])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(imageView)
        content.addSubview(messageLabel)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: content.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),
            messageLabel.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: imageView.widthAnchor, constant: -40),
            buttons.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
    }

    @objc func reload(_ sender: Any?) {
        guard let url = url else { return }
        messageLabel.stringValue = "Завантаження…"
        messageLabel.isHidden = false
        Task {
            do {
                let data = try await HTTPFetch.get(url, credentials: self.credentials)
                guard let image = NSImage(data: data) else {
                    self.messageLabel.stringValue = "Камера повернула не зображення (\(data.count) байт)"
                    return
                }
                let firstImage = self.imageView.image == nil
                self.imageView.image = image
                self.messageLabel.isHidden = true
                if firstImage { self.fit(image) }
            } catch {
                self.messageLabel.stringValue = describeError(error)
            }
        }
    }

    @objc func copyURL(_ sender: Any?) {
        guard let url = url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    /// Resizes the window to the image aspect ratio, limited to 70% of the screen.
    private func fit(_ image: NSImage) {
        guard let window = window, image.size.width > 0, image.size.height > 0 else { return }
        var pixelSize = image.size
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            pixelSize = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        let screen = window.screen?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        let scale = min(1, screen.width * 0.7 / pixelSize.width, screen.height * 0.7 / pixelSize.height)
        window.setContentSize(NSSize(width: max(320, pixelSize.width * scale),
                                     height: max(240, pixelSize.height * scale + 44)))
        window.title += " — \(Int(pixelSize.width))×\(Int(pixelSize.height))"
        window.center()
    }

    func windowWillClose(_ notification: Notification) {
        SnapshotWindowController.openControllers.removeAll { $0 === self }
    }
}
