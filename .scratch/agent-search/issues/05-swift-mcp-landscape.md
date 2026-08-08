# Swift MCP landscape: SDKs, embedding a server, client support

Type: research
Status: open

## Question

Floodlight will both expose an MCP server (so agents can call its search) and act as an MCP client (to invoke tools). Establish against primary sources:

- The official MCP Swift SDK (modelcontextprotocol/swift-sdk): maturity, SwiftPM integration, supported transports (stdio, Streamable HTTP), server *and* client APIs, minimum OS.
- How an always-resident macOS SwiftPM app best hosts a server: stdio child process the agents spawn vs a long-lived local HTTP endpoint from the running app — tradeoffs (one Floodlight instance vs many, auth, discovery).
- How each covered agent registers a third-party MCP server (ties into ticket 04's config formats) — i.e., what Floodlight's "install into your agents" story looks like.
- Client side: using the SDK to spawn/connect to servers and call `tools/list` / `tools/call`, timeouts, sandbox/permissions considerations.

Deliver: a recommended stack and transport for each direction (server, client), with the constraint that Floodlight builds via plain `swift build` (SwiftPM, no Xcode-only deps). Findings → [research/swift-mcp-landscape.md](../research/swift-mcp-landscape.md).
