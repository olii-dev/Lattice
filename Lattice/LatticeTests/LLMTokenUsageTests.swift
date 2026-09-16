import Testing
import Foundation
@testable import Lattice

@Suite struct LLMTokenUsageTests {

    @Test func decodesAnthropicMessageStartUsage() throws {
        let json = #"{"type":"message_start","message":{"usage":{"input_tokens":25,"output_tokens":1}}}"#
        let event = try JSONDecoder().decode(SSEEvent.self, from: Data(json.utf8))
        #expect(event.message?.usage?.input_tokens == 25)
    }

    @Test func decodesAnthropicMessageDeltaUsage() throws {
        let json = #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":121}}"#
        let event = try JSONDecoder().decode(SSEEvent.self, from: Data(json.utf8))
        #expect(event.usage?.output_tokens == 121)
        #expect(event.message == nil)
    }

    @Test func ignoresEventsWithoutUsage() throws {
        let json = #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}"#
        let event = try JSONDecoder().decode(SSEEvent.self, from: Data(json.utf8))
        #expect(event.usage == nil)
        #expect(event.message == nil)
    }

    @Test func mapsAnthropicAndOpenAIUsageShapes() {
        let anthropicShape = SSEUsagePayload(
            input_tokens: 10, output_tokens: 20, prompt_tokens: nil, completion_tokens: nil
        )
        #expect(anthropicShape.anthropicUsage == LLMTokenUsage(inputTokens: 10, outputTokens: 20))

        let openAIShape = SSEUsagePayload(
            input_tokens: nil, output_tokens: nil, prompt_tokens: 30, completion_tokens: 40
        )
        #expect(openAIShape.openAIUsage == LLMTokenUsage(inputTokens: 30, outputTokens: 40))
    }

    @Test func captionFormatsTokenCounts() {
        #expect(LLMTokenUsage(inputTokens: nil, outputTokens: nil).caption == nil)
        #expect(LLMTokenUsage(inputTokens: 950, outputTokens: nil).caption == "950 in")
        #expect(LLMTokenUsage(inputTokens: nil, outputTokens: 7).caption == "7 out")
        #expect(LLMTokenUsage(inputTokens: 1200, outputTokens: 412).caption == "1.2k in · 412 out")
        #expect(LLMTokenUsage(inputTokens: 1000, outputTokens: 1000).caption == "1k in · 1k out")
        #expect(LLMTokenUsage(inputTokens: 100_000, outputTokens: 2500).caption == "100k in · 2.5k out")
    }
}
