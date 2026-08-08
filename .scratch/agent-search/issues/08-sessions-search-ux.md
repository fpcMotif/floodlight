# Sessions search UX

Type: grilling
Status: open
Blocked by: 01, 02

## Question

How do session hits surface in the launcher?

- **Entry**: mixed into All with their own ranking band, a dedicated Sessions filter tab, a keyword prefix (e.g. `s `), or some combination? Must coordinate with the smarter-search map's open filter-tab and keyword-trigger questions rather than invent a colliding mechanism.
- **Row anatomy**: agent icon, session title, project name, age, matching snippet — what fits Floodlight's row?
- **Actions**: Enter = resume in the agent at the project dir (standing decision); the secondary-actions menu (transcript view, reveal in Finder) and their keybindings; the fallback when an agent can't resume by id (ticket 02's matrix).
- **Ranking**: recency-weighted? project-affinity (boost sessions from the frontmost project)?

Resolve via /grilling and /domain-modeling; the answer is the sessions-UX section of the spec.
