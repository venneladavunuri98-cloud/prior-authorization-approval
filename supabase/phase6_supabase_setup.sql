-- =====================================================================
-- Prior Auth Automation - Phase 6: Supabase audit log
-- Run once in Supabase: Dashboard -> SQL Editor -> New query -> Run.
--
-- What this creates
--   prior_auth_requests  one row per request (current status). PHI columns
--                        (patient_name, patient_dob) are encrypted with pgcrypto.
--   prior_auth_events    append-only history: every action, who did it, when.
--   log_prior_auth(p)    the ONLY way n8n writes. Upserts the request row,
--                        encrypts PHI, and appends an event - in one call.
--   prior_auth_patient() decrypts name/DOB for one request (service role only).
--   prior_auth_dashboard view without PHI, for reporting.
--
-- The encryption key lives in Supabase Vault, never in n8n.
-- =====================================================================

-- 0. Encryption key (do this FIRST, once) ------------------------------
-- Generate a key on your machine:   openssl rand -hex 32
-- Then run (replace the placeholder, keep the name exactly):
--
--   select vault.create_secret('PASTE_YOUR_64_CHAR_HEX_KEY', 'prior_auth_encryption_key',
--                              'pgcrypto key for prior auth PHI columns');
--
-- Store a copy of the key in your password manager. If it is lost,
-- encrypted names/DOBs cannot be recovered.

create extension if not exists pgcrypto with schema extensions;

-- 1. Tables ------------------------------------------------------------
create table if not exists public.prior_auth_requests (
  request_id            text primary key,              -- AUTH-<timestamp>-<rand>, non-PHI
  status                text not null,                 -- see list below
  is_mock               boolean not null default false,
  procedure_code        text,
  diagnosis_codes       text[],
  payer_id              text,
  payer_name            text,
  physician_npi         text,
  patient_name          bytea,                         -- PHI, pgp_sym_encrypt
  patient_dob           bytea,                         -- PHI, pgp_sym_encrypt
  urgency_level         text,
  review_required       boolean,
  review_reason         text,
  needs_manual_review   boolean not null default false,
  manual_review_reason  text,
  tracking_id           text,                          -- payer / Availity tracking number
  auth_number           text,
  auth_effective_date   date,
  auth_expiration_date  date,
  is_approved           boolean,
  denial_code           text,
  denial_reason         text,
  last_error            text,
  submitted_at          timestamptz,
  last_checked_at       timestamptz,
  next_check_at         timestamptz,                   -- set only while status = 'pending'
  check_count           integer not null default 0,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
-- status values used by the workflows:
--   processing, rejected_validation, awaiting_physician, physician_approved,
--   physician_rejected, physician_no_response, eligibility_failed,
--   approved, denied, pending, error, stale

create index if not exists prior_auth_requests_pending_idx
  on public.prior_auth_requests (status, next_check_at);
create index if not exists prior_auth_requests_review_idx
  on public.prior_auth_requests (needs_manual_review) where needs_manual_review;

create table if not exists public.prior_auth_events (
  id                bigint generated always as identity primary key,
  request_id        text not null references public.prior_auth_requests(request_id) on delete cascade,
  action            text not null,                     -- e.g. case_created, payer_decision, status_check
  actor             text not null default 'n8n',       -- n8n | physician | system
  status            text,
  details           jsonb not null default '{}'::jsonb, -- NON-PHI details only
  n8n_execution_id  text,
  created_at        timestamptz not null default now()
);
create index if not exists prior_auth_events_request_idx
  on public.prior_auth_events (request_id, created_at);

-- 2. Row Level Security ------------------------------------------------
-- RLS on, and no policies: anon / authenticated users can read nothing.
-- The n8n service-role key bypasses RLS. Add read policies later for a
-- dashboard role if you build one.
alter table public.prior_auth_requests enable row level security;
alter table public.prior_auth_events   enable row level security;
revoke all on public.prior_auth_requests from anon, authenticated;
revoke all on public.prior_auth_events   from anon, authenticated;

-- 3. Logging function (called by n8n: POST /rest/v1/rpc/log_prior_auth) --
-- Body: { "p": { "request_id": "...", "action": "...", ...fields } }
-- Only fields that are sent are changed. Send "next_check_at": null to clear it.
create or replace function public.log_prior_auth(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  rid text := nullif(p->>'request_id', '');
  k   text;
begin
  if rid is null then
    raise exception 'log_prior_auth: request_id is required';
  end if;
  if nullif(p->>'action', '') is null then
    raise exception 'log_prior_auth: action is required';
  end if;

  if nullif(p->>'patient_name', '') is not null or nullif(p->>'patient_dob', '') is not null then
    select decrypted_secret into k
      from vault.decrypted_secrets
     where name = 'prior_auth_encryption_key';
    if k is null then
      raise exception 'log_prior_auth: Vault secret prior_auth_encryption_key not found';
    end if;
  end if;

  insert into public.prior_auth_requests (request_id, status)
  values (rid, coalesce(nullif(p->>'status', ''), 'processing'))
  on conflict (request_id) do nothing;

  update public.prior_auth_requests r set
    status               = coalesce(nullif(p->>'status', ''), r.status),
    is_mock              = coalesce((nullif(p->>'is_mock', ''))::boolean, r.is_mock),
    procedure_code       = coalesce(nullif(p->>'procedure_code', ''), r.procedure_code),
    diagnosis_codes      = case when jsonb_typeof(p->'diagnosis_codes') = 'array'
                                then array(select jsonb_array_elements_text(p->'diagnosis_codes'))
                                else r.diagnosis_codes end,
    payer_id             = coalesce(nullif(p->>'payer_id', ''), r.payer_id),
    payer_name           = coalesce(nullif(p->>'payer_name', ''), r.payer_name),
    physician_npi        = coalesce(nullif(p->>'physician_npi', ''), r.physician_npi),
    patient_name         = case when nullif(p->>'patient_name', '') is not null
                                then pgp_sym_encrypt(p->>'patient_name', k) else r.patient_name end,
    patient_dob          = case when nullif(p->>'patient_dob', '') is not null
                                then pgp_sym_encrypt(p->>'patient_dob', k) else r.patient_dob end,
    urgency_level        = coalesce(nullif(p->>'urgency_level', ''), r.urgency_level),
    review_required      = coalesce((nullif(p->>'review_required', ''))::boolean, r.review_required),
    review_reason        = coalesce(nullif(p->>'review_reason', ''), r.review_reason),
    needs_manual_review  = coalesce((nullif(p->>'needs_manual_review', ''))::boolean, r.needs_manual_review),
    manual_review_reason = coalesce(nullif(p->>'manual_review_reason', ''), r.manual_review_reason),
    tracking_id          = coalesce(nullif(p->>'tracking_id', ''), r.tracking_id),
    auth_number          = coalesce(nullif(p->>'auth_number', ''), r.auth_number),
    auth_effective_date  = coalesce((nullif(p->>'auth_effective_date', ''))::date, r.auth_effective_date),
    auth_expiration_date = coalesce((nullif(p->>'auth_expiration_date', ''))::date, r.auth_expiration_date),
    is_approved          = coalesce((nullif(p->>'is_approved', ''))::boolean, r.is_approved),
    denial_code          = coalesce(nullif(p->>'denial_code', ''), r.denial_code),
    denial_reason        = coalesce(nullif(p->>'denial_reason', ''), r.denial_reason),
    last_error           = coalesce(nullif(p->>'last_error', ''), r.last_error),
    submitted_at         = coalesce((nullif(p->>'submitted_at', ''))::timestamptz, r.submitted_at),
    last_checked_at      = coalesce((nullif(p->>'last_checked_at', ''))::timestamptz, r.last_checked_at),
    next_check_at        = case when p ? 'next_check_at'
                                then (nullif(p->>'next_check_at', ''))::timestamptz
                                else r.next_check_at end,
    check_count          = coalesce((nullif(p->>'check_count', ''))::integer, r.check_count),
    updated_at           = now()
  where r.request_id = rid;

  insert into public.prior_auth_events (request_id, action, actor, status, details, n8n_execution_id)
  values (
    rid,
    p->>'action',
    coalesce(nullif(p->>'actor', ''), 'n8n'),
    nullif(p->>'status', ''),
    case when jsonb_typeof(p->'details') = 'object' then p->'details' else '{}'::jsonb end,
    nullif(p->>'n8n_execution_id', '')
  );

  return jsonb_build_object('ok', true, 'request_id', rid);
end;
$$;

revoke all on function public.log_prior_auth(jsonb) from public, anon, authenticated;
grant execute on function public.log_prior_auth(jsonb) to service_role;

-- 4. Decrypt helper for authorised staff tools (service role only) --------
create or replace function public.prior_auth_patient(rid text)
returns table (request_id text, patient_name text, patient_dob text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  k text;
begin
  select decrypted_secret into k from vault.decrypted_secrets where name = 'prior_auth_encryption_key';
  return query
    select r.request_id,
           case when r.patient_name is null then null else pgp_sym_decrypt(r.patient_name, k) end,
           case when r.patient_dob  is null then null else pgp_sym_decrypt(r.patient_dob,  k) end
      from public.prior_auth_requests r
     where r.request_id = rid;
end;
$$;

revoke all on function public.prior_auth_patient(text) from public, anon, authenticated;
grant execute on function public.prior_auth_patient(text) to service_role;

-- 5. Reporting view without PHI ------------------------------------------
create or replace view public.prior_auth_dashboard
with (security_invoker = true) as
select request_id, status, is_mock, procedure_code, payer_id, payer_name, urgency_level,
       review_required, needs_manual_review, manual_review_reason, tracking_id, auth_number,
       auth_effective_date, auth_expiration_date, is_approved, denial_code, denial_reason,
       submitted_at, last_checked_at, next_check_at, check_count, created_at, updated_at
  from public.prior_auth_requests;

revoke all on public.prior_auth_dashboard from anon, authenticated;

-- Handy queries ------------------------------------------------------------
-- Manual review queue:
--   select * from prior_auth_dashboard where needs_manual_review order by updated_at desc;
-- Full history of one request:
--   select * from prior_auth_events where request_id = 'AUTH-...' order by created_at;
-- Clear a request from the review queue once staff have handled it:
--   select log_prior_auth('{"request_id":"AUTH-...","action":"manual_review_done","actor":"staff","needs_manual_review":false}');
