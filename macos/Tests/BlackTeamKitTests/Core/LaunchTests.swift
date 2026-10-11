import XCTest
@testable import BlackTeamKit

private let MAINLINE = "-t, --threads N\n-tb, --threads-batch N\n-b, --batch-size N\n-ub, --ubatch-size N\n-cram, --cache-ram N\n-fa, --flash-attn [on|off|auto]\n-ctk, --cache-type-k TYPE\n-ctv, --cache-type-v TYPE\n-mm, --mmproj FILE\n--mmproj-offload, --no-mmproj-offload\n--jinja, --no-jinja\n--spec-draft-model, -md, --model-draft FNAME\n--spec-type none,draft-simple,draft-eagle3,draft-mtp,ngram-simple\n"
private let FORK = "--host HOST\n--port PORT\n-t, --threads N\n-tb, --threads-batch N\n-b, --batch-size N\n-ub, --ubatch-size N\n-np, --parallel N\n--cache-ram N\n-fa, --flash-attn [on|off|auto]\n-ctk, --cache-type-k TYPE\n-ctv, --cache-type-v TYPE\n--mmproj FILE\n--no-mmproj-offload\n--jinja\n--api-key-file FNAME\n--webui NAME controls which webui to server: none, auto\n-md, --model-draft FNAME\n--spec-type SPEC[:k=v,...] canonical speculative stage entry.\n  examples: --spec-type mtp:n_max=1,p_min=0.0\n"
private let GiB = 1024 * 1024 * 1024

private func baseModel() -> ModelConfig {
    ModelConfig(file: "/m/q.gguf", runtime: "", context: 32768, gpuLayers: 0, threads: 0, mmproj: "/m/mmproj-F16.gguf", draft: "/m/mtp-q.gguf")
}

private func after(_ plan: LaunchPlan, _ flag: String) -> String? {
    guard let at = plan.args.firstIndex(of: flag), at + 1 < plan.args.count else { return nil }
    return plan.args[at + 1]
}

final class LaunchTests: XCTestCase {
    func testFullFeaturedBuildGetsTunedCPUSettings() {
        let plan = planLaunch(model: baseModel(), port: 5000, keyFile: "/k", cores: 6, help: MAINLINE)
        XCTAssertEqual(after(plan, "--threads"), "6"); XCTAssertEqual(after(plan, "--threads-batch"), "6")
        XCTAssertEqual(after(plan, "--batch-size"), "256"); XCTAssertEqual(after(plan, "--ubatch-size"), "128")
        XCTAssertEqual(after(plan, "--cache-ram"), "1024"); XCTAssertEqual(after(plan, "--flash-attn"), "on")
        XCTAssertEqual(after(plan, "--cache-type-k"), "q8_0"); XCTAssertEqual(after(plan, "--cache-type-v"), "q8_0")
        XCTAssertEqual(after(plan, "--mmproj"), "/m/mmproj-F16.gguf"); XCTAssertTrue(plan.args.contains("--no-mmproj-offload"))
        XCTAssertEqual(after(plan, "--spec-type"), "draft-mtp"); XCTAssertEqual(after(plan, "--spec-draft-model"), "/m/mtp-q.gguf")
        XCTAssertTrue(plan.args.contains("--jinja") && plan.args.contains("--no-webui"))
        XCTAssertEqual(plan.features, ["6 threads", "q8 cache", "vision", "MTP draft"])
        XCTAssertEqual(after(plan, "--api-key-file"), "/k")
    }

    func testBuildThatKnowsNoFlagsGetsOnlyTheBasicLaunch() {
        var model = baseModel(); model.threads = 4
        let plan = planLaunch(model: model, port: 5000, keyFile: "/k", cores: 6, help: "fixture runtime")
        XCTAssertEqual(plan.args, ["--host", "127.0.0.1", "--port", "5000", "--model", "/m/q.gguf", "--ctx-size", "32768", "--n-gpu-layers", "0", "--threads", "4", "--parallel", "1", "--alias", "black-team-local", "--api-key-file", "/k", "--no-webui"])
        XCTAssertEqual(plan.features, ["4 threads"])
    }

    func testGPULaunchKeepsDefaultBatchesAndDraftTypeFollowsTheFile() {
        var gpuModel = baseModel(); gpuModel.gpuLayers = 40; gpuModel.draft = ""
        let gpu = planLaunch(model: gpuModel, port: 1, keyFile: "/k", cores: 6, help: MAINLINE)
        XCTAssertFalse(gpu.args.contains("--batch-size")); XCTAssertFalse(gpu.args.contains("--no-mmproj-offload"))
        var plainModel = baseModel(); plainModel.draft = "/m/small-draft.gguf"
        XCTAssertEqual(after(planLaunch(model: plainModel, port: 1, keyFile: "/k", cores: 6, help: MAINLINE), "--spec-type"), "draft-simple")
        // An MTP file is left out of a build that cannot use it, rather than failing the start.
        let old = planLaunch(model: baseModel(), port: 1, keyFile: "/k", cores: 6, help: MAINLINE.replacingOccurrences(of: "draft-mtp,", with: ""))
        XCTAssertFalse(old.args.contains("--spec-type"))
        XCTAssertTrue(supportOf(MAINLINE).mtp); XCTAssertFalse(supportOf("").cacheTypes)
    }

    func testForkWithoutTheBasicFlagsIsGivenOnlyWhatItKnows() {
        let plan = planLaunch(model: baseModel(), port: 7, keyFile: "/k", cores: 6, help: FORK)
        for flag in ["--no-webui", "--alias", "--n-gpu-layers", "--spec-draft-model"] { XCTAssertFalse(plan.args.contains(flag), flag) }
        XCTAssertEqual(after(plan, "--webui"), "none"); XCTAssertEqual(after(plan, "--spec-type"), "mtp:n_max=2,p_min=0.0")
        XCTAssertEqual(after(plan, "--api-key-file"), "/k"); XCTAssertEqual(after(plan, "--cache-type-k"), "q8_0"); XCTAssertEqual(after(plan, "--mmproj"), "/m/mmproj-F16.gguf")
        XCTAssertEqual(plan.features, ["6 threads", "q8 cache", "vision", "MTP"])
        var plainModel = baseModel(); plainModel.draft = "/m/small-draft.gguf"
        XCTAssertFalse(planLaunch(model: plainModel, port: 7, keyFile: "/k", cores: 6, help: FORK).args.contains("--spec-type"))
        var nglModel = baseModel(); nglModel.gpuLayers = 20
        let ngl = planLaunch(model: nglModel, port: 7, keyFile: "/k", cores: 6, help: FORK + "-ngl, --gpu-layers N\n")
        XCTAssertEqual(after(ngl, "-ngl"), "20"); XCTAssertFalse(ngl.args.contains("--n-gpu-layers"))
        let bare = planLaunch(model: baseModel(), port: 7, keyFile: "/k", cores: 6, help: FORK.replacingOccurrences(of: "--webui NAME controls which webui to server: none, auto\n", with: ""))
        XCTAssertFalse(bare.args.contains("--webui")); XCTAssertFalse(bare.args.contains("--no-webui"))
    }

    func testAppleSiliconAsksForAllLayersOnTheGPUUnlessTheModelSetsACount() {
        let metal = planLaunch(model: baseModel(), port: 5, keyFile: "/k", cores: 6, help: MAINLINE + "--port PORT\n--n-gpu-layers N\n", appleSilicon: true)
        XCTAssertEqual(after(metal, "--n-gpu-layers"), "999")
        XCTAssertFalse(metal.args.contains("--batch-size"), "a GPU launch keeps the default batches")
        XCTAssertFalse(metal.args.contains("--no-mmproj-offload"))
        var counted = baseModel(); counted.gpuLayers = 12
        XCTAssertEqual(after(planLaunch(model: counted, port: 5, keyFile: "/k", help: "--port PORT\n--n-gpu-layers N\n", appleSilicon: true), "--n-gpu-layers"), "12")
        // A build with no GPU flag is left alone, and so is any other computer.
        let noFlag = planLaunch(model: baseModel(), port: 5, keyFile: "/k", help: FORK, appleSilicon: true)
        XCTAssertFalse(noFlag.args.contains("--n-gpu-layers") || noFlag.args.contains("-ngl"))
        let intel = planLaunch(model: baseModel(), port: 5, keyFile: "/k", help: "--port PORT\n--n-gpu-layers N\n", appleSilicon: false)
        XCTAssertEqual(after(intel, "--n-gpu-layers"), "0")
        let ngl = planLaunch(model: baseModel(), port: 5, keyFile: "/k", help: FORK + "-ngl, --gpu-layers N\n", appleSilicon: true)
        XCTAssertEqual(after(ngl, "-ngl"), "999")
    }

    func testSuggestedContextFollowsTrainingLengthAndMemoryLeft() {
        XCTAssertEqual(suggestContext(trainingContext: 262144, bytes: 17 * GiB, totalMemory: 46 * GiB), 32768)
        XCTAssertEqual(suggestContext(trainingContext: 262144, bytes: 17 * GiB, totalMemory: 28 * GiB), 16384)
        XCTAssertEqual(suggestContext(trainingContext: 262144, bytes: 17 * GiB, totalMemory: 22 * GiB), 8192)
        XCTAssertEqual(suggestContext(trainingContext: 4096, bytes: GiB, totalMemory: 64 * GiB), 4096)
        XCTAssertEqual(suggestContext(trainingContext: nil, bytes: GiB, totalMemory: 64 * GiB), 32768)
    }
}
