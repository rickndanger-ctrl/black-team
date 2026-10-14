import Foundation

/// The models Black Team can recommend and download, from small laptops to machines with 64 GB or more.
///
/// Every file, size and SHA-256 below was read from the Hugging Face API (`/api/models/<repo>/tree/main`: `size` and `lfs.oid`) on
/// 2026-10-13; the licence, training context (`gguf.context_length`) and whether the chat template handles tools came from
/// `/api/models/<repo>`. The live check `testLiveCatalogueMatchesHuggingFace` (BLACK_TEAM_LIVE=1, metadata only) repeats this.
/// `StarterModels.all` is the original short list and stays as it was; this is that list and more, smallest first.
public enum ModelCatalogue {
    public static let verifiedOn = "2026-10-13"

    /// Models added to the four starters. Sizes above 14B come from the owner's daily pair (Ornith 1.5 35B-A3B from its makers, Qwen3.8 27B
    /// from unsloth) and a few well-known current open models. Each is one `.gguf` file, so the downloader can resume and check it.
    public static let added: [StarterModel] = [
        StarterModel(
            id: "gemma-4-12b", name: "Gemma 4 12B (medium)",
            summary: "Google's mid-size model: good all-round answers and it can read pictures.",
            repo: "unsloth/gemma-4-12b-it-GGUF", filename: "gemma-4-12b-it-Q4_K_M.gguf",
            bytes: 7_121_861_440, sha256: "0a270ec9fe6b34f4a0d33992b6135117b484ebc4766ab76b51d4ae8c457e4c42",
            license: "Apache-2.0", contextSize: 32768, toolCalling: true,
            vision: StarterVision(repo: "unsloth/gemma-4-12b-it-GGUF", filename: "mmproj-F16.gguf", localName: "gemma-4-12b-it-mmproj-F16.gguf",
                                  bytes: 175_115_840, sha256: "91f086971e56d7a7d8d39e271873fccdb49541bd259d6e02c401a4f1cb7a219e"),
            trainingContext: 262144,
            draft: StarterVision(repo: "unsloth/gemma-4-12b-it-GGUF", filename: "mtp-gemma-4-12b-it.gguf", localName: "gemma-4-12b-it-mtp.gguf",
                                 bytes: 465_109_248, sha256: "145db9094bc0f85f1701e255a2ed216dcc9800fc8bc8631ad00905b456bd451b")),
        StarterModel(
            id: "gpt-oss-20b", name: "gpt-oss 20B (large, fast for its size)",
            summary: "OpenAI's open model. It only uses a fifth of its weights for each word, so it answers quickly for its size.",
            repo: "ggml-org/gpt-oss-20b-GGUF", filename: "gpt-oss-20b-MXFP4.gguf",
            bytes: 12_109_566_624, sha256: "27cd6c432c7672cb812a92f611cf3ba7bbc35928262bb1e1253ff4ee6ae35901",
            license: "Apache-2.0", contextSize: 32768, toolCalling: true,
            trainingContext: 131072, activeFraction: 0.17),
        StarterModel(
            id: "mistral-small-3.2-24b", name: "Mistral Small 3.2 24B (large)",
            summary: "A capable 24B model that follows instructions well and can read pictures.",
            repo: "unsloth/Mistral-Small-3.2-24B-Instruct-2506-GGUF", filename: "Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf",
            bytes: 14_333_922_848, sha256: "a3cc56310807ed0d145eaf9f018ccda9ae7ad8edb41ec870aa2454b0d4700b3c",
            license: "Apache-2.0", contextSize: 32768, toolCalling: true,
            vision: StarterVision(repo: "unsloth/Mistral-Small-3.2-24B-Instruct-2506-GGUF", filename: "mmproj-F16.gguf", localName: "Mistral-Small-3.2-24B-mmproj-F16.gguf",
                                  bytes: 878_053_568, sha256: "d6af684ae9136398eaa0b59ea9e0b0b850bb6ac5084f1e8c5cb8f85251825eaf"),
            trainingContext: 131072, quality: 0.9),
        StarterModel(
            id: "qwen3.8-27b", name: "Qwen3.8 27B (very large)",
            summary: "A strong all-round model with reliable use of tools. Needs a \(Place.kind) with plenty of memory or a good graphics card.",
            repo: "unsloth/Qwen3.8-27B-GGUF", filename: "Qwen3.8-27B-UD-Q4_K_M.gguf",
            bytes: 16_464_440_224, sha256: "322e194ff79741c7baa497c240f677f54b201b0efab44ca8e50f122b39123482",
            license: "Apache-2.0", contextSize: 32768, toolCalling: true,
            vision: StarterVision(repo: "unsloth/Qwen3.8-27B-GGUF", filename: "mmproj-F16.gguf", localName: "Qwen3.8-27B-mmproj-F16.gguf",
                                  bytes: 927_607_488, sha256: "cbb841a9ee0636b2ec172f5bb8df2ea8dfeb01e90fe7c6126581d662a0b4e43e"),
            trainingContext: 262144, quality: 1.15),
        StarterModel(
            id: "gemma-4-26b-a4b", name: "Gemma 4 26B-A4B (very large, fast for its size)",
            summary: "Google's larger model. It uses about a sixth of its weights for each word, so it is quicker than its size suggests, and it can read pictures.",
            repo: "unsloth/gemma-4-26B-A4B-it-GGUF", filename: "gemma-4-26B-A4B-it-UD-Q4_K_M.gguf",
            bytes: 16_947_541_728, sha256: "f2c28b3dc4776931ac6f879e11f203dec637ea0f14267a86ec8f6165f63f293f",
            license: "Apache-2.0", contextSize: 32768, toolCalling: true,
            vision: StarterVision(repo: "unsloth/gemma-4-26B-A4B-it-GGUF", filename: "mmproj-F16.gguf", localName: "gemma-4-26B-A4B-it-mmproj-F16.gguf",
                                  bytes: 1_193_058_784, sha256: "418a6d8723067cd712235facbbc5cba6c8fbbd413fc1292d2aace5a027d5a42f"),
            trainingContext: 262144,
            draft: StarterVision(repo: "unsloth/gemma-4-26B-A4B-it-GGUF", filename: "mtp-gemma-4-26B-A4B-it.gguf", localName: "gemma-4-26B-A4B-it-mtp.gguf",
                                 bytes: 461_766_816, sha256: "6326fb9f5e487aa8dcdd313a091e3c67724cb2a666ec3b7d2895b5b26d93ed1b"),
            activeFraction: 0.15),
        StarterModel(
            id: "ornith-1.5-35b-a3b", name: "Ornith 1.5 35B-A3B (huge, fast for its size)",
            summary: "The big Ornith: very capable with tools, and it uses only about a tenth of its weights for each word, so it is fast for its size.",
            repo: "ornith-ai/Ornith-1.5-35B-A3B-GGUF", filename: "Ornith-1.5-35B-Q4_K_M.gguf",
            bytes: 21_713_463_040, sha256: "42739874cc2ccfdb8523b23fbe52e29b2a7555c8176737ca9ca0b5d59859d41f",
            license: "MIT", contextSize: 32768, toolCalling: true,
            vision: StarterVision(repo: "ornith-ai/Ornith-1.5-35B-A3B-GGUF", filename: "mmproj-Ornith-1.5-35B-BF16.gguf", localName: "Ornith-1.5-35B-mmproj-BF16.gguf",
                                  bytes: 902_822_240, sha256: "1921a36a85aee56cd2abd27f46701802c9d85a33474792e600df6c3b282a135d"),
            trainingContext: 262144, activeFraction: 0.085, quality: 1.5),
        StarterModel(
            id: "gpt-oss-120b", name: "gpt-oss 120B (for 64 GB and up)",
            summary: "OpenAI's largest open model. It needs a computer with 96 GB or more of memory (or a card with that much); it answers quickly for its size.",
            repo: "ggml-org/gpt-oss-120b-GGUF", filename: "gpt-oss-120b-MXFP4.gguf",
            bytes: 63_387_346_208, sha256: "582bd40f6886200101f4c4ed9f25f3fe80cc14c86e9e2b37746cd8904a0c622d",
            license: "Apache-2.0", contextSize: 32768, toolCalling: true,
            trainingContext: 131072, activeFraction: 0.044),
    ]

    /// Everything on offer, smallest first.
    public static let all: [StarterModel] = (StarterModels.all + added).sorted { $0.bytes < $1.bytes }

    public static func model(id: String) -> StarterModel? { all.first { $0.id == id } }

    /// A catalogue model by the file it was saved as (the model in use), or nil.
    public static func model(file: String, dataFolder: URL) -> StarterModel? {
        all.first { $0.destination(in: dataFolder).path == file }
    }
}
