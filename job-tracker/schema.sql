-- Job applications tracker. Lives in its own `jobs` schema inside the
-- cybersquare-outreach Supabase project, isolated from the sales tables.
-- Agents and the app reach it through the Supabase connector (execute_sql);
-- the schema is not exposed to the REST API and RLS is on with no policies.

create schema if not exists jobs;

-- ---------- profile: one row, what the agents search and apply with ----------
create table jobs.profile (
  id                   int primary key default 1 check (id = 1),
  full_name            text,
  email                text,
  phone                text,
  location             text,
  linkedin_url         text,
  portfolio_url        text,
  headline             text,
  summary              text,
  target_titles        text[] not null default '{}',
  target_locations     text[] not null default '{}',
  remote_preference    text not null default 'any' check (remote_preference in ('any','remote','hybrid','onsite')),
  keywords             text[] not null default '{}',
  exclude_keywords     text[] not null default '{}',
  exclude_companies    text[] not null default '{}',
  min_salary           numeric,
  salary_currency      text default 'CAD',
  base_cv_url          text,          -- Google Drive / storage link to the master CV
  base_cv_text         text,          -- plain-text master CV the tailoring agent works from
  min_match_score      int not null default 70 check (min_match_score between 0 and 100),
  auto_shortlist       boolean not null default false,  -- finder agents may shortlist jobs >= min_match_score
  require_approval     boolean not null default true,   -- applier must wait for approval before submitting
  daily_apply_limit    int not null default 10,
  updated_at           timestamptz not null default now()
);
insert into jobs.profile (id) values (1) on conflict do nothing;

-- ---------- agent runs: every agent logs each run ----------
create table jobs.agent_runs (
  id            bigint generated always as identity primary key,
  agent         text not null,                       -- e.g. job_finder_1, job_finder_2, applier
  started_at    timestamptz not null default now(),
  finished_at   timestamptz,
  status        text not null default 'running' check (status in ('running','success','partial','failed')),
  searches      text[] not null default '{}',        -- queries / sources searched
  jobs_found    int not null default 0,
  jobs_new      int not null default 0,
  applications_submitted int not null default 0,
  error         text,
  notes         text
);
create index on jobs.agent_runs (agent, started_at desc);

-- ---------- companies ----------
create table jobs.companies (
  id           bigint generated always as identity primary key,
  name         text not null,
  website      text,
  linkedin_url text,
  industry     text,
  size         text,
  hq_location  text,
  notes        text,
  created_at   timestamptz not null default now()
);
create unique index companies_name_key on jobs.companies (lower(name));

-- ---------- jobs: one row per posting found ----------
create table jobs.jobs (
  id              bigint generated always as identity primary key,
  company_id      bigint references jobs.companies(id) on delete set null,
  company_name    text not null,
  title           text not null,
  location        text,
  work_mode       text check (work_mode in ('remote','hybrid','onsite')),
  employment_type text check (employment_type in ('full_time','part_time','contract','temporary','internship')),
  seniority       text,
  salary_min      numeric,
  salary_max      numeric,
  salary_currency text,
  description     text,
  requirements    text,
  url             text not null,                    -- the posting
  source          text,                             -- linkedin, indeed, glassdoor, company_site ...
  source_job_id   text,
  posted_at       date,
  closes_at       date,
  apply_method    text check (apply_method in ('email','web_form','ats','easy_apply','referral','other')),
  apply_email     text,
  apply_url       text,
  contact_name    text,
  contact_email   text,
  match_score     int check (match_score between 0 and 100),
  match_reasons   text,
  missing_skills  text[] not null default '{}',
  status          text not null default 'new'
                  check (status in ('new','shortlisted','skipped','applying','applied','expired','archived')),
  status_reason   text,
  found_by        text,                             -- agent name
  found_run_id    bigint references jobs.agent_runs(id) on delete set null,
  dedupe_key      text generated always as (
                    lower(regexp_replace(company_name || '|' || title || '|' || coalesce(location,''), '\s+', ' ', 'g'))
                  ) stored,
  times_seen      int not null default 1,
  last_seen_at    timestamptz not null default now(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create unique index jobs_url_key on jobs.jobs (url);
create index on jobs.jobs (dedupe_key);
create index on jobs.jobs (status, match_score desc);
create index on jobs.jobs (created_at desc);

-- ---------- applications: one per job applied to ----------
create table jobs.applications (
  id                 bigint generated always as identity primary key,
  job_id             bigint not null unique references jobs.jobs(id) on delete cascade,
  status             text not null default 'queued' check (status in (
                       'queued',            -- picked for applying
                       'tailoring',         -- CV / cover letter being written
                       'ready',             -- materials ready, waiting for approval
                       'approved',          -- cleared to submit
                       'submitted',         -- email sent / form submitted
                       'failed',            -- submission failed (see error)
                       'acknowledged',      -- employer confirmed receipt
                       'screening',         -- recruiter call / assessment
                       'interview',
                       'offer',
                       'accepted',
                       'rejected',
                       'withdrawn',
                       'no_response')),
  method             text check (method in ('email','web_form','ats','easy_apply','referral','other')),
  cv_version_id      bigint,
  cover_letter       text,
  email_to           text,
  email_subject      text,
  email_body         text,
  gmail_message_id   text,
  gmail_thread_id    text,
  form_url           text,
  form_answers       jsonb,                         -- [{question, answer}]
  confirmation_ref   text,                          -- confirmation number / screenshot link
  submitted_at       timestamptz,
  approved_at        timestamptz,
  approved_by        text,
  last_response_at   timestamptz,
  response_summary   text,
  next_step          text,
  next_step_at       timestamptz,
  follow_up_at       date,
  attempts           int not null default 0,
  error              text,
  notes              text,
  created_by         text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index on jobs.applications (status);
create index on jobs.applications (submitted_at desc);

-- ---------- tailored CVs ----------
create table jobs.cv_versions (
  id               bigint generated always as identity primary key,
  job_id           bigint references jobs.jobs(id) on delete cascade,
  application_id   bigint references jobs.applications(id) on delete cascade,
  label            text,
  file_url         text,             -- Drive / PDF link that gets attached
  content          text,             -- CV text as sent (markdown)
  changes_summary  text,             -- what was tailored and why
  keywords_added   text[] not null default '{}',
  ats_score        int check (ats_score between 0 and 100),
  created_by       text,
  created_at       timestamptz not null default now()
);
alter table jobs.applications
  add constraint applications_cv_version_fk foreign key (cv_version_id) references jobs.cv_versions(id) on delete set null;

-- ---------- timeline of everything that happens to an application ----------
create table jobs.events (
  id              bigint generated always as identity primary key,
  job_id          bigint references jobs.jobs(id) on delete cascade,
  application_id  bigint references jobs.applications(id) on delete cascade,
  at              timestamptz not null default now(),
  kind            text not null check (kind in (
                    'found','status_change','cv_tailored','email_sent','form_submitted',
                    'email_received','interview_scheduled','follow_up','note','error')),
  from_status     text,
  to_status       text,
  actor           text,              -- agent name, 'app' or a person
  detail          text,
  data            jsonb
);
create index on jobs.events (application_id, at desc);
create index on jobs.events (job_id, at desc);
create index on jobs.events (at desc);

-- ---------- triggers ----------
create or replace function jobs.touch_updated_at() returns trigger language plpgsql
set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;

create trigger jobs_touch before update on jobs.jobs for each row execute function jobs.touch_updated_at();
create trigger applications_touch before update on jobs.applications for each row execute function jobs.touch_updated_at();
create trigger profile_touch before update on jobs.profile for each row execute function jobs.touch_updated_at();

-- Every application status change lands in the timeline automatically, and the
-- job's own status follows the application. Callers can name themselves with
--   set local jobs.actor = 'applier';
create or replace function jobs.log_application_status() returns trigger language plpgsql
set search_path = '' as $$
declare v_actor text := coalesce(nullif(current_setting('jobs.actor', true), ''), 'unknown');
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    insert into jobs.events (job_id, application_id, kind, from_status, to_status, actor, detail)
    values (new.job_id, new.id, 'status_change',
            case when tg_op = 'UPDATE' then old.status end, new.status, v_actor,
            case when new.status = 'failed' then new.error end);
    update jobs.jobs set status = case
        when new.status in ('queued','tailoring','ready','approved','failed') then 'applying'
        when new.status = 'withdrawn' then 'archived'
        else 'applied' end
      where id = new.job_id;
  end if;
  return new;
end $$;
create trigger applications_status_log after insert or update of status on jobs.applications
  for each row execute function jobs.log_application_status();

-- ---------- functions the agents call ----------

-- Finder agents: insert or refresh one job. Pass a JSON object with any jobs.jobs
-- columns plus optional "company" fields. Returns the job id and whether it is new.
-- Dedupes on url, then on company+title+location.
create or replace function jobs.upsert_job(p jsonb, p_agent text default null, p_run_id bigint default null)
returns table (job_id bigint, is_new boolean) language plpgsql
set search_path = '' as $$
declare
  v_company_id bigint;
  v_id bigint;
  v_key text := lower(regexp_replace((p->>'company_name') || '|' || (p->>'title') || '|' || coalesce(p->>'location',''), '\s+', ' ', 'g'));
begin
  if coalesce(p->>'company_name','') = '' or coalesce(p->>'title','') = '' or coalesce(p->>'url','') = '' then
    raise exception 'upsert_job needs company_name, title and url';
  end if;

  insert into jobs.companies (name, website, industry)
  values (p->>'company_name', p->>'company_website', p->>'company_industry')
  on conflict ((lower(name))) do update set website = coalesce(jobs.companies.website, excluded.website)
  returning id into v_company_id;

  select j.id into v_id from jobs.jobs j where j.url = p->>'url' or j.dedupe_key = v_key
   order by (j.url = p->>'url') desc limit 1;

  if v_id is not null then
    update jobs.jobs j set
      times_seen   = j.times_seen + 1,
      last_seen_at = now(),
      description  = coalesce(j.description, p->>'description'),
      apply_email  = coalesce(j.apply_email, p->>'apply_email'),
      apply_url    = coalesce(j.apply_url, p->>'apply_url'),
      closes_at    = coalesce((p->>'closes_at')::date, j.closes_at),
      match_score  = coalesce(j.match_score, (p->>'match_score')::int)
    where j.id = v_id;
    return query select v_id, false;
    return;
  end if;

  insert into jobs.jobs (
    company_id, company_name, title, location, work_mode, employment_type, seniority,
    salary_min, salary_max, salary_currency, description, requirements, url, source, source_job_id,
    posted_at, closes_at, apply_method, apply_email, apply_url, contact_name, contact_email,
    match_score, match_reasons, missing_skills, status, found_by, found_run_id)
  values (
    v_company_id, p->>'company_name', p->>'title', p->>'location', p->>'work_mode', p->>'employment_type', p->>'seniority',
    (p->>'salary_min')::numeric, (p->>'salary_max')::numeric, p->>'salary_currency', p->>'description', p->>'requirements',
    p->>'url', p->>'source', p->>'source_job_id',
    (p->>'posted_at')::date, (p->>'closes_at')::date, p->>'apply_method', p->>'apply_email', p->>'apply_url',
    p->>'contact_name', p->>'contact_email',
    (p->>'match_score')::int, p->>'match_reasons',
    coalesce(array(select jsonb_array_elements_text(p->'missing_skills')), '{}'),
    case when (select auto_shortlist from jobs.profile where id = 1)
              and coalesce((p->>'match_score')::int, 0) >= (select min_match_score from jobs.profile where id = 1)
         then 'shortlisted' else 'new' end,
    p_agent, p_run_id)
  returning id into v_id;

  insert into jobs.events (job_id, kind, actor, detail)
  values (v_id, 'found', p_agent, coalesce(p->>'source','') || ' · match ' || coalesce(p->>'match_score','?'));

  return query select v_id, true;
end $$;

-- Applier agent: the shortlisted jobs to work on next, best match first, that have
-- no application yet. Respects the daily limit.
create or replace function jobs.next_to_apply(p_limit int default null)
returns setof jobs.jobs language sql stable
set search_path = '' as $$
  select j.* from jobs.jobs j
  where j.status = 'shortlisted'
    and (j.closes_at is null or j.closes_at >= current_date)
    and not exists (select 1 from jobs.applications a where a.job_id = j.id)
  order by j.match_score desc nulls last, j.created_at
  limit greatest(0, least(
    coalesce(p_limit, 1000),
    (select daily_apply_limit from jobs.profile where id = 1)
      - (select count(*) from jobs.applications a where a.submitted_at >= date_trunc('day', now()))::int));
$$;

-- Applier agent: applications cleared to submit (approved, or ready when approval is off).
create or replace function jobs.ready_to_submit()
returns setof jobs.applications language sql stable
set search_path = '' as $$
  select a.* from jobs.applications a
  where a.status = 'approved'
     or (a.status = 'ready' and not (select require_approval from jobs.profile where id = 1))
  order by a.approved_at nulls last, a.created_at;
$$;

-- Change an application's status with a named actor and an optional note.
create or replace function jobs.set_application_status(p_id bigint, p_status text, p_actor text, p_detail text default null)
returns void language plpgsql
set search_path = '' as $$
begin
  perform set_config('jobs.actor', coalesce(p_actor, 'unknown'), true);
  update jobs.applications set
    status       = p_status,
    approved_at  = case when p_status = 'approved' then now() else approved_at end,
    approved_by  = case when p_status = 'approved' then p_actor else approved_by end,
    submitted_at = case when p_status = 'submitted' then coalesce(submitted_at, now()) else submitted_at end,
    error        = case when p_status = 'failed' then coalesce(p_detail, error) else error end
  where id = p_id;
  if not found then raise exception 'application % not found', p_id; end if;
  if p_detail is not null and p_status <> 'failed' then
    insert into jobs.events (job_id, application_id, kind, actor, detail)
    select job_id, id, 'note', p_actor, p_detail from jobs.applications where id = p_id;
  end if;
end $$;

-- ---------- views for the dashboard ----------
create or replace view jobs.pipeline with (security_invoker = true) as
select a.id as application_id, a.status, a.method, a.submitted_at, a.approved_at, a.follow_up_at,
       a.next_step, a.next_step_at, a.last_response_at, a.response_summary, a.error, a.updated_at,
       j.id as job_id, j.title, j.company_name, j.location, j.work_mode, j.url, j.match_score,
       j.salary_min, j.salary_max, j.salary_currency, j.closes_at,
       cv.file_url as cv_url, cv.label as cv_label
from jobs.applications a
join jobs.jobs j on j.id = a.job_id
left join jobs.cv_versions cv on cv.id = a.cv_version_id;

-- ---------- lock down ----------
alter table jobs.profile      enable row level security;
alter table jobs.agent_runs   enable row level security;
alter table jobs.companies    enable row level security;
alter table jobs.jobs         enable row level security;
alter table jobs.applications enable row level security;
alter table jobs.cv_versions  enable row level security;
alter table jobs.events       enable row level security;
revoke all on schema jobs from anon, authenticated;

-- ---------- later additions ----------
alter table jobs.profile add column if not exists base_cv_html text, add column if not exists search_rules text;
alter table jobs.profile add column if not exists standard_answers text;

-- Lessons from jobs reported as broken or closed. The app writes a first-pass
-- "why" and a proposed rule; the job scan re-checks the page, corrects and
-- activates the rule, and follows every active rule on each run.
create table jobs.lessons (
  id            bigint generated always as identity primary key,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  applies_to    text not null default 'finder' check (applies_to in ('finder','applier','all')),
  cause         text not null,
  rule          text not null,
  pattern       text,
  status        text not null default 'proposed' check (status in ('proposed','active','retired')),
  created_by    text,
  source_report_id bigint,
  times_applied int not null default 0
);
create trigger lessons_touch before update on jobs.lessons for each row execute function jobs.touch_updated_at();

create table jobs.link_reports (
  id              bigint generated always as identity primary key,
  job_id          bigint not null references jobs.jobs(id) on delete cascade,
  reported_at     timestamptz not null default now(),
  reported_by     text not null default 'app',
  kind            text not null check (kind in ('broken_link','job_closed')),
  url             text,
  user_note       text,
  quick_analysis  text,
  status          text not null default 'pending' check (status in ('pending','reviewed')),
  verified_cause  text,
  reviewed_at     timestamptz,
  lesson_id       bigint references jobs.lessons(id) on delete set null
);
create index on jobs.link_reports (status, reported_at);
alter table jobs.lessons add constraint lessons_report_fk foreign key (source_report_id) references jobs.link_reports(id) on delete set null;

alter table jobs.events drop constraint events_kind_check;
alter table jobs.events add constraint events_kind_check check (kind in (
  'found','status_change','cv_tailored','email_sent','form_submitted',
  'email_received','interview_scheduled','follow_up','note','error','link_reported','lesson'));

-- The app's "Link broken / job closed" button: records the report, withdraws any
-- unsent application, and marks the job expired.
create or replace function jobs.report_broken_link(p_job_id bigint, p_kind text, p_note text default null, p_actor text default 'app')
returns bigint language plpgsql
set search_path = '' as $$
declare v_id bigint; v_app bigint; v_app_status text;
begin
  insert into jobs.link_reports (job_id, kind, url, user_note, reported_by)
  select id, p_kind, url, p_note, p_actor from jobs.jobs where id = p_job_id
  returning id into v_id;
  if v_id is null then raise exception 'job % not found', p_job_id; end if;

  select id, status into v_app, v_app_status from jobs.applications where job_id = p_job_id;
  if v_app is not null and v_app_status in ('queued','tailoring','ready','approved','failed') then
    perform jobs.set_application_status(v_app, 'withdrawn', p_actor,
      case p_kind when 'broken_link' then 'Link broken' else 'Job closed' end);
  end if;

  update jobs.jobs set status = 'expired',
    status_reason = case p_kind when 'broken_link' then 'You reported: link not working' else 'You reported: job no longer available' end
  where id = p_job_id;

  insert into jobs.events (job_id, kind, actor, detail)
  values (p_job_id, 'link_reported', p_actor,
    case p_kind when 'broken_link' then 'Link not working' else 'Job no longer available' end || coalesce(': ' || p_note, ''));
  return v_id;
end $$;

alter table jobs.lessons      enable row level security;
alter table jobs.link_reports enable row level security;
