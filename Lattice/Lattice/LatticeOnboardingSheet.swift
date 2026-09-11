import SwiftUI

/// First-run walkthrough: what Lattice is → connect an AI → describe the first app.
/// Shown only when there is no key configured and no recent projects.
struct LatticeOnboardingSheet: View {
    /// Called when the flow finishes. `prompt` is the optional first app description.
    var onFinished: (_ prompt: String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var keyStore = APIKeyStore.shared

    @State private var step = 0
    @State private var selectedProviderRaw = "anthropic"
    @State private var apiKey = ""
    @State private var showKeyHelp = false
    @State private var appIdea = ""

    private var selectedProvider: LLMProvider? {
        LLMProvider(rawValue: selectedProviderRaw)
    }

    private var selectedKeyIsSet: Bool {
        guard let provider = selectedProvider else { return false }
        return !keyStore.key(for: provider).isEmpty || !apiKey.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? Color.accentColor : Color.primary.opacity(0.12))
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 6)

            switch step {
            case 0: welcomeStep
            case 1: connectStep
            default: firstAppStep
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(.ultraThinMaterial)
    }

    // MARK: Step 1 — Welcome

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: 8) {
                Text("Build real Apple apps by describing them")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("Lattice writes native Swift, builds it with Xcode, and runs it on your Mac or a simulator. No Xcode experience needed.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            primaryButton("Get started") { step = 1 }
            skipLink
        }
        .padding(28)
    }

    // MARK: Step 2 — Connect an AI

    private var connectStep: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("Connect your AI")
                    .font(.title2.weight(.bold))
                Text("Lattice needs one AI account to build with. Everything stays on your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding(.top, 4)

            VStack(spacing: 8) {
                providerCard(provider: .anthropic,
                             title: "Claude (Anthropic)",
                             subtitle: "Recommended — great at building apps. Get a key at console.anthropic.com.")
                providerCard(provider: .openAI,
                             title: "ChatGPT (OpenAI)",
                             subtitle: "Uses an OpenAI API key from platform.openai.com.")
                providerCard(provider: .zai,
                             title: "GLM (z.ai)",
                             subtitle: "Budget-friendly, with a generous free tier at z.ai.")
            }

            if let provider = selectedProvider {
                HStack(spacing: 10) {
                    SecureField("Paste your API key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                    if selectedKeyIsSet {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Button {
                        showKeyHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Where do I get a key?")
                    .popover(isPresented: $showKeyHelp, arrowEdge: .bottom) {
                        keyHelpPopover
                    }
                }
                .padding(.horizontal, 44)

                if provider == .zai {
                    Text("Tip: the GLM Coding Plan subscription uses the same key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
            HStack(spacing: 10) {
                Button("Back") { step = 0 }
                    .buttonStyle(.bordered)
                primaryButton("Continue") {
                    saveKey()
                    step = 2
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty && !selectedKeyIsSet)
            }
            Button("I'll connect later — skip") { step = 2 }
                .buttonStyle(.borderless)
                .font(.callout)
        }
        .padding(28)
    }

    private var keyHelpPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What's an API key?")
                .font(.headline)
            Text("It's a long password for your AI account. The provider's website shows it under “API keys” after you sign up. Lattice stores it safely in your Keychain and never shares it with anyone else.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 300)
    }

    private func providerCard(provider: LLMProvider, title: String, subtitle: String) -> some View {
        Button {
            selectedProviderRaw = provider.rawValue
            apiKey = ""
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedProviderRaw == provider.rawValue
                      ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selectedProviderRaw == provider.rawValue
                          ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        selectedProviderRaw == provider.rawValue
                            ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08),
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 44)
    }

    // MARK: Step 3 — First app

    private var firstAppStep: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "hammer.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: 8) {
                Text("What should we build first?")
                    .font(.title2.weight(.bold))
                Text("Describe any app idea — or leave it blank and start from the hub.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            TextField("e.g. A habit tracker with streaks and pretty charts", text: $appIdea, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...5)
                .padding(.horizontal, 44)
            Spacer()
            HStack(spacing: 10) {
                Button("Back") { step = 1 }
                    .buttonStyle(.bordered)
                primaryButton("Start building") {
                    finish(withPrompt: appIdea.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
        .padding(28)
    }

    // MARK: Helpers

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .frame(maxWidth: 220)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
    }

    private var skipLink: some View {
        Button("Skip tour") { finish(withPrompt: nil) }
            .buttonStyle(.borderless)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func saveKey() {
        guard let provider = selectedProvider else { return }
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        keyStore.setKey(trimmed, for: provider)
    }

    private func finish(withPrompt prompt: String?) {
        onFinished(prompt)
        dismiss()
    }
}
