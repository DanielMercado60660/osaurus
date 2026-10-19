import Foundation
import MLX
import MLXNN

/// Float32 Smart Turn v3.2 GPU conversion. Mirrors mlx_audio's Smart Turn
/// encoder/attention-pooling/classifier, including exact GELU and LN eps=1e-5.
/// Confined to SmartTurnService's serial executor; MLX arrays never cross actors.
final class SmartTurnModel {
    private let weights: [String: MLXArray]
    let threshold: Float

    enum ModelError: LocalizedError {
        case incompatible(String)
        var errorDescription: String? {
            if case .incompatible(let detail) = self { return "Smart Turn bundle is incompatible: \(detail)" }
            return nil
        }
    }
    init(directory: URL) throws {
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("config.json"))) as? [String: Any]
        guard config?["model_type"] as? String == "smart_turn",
              config?["sample_rate"] as? Int == 16000,
              config?["max_audio_seconds"] as? Int == 8,
              let threshold = (config?["threshold"] as? NSNumber)?.floatValue,
              threshold.isFinite, (0...1).contains(threshold) else {
            throw ModelError.incompatible("expected 16 kHz / 8 s smart_turn config and probability threshold")
        }
        self.threshold = threshold
        var weights: [String: MLXArray] = [:]
        for (raw, value) in try MLX.loadArrays(url: directory.appendingPathComponent("model.safetensors")) {
            let key = raw.hasPrefix("inner.") ? String(raw.dropFirst(6)) : raw
            guard weights[key] == nil else { throw ModelError.incompatible("duplicate \(key)") }
            weights[key] = value
        }
        // Validate every consumed tensor before constructing MLX operations.
        var shapes: [String: [Int]] = ["encoder.embed_positions.weight": [400, 384]]
        func linear(_ name: String, _ input: Int, _ output: Int, bias: Bool = true) {
            shapes[name + ".weight"] = [output, input]
            if bias { shapes[name + ".bias"] = [output] }
        }
        func norm(_ name: String, _ width: Int) {
            shapes[name + ".weight"] = [width]; shapes[name + ".bias"] = [width]
        }
        for (name, input) in [("encoder.conv1", 80), ("encoder.conv2", 384)] {
            shapes[name + ".weight"] = [384, input, 3]; shapes[name + ".bias"] = [384]
        }
        norm("encoder.layer_norm", 384)
        for i in 0..<4 {
            let p = "encoder.layers.\(i)"
            norm(p + ".self_attn_layer_norm", 384); norm(p + ".final_layer_norm", 384)
            for projection in ["q_proj", "k_proj", "v_proj", "out_proj"] {
                linear(p + ".self_attn." + projection, 384, 384, bias: projection != "k_proj")
            }
            linear(p + ".fc1", 384, 1536); linear(p + ".fc2", 1536, 384)
        }
        linear("pool_attention.0", 384, 256); linear("pool_attention.2", 256, 1)
        linear("classifier.0", 384, 256); norm("classifier.1", 256)
        linear("classifier.4", 256, 64); linear("classifier.6", 64, 1)
        for (key, shape) in shapes {
            guard let value = weights[key], value.shape == shape, value.dtype == .float32 else {
                throw ModelError.incompatible("\(key) must be float32 \(shape)")
            }
        }
        guard weights.count == shapes.count else { throw ModelError.incompatible("unexpected tensors") }
        for name in ["encoder.conv1.weight", "encoder.conv2.weight"] {
            weights[name] = weights[name]!.transposed(0, 2, 1)
        }
        self.weights = weights
        eval(Array(weights.values))
    }
    private func linear(_ x: MLXArray, _ name: String) -> MLXArray {
        let output = matmul(x, weights[name + ".weight"]!.T)
        return weights[name + ".bias"].map { output + $0 } ?? output
    }
    private func norm(_ x: MLXArray, _ name: String) -> MLXArray {
        MLXFast.layerNorm(x, weight: weights[name + ".weight"], bias: weights[name + ".bias"], eps: 1e-5)
    }
    func logit(features: [Float]) -> Float {
        precondition(features.count == 80 * 800)
        var x = MLXArray(features, [1, 80, 800]).transposed(0, 2, 1)
        for (name, stride) in [("encoder.conv1", 1), ("encoder.conv2", 2)] {
            x = gelu(conv1d(x, weights[name + ".weight"]!, stride: stride, padding: 1) + weights[name + ".bias"]!)
        }
        x = x + weights["encoder.embed_positions.weight"]!
        for i in 0..<4 {
            let p = "encoder.layers.\(i)"
            let h = norm(x, p + ".self_attn_layer_norm")
            let q = linear(h, p + ".self_attn.q_proj").reshaped(1, 400, 6, 64).transposed(0, 2, 1, 3)
            let k = linear(h, p + ".self_attn.k_proj").reshaped(1, 400, 6, 64).transposed(0, 2, 3, 1)
            let v = linear(h, p + ".self_attn.v_proj").reshaped(1, 400, 6, 64).transposed(0, 2, 1, 3)
            let attention = softmax(matmul(q, k) / 8, axis: -1, precise: true)
            let attended = matmul(attention, v).transposed(0, 2, 1, 3).reshaped(1, 400, 384)
            x = x + linear(attended, p + ".self_attn.out_proj")
            x = x + linear(gelu(linear(norm(x, p + ".final_layer_norm"), p + ".fc1")), p + ".fc2")
        }
        x = norm(x, "encoder.layer_norm")
        let attention = softmax(linear(tanh(linear(x, "pool_attention.0")), "pool_attention.2"), axis: 1, precise: true)
        let pooled = sum(x * attention, axis: 1)
        let hidden = gelu(norm(linear(pooled, "classifier.0"), "classifier.1"))
        let output = linear(gelu(linear(hidden, "classifier.4")), "classifier.6")
        return output.item(Float.self)
    }
}
