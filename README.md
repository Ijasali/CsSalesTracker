# Cyber Square Pipeline (CS Tracker)

A mobile tracker for Cyber Square's school outreach. It runs as a private Claude artifact
(`app/index.html`) and uses the **Supabase database as the only source of truth** — the same
database the Claude agents (Lead Finder v2, Evening Review v2, Morning Sender v2, Nightly Backup) use.
Google Sheets are not used.

## Where each screen gets its data (Supabase project `abylyjqplyxrpexwyufi`)

| Screen | Reads |
|---|---|
| Today / Pipeline | `schools` in stages engaged, meeting_booked, proposal_sent, client (or with replies), their `contacts`, and the latest `messages`. Follow-ups = our emails after the school's first reply. |
| Lead detail | `school_timeline` (emails + activities) and `messages` |
| Outreach → Next batch | `planned_actions` (kind `cold_auto`) for the next planned day |
| Outreach → This week | `outreach_contacts` touched this week, plus `planned_actions` for this week |
| Lead Bank | `outreach_due` where `next_touch = 1`; counts from `schools` |
| Sync banner | `sync_state.gmail_synced_through`, latest `agent_runs` per agent |

Gmail is synced into `messages` by the evening agent. Between syncs the app also checks the
Gmail inbox for replies from pipeline contacts and marks them "not synced yet".

## What the buttons write

| In the app | Writes |
|---|---|
| Change stage | `schools.stage`, `status_note`, `next_action(_date)`; `managed_by_ijas = true` for Replied / Meeting / Proposal / Client / Closed lost; `do_not_contact` for Do not contact; plus an `activities` row (`status_change`, source `cs-tracker-app`) |
| Add note | `activities` row (`note`), optional `next_action(_date)` |
| Reply with Claude → Send | Gmail reply in the same thread, then `ingest_message(…, 'personal')` and `recompute_school_stats()` |
| Save to Gmail drafts | Gmail draft + `activities` note |
| Approve / Hold → Confirm | Replies `SEND ALL` / `SEND 1,3` / `HOLD` in the evening agent's review thread; Morning Sender v2 reads it at 9:30 am as usual |
| Lead Bank → Casa only / Do not contact | `schools.casa_only` or `do_not_contact`; `outreach_due` then excludes them automatically |

Because every agent reads the same tables, no routine changes are needed.

## Connectors used

- Supabase: `execute_sql`
- Gmail: `search_threads`, `get_thread`, `reply`, `create_draft`, `send_message`
- Claude drafting (the artifact `sample` capability), billed to the viewer's Claude plan
