import AppKit
import ONVIFCore

final class DeviceEntry {
    let id: String
    var url: URL
    var discovered: DiscoveredDevice?
    var name: String
    var host: String
    var model: String = ""
    var credentials: Credentials?
    var report: DeviceReport?
    var status: String = ""
    var statusIsError = false
    var isLoading = false
    var isManual = false

    /// Keychain keys for this device's saved credentials.
    var credentialKeys: [String] {
        CredentialStore.keys(endpoint: discovered?.endpointReference, url: url)
    }

    init(id: String, url: URL, name: String, host: String) {
        self.id = id
        self.url = url
        self.name = name
        self.host = host
    }
}

@MainActor
final class MainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
    NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {

    private var entries: [DeviceEntry] = []
    private var reportRoots: [ReportNode] = []

    private let deviceTable = NSTableView()
    private let outline = NSOutlineView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let headerLabel = NSTextField(labelWithString: "Оберіть пристрій")
    private var scanButton: NSButton?

    private var busyCount = 0
    private var isScanning = false
    private var lastUsername: String = UserDefaults.standard.string(forKey: "lastUsername") ?? "admin"
    private var rememberPasswords: Bool = (UserDefaults.standard.object(forKey: "rememberPasswords") as? Bool) ?? true

    convenience init(title: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.minSize = NSSize(width: 860, height: 460)
        self.init(window: window)
        buildUI()
        restoreManualDevices()
        window.center()
        window.setFrameAutosaveName("ONVIFBrowserMainWindow")
    }

    // MARK: - Layout

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let left = makeLeftPane()
        let right = makeRightPane()
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)
        split.setHoldingPriority(NSLayoutConstraint.Priority(rawValue: 260), forSubviewAt: 0)
        split.setHoldingPriority(NSLayoutConstraint.Priority(rawValue: 250), forSubviewAt: 1)

        let preferred = left.widthAnchor.constraint(equalToConstant: 560)
        preferred.priority = NSLayoutConstraint.Priority(rawValue: 200)
        NSLayoutConstraint.activate([
            left.widthAnchor.constraint(greaterThanOrEqualToConstant: 470),
            right.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
            preferred,
        ])
    }

    private func makeLeftPane() -> NSView {
        let pane = NSView()

        let scanBtn = NSButton(title: "Пошук", target: self, action: #selector(MainWindowController.scan(_:)))
        scanButton = scanBtn
        let addBtn = NSButton(title: "Додати…", target: self, action: #selector(MainWindowController.addManually(_:)))
        let loginBtn = NSButton(title: "Вхід…", target: self, action: #selector(MainWindowController.login(_:)))
        let loginAllBtn = NSButton(title: "Вхід для всіх…", target: self, action: #selector(MainWindowController.loginAll(_:)))
        let buttons = NSStackView(views: [scanBtn, addBtn, loginBtn, loginAllBtn])
        buttons.orientation = .horizontal
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false

        for (id, title, width) in [("name", "Назва", 130.0), ("host", "IP", 120.0),
                                   ("model", "Модель", 120.0), ("status", "Стан", 90.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = CGFloat(width)
            column.minWidth = id == "host" ? 112 : 60
            deviceTable.addTableColumn(column)
        }
        deviceTable.dataSource = self
        deviceTable.delegate = self
        deviceTable.usesAlternatingRowBackgroundColors = true
        deviceTable.allowsMultipleSelection = false
        deviceTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        deviceTable.target = self
        deviceTable.doubleAction = #selector(MainWindowController.login(_:))

        let scroll = NSScrollView()
        scroll.documentView = deviceTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 6
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        pane.addSubview(buttons)
        pane.addSubview(scroll)
        pane.addSubview(statusRow)
        NSLayoutConstraint.activate([
            buttons.topAnchor.constraint(equalTo: pane.topAnchor, constant: 10),
            buttons.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 10),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: pane.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -6),
            statusRow.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            statusRow.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 10),
            statusRow.trailingAnchor.constraint(lessThanOrEqualTo: pane.trailingAnchor, constant: -10),
            statusRow.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -8),
        ])
        return pane
    }

    private func makeRightPane() -> NSView {
        let pane = NSView()

        headerLabel.font = NSFont.boldSystemFont(ofSize: 14)
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let expandBtn = NSButton(title: "Розгорнути", target: self, action: #selector(MainWindowController.expandAll(_:)))
        let collapseBtn = NSButton(title: "Згорнути", target: self, action: #selector(MainWindowController.collapseAll(_:)))
        let copyBtn = NSButton(title: "Копіювати звіт", target: self, action: #selector(MainWindowController.copyReport(_:)))
        let saveBtn = NSButton(title: "Зберегти…", target: self, action: #selector(MainWindowController.saveReport(_:)))
        let top = NSStackView(views: [headerLabel, expandBtn, collapseBtn, copyBtn, saveBtn])
        top.orientation = .horizontal
        top.spacing = 6
        top.translatesAutoresizingMaskIntoConstraints = false

        let keyColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key"))
        keyColumn.title = "Параметр"
        keyColumn.width = 300
        keyColumn.minWidth = 120
        let valueColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        valueColumn.title = "Значення"
        valueColumn.width = 420
        valueColumn.minWidth = 120
        outline.addTableColumn(keyColumn)
        outline.addTableColumn(valueColumn)
        outline.outlineTableColumn = keyColumn
        outline.dataSource = self
        outline.delegate = self
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = true
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.target = self
        outline.doubleAction = #selector(MainWindowController.reportDoubleClicked(_:))
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        outline.menu = contextMenu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        pane.addSubview(top)
        pane.addSubview(scroll)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: pane.topAnchor, constant: 10),
            top.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 6),
            top.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -10),
        ])
        return pane
    }

    // MARK: - Status

    private func setBusy(_ delta: Int) {
        busyCount = max(0, busyCount + delta)
        if busyCount > 0 { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.toolTip = text
    }

    // MARK: - Actions

    @objc func scan(_ sender: Any?) {
        guard !isScanning else { return }
        isScanning = true
        scanButton?.isEnabled = false
        setBusy(1)
        setStatus("Пошук пристроїв у мережі…")
        Task {
            let found = await WSDiscovery.probe(timeout: 4)
            self.merge(found)
            self.isScanning = false
            self.scanButton?.isEnabled = true
            self.setBusy(-1)
            self.setStatus("Знайдено пристроїв: \(found.count). Усього у списку: \(self.entries.count)")
        }
    }

    @objc func addManually(_ sender: Any?) {
        guard let window = window else { return }
        let alert = NSAlert()
        alert.messageText = "Додати пристрій"
        alert.informativeText = "IP-адреса, адреса з портом (192.168.1.10:8080) або повний URL device service."
        alert.addButton(withTitle: "Додати")
        alert.addButton(withTitle: "Скасувати")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "192.168.1.10"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            guard let url = DeviceAddress.url(from: field.stringValue) else {
                NSSound.beep()
                return
            }
            let entry: DeviceEntry
            if let existing = self.entries.first(where: { $0.url == url }) {
                entry = existing
            } else {
                entry = self.makeManualEntry(url)
                self.entries.append(entry)
                self.deviceTable.reloadData()
            }
            ManualDevices.add(url)
            if let row = self.entries.firstIndex(where: { $0 === entry }) {
                self.deviceTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                self.deviceTable.scrollRowToVisible(row)
            }
            // Open the next sheet once this one has fully closed.
            DispatchQueue.main.async {
                self.askCredentials(title: "Вхід: \(entry.name)",
                                    prefill: CredentialStore.load(keys: entry.credentialKeys)) { credentials, remember in
                    self.load(entry, credentials: credentials, remember: remember)
                }
            }
        }
    }

    @objc func login(_ sender: Any?) {
        if let table = sender as? NSTableView, table.clickedRow < 0 { return }
        guard let entry = selectedEntry else {
            NSSound.beep()
            setStatus("Спочатку оберіть пристрій у списку")
            return
        }
        let saved = entry.credentials ?? CredentialStore.load(keys: entry.credentialKeys)
        askCredentials(title: "Вхід: \(entry.name) (\(entry.host))", prefill: saved) { credentials, remember in
            self.load(entry, credentials: credentials, remember: remember)
        }
    }

    @objc func loginAll(_ sender: Any?) {
        guard !entries.isEmpty else {
            NSSound.beep()
            return
        }
        askCredentials(title: "Вхід для всіх пристроїв (\(entries.count))", prefill: nil) { credentials, remember in
            for entry in self.entries { self.load(entry, credentials: credentials, remember: remember) }
        }
    }

    @objc func forgetPassword(_ sender: Any?) {
        guard let entry = selectedEntry else {
            NSSound.beep()
            return
        }
        CredentialStore.delete(keys: entry.credentialKeys)
        setStatus("Пароль для \(entry.host) видалено зі зв'язки ключів")
    }

    @objc func forgetAllPasswords(_ sender: Any?) {
        guard let window = window else { return }
        let alert = NSAlert()
        alert.messageText = "Видалити всі збережені паролі?"
        alert.informativeText = "Усі логіни й паролі камер, збережені ONVIF Browser у зв'язці ключів, буде видалено."
        alert.addButton(withTitle: "Видалити")
        alert.addButton(withTitle: "Скасувати")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            CredentialStore.deleteAll()
            self.setStatus("Усі збережені паролі видалено")
        }
    }

    @objc func removeDevice(_ sender: Any?) {
        guard let entry = selectedEntry, let row = entries.firstIndex(where: { $0 === entry }) else {
            NSSound.beep()
            return
        }
        ManualDevices.remove(entry.url)
        entries.remove(at: row)
        deviceTable.reloadData()
        if !entries.isEmpty {
            deviceTable.selectRowIndexes(IndexSet(integer: min(row, entries.count - 1)), byExtendingSelection: false)
        }
        showSelected()
        setStatus("\(entry.host) прибрано зі списку")
    }

    @objc func copyReport(_ sender: Any?) {
        guard let text = currentReportText() else {
            NSSound.beep()
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        setStatus("Звіт скопійовано в буфер обміну")
    }

    @objc func saveReport(_ sender: Any?) {
        guard let window = window, let text = currentReportText(), let entry = selectedEntry else {
            NSSound.beep()
            return
        }
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["txt"]
        let safeName = entry.name.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "ONVIF \(safeName) \(entry.host).txt"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                self.setStatus("Збережено: \(url.path)")
            } catch {
                NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    @objc func expandAll(_ sender: Any?) {
        outline.expandItem(nil, expandChildren: true)
    }

    @objc func collapseAll(_ sender: Any?) {
        outline.collapseItem(nil, collapseChildren: true)
    }

    /// Cmd+C: copies the selected report rows, or the device URL when the device list has focus.
    @objc func copy(_ sender: Any?) {
        var text = ""
        if window?.firstResponder === deviceTable {
            text = selectedEntry?.url.absoluteString ?? ""
        } else {
            text = outline.selectedRowIndexes
                .compactMap { outline.item(atRow: $0) as? ReportNode }
                .map { $0.value.isEmpty ? $0.title : "\($0.title): \($0.value)" }
                .joined(separator: "\n")
        }
        guard !text.isEmpty else {
            NSSound.beep()
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Streams and snapshots

    private func isStream(_ node: ReportNode) -> Bool {
        node.value.lowercased().hasPrefix("rtsp://")
    }

    private func isSnapshot(_ node: ReportNode) -> Bool {
        node.title.contains("Snapshot") && node.value.lowercased().hasPrefix("http")
    }

    @objc func reportDoubleClicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? ReportNode else { return }
        if isStream(node) {
            openStream(node.value)
        } else if isSnapshot(node) {
            showSnapshot(node.value)
        } else if outline.isExpandable(node) {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? ReportNode else { return }
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = node
            menu.addItem(item)
        }
        if isStream(node) {
            add("Відкрити потік у VLC", #selector(MainWindowController.menuOpenStream(_:)))
            add("Копіювати URL з логіном і паролем", #selector(MainWindowController.menuCopyAuthURL(_:)))
        }
        if isSnapshot(node) {
            add("Показати знімок", #selector(MainWindowController.menuShowSnapshot(_:)))
            add("Копіювати URL з логіном і паролем", #selector(MainWindowController.menuCopyAuthURL(_:)))
        }
        add("Копіювати значення", #selector(MainWindowController.menuCopyValue(_:)))
        add("Копіювати рядок", #selector(MainWindowController.menuCopyRow(_:)))
    }

    @objc func menuOpenStream(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? ReportNode else { return }
        openStream(node.value)
    }

    @objc func menuShowSnapshot(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? ReportNode else { return }
        showSnapshot(node.value)
    }

    @objc func menuCopyAuthURL(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? ReportNode,
              let url = StreamURL.withCredentials(node.value, selectedEntry?.credentials) else { return }
        putOnPasteboard(url.absoluteString)
    }

    @objc func menuCopyValue(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? ReportNode else { return }
        putOnPasteboard(node.value.isEmpty ? node.title : node.value)
    }

    @objc func menuCopyRow(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? ReportNode else { return }
        putOnPasteboard(node.value.isEmpty ? node.title : "\(node.title): \(node.value)")
    }

    private func putOnPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        setStatus("Скопійовано")
    }

    private func openStream(_ uri: String) {
        guard let url = StreamURL.withCredentials(uri, selectedEntry?.credentials) else {
            NSSound.beep()
            return
        }
        let vlcID = "org.videolan.vlc"
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: vlcID) != nil {
            NSWorkspace.shared.open([url], withAppBundleIdentifier: vlcID, options: [],
                                    additionalEventParamDescriptor: nil, launchIdentifiers: nil)
            setStatus("Потік відкрито у VLC")
        } else if NSWorkspace.shared.open(url) {
            setStatus("Потік передано програмі, що обробляє rtsp://")
        } else {
            putOnPasteboard(url.absoluteString)
            guard let window = window else { return }
            let alert = NSAlert()
            alert.messageText = "Не знайдено програми для перегляду RTSP"
            alert.informativeText = "Встановіть VLC (videolan.org). URL потоку з логіном і паролем скопійовано в буфер обміну."
            alert.beginSheetModal(for: window, completionHandler: nil)
        }
    }

    private func showSnapshot(_ uri: String) {
        guard let url = URL(string: uri.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            NSSound.beep()
            return
        }
        let name = selectedEntry.map { "\($0.name) (\($0.host))" } ?? "Знімок"
        SnapshotWindowController.show(title: "Знімок: \(name)", url: url, credentials: selectedEntry?.credentials)
    }

    // MARK: - Logic

    private var selectedEntry: DeviceEntry? {
        let row = deviceTable.selectedRow
        return row >= 0 && row < entries.count ? entries[row] : nil
    }

    private func merge(_ found: [DiscoveredDevice]) {
        let selectedID = selectedEntry?.id
        var newEntries: [DeviceEntry] = []
        for device in found {
            guard let url = device.serviceURL else { continue }
            let id = device.endpointReference.isEmpty ? url.absoluteString : device.endpointReference
            if let existing = entries.first(where: { $0.id == id || $0.url == url }) {
                existing.discovered = device
                existing.host = device.sourceAddress
                if existing.report == nil { existing.url = url }
            } else {
                let entry = DeviceEntry(id: id, url: url,
                                        name: device.name ?? device.sourceAddress,
                                        host: device.sourceAddress)
                entry.discovered = device
                entry.model = device.hardware ?? ""
                entry.status = "Знайдено"
                entries.append(entry)
                newEntries.append(entry)
            }
        }
        entries.sort { a, b in
            DeviceAddress.sortKey(a.host) < DeviceAddress.sortKey(b.host)
        }
        deviceTable.reloadData()
        if let id = selectedID, let row = entries.firstIndex(where: { $0.id == id }) {
            deviceTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if deviceTable.selectedRow < 0, !entries.isEmpty {
            deviceTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        showSelected()
        for entry in newEntries { autoLogin(entry) }
    }

    private func makeManualEntry(_ url: URL) -> DeviceEntry {
        let host = url.host ?? url.absoluteString
        let entry = DeviceEntry(id: url.absoluteString, url: url, name: host, host: host)
        entry.isManual = true
        entry.status = "Додано вручну"
        return entry
    }

    private func restoreManualDevices() {
        for url in ManualDevices.urls where !entries.contains(where: { $0.url == url }) {
            entries.append(makeManualEntry(url))
        }
        deviceTable.reloadData()
        for entry in entries { autoLogin(entry) }
    }

    /// Connects with the password saved in the keychain, if there is one.
    private func autoLogin(_ entry: DeviceEntry) {
        guard entry.report == nil, !entry.isLoading,
              let saved = CredentialStore.load(keys: entry.credentialKeys) else { return }
        load(entry, credentials: saved, remember: false, fromKeychain: true)
    }

    private func askCredentials(title: String, prefill: Credentials?,
                                completion: @escaping (Credentials, Bool) -> Void) {
        guard let window = window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Логін і пароль ONVIF-користувача камери. Залиште логін порожнім для доступу без авторизації."
        alert.addButton(withTitle: "Підключитись")
        alert.addButton(withTitle: "Скасувати")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 86))
        let userLabel = NSTextField(labelWithString: "Логін:")
        userLabel.frame = NSRect(x: 0, y: 62, width: 70, height: 20)
        let user = NSTextField(frame: NSRect(x: 75, y: 60, width: 245, height: 24))
        user.stringValue = prefill?.username ?? lastUsername
        let passLabel = NSTextField(labelWithString: "Пароль:")
        passLabel.frame = NSRect(x: 0, y: 32, width: 70, height: 20)
        let pass = NSSecureTextField(frame: NSRect(x: 75, y: 30, width: 245, height: 24))
        pass.stringValue = prefill?.password ?? ""
        let remember = NSButton(checkboxWithTitle: "Запам'ятати пароль у зв'язці ключів", target: nil, action: nil)
        remember.frame = NSRect(x: 73, y: 2, width: 247, height: 20)
        remember.state = rememberPasswords ? .on : .off
        for v in [userLabel, user, passLabel, pass, remember] { container.addSubview(v) }
        user.nextKeyView = pass
        pass.nextKeyView = remember
        remember.nextKeyView = user
        alert.accessoryView = container
        alert.window.initialFirstResponder = user.stringValue.isEmpty ? user : pass

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let username = user.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            self.lastUsername = username
            UserDefaults.standard.set(username, forKey: "lastUsername")
            self.rememberPasswords = remember.state == .on
            UserDefaults.standard.set(self.rememberPasswords, forKey: "rememberPasswords")
            completion(Credentials(username: username, password: pass.stringValue), self.rememberPasswords)
        }
    }

    private func load(_ entry: DeviceEntry, credentials: Credentials, remember: Bool, fromKeychain: Bool = false) {
        guard !entry.isLoading else { return }
        entry.credentials = credentials.isEmpty ? nil : credentials
        entry.isLoading = true
        entry.status = "Завантаження…"
        entry.statusIsError = false
        refresh(entry)
        setBusy(1)
        setStatus(fromKeychain ? "Підключення до \(entry.host) зі збереженим паролем…" : "Підключення до \(entry.host)…")

        Task {
            let report = await DeviceReporter.build(url: entry.url, credentials: entry.credentials)
            entry.isLoading = false
            entry.report = report
            if report.authFailed {
                entry.status = fromKeychain ? "Збережений пароль не підходить" : "Невірний логін"
                entry.statusIsError = true
            } else if let s = report.summary {
                entry.status = "OK"
                if remember, !credentials.isEmpty {
                    // Saved only after a successful login, so a mistyped password is never stored.
                    CredentialStore.save(credentials, keys: entry.credentialKeys)
                } else if !remember, !fromKeychain {
                    // The user unticked "remember": drop a password saved earlier.
                    CredentialStore.delete(keys: entry.credentialKeys)
                }
                entry.model = [s.manufacturer, s.model].filter { !$0.isEmpty }.joined(separator: " ")
                if entry.discovered?.name == nil {
                    entry.name = entry.model.isEmpty ? entry.host : entry.model
                }
            } else {
                entry.status = "Помилка"
                entry.statusIsError = true
            }
            self.refresh(entry)
            self.setBusy(-1)
            self.setStatus("\(entry.host): \(entry.status)")
        }
    }

    private func refresh(_ entry: DeviceEntry) {
        guard let row = entries.firstIndex(where: { $0 === entry }) else { return }
        deviceTable.reloadData(forRowIndexes: IndexSet(integer: row),
                               columnIndexes: IndexSet(integersIn: 0..<deviceTable.numberOfColumns))
        if selectedEntry === entry { showSelected() }
    }

    private func showSelected() {
        guard let entry = selectedEntry else {
            headerLabel.stringValue = "Оберіть пристрій"
            reportRoots = []
            outline.reloadData()
            return
        }
        headerLabel.stringValue = entry.name == entry.host ? entry.host : "\(entry.name) — \(entry.host)"
        if let report = entry.report, !entry.isLoading {
            reportRoots = report.sections
        } else {
            var roots: [ReportNode] = []
            let hint = entry.isLoading
                ? "Завантаження даних з пристрою…"
                : "Натисніть «Вхід…» або двічі клацніть пристрій, щоб отримати повний опис"
            roots.append(ReportNode("Підказка", hint))
            if let d = entry.discovered { roots += DeviceReporter.discoveryReport(d) }
            let addr = ReportNode("Device service", entry.url.absoluteString)
            roots.append(addr)
            reportRoots = roots
        }
        outline.reloadData()
        for root in reportRoots { outline.expandItem(root) }
    }

    private func currentReportText() -> String? {
        guard let entry = selectedEntry, !reportRoots.isEmpty else { return nil }
        let header = "ONVIF-звіт: \(entry.name) (\(entry.host))\nСтворено: \(Date())\n\n"
        return header + reportRoots.map { $0.renderText() }.joined(separator: "\n")
    }

    // MARK: - Cells

    private func cell(in tableView: NSTableView, id: String, text: String,
                      color: NSColor = .labelColor, bold: Bool = false) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier(id)
        let view: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            view = reused
        } else {
            view = NSTableCellView()
            view.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.addSubview(field)
            view.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
        }
        view.textField?.stringValue = text
        view.textField?.textColor = color
        view.textField?.font = bold
            ? NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
            : NSFont.systemFont(ofSize: NSFont.systemFontSize)
        view.textField?.toolTip = text.isEmpty ? nil : text
        return view
    }

    // MARK: - Device table

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === deviceTable ? entries.count : 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tableView === deviceTable, row < entries.count, let column = tableColumn?.identifier.rawValue else {
            return nil
        }
        let e = entries[row]
        switch column {
        case "name": return cell(in: tableView, id: "dev-name", text: e.name)
        case "host": return cell(in: tableView, id: "dev-host", text: e.host)
        case "model": return cell(in: tableView, id: "dev-model", text: e.model)
        default:
            return cell(in: tableView, id: "dev-status", text: e.status,
                        color: e.statusIsError ? .systemRed : .secondaryLabelColor)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) === deviceTable else { return }
        showSelected()
    }

    // MARK: - Report outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? ReportNode { return node.children.count }
        return reportRoots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? ReportNode { return node.children[index] }
        return reportRoots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? ReportNode else { return false }
        return !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ReportNode else { return nil }
        let color: NSColor = node.isError ? .systemRed : .labelColor
        if tableColumn?.identifier.rawValue == "value" {
            let isLink = !node.isError && (isStream(node) || isSnapshot(node))
            let view = cell(in: outlineView, id: "rep-value", text: node.value, color: isLink ? .linkColor : color)
            if isLink {
                (view as? NSTableCellView)?.textField?.toolTip = node.value + "\nПодвійний клік — відкрити, правий клік — інші дії"
            }
            return view
        }
        return cell(in: outlineView, id: "rep-key", text: node.title, color: color,
                    bold: outlineView.level(forItem: node) == 0)
    }
}
