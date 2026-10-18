import Foundation
import HeadroomKit

/// Reads Claude limits from the OAuth usage endpoint (PLAN §5.1, §14.1). GET only.
public actor ClaudeUsageClient {
    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")!
    public static let betaHeader = "oauth-2025-04-20"

    let transport: any HTTPTransport
    let credentials: any ClaudeCredentialSource
    let refresher: ClaudeRefresher?
    let clock: any ProviderClock
    let accountKey: @Sendable () -> String?

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        credentials: any ClaudeCredentialSource = ClaudeCredentialReader(),
        refresher: ClaudeRefresher?,
        clock: any ProviderClock = SystemClock(),
        accountKey: @escaping @Sendable () -> String? = { ClaudeAccountKey.read() }
    ) {
        self.transport = transport
        self.credentials = credentials
        self.refresher = refresher
        self.clock = clock
        self.accountKey = accountKey
    }

    /// One read. Refreshes through `claude -p /usage` at most once (and only when the throttle
    /// allows), then retries the API once. The `/usage` text is kept as a fallback reading.
    public func read(popoverOpen: Bool = false) async -> ProviderReadOutcome {
        let key = accountKey()
        var creds: ClaudeCredentials
        do {
            creds = try await credentials.read()
        } catch {
            return .failure(error.fault)
        }
        if let plan = creds.plan, plan.isEnterprise {
            return .failure(.enterprise)
        }

        var fallback: LimitReading?
        var refreshed = false

        if creds.isExpired(at: clock.now) {
            refreshed = true
            if let result = await runRefresh(popoverOpen: popoverOpen, plan: creds.plan, key: key) {
                fallback = result.fallback ?? fallback
                creds = result.credentials ?? creds
            }
        }

        for attempt in 0..<2 {
            let response: HTTPResponse
            do {
                response = try await transport.get(
                    Self.usageURL,
                    headers: [
                        "Authorization": "Bearer " + creds.accessToken,
                        "anthropic-beta": Self.betaHeader,
                        "Accept": "application/json",
                        "User-Agent": "Headroom/1.0",
                    ],
                    timeout: 15
                )
            } catch let error as HTTPTransportError {
                switch error {
                case .offline: return .failure(.offline, fallback: fallback)
                case .timedOut: return .failure(.failed(reason: "Claude's usage service timed out."), fallback: fallback)
                case .hostNotAllowed: return .failure(.failed(reason: "Blocked a request outside the allowlist."), fallback: fallback)
                case .other: return .failure(.failed(reason: "Couldn't reach Claude's usage service."), fallback: fallback)
                }
            } catch {
                return .failure(.failed(reason: "Couldn't reach Claude's usage service."), fallback: fallback)
            }

            switch response.status {
            case 200:
                do {
                    let reading = try ClaudeUsageParser.parse(response.body, fetchedAt: clock.now, plan: creds.plan, accountKey: key)
                    return .success(reading)
                } catch {
                    return .failure(error.fault, fallback: fallback)
                }
            case 401, 403:
                if attempt == 0, !refreshed {
                    refreshed = true
                    if let result = await runRefresh(popoverOpen: popoverOpen, plan: creds.plan, key: key) {
                        fallback = result.fallback ?? fallback
                        creds = result.credentials ?? creds
                        continue
                    }
                }
                return .failure(.signedOut, fallback: fallback)
            case 429:
                return .failure(.failed(reason: "Claude's usage service is rate limiting reads."), fallback: fallback)
            case 500...599:
                return .failure(.outage(description: "Claude's usage service returned an error (HTTP \(response.status))."),
                                fallback: fallback)
            default:
                return .failure(.failed(reason: "Claude's usage service returned HTTP \(response.status)."), fallback: fallback)
            }
        }
        return .failure(.signedOut, fallback: fallback)
    }

    /// Runs `claude -p /usage` when the throttle allows. Returns the text reading and re-read
    /// credentials, or nil when nothing ran.
    private func runRefresh(popoverOpen: Bool, plan: PlanInfo?, key: String?) async
        -> (fallback: LimitReading?, credentials: ClaudeCredentials?)?
    {
        guard let refresher else { return nil }
        guard case .ran(let output) = await refresher.refreshIfAllowed(popoverOpen: popoverOpen) else { return nil }
        let reading = ClaudeUsageTextParser.parse(output, now: clock.now, plan: plan, accountKey: key)
        let fresh = try? await credentials.read()
        return (reading, fresh)
    }
}
