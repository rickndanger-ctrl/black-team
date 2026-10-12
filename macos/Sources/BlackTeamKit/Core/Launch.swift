import Foundation

// How Black Team starts a model file well on this computer. The plan follows settings
// proven on a CPU laptop, and adds each one only when the llama-server build in use
// understands it, so a start never fails over a flag.

private let GiB = 1024 * 1024 * 1024

/// The flags a llama-server build accepts, read from its own help text.
private func hasFlag(_ help: String, _ flag: String) -> Bool {
    let pattern = "(^|[\\s,])" + NSRegularExpression.escapedPattern(for: flag) + "(?=[\\s,]|$)"
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return false }
    return expression.firstMatch(in: help, range: NSRange(help.startIndex..., in: help)) != nil
}

public struct LlamaSupport: Equatable, Sendable {
    public var known = false
    public var threadsBatch = false, batch = false, cacheRam = false
    public var flashAttn = false, cacheTypes = false
    public var mmproj = false, mmprojOffload = false, jinja = false
    public var draft = false, mtp = false, specType = false
    /// "flag" for --no-webui, "value" for --webui none, "" for neither.
    public var webui = ""
    public var alias = false
    /// "--n-gpu-layers", "-ngl" or "" when the build has no GPU flag.
    public var gpuLayers = ""
    public var mtpHeads = false
}

public func supportOf(_ help: String = "") -> LlamaSupport {
    func has(_ flag: String) -> Bool { hasFlag(help, flag) }
    func contains(_ pattern: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return false }
        return expression.firstMatch(in: help, range: NSRange(help.startIndex..., in: help)) != nil
    }
    // A text without --port is no help text at all (the build could not be asked), so the
    // basic flags every llama-server has known for years are kept rather than dropped.
    let known = has("--port")
    var support = LlamaSupport()
    support.known = known
    support.threadsBatch = has("--threads-batch")
    support.batch = has("--batch-size") && has("--ubatch-size")
    support.cacheRam = has("--cache-ram")
    support.flashAttn = has("--flash-attn")
    support.cacheTypes = has("--cache-type-k") && has("--cache-type-v")
    support.mmproj = has("--mmproj")
    support.mmprojOffload = has("--no-mmproj-offload")
    support.jinja = has("--jinja")
    support.draft = has("--spec-draft-model")
    support.mtp = help.contains("draft-mtp")
    support.specType = has("--spec-type")
    // Forks differ in the basics: some have no web UI switch, alias or GPU flag at all,
    // and some take speculative decoding as --spec-type mtp:... from heads inside the model.
    support.webui = !known || has("--no-webui") ? "flag" : has("--webui") ? "value" : ""
    support.alias = !known || has("--alias")
    support.gpuLayers = !known || has("--n-gpu-layers") ? "--n-gpu-layers" : has("-ngl") ? "-ngl" : ""
    support.mtpHeads = has("--spec-type") && contains(#"(^|\s)mtp:"#)
    return support
}

/// A context that fits: the model's training length, capped by the memory left beside the weights.
public func suggestContext(trainingContext: Int? = nil, bytes: Int = 0, totalMemory: Int = 0) -> Int {
    let headroom = totalMemory - bytes - 4 * GiB
    let cap = headroom >= 12 * GiB ? 32768 : headroom >= 6 * GiB ? 16384 : 8192
    let trained = trainingContext.map { $0 >= 512 ? $0 : cap } ?? cap
    return max(512, min(cap, trained, 131072))
}

public struct LaunchPlan: Equatable, Sendable {
    public var args: [String]
    public var features: [String]
    public var support: LlamaSupport
}

/// The llama-server command line for a model. `appleSilicon` is passed in (not detected) to keep
/// this pure: the Metal build then puts every layer on the GPU unless the model sets a count.
public func planLaunch(model: ModelConfig, port: Int, keyFile: String, cores: Int = 4, help: String = "", appleSilicon: Bool = false) -> LaunchPlan {
    let support = supportOf(help)
    let gpuLayers = model.gpuLayers > 0 ? model.gpuLayers : (appleSilicon && !support.gpuLayers.isEmpty ? 999 : 0)
    let cpuOnly = gpuLayers == 0
    let threads = model.threads > 0 ? model.threads : max(1, cores)
    var args = ["--host", "127.0.0.1", "--port", String(port), "--model", model.file, "--ctx-size", String(model.context)]
    // A build without a GPU flag is a CPU build; it is only asked for layers it can place.
    if !support.gpuLayers.isEmpty && (gpuLayers > 0 || support.gpuLayers == "--n-gpu-layers") { args += [support.gpuLayers, String(gpuLayers)] }
    args += ["--threads", String(threads), "--parallel", "1"]
    if support.alias { args += ["--alias", "black-team-local"] }
    args += ["--api-key-file", keyFile]
    if support.webui == "flag" { args.append("--no-webui") } else if support.webui == "value" { args += ["--webui", "none"] }
    var features = ["\(threads) threads"]
    if support.threadsBatch { args += ["--threads-batch", String(threads)] }
    // Smaller batches keep prompt processing memory down on a CPU; a GPU wants the defaults.
    if cpuOnly && support.batch { args += ["--batch-size", "256", "--ubatch-size", "128"] }
    // The prompt cache otherwise claims 8 GiB of RAM beside the model.
    if support.cacheRam { args += ["--cache-ram", "1024"] }
    // Eight-bit KV cache halves context memory; it needs flash attention, which the CPU path provides.
    if support.flashAttn && support.cacheTypes { args += ["--flash-attn", "on", "--cache-type-k", "q8_0", "--cache-type-v", "q8_0"]; features.append("q8 cache") }
    if support.jinja { args.append("--jinja") }
    if !model.mmproj.isEmpty && support.mmproj {
        args += ["--mmproj", model.mmproj]
        if cpuOnly && support.mmprojOffload { args.append("--no-mmproj-offload") }
        features.append("vision")
    }
    if !model.draft.isEmpty && support.specType {
        let name = (model.draft as NSString).lastPathComponent
        let mtp = name.range(of: #"(^|[-_.])mtp([-_.]|$)"#, options: [.regularExpression, .caseInsensitive]) != nil
        if support.draft && (!mtp || support.mtp) {
            args += ["--spec-type", mtp ? "draft-mtp" : "draft-simple", "--spec-draft-model", model.draft]
            features.append(mtp ? "MTP draft" : "draft model")
        } else if mtp && support.mtpHeads {
            // An MTP file beside the model says the model carries MTP heads; a build that reads them itself needs no file.
            args += ["--spec-type", "mtp:n_max=2,p_min=0.0"]
            features.append("MTP")
        }
    }
    return LaunchPlan(args: args, features: features, support: support)
}
