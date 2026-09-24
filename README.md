# Cyber Square Pipeline (CS Tracker)

A mobile tracker for Cyber Square's school outreach. It runs as a private Claude artifact
(`app/index.html`) and reads the same data the Claude outreach agents write.

## Where the data comes from

| Source | Written by | Used for |
|---|---|---|
| Google Sheet "Cyber Square — Claude Pipeline" (pipeline folder) | Evening Review agent, rewritten each run | Stages, notes, reply summaries, Lead Bank (Queued rows) |
| Tom's sheet `CyberSquare_Tom_Tracker` | Tom | Hot Leads (engaged schools) and the Prospect Tracker cold list the agent has not imported yet |
| Gmail (ijas@cybersquare.ca) | You and the agents | Follow-up counts, last contact, "reply waiting", history, the nightly review email, this week's cold sends |

The app finds the newest copy of the pipeline sheet by title, because the agent creates a
new file on every run. Follow-up counts and "reply waiting" come live from Gmail, so they
stay right even when the sheet is behind.

## What the buttons do

| In the app | What happens |
|---|---|
| **Reply with Claude** | Reads the Gmail thread and Claude's notes, drafts a reply with Claude (Regenerate, quick changes, or your own instruction). **Send** replies in the same thread; **Save to Gmail drafts** leaves it for later. |
| **Approve / Hold → Confirm** (Outreach) | Replies `SEND ALL`, `SEND 1,3` or `HOLD` in the evening agent's review thread. The 9:30 am morning sender acts on it as usual. |
| **Change stage**, **Add note** | Emails `[CS Tracker] <school>: …` to ijas@cybersquare.ca. The evening agent applies it to the sheet at 8 pm (see `docs/evening-agent-changes.md`). The app shows it right away and marks it as waiting for Claude. |
| **Send first** (Lead Bank) | Same mechanism: asks the evening agent to draft those schools first. |

Every app action is also logged in the artifact's own store (`actions` collection), so it
shows on every device straight away.

## Setup still needed

Apply `docs/evening-agent-changes.md` to the Evening Review routine. Until you do, stage
changes, notes and "send first" are sent but not written into the sheet.

## Connectors used

- Gmail: `search_threads`, `get_thread`, `reply`, `create_draft`, `send_message`
- Google Drive: `search_files`, `download_file_content`
- Claude drafting (the artifact `sample` capability), billed to the viewer's Claude plan
