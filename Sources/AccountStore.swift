import Foundation

/// One Codex account, backed by a saved `auth.json` in the registry.
struct Account: Hashable {
    let email: String
    let fileURL: URL
}

enum AccountStoreError: LocalizedError {
    case cannotRemoveActiveAccount

    var errorDescription: String? {
        switch self {
        case .cannotRemoveActiveAccount:
            return "Switch to another account before removing this one."
        }
    }
}

/// Manages the on-disk Codex account registry and the active `~/.codex` login.
///
/// Layout:
///   ~/.codex/auth.json              — the login Codex uses right now
///   ~/.codex-accounts/<email>.auth.json  — one saved copy per account
///   ~/.codex-accounts/.removed/     — soft-deleted accounts (never hard-deleted)
final class AccountStore {
    private(set) var accounts: [Account] = []
    private(set) var activeEmail: String?

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var registryDir: URL { home.appendingPathComponent(".codex-accounts") }
    private var removedDir: URL { registryDir.appendingPathComponent(".removed") }
    private var codexHome: URL { home.appendingPathComponent(".codex") }
    private var activeAuth: URL { codexHome.appendingPathComponent("auth.json") }
    private let fm = FileManager.default

    private var pollTimer: Timer?

    init() { reload() }

    // MARK: - Reading

    /// Decode the `email` claim from an `auth.json`'s ChatGPT id_token (best effort).
    func email(in authURL: URL) -> String? {
        guard let data = try? Data(contentsOf: authURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String else { return nil }
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
                                   .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let payload = Data(base64Encoded: b64),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }
        return claims["email"] as? String
    }

    /// Rescan the registry and recompute which account is active.
    func reload() {
        try? fm.createDirectory(at: registryDir, withIntermediateDirectories: true)

        let files = (try? fm.contentsOfDirectory(at: registryDir,
                                                 includingPropertiesForKeys: nil)) ?? []
        var found: [Account] = []
        for url in files where url.lastPathComponent.hasSuffix(".auth.json") {
            let email = String(url.lastPathComponent.dropLast(".auth.json".count))
            found.append(Account(email: email, fileURL: url))
        }
        accounts = found.sorted { $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending }

        // Determine the active account from ~/.codex/auth.json.
        if fm.fileExists(atPath: activeAuth.path) {
            let active = email(in: activeAuth)
            activeEmail = active
            // Make sure the active login is represented in the registry so it can be switched back to.
            if let active, !accounts.contains(where: { $0.email == active }) {
                let dest = registryDir.appendingPathComponent("\(active).auth.json")
                do {
                    try replace(at: dest, withContentsOf: activeAuth)
                    accounts.append(Account(email: active, fileURL: dest))
                    accounts.sort { $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending }
                } catch {
                    NSLog("Codex Switch could not save active login: \(error.localizedDescription)")
                }
            }
        } else {
            activeEmail = nil
        }
    }

    // MARK: - Switching

    func isActive(_ account: Account) -> Bool { account.email == activeEmail }

    func account(for email: String) -> Account? { accounts.first { $0.email == email } }

    /// Make `account` the login the `codex` CLI uses, preserving the previous one in the registry.
    func switchTo(_ account: Account) throws {
        guard !isActive(account) else { return }
        try fm.createDirectory(at: registryDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: codexHome, withIntermediateDirectories: true)

        // Back up / refresh the currently-active login into the registry first.
        if fm.fileExists(atPath: activeAuth.path), let cur = email(in: activeAuth) {
            let backup = registryDir.appendingPathComponent("\(cur).auth.json")
            try replace(at: backup, withContentsOf: activeAuth)
        }

        // Activate the chosen account atomically.
        try replace(at: activeAuth, withContentsOf: account.fileURL)
        reload()
    }

    /// Copy `src` over `dest` atomically (write to temp, then swap into place).
    private func replace(at dest: URL, withContentsOf src: URL) throws {
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Data(contentsOf: src)
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent(".\(dest.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: tmp) }
        try data.write(to: tmp, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: tmp, to: dest)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
    }

    // MARK: - Removing (soft delete)

    /// Move an account's saved login into `.removed/` — recoverable, never hard-deleted.
    func remove(_ account: Account) throws {
        guard !isActive(account) else { throw AccountStoreError.cannotRemoveActiveAccount }

        try fm.createDirectory(at: removedDir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let dest = removedDir.appendingPathComponent("\(account.email).\(stamp).auth.json")
        try fm.moveItem(at: account.fileURL, to: dest)
        reload()
    }

    // MARK: - Adding (drives `codex login` in Terminal)

    /// Open Terminal to run `codex login` against a throwaway home, then import the result.
    func addAccount() throws {
        let pending = registryDir.appendingPathComponent(".pending-\(Int(Date().timeIntervalSince1970))")
        try fm.createDirectory(at: pending, withIntermediateDirectories: true)
        let pendingAuth = pending.appendingPathComponent("auth.json")

        let cmd = "CODEX_HOME=\(shellQuote(pending.path)) codex login"
        let script = """
        tell application "Terminal"
            activate
            do script "echo 'Codex Switch — sign in to the account you want to ADD, then you can close this window.'; \(escapeForAppleScript(cmd))"
        end tell
        """
        do {
            try runAppleScript(script)
        } catch {
            try? fm.removeItem(at: pending)
            throw error
        }

        // Poll for the new auth.json to appear, then import it.
        var waited = 0.0
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            waited += 1.5
            if self.fm.fileExists(atPath: pendingAuth.path), let email = self.email(in: pendingAuth) {
                timer.invalidate()
                let dest = self.registryDir.appendingPathComponent("\(email).auth.json")
                do {
                    try self.replace(at: dest, withContentsOf: pendingAuth)
                } catch {
                    NSLog("Codex Switch add account failed: \(error.localizedDescription)")
                }
                try? self.fm.removeItem(at: pending)
                self.reload()
            } else if waited > 240 {
                timer.invalidate()
                try? self.fm.removeItem(at: pending)
                NSLog("Codex Switch add account timed out.")
            }
        }
    }

    // MARK: - Helpers

    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func runAppleScript(_ source: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        try p.run()
    }
}
