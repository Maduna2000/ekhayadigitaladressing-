-- Verification cases and the case status state machine.
--
-- Status changes happen only through public.transition_case(). A trigger rejects any other attempt to
-- change `status`, including from the service role, so the rules live in one place. Allowed moves and the
-- roles that may make them are DATA (case_transitions), so policy changes do not need a code deploy.

create table public.verification_cases (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.organisations(id),
  customer_id       uuid not null,
  address_id        uuid,
  verification_type text not null default 'residential_address' check (verification_type in ('residential_address')),
  purpose           text not null check (length(btrim(purpose)) between 3 and 120),
  status            text not null default 'draft' check (status in (
    'draft', 'pending_consent', 'in_progress', 'pending_review', 'verified',
    'unable_to_verify', 'rejected', 'expired', 'revoked', 'cancelled')),
  policy_version    text,
  created_by        uuid,
  expires_at        timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (id, org_id),
  foreign key (customer_id, org_id) references public.customers(id, org_id),
  foreign key (address_id, org_id)  references public.addresses(id, org_id)
);
create index idx_cases_org_status on public.verification_cases(org_id, status, created_at desc);
create index idx_cases_customer on public.verification_cases(customer_id);
create index idx_cases_address on public.verification_cases(address_id) where address_id is not null;

create table public.case_transitions (
  from_status   text not null,
  to_status     text not null,
  allowed_roles text[] not null,
  primary key (from_status, to_status)
);

insert into public.case_transitions (from_status, to_status, allowed_roles) values
  ('draft',           'pending_consent',  '{owner,admin,developer,system}'),
  ('draft',           'cancelled',        '{owner,admin,developer,system}'),
  ('pending_consent', 'in_progress',      '{system}'),
  ('pending_consent', 'cancelled',        '{owner,admin,developer,system}'),
  ('pending_consent', 'expired',          '{system}'),
  ('in_progress',     'pending_review',   '{system}'),
  ('in_progress',     'cancelled',        '{owner,admin,system}'),
  ('in_progress',     'expired',          '{system}'),
  ('pending_review',  'in_progress',      '{owner,admin,reviewer,system}'),
  ('pending_review',  'verified',         '{owner,admin,reviewer}'),
  ('pending_review',  'unable_to_verify', '{owner,admin,reviewer}'),
  ('pending_review',  'rejected',         '{owner,admin,reviewer}'),
  ('pending_review',  'cancelled',        '{owner,admin}'),
  ('pending_review',  'expired',          '{system}'),
  ('verified',        'revoked',          '{owner,admin}');
-- Terminal: unable_to_verify, rejected, expired, revoked, cancelled.

alter table public.verification_cases enable row level security;
alter table public.case_transitions   enable row level security;
create policy cases_select on public.verification_cases for select to authenticated using (app.is_member(org_id));
create policy transitions_read on public.case_transitions for select to authenticated using (true);

create function app.guard_case_update() returns trigger
language plpgsql as $$
begin
  if new.org_id is distinct from old.org_id or new.customer_id is distinct from old.customer_id then
    raise exception 'org_id and customer_id cannot change';
  end if;
  if new.status is distinct from old.status
     and coalesce(current_setting('ekhaya.in_transition', true), '') <> 'on' then
    raise exception 'status can only change through transition_case()';
  end if;
  new.updated_at := now();
  return new;
end $$;

create trigger cases_guard_update
  before update on public.verification_cases
  for each row execute function app.guard_case_update();

create function app.cases_no_delete() returns trigger
language plpgsql as $$
begin
  raise exception 'cases cannot be deleted; cancel them instead';
end $$;

create trigger cases_no_delete before delete on public.verification_cases
  for each row execute function app.cases_no_delete();

create function public.create_case(
  p_customer uuid, p_purpose text, p_expires_at timestamptz default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_org uuid;
  v_id uuid;
begin
  select org_id into v_org from public.customers where id = p_customer;
  if v_org is null or not app.has_role(v_org, array['owner', 'admin', 'developer', 'system']) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if not app.org_is_approved(v_org) then
    raise exception 'organisation is not approved to send verification requests' using errcode = '42501';
  end if;
  insert into public.verification_cases (org_id, customer_id, purpose, expires_at, created_by)
    values (v_org, p_customer, p_purpose, p_expires_at, auth.uid())
    returning id into v_id;
  perform app.log_audit(v_org, 'case.created', 'case', v_id::text);
  return v_id;
end $$;

create function public.attach_address(p_case uuid, p_address uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_org uuid;
  v_status text;
begin
  select org_id, status into v_org, v_status from public.verification_cases where id = p_case for update;
  if v_org is null or not app.has_role(v_org, array['owner', 'admin', 'developer', 'system']) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if v_status not in ('draft', 'pending_consent', 'in_progress') then
    raise exception 'address cannot be changed in status %', v_status;
  end if;
  -- The composite foreign key rejects an address from another organisation.
  update public.verification_cases set address_id = p_address where id = p_case;
  perform app.log_audit(v_org, 'case.address_attached', 'case', p_case::text);
end $$;

create function public.transition_case(p_case uuid, p_to text, p_reason_code text default null)
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
  -- Same error for "does not exist" and "not yours", so ids cannot be probed.
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

  perform set_config('ekhaya.in_transition', 'on', true);
  update public.verification_cases set status = p_to where id = p_case;
  perform set_config('ekhaya.in_transition', 'off', true);

  perform app.log_audit(v_org, 'case.status_changed', 'case', p_case::text,
    jsonb_build_object('from', v_from, 'to', p_to, 'reason_code', p_reason_code));
  return p_to;
end $$;

revoke all on table public.verification_cases, public.case_transitions from anon, authenticated;
grant select on public.verification_cases, public.case_transitions to authenticated;

revoke all on function public.create_case(uuid, text, timestamptz) from public, anon;
revoke all on function public.attach_address(uuid, uuid) from public, anon;
revoke all on function public.transition_case(uuid, text, text) from public, anon;
grant execute on function public.create_case(uuid, text, timestamptz) to authenticated;
grant execute on function public.attach_address(uuid, uuid) to authenticated;
grant execute on function public.transition_case(uuid, text, text) to authenticated;
