// MainMenuInstaller — installs a standard NSApp.mainMenu so that
// keyboard shortcuts (⌘V, ⌘X, ⌘C, ⌘A, ⌘Z, ⌘⇧Z, ⌘Q) route through
// the responder chain to focused text fields.
//
// Why this is needed
// ------------------
// Parleq is an `LSUIElement` (accessory-policy) app — there is no Dock
// icon and no top-of-screen menu bar drawn for it. SwiftUI text fields
// inside the Setup Wizard and Settings windows still rely on the
// standard AppKit responder chain to translate ⌘V into `paste:`,
// ⌘X into `cut:`, etc. AppKit's key-equivalent matching walks
// `NSApp.mainMenu` looking for a menu item whose `keyEquivalent`
// matches the keystroke, then sends that item's action up the
// responder chain. With no `mainMenu` installed, no key-equivalent
// match ever happens, so ⌘V is silently dropped at the system level.
// (The right-click context menu on `NSTextView` works because that
// menu builds its own items independently of `mainMenu` — that path
// doesn't depend on this code at all.)
//
// What this installs
// ------------------
// A minimal two-submenu structure:
//
//   1. Application menu (leftmost; AppKit treats whatever is at
//      index 0 as the app menu). Just About + Hide + Quit so the
//      standard ⌘Q / ⌘H / ⌘⌥H shortcuts work.
//   2. Edit menu — Undo, Redo, Cut, Copy, Paste, Select All. Each
//      item has `target = nil` so the action selector travels up the
//      responder chain to whatever NSTextView / NSText subclass
//      currently holds first responder.
//
// For an LSUIElement app the menu bar is not drawn, so users never
// see this UI; it exists purely so the keystrokes work.
//
// What this DOESN'T install
// -------------------------
// No File / View / Window menus. Parleq has no document concept and
// the wizard/Settings windows close via the standard NSWindow close
// button (or the Finish/Skip buttons in the wizard); we don't need
// ⌘W. Adding more menus would be scope creep relative to the
// reported bug (#24).

import AppKit

/// Builds and assigns `NSApp.mainMenu` with App + Edit submenus so
/// standard text-editing keystrokes (⌘V etc.) work. Idempotent —
/// safe to call multiple times; later calls just replace the menu.
@MainActor
public func installApplicationMainMenu() {
    let mainMenu = NSMenu()

    // ----- Application submenu (slot 0). -----
    let appName = ProcessInfo.processInfo.processName
    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu(title: appName)

    appMenu.addItem(
        NSMenuItem(
            title: "About \(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
    )
    appMenu.addItem(.separator())

    let hideItem = NSMenuItem(
        title: "Hide \(appName)",
        action: #selector(NSApplication.hide(_:)),
        keyEquivalent: "h"
    )
    appMenu.addItem(hideItem)

    let hideOthersItem = NSMenuItem(
        title: "Hide Others",
        action: #selector(NSApplication.hideOtherApplications(_:)),
        keyEquivalent: "h"
    )
    hideOthersItem.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(hideOthersItem)

    appMenu.addItem(
        NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
    )
    appMenu.addItem(.separator())

    appMenu.addItem(
        NSMenuItem(
            title: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
    )

    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    // ----- Edit submenu (the actual fix for #24). -----
    let editMenuItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")

    // Undo / Redo — first responder gets the message via the
    // responder chain. NSTextView implements both.
    editMenu.addItem(
        makeResponderItem(title: "Undo", selector: Selector(("undo:")), keyEquivalent: "z")
    )
    let redoItem = makeResponderItem(title: "Redo", selector: Selector(("redo:")), keyEquivalent: "z")
    redoItem.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(redoItem)
    editMenu.addItem(.separator())

    editMenu.addItem(
        makeResponderItem(title: "Cut", selector: #selector(NSText.cut(_:)), keyEquivalent: "x")
    )
    editMenu.addItem(
        makeResponderItem(title: "Copy", selector: #selector(NSText.copy(_:)), keyEquivalent: "c")
    )
    editMenu.addItem(
        makeResponderItem(title: "Paste", selector: #selector(NSText.paste(_:)), keyEquivalent: "v")
    )
    editMenu.addItem(
        makeResponderItem(
            title: "Select All",
            selector: #selector(NSResponder.selectAll(_:)),
            keyEquivalent: "a"
        )
    )

    editMenuItem.submenu = editMenu
    mainMenu.addItem(editMenuItem)

    NSApp.mainMenu = mainMenu
}

/// Makes a menu item whose action travels up the responder chain
/// (target=nil). Cleaner than building each item inline with the
/// nil target spelled out repeatedly.
@MainActor
private func makeResponderItem(title: String, selector: Selector, keyEquivalent: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: selector, keyEquivalent: keyEquivalent)
    item.target = nil
    return item
}
