-- Customers, addresses, immutable address versions and address sources.
--
-- Design points
--   * Tenant integrity is enforced by composite foreign keys (id, org_id), so a row can never point at
--     another organisation's customer or address, even if application code is wrong.
--   * Address versions are immutable. A correction is a new version; history is never rewritten.
--   * `provenance` says where an address version came from. It is checked against the source's kind, so
--     "officially matched" cannot be set without an official national source and an official ID.
--   * Coordinates never change provenance. There is no code path from GPS to "matched".
--   * Whether one verified address can be reused across organisations is an open product decision;
--     for now every address belongs to exactly one organisation.

create table public.address_sources (
  id          smallint primary key,
  kind        text not null check (kind in ('official_national', 'licensed_reference', 'customer_submitted')),
  name        text not null unique,
  description text,
  active      boolean not null default true
);

insert into public.address_sources (id, kind, name, description) values
  (1, 'customer_submitted', 'Customer submitted', 'Entered by the customer. Unverified until checks complete.'),
  (2, 'licensed_reference', 'Ekhaya synthetic reference (testing only)', 'Synthetic data for development. Not a real dataset.');
-- No 'official_national' row exists: no authorised government source is available yet.

create table public.customers (
  id                 uuid primary key default gen_random_uuid(),
  org_id             uuid not null references public.organisations(id),
  external_reference text not null check (length(btrim(external_reference)) between 1 and 80),
  created_at         timestamptz not null default now(),
  unique (org_id, external_reference),
  unique (id, org_id)
);

create table public.addresses (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organisations(id),
  customer_id uuid not null,
  class_id    smallint not null references public.address_classes(id),
  created_at  timestamptz not null default now(),
  unique (id, org_id),
  foreign key (customer_id, org_id) references public.customers(id, org_id)
);
create index idx_addresses_org on public.addresses(org_id);
create index idx_addresses_customer on public.addresses(customer_id);

create table public.address_versions (
  id                  uuid primary key default gen_random_uuid(),
  address_id          uuid not null,
  org_id              uuid not null,
  version_no          integer not null check (version_no >= 1),
  source_id           smallint not null references public.address_sources(id),
  provenance          text not null check (provenance in ('customer_submitted', 'reference_matched', 'officially_matched')),
  official_address_id text,
  -- component code -> text as written, e.g. {"region":"Hhohho","community":"Ezulwini Valley"}
  components          jsonb not null default '{}'::jsonb check (jsonb_typeof(components) = 'object'),
  landmark            text check (length(landmark) <= 300),
  directions          text check (length(directions) <= 1000),
  postcode            text references public.postcodes(code),
  lat                 double precision,
  lng                 double precision,
  accuracy_m          real check (accuracy_m is null or accuracy_m >= 0),
  capture_method      text check (capture_method in ('device_gps', 'manual_pin')),
  source_checked_at   timestamptz,
  created_by          uuid,
  created_at          timestamptz not null default now(),
  unique (address_id, version_no),
  foreign key (address_id, org_id) references public.addresses(id, org_id),
  -- Eswatini bounding range, to catch swapped or bad GPS values.
  check (lat is null or lat between -27.5 and -25.5),
  check (lng is null or lng between 30.5 and 32.5),
  check ((lat is null) = (lng is null)),
  check ((lat is null) = (capture_method is null)),
  check (provenance <> 'officially_matched' or official_address_id is not null)
);
create index idx_address_versions_address on public.address_versions(address_id, version_no desc);
create index idx_address_versions_org on public.address_versions(org_id);

create function app.check_address_version() returns trigger
language plpgsql set search_path = '' as $$
declare
  v_kind text;
begin
  select kind into v_kind from public.address_sources where id = new.source_id and active;
  if v_kind is null then
    raise exception 'unknown or inactive address source';
  end if;
  if (new.provenance = 'customer_submitted'  and v_kind <> 'customer_submitted')
  or (new.provenance = 'reference_matched'   and v_kind <> 'licensed_reference')
  or (new.provenance = 'officially_matched'  and v_kind <> 'official_national') then
    raise exception 'provenance % does not match source kind %', new.provenance, v_kind;
  end if;
  return new;
end $$;

create trigger address_versions_check
  before insert on public.address_versions
  for each row execute function app.check_address_version();

create function app.versions_are_immutable() returns trigger
language plpgsql as $$
begin
  raise exception 'address_versions are immutable; add a new version instead';
end $$;

create trigger address_versions_no_update_delete
  before update or delete on public.address_versions
  for each row execute function app.versions_are_immutable();

-- The latest version of each address.
create view public.current_address_versions with (security_invoker = true) as
select distinct on (v.address_id) v.*
from public.address_versions v
order by v.address_id, v.version_no desc;

-- ------------------------------------------------------------------------ RLS ---

alter table public.address_sources  enable row level security;
alter table public.customers        enable row level security;
alter table public.addresses        enable row level security;
alter table public.address_versions enable row level security;

create policy sources_read on public.address_sources for select to authenticated using (true);
create policy customers_select on public.customers for select to authenticated using (app.is_member(org_id));
create policy addresses_select on public.addresses for select to authenticated using (app.is_member(org_id));
create policy address_versions_select on public.address_versions for select to authenticated using (app.is_member(org_id));

-- -------------------------------------------------------------------- functions ---

create function public.create_customer(p_org uuid, p_external_reference text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
begin
  if not app.has_role(p_org, array['owner', 'admin', 'developer', 'system']) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  insert into public.customers (org_id, external_reference) values (p_org, p_external_reference)
    returning id into v_id;
  perform app.log_audit(p_org, 'customer.created', 'customer', v_id::text);
  return v_id;
end $$;

-- Checks components against the class: known codes only, non-empty text, all required codes present.
create function app.validate_components(p_class smallint, p_components jsonb) returns void
language plpgsql stable security definer set search_path = '' as $$
declare
  v_key text;
  v_missing text;
begin
  for v_key in select jsonb_object_keys(p_components) loop
    if not exists (
      select 1 from public.class_components cc
      join public.component_types ct on ct.id = cc.component_type_id
      where cc.class_id = p_class and ct.code = v_key
    ) then
      raise exception 'component % is not used by this address class', v_key;
    end if;
    if jsonb_typeof(p_components -> v_key) <> 'string' or btrim(p_components ->> v_key) = '' then
      raise exception 'component % must be non-empty text', v_key;
    end if;
  end loop;

  select string_agg(ct.code, ', ' order by cc.position) into v_missing
  from public.class_components cc
  join public.component_types ct on ct.id = cc.component_type_id
  where cc.class_id = p_class and cc.required
    and coalesce(btrim(p_components ->> ct.code), '') = '';
  if v_missing is not null then
    raise exception 'missing required components: %', v_missing;
  end if;
end $$;

-- A customer-submitted address always starts (and stays) as customer_submitted. Matching to reference or
-- official data is a separate, later step with its own source; GPS never upgrades provenance.
create function public.submit_address(
  p_customer uuid, p_class_code text, p_components jsonb,
  p_landmark text default null, p_directions text default null, p_postcode text default null,
  p_lat double precision default null, p_lng double precision default null,
  p_accuracy_m real default null, p_capture_method text default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_org uuid;
  v_class smallint;
  v_address uuid;
begin
  select org_id into v_org from public.customers where id = p_customer;
  if v_org is null or not app.has_role(v_org, array['owner', 'admin', 'developer', 'system']) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select id into v_class from public.address_classes where code = p_class_code;
  if v_class is null then
    raise exception 'unknown address class';
  end if;
  perform app.validate_components(v_class, p_components);

  insert into public.addresses (org_id, customer_id, class_id) values (v_org, p_customer, v_class)
    returning id into v_address;
  insert into public.address_versions (address_id, org_id, version_no, source_id, provenance, components,
      landmark, directions, postcode, lat, lng, accuracy_m, capture_method, created_by)
    values (v_address, v_org, 1, 1, 'customer_submitted', p_components, p_landmark, p_directions, p_postcode,
      p_lat, p_lng, p_accuracy_m, p_capture_method, auth.uid());
  perform app.log_audit(v_org, 'address.submitted', 'address', v_address::text, jsonb_build_object('version', 1));
  return v_address;
end $$;

create function public.correct_address(
  p_address uuid, p_components jsonb,
  p_landmark text default null, p_directions text default null, p_postcode text default null,
  p_lat double precision default null, p_lng double precision default null,
  p_accuracy_m real default null, p_capture_method text default null
) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_org uuid;
  v_class smallint;
  v_next integer;
begin
  select org_id, class_id into v_org, v_class from public.addresses where id = p_address for update;
  if v_org is null or not app.has_role(v_org, array['owner', 'admin', 'developer', 'system']) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  perform app.validate_components(v_class, p_components);
  select coalesce(max(version_no), 0) + 1 into v_next from public.address_versions where address_id = p_address;
  -- A correction is customer-submitted again: previous matches described the old text.
  insert into public.address_versions (address_id, org_id, version_no, source_id, provenance, components,
      landmark, directions, postcode, lat, lng, accuracy_m, capture_method, created_by)
    values (p_address, v_org, v_next, 1, 'customer_submitted', p_components, p_landmark, p_directions, p_postcode,
      p_lat, p_lng, p_accuracy_m, p_capture_method, auth.uid());
  perform app.log_audit(v_org, 'address.corrected', 'address', p_address::text, jsonb_build_object('version', v_next));
  return v_next;
end $$;

-- ------------------------------------------------------------------- privileges ---

revoke all on table public.address_sources, public.customers, public.addresses, public.address_versions,
  public.current_address_versions from anon, authenticated;
grant select on public.address_sources, public.customers, public.addresses, public.address_versions,
  public.current_address_versions to authenticated;

revoke all on function public.create_customer(uuid, text) from public, anon;
revoke all on function public.submit_address(uuid, text, jsonb, text, text, text, double precision, double precision, real, text) from public, anon;
revoke all on function public.correct_address(uuid, jsonb, text, text, text, double precision, double precision, real, text) from public, anon;
grant execute on function public.create_customer(uuid, text) to authenticated;
grant execute on function public.submit_address(uuid, text, jsonb, text, text, text, double precision, double precision, real, text) to authenticated;
grant execute on function public.correct_address(uuid, jsonb, text, text, text, double precision, double precision, real, text) to authenticated;
revoke all on function app.validate_components(smallint, jsonb) from public, anon, authenticated;
