import Foundation

/// Turns raw API / JSON error bodies into short, readable chat copy.
enum APIErrorFormatting {
    static func friendlyMessage(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Something went wrong. Please try again." }

        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let parsed = parseOpenAIStyleError(obj) {
                return parsed
            }
        }

        if trimmed.count > 280 {
            return String(trimmed.prefix(240)) + "…"
        }
        return trimmed
    }

    static func userFacingMessage(from error: Error) -> String {
        if let urlError = error as? URLError {
            return friendlyConnectionMessage(urlError)
        }
        if let stream = error as? StreamError, case .apiError(let raw, _) = stream {
            return friendlyMessage(from: raw)
        }
        return error.localizedDescription
    }

    /// Translates connection-level failures into plain language.
    private static func friendlyConnectionMessage(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return "You appear to be offline. Check your internet connection and try again."
        case .timedOut:
            return "The AI provider took too long to answer. Give it another try."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "Couldn't reach the provider. If you're using a custom provider, double-check its address — otherwise check your internet connection."
        default:
            return "A network problem stopped the request. \(error.localizedDescription)"
        }
    }

    private static func parseOpenAIStyleError(_ obj: [String: Any]) -> String? {
        var code: String?
        var message: String?

        if let err = obj["error"] as? [String: Any] {
            if let c = err["code"] {
                code = "\(c)"
            }
            if let m = err["message"] as? String {
                message = m
            } else if let m = err["message"] {
                message = "\(m)"
            }
        } else if let err = obj["error"] as? String {
            message = err
        }

        guard message != nil || code != nil else { return nil }

        let base = (message?.isEmpty == false) ? message! : "Request failed"
        let hint = code.flatMap { knownHint(forCode: $0) }

        if let code, !code.isEmpty {
            if let hint {
                return "\(base)\n\n\(hint) (code \(code))"
            }
            return "\(base) (code \(code))"
        }
        if let hint {
            return "\(base)\n\n\(hint)"
        }
        return base
    }

    private static func knownHint(forCode code: String) -> String? {
        switch code {
        case "1305":
            return "The provider’s service is temporarily overloaded. Wait a moment and try again."
        case "1214":
            return "The provider rejected the request payload. Retry should rebuild it; if this repeats, switch model or provider."
        case "1234":
            return "The provider hit a temporary internal network failure. Retry should usually recover."
        case "429":
            return "Rate limited. Wait briefly or try again later."
        case "401", "403":
            return "Check that your API key is valid and has access. In Settings, try pasting the key again — extra spaces or a partial copy are the usual culprits."
        case "404", "model_not_found":
            return "That model name wasn't recognized. Pick a different model in Settings (Account → Model)."
        case "402", "insufficient_quota", "insufficient_credits":
            return "The provider account is out of credit or over its limit. Top up the account, or pick a cheaper model."
        default:
            return nil
        }
    }
}
