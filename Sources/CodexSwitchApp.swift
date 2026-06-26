import AppKit
import SwiftUI

@main
struct CodexSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() } // no windows — this is a menu-bar-only (LSUIElement) app
    }
}

/// Owns the status-bar item and builds a standard macOS menu on demand.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = AccountStore()
    private let usageStore = UsageStore()
    private var statusItem: NSStatusItem!
    private var isMenuOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isAnotherInstanceRunning else {
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.menuBarIcon
        statusItem.button?.toolTip = "Codex Switch"

        let menu = NSMenu()
        menu.delegate = self // rebuild every time it opens → always fresh
        statusItem.menu = menu

        usageStore.onChange = { [weak self] in
            guard let self,
                  !self.isMenuOpen,
                  let menu = self.statusItem.menu,
                  menu.numberOfItems > 0
            else { return }
            self.menuNeedsUpdate(menu)
        }
        usageStore.startAutoRefresh { [weak self] in
            self?.store.reload()
            return self?.store.accounts ?? []
        }
    }

    // MARK: - Build the menu (called each time it's about to open)

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        store.reload()
        usageStore.refreshIfNeeded(accounts: store.accounts)
        menu.removeAllItems()

        if store.accounts.isEmpty {
            let empty = NSMenuItem(title: "No Accounts", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for account in store.accounts {
                let item = NSMenuItem(title: account.email,
                                      action: #selector(switchAccount(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = account.email
                item.state = store.isActive(account) ? .on : .off // native checkmark
                menu.addItem(item)
                addUsageItems(for: account, to: menu)
            }
        }

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: usageStore.isRefreshing ? "Refreshing..." : "Refresh",
                                 action: #selector(refreshUsage),
                                 keyEquivalent: "r")
        refresh.target = self
        refresh.isEnabled = !usageStore.isRefreshing && !store.accounts.isEmpty
        menu.addItem(refresh)

        let lastRefreshed = NSMenuItem(title: lastRefreshedTitle, action: nil, keyEquivalent: "")
        lastRefreshed.isEnabled = false
        menu.addItem(lastRefreshed)

        menu.addItem(.separator())

        let add = NSMenuItem(title: "Add Account…", action: #selector(addAccount), keyEquivalent: "n")
        add.target = self
        menu.addItem(add)

        if !store.accounts.isEmpty {
            let remove = NSMenuItem(title: "Remove Account", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for account in store.accounts {
                let isActive = store.isActive(account)
                let title = isActive ? "\(account.email) (Active)" : account.email
                let r = NSMenuItem(title: title,
                                   action: isActive ? nil : #selector(removeAccount(_:)),
                                   keyEquivalent: "")
                r.target = self
                r.representedObject = account.email
                r.isEnabled = !isActive
                sub.addItem(r)
            }
            remove.submenu = sub
            menu.addItem(remove)
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Codex Switch",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func addUsageItems(for account: Account, to menu: NSMenu) {
        switch usageStore.state(for: account) {
        case .loading:
            addDetailItem("Loading usage...", to: menu)
        case .failed(let message):
            addDetailItem(message, to: menu)
        case .loaded(let summary):
            if summary.windows.isEmpty {
                addDetailItem("Usage unavailable", to: menu)
            } else {
                for window in summary.windows {
                    let reset = window.resetsAt.map(resetText) ?? "Unknown"
                    addDetailItem(window.title, detail: "\(window.remainingPercent)% · \(reset)", to: menu)
                }
            }

            if let resetCreditsAvailable = summary.resetCreditsAvailable {
                let suffix = resetCreditsAvailable == 1 ? "reset" : "resets"
                addDetailItem("\(resetCreditsAvailable) \(suffix) available", to: menu)
            }
        }
    }

    private func addDetailItem(_ title: String, detail: String? = nil, to menu: NSMenu) {
        let item = NSMenuItem()
        item.isEnabled = false
        item.view = DetailMenuRowView(title: title, detail: detail)
        menu.addItem(item)
    }

    private var lastRefreshedTitle: String {
        guard let lastRefreshedAt = usageStore.lastRefreshedAt else {
            return "Last Refreshed at: Never"
        }
        return "Last Refreshed at: \(Self.timeFormatter.string(from: lastRefreshedAt))"
    }

    // MARK: - Actions

    @objc private func switchAccount(_ sender: NSMenuItem) {
        guard let email = sender.representedObject as? String,
              let account = store.account(for: email) else { return }
        do {
            try store.switchTo(account)
            usageStore.refresh(accounts: store.accounts, force: true)
        } catch {
            showError(message: "Could not switch accounts.", error: error)
        }
    }

    @objc private func addAccount() {
        do {
            try store.addAccount()
        } catch {
            showError(message: "Could not start Codex login.", error: error)
        }
    }

    @objc private func removeAccount(_ sender: NSMenuItem) {
        guard let email = sender.representedObject as? String,
              let account = store.account(for: email) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove “\(email)”?"
        alert.informativeText = "The saved login is moved to ~/.codex-accounts/.removed and can be restored later. This doesn’t sign out the active session."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try store.remove(account)
                usageStore.refresh(accounts: store.accounts, force: true)
            } catch {
                showError(message: "Could not remove account.", error: error)
            }
        }
    }

    @objc private func refreshUsage() {
        store.reload()
        usageStore.refresh(accounts: store.accounts, force: true)
    }

    private func showError(message: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Icon

    private static var isAnotherInstanceRunning: Bool {
        let currentPID = ProcessInfo.processInfo.processIdentifier

        return NSWorkspace.shared.runningApplications.contains { app in
            guard app.processIdentifier != currentPID else { return false }

            if app.bundleIdentifier == "com.2xf.codexswitch" {
                return true
            }

            return app.executableURL?.lastPathComponent == "CodexSwitch"
        }
    }

    private func resetText(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return Self.timeFormatter.string(from: date)
        }
        return Self.dateFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    static let menuBarIcon: NSImage = {
        let img: NSImage
        if let url = Bundle.main.url(forResource: "menubar@2x", withExtension: "png"),
           let loaded = NSImage(contentsOf: url) {
            img = loaded
        } else {
            img = NSImage(systemSymbolName: "arrow.left.arrow.right",
                          accessibilityDescription: "Codex Switch") ?? NSImage()
        }
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = true // adapts to light/dark menu bar
        return img
    }()
}

private final class DetailMenuRowView: NSView {
    private static let rowSize = NSSize(width: 276, height: 24)

    init(title: String, detail: String?) {
        super.init(frame: NSRect(origin: .zero, size: Self.rowSize))

        let titleLabel = Self.makeLabel(title)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        if let detail {
            let detailLabel = Self.makeLabel(detail)
            detailLabel.alignment = .right
            detailLabel.lineBreakMode = .byTruncatingTail
            addSubview(detailLabel)
            detailLabel.translatesAutoresizingMaskIntoConstraints = false

            NSLayoutConstraint.activate([
                titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 34),
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: detailLabel.leadingAnchor, constant: -12),

                detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                detailLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 96)
            ])
        } else {
            NSLayoutConstraint.activate([
                titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 34),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { Self.rowSize }
    override var fittingSize: NSSize { Self.rowSize }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(NSSize(width: max(newSize.width, Self.rowSize.width), height: Self.rowSize.height))
    }

    private static func makeLabel(_ string: String) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.font = NSFont.menuFont(ofSize: 0)
        label.textColor = .disabledControlTextColor
        return label
    }
}
