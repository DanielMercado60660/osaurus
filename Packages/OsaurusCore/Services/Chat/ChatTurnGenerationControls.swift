//
//  ChatTurnGenerationControls.swift
//  osaurus
//
//  Freezes prompt-affecting UI model controls for one logical chat turn.
//  Agent loops rebuild ChatCompletionRequest for every model step, so the
//  explicit Thinking choice must be copied to every reconstruction in both
//  its local runtime representation (`modelOptions`) and its wire-safe API
//  representation (`enable_thinking`).
//

import Foundation

struct ChatTurnGenerationControls: Sendable, Equatable {
    let modelOptions: [String: ModelOptionValue]?
    let enableThinking: Bool?

    var reasoningEffort: String? { modelOptions?["reasoningEffort"]?.stringValue }

    static func capture(
        activeModelOptions: [String: ModelOptionValue]
    ) -> ChatTurnGenerationControls {
        let options = activeModelOptions.isEmpty ? nil : activeModelOptions

        // Only an explicit toggle becomes an API override. An absent value
        // remains nil so the bundle's chat-template default still owns fresh
        // models. `disableThinking` is the canonical stored option for every
        // current Thinking profile, including dynamically discovered local
        // profiles such as Ornith. Translate it directly instead of resolving
        // the model profile again on the send path; dynamic profile discovery
        // can touch the local model catalog and must not add synchronous TTFT.
        let enableThinking = options?["disableThinking"]?.boolValue.map { !$0 }

        return ChatTurnGenerationControls(
            modelOptions: options,
            enableThinking: enableThinking
        )
    }

    /// Recover persisted explicit Thinking/effort choices when launch-time UI
    /// normalization raced the cold local-model capability cache. The caller
    /// supplies the already-read versioned payload and the off-main resolver,
    /// keeping this policy deterministic in tests. Unrelated model options
    /// and already-live reasoning choices do not wait for discovery.
    static func captureForSend(
        modelId: String?,
        activeModelOptions: [String: ModelOptionValue],
        storedExplicitOptions: [String: ModelOptionValue]?,
        resolveCapability: @Sendable (String) async -> Void
    ) async -> ChatTurnGenerationControls {
        guard activeModelOptions["disableThinking"] == nil,
            activeModelOptions["reasoningEffort"] == nil,
            let modelId,
            let storedExplicitOptions,
            storedExplicitOptions["disableThinking"]?.boolValue != nil
                || storedExplicitOptions["reasoningEffort"]?.stringValue != nil
        else {
            return capture(activeModelOptions: activeModelOptions)
        }

        await resolveCapability(modelId)
        let validated = ModelProfileRegistry.normalizedOptions(
            for: modelId,
            persisted: storedExplicitOptions
        )
        var merged = activeModelOptions
        for key in ["disableThinking", "reasoningEffort"] {
            if let recovered = validated[key] { merged[key] = recovered }
        }
        return capture(activeModelOptions: merged)
    }

    /// Reuse the composer's canonical option, without mutating its saved choice.
    static func captureForTalk(activeModelOptions: [String: ModelOptionValue],
                               thinkBeforeSpeaking: Bool, toggleable: Bool) -> ChatTurnGenerationControls {
        var options = activeModelOptions
        options.removeValue(forKey: "disableThinking")
        options.removeValue(forKey: "reasoningEffort")
        if let enabled = TalkThinkingPolicy.enableThinking(
            thinkBeforeSpeaking: thinkBeforeSpeaking, toggleable: toggleable) {
            options["disableThinking"] = .bool(!enabled)
        }
        // An explicit empty dictionary prevents ChatEngine's UI-agent fallback
        // from reloading the composer's persisted Thinking/effort options.
        return ChatTurnGenerationControls(
            modelOptions: options, enableThinking: options["disableThinking"]?.boolValue.map { !$0 })
    }

    func apply(to request: inout ChatCompletionRequest) {
        request.modelOptions = modelOptions
        request.enable_thinking = enableThinking
        request.reasoning_effort = reasoningEffort
    }
}
