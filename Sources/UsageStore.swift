import Foundation

struct UsageSummary {
    let windows: [UsageWindowSummary]
    let resetCreditsAvailable: Int?
}

struct UsageWindowSummary {
    let title: String
    let remainingPercent: Int
    let resetsAt: Date?
}

enum UsageState {
    case loading
    case loaded(UsageSummary)
    case failed(String)
}

@MainActor
final class UsageStore {
    private let client = CodexUsageClient()
    private var refreshTask: Task<Void, Never>?
    private var refreshTimer: Timer?

    private(set) var states: [String: UsageState] = [:]
    private(set) var isRefreshing = false
    private(set) var lastRefreshedAt: Date?

    var onChange: (() -> Void)?

    func startAutoRefresh(accounts: @escaping @MainActor () -> [Account]) {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh(accounts: accounts(), force: true)
            }
        }
        refresh(accounts: accounts(), force: false)
    }

    func refreshIfNeeded(accounts: [Account]) {
        let hasMissingAccount = accounts.contains { states[$0.email] == nil }
        guard hasMissingAccount || lastRefreshedAt == nil || Date().timeIntervalSince(lastRefreshedAt!) > 300 else { return }
        refresh(accounts: accounts, force: false)
    }

    func refresh(accounts: [Account], force: Bool) {
        let accounts = accounts.sorted { $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending }
        guard !accounts.isEmpty else {
            refreshTask?.cancel()
            states.removeAll()
            isRefreshing = false
            lastRefreshedAt = nil
            onChange?()
            return
        }
        guard force || !isRefreshing else { return }

        refreshTask?.cancel()
        isRefreshing = true
        for account in accounts where states[account.email] == nil {
            states[account.email] = .loading
        }
        onChange?()

        refreshTask = Task { [weak self] in
            var next: [String: UsageState] = [:]
            guard let self else { return }

            for account in accounts {
                if Task.isCancelled { return }
                do {
                    let summary = try await self.client.fetchUsage(for: account)
                    next[account.email] = .loaded(summary)
                } catch is CancellationError {
                    return
                } catch {
                    next[account.email] = .failed("Usage unavailable")
                }
            }

            guard !Task.isCancelled else { return }
            self.states = next
            self.isRefreshing = false
            self.lastRefreshedAt = Date()
            self.onChange?()
        }
    }

    func state(for account: Account) -> UsageState {
        states[account.email] ?? .loading
    }
}

private struct CodexUsageClient {
    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    func fetchUsage(for account: Account) async throws -> UsageSummary {
        let accessToken = try accessToken(in: account.fileURL)
        var request = URLRequest(url: usageURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexSwitch/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UsageClientError.requestFailed
        }

        let decoded = try JSONDecoder().decode(WhamUsageResponse.self, from: data)
        let windows = decoded.rateLimit?.windows ?? []

        return UsageSummary(
            windows: windows,
            resetCreditsAvailable: decoded.rateLimitResetCredits?.availableCount
        )
    }

    private func accessToken(in authURL: URL) throws -> String {
        let data = try Data(contentsOf: authURL)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let tokens = root?["tokens"] as? [String: Any]
        guard let accessToken = tokens?["access_token"] as? String, !accessToken.isEmpty else {
            throw UsageClientError.missingAccessToken
        }
        return accessToken
    }
}

private enum UsageClientError: Error {
    case missingAccessToken
    case requestFailed
}

private struct WhamUsageResponse: Decodable {
    let rateLimit: RateLimit?
    let rateLimitResetCredits: ResetCredits?

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
        case rateLimitResetCredits = "rate_limit_reset_credits"
    }
}

private struct RateLimit: Decodable {
    let primaryWindow: RateLimitWindow?
    let secondaryWindow: RateLimitWindow?

    var windows: [UsageWindowSummary] {
        [primaryWindow, secondaryWindow]
            .compactMap { $0 }
            .map { $0.summary }
    }

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct RateLimitWindow: Decodable {
    let usedPercent: Double?
    let limitWindowSeconds: Double?
    let resetAt: Date?
    let resetAfterSeconds: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = try container.decodeFlexibleDoubleIfPresent(forKey: .usedPercent)
        limitWindowSeconds = try container.decodeFlexibleDoubleIfPresent(forKey: .limitWindowSeconds)
        resetAfterSeconds = try container.decodeFlexibleDoubleIfPresent(forKey: .resetAfterSeconds)

        if let timestamp = try container.decodeFlexibleDoubleIfPresent(forKey: .resetAt) {
            resetAt = Date(timeIntervalSince1970: timestamp)
        } else if let string = try? container.decodeIfPresent(String.self, forKey: .resetAt) {
            resetAt = ISO8601DateFormatter().date(from: string)
        } else {
            resetAt = nil
        }
    }

    var summary: UsageWindowSummary {
        let normalizedUsed = (usedPercent ?? 0) <= 1 ? (usedPercent ?? 0) * 100 : (usedPercent ?? 0)
        let used = Int(normalizedUsed.rounded())
        let remaining = max(0, min(100, 100 - used))
        let resetDate = resetAt ?? resetAfterSeconds.map { Date(timeIntervalSinceNow: $0) }

        return UsageWindowSummary(
            title: Self.title(for: limitWindowSeconds),
            remainingPercent: remaining,
            resetsAt: resetDate
        )
    }

    private static func title(for seconds: Double?) -> String {
        guard let seconds else { return "Window" }
        switch seconds {
        case 0..<86_400:
            let hours = max(1, Int((seconds / 3_600).rounded()))
            return "\(hours)h"
        case 86_400..<604_800:
            let days = max(1, Int((seconds / 86_400).rounded()))
            return days == 1 ? "Daily" : "\(days)d"
        default:
            return "Weekly"
        }
    }

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
        case resetAfterSeconds = "reset_after_seconds"
    }
}

private struct ResetCredits: Decodable {
    let availableCount: Int?

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleDoubleIfPresent(forKey key: Key) throws -> Double? {
        if let double = try? decodeIfPresent(Double.self, forKey: key) {
            return double
        }
        if let int = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(int)
        }
        if let string = try? decodeIfPresent(String.self, forKey: key) {
            return Double(string)
        }
        return nil
    }
}
