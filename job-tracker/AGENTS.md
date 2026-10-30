# Job Hunt tracker — agent instructions

All data lives in the **`jobs` schema** of Supabase project `abylyjqplyxrpexwyufi`
(cybersquare-outreach), separate from the sales tables in `public`. Agents use the Supabase
connector's `execute_sql`. Always schema-qualify names (`jobs.jobs`, not `jobs`).

## Tables

| Table | What it holds |
|---|---|
| `jobs.profile` | One row (`id = 1`): your details, target titles/locations, keywords, exclusions, `base_cv_text` / `base_cv_url`, and the rules: `min_match_score`, `auto_shortlist`, `require_approval`, `daily_apply_limit`. Edited from the app's Profile tab. |
| `jobs.agent_runs` | One row per agent run: `agent`, `status`, `searches`, `jobs_found`, `jobs_new`, `applications_submitted`, `error`. |
| `jobs.companies` | Companies, unique by name (case-insensitive). Filled by `upsert_job`. |
| `jobs.jobs` | One row per posting. Unique by `url`, also deduped on company + title + location. `status`: `new` → `shortlisted` / `skipped` → `applying` → `applied` (or `expired`, `archived`). |
| `jobs.applications` | One per job applied to. `status`: `queued` → `tailoring` → `ready` → `approved` → `submitted` → `acknowledged` / `screening` / `interview` / `offer` / `accepted` / `rejected` / `no_response`; also `failed`, `withdrawn`. |
| `jobs.cv_versions` | Each tailored CV: `file_url`, `content`, `changes_summary`, `keywords_added`, `ats_score`. |
| `jobs.events` | Timeline. Status changes are logged automatically by a trigger; agents add `email_sent`, `form_submitted`, `email_received`, `cv_tailored`, `error`, `note`. |
| `jobs.pipeline` (view) | Applications joined with job and CV, for reporting. |

The job's own `status` follows its application automatically (any active application → `applying`,
submitted or later → `applied`, withdrawn → `archived`).

## Job Finder agents (1 and 2)

1. Read the profile: `select * from jobs.profile where id = 1;`
2. Start a run and keep its id:
   `insert into jobs.agent_runs (agent) values ('job_finder_1') returning id;`
3. Search the web for postings matching `target_titles`, `target_locations`, `remote_preference`,
   `keywords`; drop anything matching `exclude_keywords` / `exclude_companies` or below `min_salary`.
4. Score each posting 0–100 against `base_cv_text`, then save it (dedupe is handled for you):
   ```sql
   select * from jobs.upsert_job('{
     "company_name": "Acme", "company_website": "https://acme.com",
     "title": "Data Analyst", "location": "Toronto, ON", "work_mode": "hybrid",
     "employment_type": "full_time", "seniority": "mid",
     "salary_min": 80000, "salary_max": 95000, "salary_currency": "CAD",
     "url": "https://…", "source": "linkedin", "source_job_id": "123",
     "posted_at": "2026-10-28", "closes_at": "2026-11-20",
     "apply_method": "email", "apply_email": "jobs@acme.com", "apply_url": null,
     "contact_name": null, "contact_email": null,
     "description": "…", "requirements": "…",
     "match_score": 84, "match_reasons": "SQL, Tableau, 4 yrs analytics",
     "missing_skills": ["dbt"]
   }'::jsonb, 'job_finder_1', <run_id>);
   ```
   Returns `job_id, is_new`. `company_name`, `title` and `url` are required; `apply_method` is one
   of `email`, `web_form`, `ats`, `easy_apply`, `referral`, `other`. When `auto_shortlist` is on,
   new jobs at or above `min_match_score` start as `shortlisted`; otherwise they wait as `new` for
   you to shortlist in the app.
5. Close the run:
   `update jobs.agent_runs set status = 'success', finished_at = now(), jobs_found = …, jobs_new = …, searches = array[…] where id = <run_id>;`
   On failure set `status = 'failed'` and `error`.

Use different `agent` names (`job_finder_1`, `job_finder_2`) so the app shows each separately.

## Applier agent (tailor CV + apply)

1. Start a run: `insert into jobs.agent_runs (agent) values ('applier') returning id;`
2. Read the profile (`require_approval`, `base_cv_text`, contact details).
3. **Prepare** new applications. `select * from jobs.next_to_apply();` returns shortlisted jobs with
   no application yet, best match first, capped by what is left of `daily_apply_limit` today. Also
   pick up applications sent back from the app: `select * from jobs.applications where status = 'queued';`
   (read the latest `note` event for what to change). For each:
   ```sql
   insert into jobs.applications (job_id, method, created_by) values (<job_id>, 'email', 'applier') returning id;
   select jobs.set_application_status(<app_id>, 'tailoring', 'applier');
   -- write the tailored CV (upload to Drive, keep the link)
   insert into jobs.cv_versions (job_id, application_id, label, file_url, content, changes_summary, keywords_added, ats_score, created_by)
   values (…, 'applier') returning id;
   update jobs.applications set cv_version_id = <cv_id>, cover_letter = '…',
     email_to = '…', email_subject = '…', email_body = '…', form_url = '…' where id = <app_id>;
   insert into jobs.events (job_id, application_id, kind, actor, detail) values (<job_id>, <app_id>, 'cv_tailored', 'applier', '<summary>');
   select jobs.set_application_status(<app_id>, 'ready', 'applier');
   ```
4. **Submit** what is cleared: `select * from jobs.ready_to_submit();` (status `approved`, or
   `ready` when `require_approval` is false). For each:
   - Email: send with Gmail (CV attached), then
     `update jobs.applications set gmail_message_id = '…', gmail_thread_id = '…', attempts = attempts + 1 where id = …;`
     and an `email_sent` event.
   - Web form / ATS: fill and submit, then save `form_answers` (`[{"question":…,"answer":…}]`),
     `confirmation_ref`, `attempts = attempts + 1`, and a `form_submitted` event.
   - Then `select jobs.set_application_status(<app_id>, 'submitted', 'applier');` and set
     `follow_up_at = current_date + 7`.
   - On failure: `select jobs.set_application_status(<app_id>, 'failed', 'applier', '<what went wrong>');`
     The app offers **Retry**, which sets it back to `approved`.
5. **Track replies** (optional, same or a separate run): search Gmail for replies on
   `gmail_thread_id`s. For each: an `email_received` event, `last_response_at`, `response_summary`,
   and the new status (`acknowledged`, `screening`, `interview`, `offer`, `rejected`) via
   `set_application_status`. Put interview times in `next_step` / `next_step_at`.
6. Close the run with `applications_submitted = …`.

Never submit an application whose status is not returned by `jobs.ready_to_submit()`.

## What the app writes

| In the app | Writes |
|---|---|
| Jobs → Shortlist / Skip | `jobs.jobs.status`, `status_reason`, plus a `note` event |
| Application → Approve | `set_application_status(id, 'approved', 'app')` |
| Application → Send back | `set_application_status(id, 'queued', 'app', '<your note>')` |
| Application → Retry | `failed` → `approved` |
| Application → Record outcome | status (`screening`, `interview`, `offer`, …), `next_step`, `next_step_at`, note |
| Application → Withdraw | `withdrawn` |
| Profile → Save | `jobs.profile` |
