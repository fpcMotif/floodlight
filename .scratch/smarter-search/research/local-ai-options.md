# Local AI options for Floodlight's smarter search

Resolves: `.scratch/smarter-search/issues/01-local-ai-options.md`
Date: 2026-08-05

The three AI jobs, with their budgets:

1. **NL file search** — user intent → structured FFF query (terms, filters). Tolerates ~1–3 s.
2. **Explore/answer mode** — conversational answers over the user's files. Tolerates ~1–3 s per turn.
3. **Intent router** — classify query as file / web / app / calculation. Needs ~≤100–300 ms per pause.

Hard constraints: pure SwiftPM app built with `swift build` (see `Makefile`), no extra toolchains at build time, always-resident process (memory matters), fully offline. Current minimum OS: macOS 14. Native deps arrive as prebuilt XCFrameworks (the FFF pattern via `fff-swift`).

## Comparison table

| | Apple Foundation Models | MLX (mlx-swift + mlx-swift-lm) | llama.cpp (XCFramework) | Core ML conversion |
|---|---|---|---|---|
| **Min OS** | macOS 26, Apple Intelligence enabled | macOS 14 (per Package.swift of both repos) | macOS 14 fine (C ABI, no OS gate) | macOS 15 for usable perf (MLState KV cache, fused SDPA) |
| **Hardware** | Apple Silicon (M1+) only | Apple Silicon only (Metal) | Apple Silicon (Metal) *and* Intel (AVX CPU, slow) | Apple Silicon realistically |
| **SwiftPM story** | System framework, `import FoundationModels`, weak-linkable with `#available` | Native SwiftPM packages, **but SwiftPM command-line builds cannot compile Metal shaders — Xcode/xcodebuild required**; breaks Floodlight's `swift build` flow | Official prebuilt `llama-bNNNN-xcframework.zip` in releases → SwiftPM `binaryTarget`, exactly the existing FFF pattern; wrappers: mattt/llama.swift, StanfordBDHG fork | Runtime is built-in, but conversion needs a Python/coremltools pipeline and per-model engineering |
| **Model download** | **0 bytes** — OS-managed ~3B model, shared system-wide | e.g. Qwen2.5-0.5B-4bit 278 MB; Llama-3.2-1B-4bit 695 MB; 3B-4bit ~1.8 GB (Hugging Face) | Same ballpark (GGUF Q4: 0.3–2 GB) | 4-bit Llama-3.1-8B = 4.2 GB in Apple's own writeup |
| **App-resident memory** | ~0 — model lives in the OS, not the app | ~model size + KV cache + runtime (1B 4-bit ≈ 1 GB+ resident) | Same; can load lazily / free after idle | Similar, plus compiled model caching quirks |
| **Speed (indicative)** | TTFT ~0.6 ms/prompt token, ~30 tok/s gen (Apple, iPhone 15 Pro; Macs faster); 1–2 s cold start unless prewarmed | Small models fast; bandwidth-bound. Anchor: llama.cpp 7B Q4 = 14 tok/s (M1) → 83 tok/s (M4 Max); 1B models several× faster (~50–100+ tok/s on M1-class) | Same anchor numbers (its own benchmark); GPU prefill 118 tok/s (M1, 7B) → 886 (M4 Max) | ~33 tok/s decode, 52 ms TTFT (Llama-3.1-8B-int4, M1 Max, macOS 15) |
| **Structured output** | First-class: `@Generable`/`@Guide` constrained decoding + tool calling | MLXGuidedGeneration (JSON Schema / EBNF) | GBNF grammars / JSON-schema constrained sampling | None built in |
| **Context** | 4,096 tokens hard limit per session | Model-dependent (8k–128k) | Model-dependent | Fixed at conversion (e.g. 2048) |
| **Fits ≤300 ms router?** | Borderline (prewarmed, tiny prompt, 1-token verdict) | Yes with a resident 0.5B model — but pays ~0.5–1 GB RAM forever | Same trade | No |
| **Verdict** | **Best default** — zero download, zero resident memory, purpose-built structured output | Good, but Metal-shader/SwiftPM clash + permanent RAM cost | **Best fallback** — matches FFF packaging, only Intel-capable option | **Not practical today** for this use |

## Per-option notes

### 1. Apple Foundation Models framework

- Ships in macOS 26 (also iOS/iPadOS/visionOS 26); runs on any Apple Intelligence-compatible device (Apple Silicon Mac, M1+) with Apple Intelligence enabled. Direct Swift API over the on-device LLM. Sources: [WWDC25 "Meet the Foundation Models framework"](https://developer.apple.com/videos/play/wwdc2025/286/), [Apple Newsroom, Sep 2025](https://www.apple.com/newsroom/2025/09/apples-foundation-models-framework-unlocks-new-intelligent-app-experiences/), [framework docs](https://developer.apple.com/documentation/foundationmodels).
- **Guided generation**: `@Generable` + `@Guide` macros make the model emit instances of your Swift types via *constrained decoding* — structure is enforced during generation, not validated after. Ideal for job 1 (emit an FFF query struct: terms, extension filter, path scope, date range) and job 3 (emit one enum case). Also: tool calling, streaming, `LanguageModelSession`, `prewarm()`. Sources: [WWDC25 deep dive](https://developer.apple.com/videos/play/wwdc2025/301/), [code-along](https://developer.apple.com/videos/play/wwdc2025/259/).
- **Model & latency**: ~3B parameters, mixed 2/4-bit quantization (~3.5–3.7 bpw). Apple's published numbers (iPhone 15 Pro): TTFT ~0.6 ms per prompt token, ~30 tok/s generation — M-series Macs are faster. Source: [Apple ML Research: Introducing Apple's On-Device and Server Foundation Models](https://machinelearning.apple.com/research/introducing-apple-foundation-models).
- **Real-app caveats**: 1–2 s cold start unless the session is prewarmed at launcher-show time; three distinct unavailability states to handle (unsupported hardware, AI toggled off, model still downloading); 4,096-token context shared by instructions + turns + tool output — explore mode needs summarize-and-trim discipline. Sources: [Drobinin, shipping FM in a real app](https://drobinin.com/consulting/foundation-models-apple-intelligence/putting-apple-foundation-models-in-a-real-app/), [TN3193: Managing the on-device foundation model's context window](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window) (26.4 adds `contextSize` / `tokenCount(for:)`, per [InfoQ](https://infoq.com/news/2026/03/apple-foundation-models-context)).
- **Cost of requiring macOS 26**: Tahoe runs on all Apple Silicon Macs but only 4 Intel models (which can't run Apple Intelligence anyway); macOS 27 drops Intel entirely. Sources: [EveryMac compatibility list](https://everymac.com/mac-answers/macos-26-tahoe-faq/macos-tahoe-macos-26-compatbility-list-system-requirements.html), [Macworld](https://www.macworld.com/article/673697/what-version-of-macos-can-my-mac-run.html). **But raising the minimum is unnecessary**: `FoundationModels` can be weak-linked and gated with `if #available(macOS 26.0, *)` plus `SystemLanguageModel.default.availability` at runtime. Floodlight keeps macOS 14; AI features simply light up on capable systems.
- The decisive launcher-specific win: **zero download and zero resident memory in the app** — the OS hosts one shared model. For an always-resident menu-bar process this beats every self-hosted option.

### 2. MLX / mlx-swift + mlx-swift-lm

- [mlx-swift](https://github.com/ml-explore/mlx-swift) is SwiftPM-native; declares `.macOS("14.0")` ([Package.swift](https://raw.githubusercontent.com/ml-explore/mlx-swift/main/Package.swift)). Apple Silicon only (Metal backend).
- LLM layers moved from mlx-swift-examples to [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm): MLXLLM, MLXLMCommon, MLXEmbedders, **MLXGuidedGeneration** (JSON Schema / EBNF constrained generation), MLXFoundationModels bridge; also `.macOS(.v14)` ([Package.swift](https://raw.githubusercontent.com/ml-explore/mlx-swift-lm/main/Package.swift)). Models pulled from Hugging Face via swift-huggingface/swift-transformers.
- **Blocker for this repo**: per the mlx-swift README, *SwiftPM command-line builds cannot compile Metal shaders — Xcode is required*. Floodlight builds with plain `swift build` (`Makefile`, `scripts/bundle.sh`), so adopting MLX means moving the build to xcodebuild or maintaining a workaround. That's a real build-system tax, though not a Rust-style foreign toolchain.
- Sizes (Hugging Face, 4-bit MLX community builds): [Qwen2.5-0.5B-Instruct-4bit = 278 MB](https://huggingface.co/mlx-community/Qwen2.5-0.5B-Instruct-4bit), [Llama-3.2-1B-Instruct-4bit = 695 MB](https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit); 3B-class ≈ 1.7–1.8 GB. Resident memory ≈ weights + KV cache + runtime; figure ~1 GB+ for a 1B model kept warm.
- Throughput on M-series is ample for the 1–3 s jobs; on small (≤3B) models MLX and llama.cpp are roughly tied per third-party comparisons ([local-llm.net](https://www.local-llm.net/compare/llama-cpp-vs-mlx/), [sitepoint 2026 guide](https://www.sitepoint.com/local-llms-apple-silicon-mac-2026/) — secondary sources).

### 3. llama.cpp

- C/C++; Metal on Apple Silicon, AVX CPU path on Intel — the **only** option here that can serve Intel Macs on macOS 14 at all (slowly). Source: [llama.cpp README](https://github.com/ggml-org/llama.cpp).
- The project **publishes an official prebuilt XCFramework per release** (`llama-bNNNN-xcframework.zip`, built by `build-xcframework.sh`), consumable as a SwiftPM `binaryTarget` — the same pattern Floodlight already uses for FFF's Rust core via `fff-swift`. No toolchain added at build time. Sources: [Swift Package Registry entry showing the binaryTarget recipe](https://swiftpackageregistry.com/ggml-org/llama.cpp), [mattt/llama.swift](https://github.com/mattt/llama.swift) (thin Swift package over the official XCFramework), [StanfordBDHG llama.cpp fork](https://swiftpackageregistry.com/StanfordBDHG/llama.cpp).
- GGUF models (same HF ecosystem, Q4 sizes match the MLX numbers above). Grammar-constrained sampling (GBNF / JSON schema) covers structured FFF-query output.
- Benchmarks from the project's own [Apple Silicon M-series discussion](https://github.com/ggml-org/llama.cpp/discussions/4167) (7B Q4_0): M1 = 118 tok/s prefill / 14 tok/s gen; M2 Pro = 294/38; M3 Max = 760/66; M4 Max = 886/83. Generation is memory-bandwidth-bound, so 1B-class models run several times faster — comfortably inside the 1–3 s budget even on M1.

### 4. Core ML conversions

- Apple's own best case: [Llama-3.1-8B-Instruct on Core ML](https://machinelearning.apple.com/research/core-ml-on-device-llama) — requires macOS 15's stateful KV cache (`MLState`, ~13× speedup) and fused SDPA, block-wise int4 (16 GB → 4.2 GB), reaching ~33 tok/s and 52 ms TTFT on M1 Max at 2048 context.
- It works, but the workflow is a Python/coremltools conversion pipeline with fixed shapes and hand-tuned state management, few maintained prebuilt instruct-model packages exist, and there's no constrained-decoding story. Every criterion it wins on, Foundation Models (same OS family, zero effort) or llama.cpp (older OS, less effort) wins harder. **Not practical for Floodlight today.**

## Latency reality check for the router (job 3)

Even the best LLM path is marginal at ≤100–300 ms: a prewarmed Foundation Models session with a ~200-token prompt costs ~120 ms of prefill plus ~33 ms per output token — feasible for a one-token enum verdict on a good day, but cold starts (1–2 s) and per-keystroke invocation kill it. A resident 0.5B MLX/llama.cpp model could also make the window, but only by pinning ~0.5–1 GB of RAM in an always-on launcher. Routing is also mostly *not a language problem*: `2+2*7` → calculation, URL-shaped / "search for" → web, prefix-matches a known app name → app, else file. Deterministic rules (optionally plus a trivial keyword/embedding score via the built-in NaturalLanguage framework) give a 0 ms verdict with no failure modes.

## Recommendation

**Primary stack: Apple Foundation Models, weak-linked; keep the SwiftPM minimum at macOS 14.**

- **Job 3 (router):** deterministic heuristics, always, on every OS — regex/lexical rules for calculation, URL/web, and app-name matches, defaulting to file search. Optionally refine ambiguous cases with a prewarmed Foundation Models `@Generable` enum classification, fired only on an idle pause, only when available. No model download, no memory cost, verdicts in microseconds.
- **Job 1 (NL file search):** Foundation Models guided generation — `@Generable` struct mirroring FFF's query surface (terms, extensions, path scopes, date/size filters), constrained decoding guarantees a well-formed query. Prewarm the session when the launcher window appears.
- **Job 2 (explore/answer):** Foundation Models with tool calling — expose FFF search and a bounded file-snippet reader as tools; manage the 4,096-token window aggressively (summarize prior turns, cap tool output).
- **Availability line:** AI features require macOS 26 + Apple Silicon (M1+) + Apple Intelligence enabled; everywhere else (macOS 14–15, Intel, AI disabled) Floodlight behaves exactly as today, with the heuristic router still active. Handle the three distinct unavailability states explicitly.
- **Fallback, only if AI on macOS 14–15 becomes a product requirement:** llama.cpp via its official prebuilt XCFramework as a SwiftPM binary target (the proven FFF pattern) with a Qwen2.5-1.5B/Llama-3.2-1B Q4 GGUF (~0.7–1 GB download), loaded lazily and unloaded after idle to respect the resident-memory budget. Prefer this over MLX solely because MLX's Metal shaders can't be compiled by command-line SwiftPM, which conflicts with Floodlight's `swift build`-based Makefile; revisit MLX if the build ever moves to xcodebuild.
- **Core ML conversions:** skip.

Net effect: no new build-time toolchain, no bundled weights, no resident memory growth, minimum OS unchanged at macOS 14 — and the AI hardware line lands where the platform is already going (Apple Silicon + macOS 26, with Intel fully sunset in macOS 27).
