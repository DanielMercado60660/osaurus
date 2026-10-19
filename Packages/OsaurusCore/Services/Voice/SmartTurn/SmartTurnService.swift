import Foundation

struct SmartTurnPrediction: Sendable {
    let probability: Float
    let threshold: Float
}

/// Lazy, serial, off-main inference. GPU ownership composes with the chat and
/// embedding producers; a cancelled check cannot remain parked behind a reply.
actor SmartTurnService {
    static let shared = SmartTurnService()
    private var model: SmartTurnModel?
    private var loadedDirectory: URL?

    /// Load the model and run one throwaway pass so the first real end-of-turn
    /// check doesn't pay Metal pipeline compilation (~2 s cold, ~5 ms warm).
    func warmUp(directory: URL) async {
        _ = try? await predict(samples: [Float](repeating: 0, count: 16_000), directory: directory)
    }

    func predict(samples: [Float], directory: URL) async throws -> SmartTurnPrediction {
        try Task.checkCancellation()
        let features = SmartTurnFeatures.extract(samples)
        try Task.checkCancellation()
        let owner = "smart-turn"
        try await MetalGate.shared.acquireCancellable(owner, shared: false)
        do {
            try Task.checkCancellation()
            if model == nil || loadedDirectory != directory {
                let loaded = try SmartTurnModel(directory: directory)
                try Task.checkCancellation()
                model = loaded
                loadedDirectory = directory
                AuxiliaryModelResidency.shared.track(loaded, kind: .smartTurn,
                    estimatedBytes: AuxiliaryModelEstimate.bytes(at: [directory.appendingPathComponent("model.safetensors")]))
            }
            let logit = model!.logit(features: features)
            guard logit.isFinite else { throw SmartTurnModel.ModelError.incompatible("non-finite output") }
            let probability = 1 / (1 + exp(-logit))
            let prediction = SmartTurnPrediction(probability: probability, threshold: model!.threshold)
            try Task.checkCancellation()
            await MetalGate.shared.release(owner)
            return prediction
        } catch {
            await MetalGate.shared.release(owner)
            throw error
        }
    }
}
