-- Ekhaya foundation: profiles, organisations, membership, tenant helpers, audit log.
--
-- Rules this migration enforces (see docs/screen-spec.md and the project brief):
--   * Every business-owned row carries org_id; access is by active organisation membership.
--   * Browser-facing roles (anon, authenticated) get read access through RLS only. Writes go through
--     security-definer functions that check the caller's role and write an audit event.
--   * The audit log is append-only. Audit metadata must not hold personal data.

create schema if not exists app;
grant usage on schema app to authenticated, service_role;

-- ------------------------------------------------------------------ profiles ---

create table public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  full_name  text,
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;

create policy profiles_select_own on public.profiles
  for select to authenticated using (id = auth.uid());
create policy profiles_update_own on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create function app.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id) values (new.id) on conflict do nothing;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function app.handle_new_user();

-- ------------------------------------------------------------- organisations ---

create table public.organisations (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(btrim(name)) between 2 and 120),
  -- Only Ekhaya staff (service role) move an organisation out of 'pending'.
  status      text not null default 'pending' check (status in ('pending', 'approved', 'suspended')),
  approved_at timestamptz,
  created_at  timestamptz not null default now(),
  check ((status = 'approved') = (approved_at is not null) or status = 'suspended')
);

create table public.organisation_members (
  org_id     uuid not null references public.organisations(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  role       text not null check (role in ('owner', 'admin', 'reviewer', 'analyst', 'developer')),
  status     text not null default 'active' check (status in ('invited', 'active', 'suspended')),
  created_at timestamptz not null default now(),
  primary key (org_id, user_id)
);
create index idx_org_members_user on public.organisation_members(user_id);

alter table public.organisations enable row level security;
alter table public.organisation_members enable row level security;

-- ------------------------------------------------------------ tenant helpers ---

-- The caller's role in an organisation: their membership role, 'system' for the service role,
-- or null when they have no active membership.
create function app.caller_role(p_org uuid) returns text
language sql stable security definer set search_path = '' as $$
  select case
    when auth.role() = 'service_role' then 'system'
    else (select m.role from public.organisation_members m
          where m.org_id = p_org and m.user_id = auth.uid() and m.status = 'active')
  end
$$;

create function app.is_member(p_org uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.organisation_members m
                 where m.org_id = p_org and m.user_id = auth.uid() and m.status = 'active')
$$;

create function app.has_role(p_org uuid, p_roles text[]) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(app.caller_role(p_org) = any (p_roles), false)
$$;

create function app.org_is_approved(p_org uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.organisations o where o.id = p_org and o.status = 'approved')
$$;

create policy organisations_select_member on public.organisations
  for select to authenticated using (app.is_member(id));

create policy members_select_same_org on public.organisation_members
  for select to authenticated using (app.is_member(org_id));

-- ---------------------------------------------------------------------- audit ---

create table public.audit_events (
  id          bigint generated always as identity primary key,
  org_id      uuid references public.organisations(id),
  actor_id    uuid,
  actor_type  text not null default 'user' check (actor_type in ('user', 'system', 'customer', 'attester')),
  action      text not null check (action ~ '^[a-z_.]{3,60}$'),
  object_type text,
  object_id   text,
  -- References and codes only. Never names, phone numbers, addresses or document contents.
  metadata    jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);
create index idx_audit_org_time on public.audit_events(org_id, created_at desc);
create index idx_audit_object on public.audit_events(object_type, object_id);

alter table public.audit_events enable row level security;
create policy audit_select_admins on public.audit_events
  for select to authenticated using (app.has_role(org_id, array['owner', 'admin']));

create function app.audit_is_append_only() returns trigger
language plpgsql as $$
begin
  raise exception 'audit_events is append-only';
end $$;

create trigger audit_no_update_delete
  before update or delete on public.audit_events
  for each row execute function app.audit_is_append_only();

create function app.log_audit(
  p_org uuid, p_action text, p_object_type text, p_object_id text, p_metadata jsonb default '{}'::jsonb
) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.audit_events (org_id, actor_id, actor_type, action, object_type, object_id, metadata)
  values (p_org, auth.uid(),
          case when auth.role() = 'service_role' then 'system' else 'user' end,
          p_action, p_object_type, p_object_id, coalesce(p_metadata, '{}'::jsonb));
end $$;

-- --------------------------------------------------------- create organisation ---

-- The only way to create an organisation. The caller becomes its owner. It starts 'pending'
-- and cannot send verification requests until Ekhaya approves it.
create function public.create_organisation(p_name text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_org uuid;
begin
  if auth.uid() is null then
    raise exception 'sign in required' using errcode = '28000';
  end if;
  insert into public.organisations (name) values (p_name) returning id into v_org;
  insert into public.organisation_members (org_id, user_id, role) values (v_org, auth.uid(), 'owner');
  perform app.log_audit(v_org, 'organisation.created', 'organisation', v_org::text);
  return v_org;
end $$;

-- ------------------------------------------------------------------- privileges ---

revoke all on table public.profiles, public.organisations, public.organisation_members,
  public.audit_events from anon, authenticated;
grant select on public.profiles, public.organisations, public.organisation_members,
  public.audit_events to authenticated;
grant update (full_name) on public.profiles to authenticated;

revoke all on function public.create_organisation(text) from public, anon;
grant execute on function public.create_organisation(text) to authenticated;
revoke all on function app.log_audit(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function app.caller_role(uuid), app.is_member(uuid), app.has_role(uuid, text[]),
  app.org_is_approved(uuid) to authenticated, service_role;
