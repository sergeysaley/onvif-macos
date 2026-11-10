import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        let controller = MainWindowController(title: "ONVIF Browser")
        windowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.scan(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Про ONVIF Browser",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Сховати ONVIF Browser", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Завершити ONVIF Browser", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Редагування")
        editMenu.addItem(withTitle: "Вирізати", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Копіювати", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Вставити", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Виділити все", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let devicesItem = NSMenuItem()
        main.addItem(devicesItem)
        let devicesMenu = NSMenu(title: "Пристрої")
        devicesMenu.addItem(withTitle: "Пошук у мережі", action: #selector(MainWindowController.scan(_:)), keyEquivalent: "r")
        devicesMenu.addItem(withTitle: "Додати за адресою…", action: #selector(MainWindowController.addManually(_:)), keyEquivalent: "n")
        devicesMenu.addItem(NSMenuItem.separator())
        devicesMenu.addItem(withTitle: "Вхід…", action: #selector(MainWindowController.login(_:)), keyEquivalent: "l")
        devicesMenu.addItem(withTitle: "Вхід для всіх…", action: #selector(MainWindowController.loginAll(_:)), keyEquivalent: "")
        devicesMenu.addItem(withTitle: "Забути пароль пристрою", action: #selector(MainWindowController.forgetPassword(_:)), keyEquivalent: "")
        devicesMenu.addItem(withTitle: "Забути всі паролі…", action: #selector(MainWindowController.forgetAllPasswords(_:)), keyEquivalent: "")
        devicesMenu.addItem(withTitle: "Прибрати зі списку", action: #selector(MainWindowController.removeDevice(_:)), keyEquivalent: "")
        devicesMenu.addItem(NSMenuItem.separator())
        devicesMenu.addItem(withTitle: "Копіювати звіт", action: #selector(MainWindowController.copyReport(_:)), keyEquivalent: "C")
        devicesMenu.addItem(withTitle: "Зберегти звіт…", action: #selector(MainWindowController.saveReport(_:)), keyEquivalent: "s")
        devicesItem.submenu = devicesMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Вікно")
        windowMenu.addItem(withTitle: "Згорнути", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Закрити", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        return main
    }
}
