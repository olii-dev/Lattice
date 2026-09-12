import Testing
import Foundation
@testable import Lattice

@Suite struct LLMRetryPolicyTests {

    private static let retryableStatuses = [408, 429, 500, 502, 503, 504, 529]
    private static let permanentStatuses = [400, 401, 403, 404, 409, 422]

    @Test func retriesTransientStatusCodes() {
        for status in Self.retryableStatuses {
            let error = StreamError.apiError(message: "HTTP \(status)", statusCode: status)
            #expect(LLMService.shouldRetryAfterTransientProviderFailure(error), "expected retry on \(status)")
        }
    }

    @Test func doesNotRetryPermanentStatusCodes() {
        for status in Self.permanentStatuses {
            let error = StreamError.apiError(message: "HTTP \(status)", statusCode: status)
            #expect(!LLMService.shouldRetryAfterTransientProviderFailure(error), "did not expect retry on \(status)")
        }
    }

    @Test func retriesProviderBodyMarkersWithoutStatusCode() {
        let cases = [
            StreamError.apiError(message: "{\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}", statusCode: nil),
            StreamError.apiError(message: "provider is temporarily overloaded", statusCode: nil),
            StreamError.apiError(message: "internal network failure (code 1234)", statusCode: nil),
            StreamError.apiError(message: "gateway error code 1305", statusCode: nil),
            StreamError.apiError(message: "{\"error\":{\"code\":429,\"message\":\"rate limit exceeded\"}}", statusCode: nil),
            StreamError.apiError(message: "rate_limit_error: slow down", statusCode: nil),
        ]
        for error in cases {
            #expect(LLMService.shouldRetryAfterTransientProviderFailure(error))
        }
    }

    @Test func doesNotRetryNonTransientApiBodies() {
        let cases = [
            StreamError.apiError(message: "invalid model id", statusCode: nil),
            StreamError.apiError(message: "request id 51234 rejected", statusCode: 400),
            StreamError.apiError(message: "", statusCode: nil),
        ]
        for error in cases {
            #expect(!LLMService.shouldRetryAfterTransientProviderFailure(error))
        }
    }

    @Test func retriesNetworkLevelFailures() {
        #expect(LLMService.shouldRetryAfterTransientProviderFailure(URLError(.timedOut)))
        #expect(LLMService.shouldRetryAfterTransientProviderFailure(URLError(.networkConnectionLost)))
        #expect(LLMService.shouldRetryAfterTransientProviderFailure(URLError(.cannotConnectToHost)))
    }

    @Test func doesNotRetryOtherNetworkFailures() {
        #expect(!LLMService.shouldRetryAfterTransientProviderFailure(URLError(.badURL)))
        #expect(!LLMService.shouldRetryAfterTransientProviderFailure(URLError(.cancelled)))
    }

    @Test func ignoresSubstringMatchesInArbitraryErrors() {
        // Regression: the old heuristic matched these substrings anywhere, including
        // localized descriptions of unrelated failures.
        struct OpaqueError: LocalizedError {
            var errorDescription: String? { "failed writing file 1234.txt near exit code 1305" }
        }
        #expect(!LLMService.shouldRetryAfterTransientProviderFailure(OpaqueError()))
    }

    @Test func streamErrorExposesMessageAndStatus() {
        let withStatus = StreamError.apiError(message: "boom", statusCode: 503)
        #expect(withStatus.rawMessage == "boom")
        #expect(withStatus.statusCode == 503)

        let withoutStatus = StreamError.apiError(message: "overloaded", statusCode: nil)
        #expect(withoutStatus.statusCode == nil)
        #expect(withoutStatus.errorDescription?.contains("verloaded") == true)
    }
}
