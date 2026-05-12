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
        if let stream = error as? StreamError, case .apiError(let raw) = stream {
            return friendlyMessage(from: raw)
        }
        return error.localizedDescription
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
        case "429":
            return "Rate limited. Wait briefly or try again later."
        case "401", "403":
            return "Check that your API key is valid and has access."
        default:
            return nil
        }
    }
}
