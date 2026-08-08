# Invoking MCP tools from Floodlight

Type: grilling
Status: open
Blocked by: 09, 10

## Question

The heaviest strand, last by standing priority: Floodlight as an MCP *client*, running tools straight from the launcher.

- **Which servers**: only ones already declared in agent configs (ticket 04's catalog), or Floodlight-owned declarations too?
- **Lifecycle**: when does Floodlight spawn/connect (on demand per invocation? warm pool?), timeouts, teardown for an always-resident app.
- **UX**: how a tool's input schema becomes a launcher interaction (args typed after a keyword? a small form?), where output renders, and history.
- **Safety**: confirmation before side-effectful tools, and how Floodlight tells read-only from side-effectful.

Resolve via /grilling and /domain-modeling; the answer is the invocation section of the spec — or, if the discussion concludes the value isn't there, a deliberate cut recorded on the map.
