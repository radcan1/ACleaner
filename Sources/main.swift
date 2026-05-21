import Cocoa
import SwiftUI

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// Handles the "Privacy & Permissions" menu item — posts a notification that
// RootView receives to re-open the permissions sheet.
class MenuHandler: NSObject {
    @objc func openPermissions(_ sender: Any?) {
        NotificationCenter.default.post(name: .acleanerShowPermissions, object: nil)
    }
}
let menuHandler = MenuHandler()

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var cleanState: AppState!

    func applicationDidFinishLaunching(_ notification: Notification) {
        cleanState = AppState()
        cleanState.startWatching()
        cleanState.loginItemEnabled = LoginItem.isEnabled

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ACleaner"
        window.minSize = NSSize(width: 820, height: 540)
        window.center()
        window.contentView = NSHostingView(rootView: RootView(cleanState: cleanState))
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for w in sender.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil) }
        }
        return true
    }
}

let delegate = AppDelegate()
app.delegate = delegate

// MARK: - Menu bar

let menu = NSMenu()

let appItem = NSMenuItem()
menu.addItem(appItem)
let appMenu = NSMenu()
appItem.submenu = appMenu
appMenu.addItem(NSMenuItem(
    title: "About ACleaner",
    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
    keyEquivalent: ""
))
appMenu.addItem(.separator())
let permItem = NSMenuItem(
    title: "Privacy & Permissions\u{2026}",
    action: #selector(MenuHandler.openPermissions(_:)),
    keyEquivalent: ""
)
permItem.target = menuHandler
appMenu.addItem(permItem)
appMenu.addItem(.separator())
appMenu.addItem(NSMenuItem(
    title: "Quit ACleaner",
    action: #selector(NSApplication.terminate(_:)),
    keyEquivalent: "q"
))

let editItem = NSMenuItem()
menu.addItem(editItem)
let editMenu = NSMenu(title: "Edit")
editItem.submenu = editMenu
editMenu.addItem(NSMenuItem(title: "Copy",       action: #selector(NSText.copy(_:)),      keyEquivalent: "c"))
editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

app.mainMenu = menu

app.run()
