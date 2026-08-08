# Local AI options for on-device search

Type: research
Status: resolved

## Question

Which on-device AI option should power Floodlight's three AI jobs — natural-language file search, explore/answer mode, and query intent routing? Compare, against primary sources:

- **Apple Foundation Models framework** (macOS 26+, Apple Silicon): capabilities, guided generation/structured output, tool calling, latency; the cost of raising Floodlight's minimum from macOS 14.
- **MLX / mlx-swift** with a small open model (Qwen, Llama 3.2 1B/3B, etc.): Swift Package Manager integration, model download/size, memory footprint.
- **llama.cpp** (or a Swift wrapper): same criteria.
- **Core ML** conversions: whether they're practical for small instruct models today.

Constraints that matter: Floodlight is a Swift Package Manager app (no Rust toolchain at build time, per README); a launcher has a tight latency budget — intent routing needs a verdict in roughly ≤100–300 ms to be useful per keystroke or per pause, while NL file search and explore mode can tolerate ~1–3 s; memory footprint matters for an always-resident background app; everything must run offline (cloud is out of scope for this effort).

Deliver: a comparison table plus a recommendation — which stack for which of the three jobs (they need not share one answer; e.g. a heuristic or tiny model for routing, a bigger model for explore mode), and what minimum-OS/hardware line it implies.

## Answer

Use Apple's Foundation Models framework as the primary AI stack, weak-linked with `#available(macOS 26, *)` so Floodlight's SwiftPM minimum stays at macOS 14: NL file search via `@Generable` guided generation emitting a structured FFF query, and explore mode via tool calling over FFF with careful management of the 4,096-token context. The intent router should be deterministic heuristics (math/URL/app-name rules, 0 ms, every OS), with optional Foundation Models refinement on idle pause — no LLM reliably fits ≤100–300 ms per keystroke. Foundation Models wins for an always-resident launcher because the OS hosts the ~3B model: zero download, zero app-resident memory. If AI on macOS 14–15 ever becomes a requirement, fall back to llama.cpp's official prebuilt XCFramework as a SwiftPM binary target (the existing FFF pattern) with a ~1B Q4 GGUF; MLX conflicts with the `swift build` Makefile (SwiftPM CLI can't compile Metal shaders), and Core ML conversions are not practical today. Effective AI hardware line: Apple Silicon (M1+) on macOS 26 with Apple Intelligence enabled; everyone else keeps today's non-AI behavior plus the heuristic router.

Full findings: [research/local-ai-options.md](../research/local-ai-options.md)
