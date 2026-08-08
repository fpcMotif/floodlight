# Transcript viewer prototype

Type: prototype
Status: open
Blocked by: 01

## Question

What should the friendly rendering of a session actually look like? Build a throwaway SwiftUI prototype (via the mattpocock-skills prototype skill) that renders *real* session files from this machine — at least one each of Claude Code, codex, and pi/omp JSONL — as a readable conversation: role-distinguished bubbles or blocks, tool calls collapsed by default, timestamps, and a plain-JSONL fallback view (record-by-record, keys aligned) for non-session files. React to it with the user:

- Chat layout vs compact log layout for a launcher preview pane?
- How much of a tool call shows collapsed / expanded?
- Does the generic JSONL view earn its place, or is pretty-printing enough?

Link the prototype as an asset; the reaction becomes the viewer section of the spec.
