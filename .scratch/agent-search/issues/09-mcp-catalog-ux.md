# MCP catalog search UX

Type: grilling
Status: open
Blocked by: 04

## Question

What is an MCP catalog hit, and what can you do with it?

- **Entities**: servers, tools, or both as separate result kinds? (Typing "figma" should find the server; typing "screenshot" should find the tool.)
- **Row anatomy**: which agents have it configured, transport, enabled/disabled state, scope (global/project).
- **Actions**: open the declaring config file at the right line, copy the declaration, jump to docs — and whether enable/disable toggling from the launcher is in or out (it edits agent configs).
- **Freshness**: static config parsing per ticket 04's recommendation — when, if ever, to probe a server live for its tool list.

Resolve via /grilling and /domain-modeling; the answer is the catalog section of the spec.
