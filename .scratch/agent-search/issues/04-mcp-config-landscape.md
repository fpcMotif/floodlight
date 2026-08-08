# MCP configuration landscape across agents

Type: research
Status: resolved

## Question

To index "which MCP servers/tools do my agents have", establish for each covered agent (Claude Code, Claude Desktop, codex, crush, opencode, pi, omp, amp, droid, gemini):

- Where MCP servers are declared: exact file paths and formats (`.mcp.json`, `settings.json`, `config.toml`, etc.), global vs project scope, on this machine and per docs.
- The declaration schema: command/args/env for stdio servers, URLs for HTTP, enable/disable flags.
- How to enumerate a server's *tools*: is tool metadata available statically anywhere (caches, lockfiles), or does enumeration require actually speaking MCP to the server (spawn + `tools/list`)?

Deliver: a config-location matrix plus a recommendation for how a catalog indexer should read them (parse configs statically; whether/when to probe servers live). Findings → [research/mcp-config-landscape.md](../research/mcp-config-landscape.md).

## Answer

**Matrix gist:** all ten agents declare MCP servers in JSON (Codex: TOML) with stdio (`command`/`args`/`env`) or remote (`url`/`headers`, `type` discriminator) transports, but paths and scoping diverge: Claude Code `~/.claude.json` (user+local scope) plus project `.mcp.json` (needs interactive approval); Claude Desktop `claude_desktop_config.json` **plus** a separate DXT extension system (`Claude Extensions/<id>/manifest.json`); Codex `~/.codex/config.toml` `[mcp_servers.*]` (distinct from its `[apps.connector_*]` ChatGPT-Apps blocks — don't conflate); Crush/opencode under `crush.json`/`opencode.json` (global+project); pi `~/.pi/agent/mcp.json` **plus a parallel extension-file path** (`extensions/*.json`, different flat schema); omp (sibling runtime, diverged schema, no tool filtering) `~/.omp/agent/mcp.json`; droid three-level `mcp.json` (user/folder/project); amp `amp.mcpServers` in `settings.json` with workspace-approval gating; Gemini CLI's on-disk layout here (`~/.gemini/config/config.json` + empty `mcp_config.json`) has drifted from current public docs (`~/.gemini/settings.json`).

**Tool caching:** mostly live (`tools/list` on spawn). Exceptions: pi has a real static cache (`mcp-cache.json`, keyed by config hash, full inputSchemas); Claude Code caches remote-server tool lists across sessions (v2.1.221+, undocumented location); Claude Desktop DXT manifests ship a static name+description `tools` array.

**Indexer recommendation:** static-parse all configs for inventory (redact secret-shaped fields beyond just `env`); respect enable/approval flags to avoid overcounting; live-probe only where no cache exists for full tool schemas, caching probe results by config hash; watch the specific files, not directories — resolving Nix-symlinked configs (crush, amp) to real targets; treat Codex Apps and DXT extensions as separate surfaces from plain `mcpServers`.

Full findings: [research/mcp-config-landscape.md](../research/mcp-config-landscape.md)
