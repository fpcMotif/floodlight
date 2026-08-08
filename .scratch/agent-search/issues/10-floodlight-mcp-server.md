# Floodlight as an MCP server

Type: grilling
Status: open
Blocked by: 05, 06

## Question

Design the server Floodlight exposes to the user's agents (generalizing today's pi-fff wiring):

- **Tools**: file search (FFF), session search (once ticket 06's index exists), open/reveal actions? What's the minimal high-value set?
- **Transport & lifecycle** per ticket 05's recommendation: stdio binary the agents spawn (independent of the running app?) vs the resident app serving local HTTP — and what happens when Floodlight isn't running.
- **Registration story**: how Floodlight installs itself into each agent's MCP config (ticket 04's formats) — a "connect your agents" settings surface?
- **Boundaries**: what an agent may read through this server; any paths/data off-limits.

Resolve via /grilling and /domain-modeling; the answer is the MCP-server section of the spec.
