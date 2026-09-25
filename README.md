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
| Outreach → Up next | `outreach_schedule(15)`: every school due in the next 15 send days, by day. Drafted batches (`planned_actions`) show first with Approve / Hold. Tap a school for its full history. |
| Outreach → Sent this week | `outreach_contacts` touched this week, plus `planned_actions` for this week |
| Lead Bank | `outreach_due` where `next_touch = 1`; counts from `schools` |
| Sync banner | `sync_state.gmail_synced_through`, latest `agent_runs` per agent |

## Outreach schedule

`public.outreach_schedule(p_days int default 10)` (database function) lists who will be emailed on
each upcoming send day (Mon–Fri). It uses the same rules as `outreach_due` and the Evening Review
agent: follow-ups first (up to 20 a day; Touch 2 seven days after Touch 1, Touch 3 fourteen days
after Touch 2), then up to 20 new Touch 1 a day, direct emails first, at most 5 per city. Batches
the agent has already drafted come from `planned_actions`. A projected first email also schedules
that school's later follow-ups, so the calendar always shows whole sequences, and new Lead Finder
schools join the queue as soon as they are added.

Gmail is synced into `messages` by the evening agent, and on demand by the app's **Sync** button
(Today and Pipeline tabs). Between syncs the app also checks the Gmail inbox for replies from
pipeline contacts and marks them "not synced yet".

### What Sync does

It runs the same steps as the Evening Review agent's Step 1 and Step 2:

1. Reads `sync_state.gmail_synced_through` and opens every Gmail conversation with activity since
   then (minus one day; promotions, social and forums are skipped).
2. Classifies each message as outbound, inbound, autoreply, calendar, bounce or bounce_temporary
   (internal mail is skipped) and saves it with `ingest_message()`, which ignores duplicates.
3. New replies from schools the agents cold-email are handled like the agent does: Claude sorts
   them into unsubscribe / not interested (school set to do not contact, contact unsubscribed) or
   a real reply (stage `engaged`, `managed_by_ijas = true`, status note), each with an `activities` row.
4. Moves `gmail_synced_through` to the time the sync started, runs `recompute_school_stats()`,
   logs the run in `agent_runs` as `app_sync`, and reloads every screen.

If any conversation cannot be read, nothing is saved and the sync mark stays put, so tapping
Sync again is always safe.

## What the buttons write

| In the app | Writes |
|---|---|
| Change stage | `schools.stage`, `status_note`, `next_action(_date)`; `managed_by_ijas = true` for Replied / Meeting / Proposal / Client / Closed lost; `do_not_contact` for Do not contact; plus an `activities` row (`status_change`, source `cs-tracker-app`) |
| Add note | `activities` row (`note`), optional `next_action(_date)` |
| Reply with Claude → Send | Gmail reply in the same thread, then `ingest_message(…, 'personal')` and `recompute_school_stats()` |
| Save to Gmail drafts | Gmail draft + `activities` note |
| Approve / Hold → Confirm | Replies `SEND ALL` / `SEND 1,3` / `HOLD` in the evening agent's review thread; Morning Sender v2 reads it at 9:30 am as usual |
| Sync | `messages` (via `ingest_message`), reply handling on `schools` / `contacts` / `activities`, `sync_state`, `agent_runs` |
| Lead Bank → Casa only / Do not contact | `schools.casa_only` or `do_not_contact`; `outreach_due` then excludes them automatically |

Because every agent reads the same tables, no routine changes are needed.

## Connectors used

- Supabase: `execute_sql`
- Gmail: `search_threads`, `get_thread`, `reply`, `create_draft`, `send_message`
- Claude drafting (the artifact `sample` capability), billed to the viewer's Claude plan
