-- Consent records, review decisions (with a second reviewer for rejections) and attestations.
--
-- Decisions can no longer be made through transition_case(): a reviewer's outcome must go through
-- decide_case(), which records who decided, under which policy version, and enforces the second-reviewer
-- rule. transition_case() keeps the other status moves. Both share app.apply_transition().

-- ------------------------------------------------------------- shared helpers ---

create function app.reject_change() returns trigger
language plpgsql as $$
begin
  raise exception 'rows in % are append-only', tg_table_name;
end $$;

alter table public.verification_cases add column review_round integer not null default 0;

-- Applies a status move with no permission check. Callers must have checked permission already.
create function app.apply_transition(p_case uuid, p_to text, p_reason_code text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_org uuid;
  v_from text;
begin
  select org_id, status into v_org, v_from from public.verification_cases where id = p_case for update;
  perform set_config('ekhaya.in_transition', 'on', true);
  update public.verification_cases
    set status = p_to,
        review_round = review_round + case when p_to = 'pending_review' then 1 else 0 end
    where id = p_case;
  perform set_config('ekhaya.in_transition', 'off', true);
  perform app.log_audit(v_org, 'case.status_changed', 'case', p_case::text,
    jsonb_build_object('from', v_from, 'to', p_to, 'reason_code', p_reason_code));
  return p_to;
end $$;
revoke all on function app.apply_transition(uuid, text, text) from public, anon, authenticated;

-- Decision outcomes are not available through transition_case().
update public.case_transitions set allowed_roles = '{}'
  where to_status in ('verified', 'unable_to_verify', 'rejected');

create or replace function public.transition_case(p_case uuid, p_to text, p_reason_code text default null)
returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_org uuid;
  v_from text;
  v_roles text[];
  v_caller text;
begin
  if p_reason_code is not null and p_reason_code !~ '^[a-z_]{1,40}$' then
    raise exception 'reason code must be a short lowercase code';
  end if;

  select org_id, status into v_org, v_from from public.verification_cases where id = p_case for update;
  v_caller := case when v_org is null then null else app.caller_role(v_org) end;
  if v_caller is null then
    raise exception 'case not found' using errcode = 'P0002';
  end if;

  select allowed_roles into v_roles from public.case_transitions where from_status = v_from and to_status = p_to;
  if v_roles is null then
    raise exception 'invalid transition from % to %', v_from, p_to using errcode = '22023';
  end if;
  if not (v_caller = any (v_roles)) then
    raise exception 'role % may not move a case from % to %', v_caller, v_from, p_to using errcode = '42501';
  end if;
  return app.apply_transition(p_case, p_to, p_reason_code);
end $$;

-- --------------------------------------------------------------------- consent ---

create table public.consent_records (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null,
  case_id         uuid not null,
  granted         boolean not null,
  -- Snapshot of what the customer was told, so later edits cannot change the record.
  purpose         text not null,
  notice_version  text not null check (length(notice_version) between 1 and 40),
  wording_version text not null check (length(wording_version) between 1 and 40),
  language        text not null check (language in ('en', 'ss')),
  created_at      timestamptz not null default now(),
  foreign key (case_id, org_id) references public.verification_cases(id, org_id)
);
create index idx_consent_case on public.consent_records(case_id);
create index idx_consent_org on public.consent_records(org_id);
create trigger consent_append_only before update or delete on public.consent_records
  for each row execute function app.reject_change();

-- Called by trusted server code (service role) after the customer answers the consent screen.
create function public.record_consent(
  p_case uuid, p_granted boolean, p_notice_version text, p_wording_version text, p_language text
) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_org uuid;
  v_status text;
  v_purpose text;
begin
  select org_id, status, purpose into v_org, v_status, v_purpose
    from public.verification_cases where id = p_case for update;
  if v_org is null or app.caller_role(v_org) is distinct from 'system' then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if v_status <> 'pending_consent' then
    raise exception 'case is not awaiting consent (status %)', v_status;
  end if;
  insert into public.consent_records (org_id, case_id, granted, purpose, notice_version, wording_version, language)
    values (v_org, p_case, p_granted, v_purpose, p_notice_version, p_wording_version, p_language);
  perform app.log_audit(v_org, case when p_granted then 'consent.granted' else 'consent.declined' end,
    'case', p_case::text, jsonb_build_object('notice_version', p_notice_version, 'language', p_language));
  return app.apply_transition(p_case, case when p_granted then 'in_progress' else 'cancelled' end,
    case when p_granted then null else 'customer_declined' end);
end $$;

-- ------------------------------------------------------------ review decisions ---

create table public.review_decisions (
  id             uuid primary key default gen_random_uuid(),
  org_id         uuid not null,
  case_id        uuid not null,
  review_round   integer not null,
  reviewer_id    uuid not null,
  outcome        text not null check (outcome in ('verified', 'unable_to_verify', 'rejected')),
  reason_code    text not null check (reason_code ~ '^[a-z_]{1,40}$'),
  policy_version text not null check (length(policy_version) between 1 and 20),
  -- A first rejection is only a proposal (finalised = false) until a second reviewer confirms it.
  finalised      boolean not null,
  created_at     timestamptz not null default now(),
  foreign key (case_id, org_id) references public.verification_cases(id, org_id),
  check (outcome = 'rejected' or finalised)
);
create index idx_decisions_case on public.review_decisions(case_id, review_round);
create index idx_decisions_org on public.review_decisions(org_id);
create trigger decisions_append_only before update or delete on public.review_decisions
  for each row execute function app.reject_change();

create function public.decide_case(p_case uuid, p_outcome text, p_reason_code text, p_policy_version text)
returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_org uuid;
  v_status text;
  v_creator uuid;
  v_round integer;
  v_role text;
  v_prior uuid;
begin
  if p_outcome not in ('verified', 'unable_to_verify', 'rejected') then
    raise exception 'unknown outcome';
  end if;
  if p_reason_code is null or p_reason_code !~ '^[a-z_]{1,40}$' then
    raise exception 'a reason code is required (short lowercase code)';
  end if;

  select org_id, status, created_by, review_round into v_org, v_status, v_creator, v_round
    from public.verification_cases where id = p_case for update;
  v_role := case when v_org is null then null else app.caller_role(v_org) end;
  if v_role is null then
    raise exception 'case not found' using errcode = 'P0002';
  end if;
  if auth.uid() is null or v_role not in ('owner', 'admin', 'reviewer') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if v_status <> 'pending_review' then
    raise exception 'case is not awaiting review (status %)', v_status;
  end if;
  if v_creator = auth.uid() then
    raise exception 'you created this case and cannot decide it' using errcode = '42501';
  end if;

  if p_outcome = 'rejected' then
    select reviewer_id into v_prior from public.review_decisions
      where case_id = p_case and review_round = v_round and outcome = 'rejected' and not finalised
      order by created_at limit 1;
    if v_prior is null then
      insert into public.review_decisions (org_id, case_id, review_round, reviewer_id, outcome, reason_code, policy_version, finalised)
        values (v_org, p_case, v_round, auth.uid(), 'rejected', p_reason_code, p_policy_version, false);
      perform app.log_audit(v_org, 'case.rejection_proposed', 'case', p_case::text,
        jsonb_build_object('reason_code', p_reason_code, 'policy_version', p_policy_version));
      return 'pending_review';
    elsif v_prior = auth.uid() then
      raise exception 'a second reviewer is required to reject' using errcode = '42501';
    end if;
  end if;

  insert into public.review_decisions (org_id, case_id, review_round, reviewer_id, outcome, reason_code, policy_version, finalised)
    values (v_org, p_case, v_round, auth.uid(), p_outcome, p_reason_code, p_policy_version, true);
  update public.verification_cases set policy_version = p_policy_version where id = p_case;
  perform app.log_audit(v_org, 'case.decision_recorded', 'case', p_case::text,
    jsonb_build_object('outcome', p_outcome, 'reason_code', p_reason_code, 'policy_version', p_policy_version));
  return app.apply_transition(p_case, p_outcome, p_reason_code);
end $$;

-- ---------------------------------------------------------------- attestations ---

create table public.attestation_requests (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null,
  case_id       uuid not null,
  -- Personal data about a third party: visible only to owners, admins and reviewers, never in audit metadata.
  attester_name text not null check (length(btrim(attester_name)) between 2 and 120),
  contact       text not null check (length(btrim(contact)) between 5 and 120),
  relationship  text not null check (relationship in ('neighbour', 'chiefs_office', 'employer', 'landlord', 'other')),
  -- SHA-256 of the one-time link token (hex). The token itself is never stored.
  token_hash    text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  status        text not null default 'requested' check (status in ('requested', 'answered', 'declined', 'expired')),
  answer        text check (answer in ('yes', 'no', 'unsure')),
  known_for     text check (known_for in ('under_1_year', '1_to_2_years', 'over_2_years')),
  comment       text check (length(comment) <= 500),
  expires_at    timestamptz not null,
  created_at    timestamptz not null default now(),
  answered_at   timestamptz,
  foreign key (case_id, org_id) references public.verification_cases(id, org_id),
  check ((status = 'answered') = (answer is not null))
);
create index idx_attestations_case on public.attestation_requests(case_id);
create index idx_attestations_org on public.attestation_requests(org_id);

create function app.attestation_settled() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'attestation requests cannot be deleted';
  end if;
  if old.status <> 'requested' then
    raise exception 'an answered attestation cannot be changed';
  end if;
  return new;
end $$;
create trigger attestation_settled before update or delete on public.attestation_requests
  for each row execute function app.attestation_settled();

create function public.request_attestation(
  p_case uuid, p_name text, p_relationship text, p_contact text, p_token_hash text, p_expires_at timestamptz
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_org uuid;
  v_status text;
  v_id uuid;
begin
  select org_id, status into v_org, v_status from public.verification_cases where id = p_case for update;
  if v_org is null or not app.has_role(v_org, array['owner', 'admin', 'developer', 'system']) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if v_status not in ('pending_consent', 'in_progress') then
    raise exception 'attestations cannot be requested in status %', v_status;
  end if;
  if p_expires_at <= now() then
    raise exception 'expiry must be in the future';
  end if;
  if (select count(*) from public.attestation_requests where case_id = p_case and status = 'requested') >= 3 then
    raise exception 'too many open attestation requests for this case';
  end if;
  insert into public.attestation_requests (org_id, case_id, attester_name, contact, relationship, token_hash, expires_at)
    values (v_org, p_case, p_name, p_contact, p_relationship, p_token_hash, p_expires_at)
    returning id into v_id;
  perform app.log_audit(v_org, 'attestation.requested', 'case', p_case::text, jsonb_build_object('relationship', p_relationship));
  return v_id;
end $$;

-- Called by trusted server code when an attester answers through their one-time link.
create function public.record_attestation(
  p_token_hash text, p_answer text, p_known_for text default null, p_comment text default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_row public.attestation_requests%rowtype;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_answer not in ('yes', 'no', 'unsure', 'declined') then
    raise exception 'unknown answer';
  end if;
  select * into v_row from public.attestation_requests
    where token_hash = p_token_hash and status = 'requested' and expires_at > now() for update;
  if v_row.id is null then
    raise exception 'attestation request not found or no longer open' using errcode = 'P0002';
  end if;
  update public.attestation_requests
    set status = case when p_answer = 'declined' then 'declined' else 'answered' end,
        answer = case when p_answer = 'declined' then null else p_answer end,
        known_for = p_known_for, comment = p_comment, answered_at = now()
    where id = v_row.id;
  perform app.log_audit(v_row.org_id, 'attestation.answered', 'case', v_row.case_id::text,
    jsonb_build_object('answer', p_answer));
  return v_row.id;
end $$;

-- ------------------------------------------------------------------- RLS & grants ---

alter table public.consent_records     enable row level security;
alter table public.review_decisions    enable row level security;
alter table public.attestation_requests enable row level security;

create policy consent_select on public.consent_records for select to authenticated using (app.is_member(org_id));
create policy decisions_select on public.review_decisions for select to authenticated using (app.is_member(org_id));
create policy attestations_select on public.attestation_requests for select to authenticated
  using (app.has_role(org_id, array['owner', 'admin', 'reviewer']));

revoke all on table public.consent_records, public.review_decisions, public.attestation_requests from anon, authenticated;
grant select on public.consent_records, public.review_decisions to authenticated;
-- Everything except the token hash.
grant select (id, org_id, case_id, attester_name, contact, relationship, status, answer, known_for, comment,
              expires_at, created_at, answered_at) on public.attestation_requests to authenticated;

revoke all on function public.record_consent(uuid, boolean, text, text, text) from public, anon, authenticated;
revoke all on function public.decide_case(uuid, text, text, text) from public, anon;
revoke all on function public.request_attestation(uuid, text, text, text, text, timestamptz) from public, anon;
revoke all on function public.record_attestation(text, text, text, text) from public, anon, authenticated;
grant execute on function public.record_consent(uuid, boolean, text, text, text) to service_role;
grant execute on function public.decide_case(uuid, text, text, text) to authenticated;
grant execute on function public.request_attestation(uuid, text, text, text, text, timestamptz) to authenticated;
grant execute on function public.record_attestation(text, text, text, text) to service_role;
