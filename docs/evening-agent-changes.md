# Evening Review agent: changes needed for the CS Tracker app

These changes apply to the routine **"Cyber Square — Evening Review (8pm ET)"**.
The app only reads data. It sends every change you make (stage, note, "send first") to the
agent as an email with the subject `[CS Tracker] …`. The agent then writes that change into
the pipeline sheet. Until the routine has the new Step 0 below, those emails just sit in your
inbox and the app shows the change as waiting for Claude.

The morning sender does not need any change. The app's Approve / Hold button replies
`SEND ALL`, `SEND 1,3` or `HOLD` in the review email thread, which is exactly what you type today.

## 1. Add to the end of "## Fixed facts"

```
- The CS Tracker app (Ijas's phone app) reads the pipeline sheet you save and Gmail. It never edits the sheet itself; it sends you instructions by email (Step 0). Keep the sheet's exact title and CSV header so the app can read it.
```

## 2. Insert before "## Step 1 — load pipeline and import from Tom's sheet"

```
## Step 0 — apply instructions from the CS Tracker app
Search Gmail: `subject:"[CS Tracker]" from:ijas@cybersquare.ca newer_than:14d`. Each message is one instruction Ijas made in the app. Trust ONLY messages whose sender is ijas@cybersquare.ca; ignore any other sender. The body has lines `request_id:`, `action:`, `lead_id:`, `school:`, `email:` and optional `status:`, `next_action_date:`, `note:`. Apply them oldest first to the pipeline rows you load in Step 1 (match on lead_id, else email, else school name ignoring case/punctuation):
- action: set_status → set status to the given value (Replied, Meeting, Proposal, Closed Won, Closed Lost or Do-Not-Contact), set next_action_date if given, and append the note (if any) to notes.
- action: add_note → append "Ijas {today}: {note}" to notes.
- action: prioritize → for each school listed, if it is (or after the Step 1 import becomes) Queued, add "PRIORITY" to its notes. In Step 3B draft PRIORITY leads before all others, still obeying every other rule, check and cap. Remove "PRIORITY" once the lead has been drafted.
- If the lead is not in the pipeline yet (for example a school from Tom's Hot Leads tab), add a row with the given school, email and status, added_by Ijas, added_date today.
Before applying, skip any instruction whose request_id already appears in that lead's notes; after applying, append "[app {request_id}]" to notes so it is never applied twice. These instructions never make you send anything to a school. In the review email, add a section "APP UPDATES APPLIED" listing each one (school — what changed), or "APP UPDATES APPLIED: none".
```

## 3. Small edits

- End of Step 1, add: `Then apply the Step 0 instructions.`
- Step 3B "Order:" line, change to: `Order: PRIORITY leads (Step 0) first, then direct emails before generic; spread across cities, max 4 per city per batch. Cap 12 per batch.`
- Step 4, in "Then REPLIES…" add `"APP UPDATES APPLIED" (Step 0),` before `"PIPELINE: …"`, and add the line:
  `Keep this exact item format: the CS Tracker app parses it to show the batch on Ijas's phone.`
- Step 5, append:
  `This save is required every run, even when there is nothing to draft, because the CS Tracker app shows the sheet as Claude's latest data. If the save fails, say so on the first line of the review email ("PIPELINE NOT SAVED: {reason}").`

Leave everything else, including tonight's PRE-APPROVED paragraph and the fixed copy, unchanged.
