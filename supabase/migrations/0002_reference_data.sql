-- Reference data: the address model (ISO 19160 style) and administrative units.
-- Ported from legacy-d1/. The profile, classes and components are DATA, not code, so adopting the real
-- SZNS ISO 19160 profile is a data change. Everything here is a PLACEHOLDER (confirmed = false)
-- until the standard text is obtained and loaded.
--
-- Deliberate change from the D1 version: the minimum for a rural address is Region + Community,
-- which matches the customer form. Inkhundla, umphakatsi, sigodzi and homestead are optional,
-- because not every customer knows them and not every address has a street or number.

create table public.address_profiles (
  id        smallint primary key,
  code      text not null unique,
  name      text not null,
  version   text not null,
  confirmed boolean not null default false,
  source    text
);

create table public.address_classes (
  id          smallint primary key,
  profile_id  smallint not null references public.address_profiles(id),
  code        text not null,
  name        text not null,
  description text,
  confirmed   boolean not null default false,
  unique (profile_id, code)
);

create table public.component_types (
  id          smallint primary key,
  profile_id  smallint not null references public.address_profiles(id),
  code        text not null,
  name        text not null,
  kind        text not null check (kind in ('admin', 'locality', 'thoroughfare', 'number', 'building', 'unit', 'postal')),
  admin_level smallint,
  unique (profile_id, code)
);

-- Which components a class uses, in order, required or optional.
create table public.class_components (
  class_id          smallint not null references public.address_classes(id),
  component_type_id smallint not null references public.component_types(id),
  position          smallint not null,
  required          boolean not null default true,
  primary key (class_id, component_type_id),
  unique (class_id, position)
);

create table public.admin_units (
  id                integer generated always as identity primary key,
  parent_id         integer references public.admin_units(id),
  component_type_id smallint not null references public.component_types(id),
  name              text not null,
  official_code     text,
  unique (parent_id, component_type_id, name)
);
create index idx_admin_units_parent on public.admin_units(parent_id);

create table public.postcodes (
  code       text primary key check (code ~ '^[A-Z][0-9]{3}$'),
  place_name text not null,
  region_id  integer references public.admin_units(id)
);

insert into public.address_profiles (id, code, name, version, confirmed, source) values
  (1, 'SZNS-ISO19160', 'Eswatini National Addressing Standard (SZNS ISO 19160)', 'placeholder-0', false,
   'Project brief; replace with the published standard');

insert into public.address_classes (id, profile_id, code, name, description) values
  (1, 1, 'street',              'Street address',              'Address on a named street'),
  (2, 1, 'rural',               'Community address',           'Region and community, with chiefdom detail where known'),
  (3, 1, 'informal_settlement', 'Informal settlement address', 'Address within an informal settlement');

insert into public.component_types (id, profile_id, code, name, kind, admin_level) values
  (1,  1, 'region',      'Region',              'admin',        1),
  (2,  1, 'inkhundla',   'Inkhundla',           'admin',        2),
  (3,  1, 'umphakatsi',  'Umphakatsi',          'admin',        3),
  (4,  1, 'sigodzi',     'Sigodzi',             'admin',        4),
  (5,  1, 'homestead',   'Homestead',           'building',     null),
  (6,  1, 'locality',    'Town / urban area',   'locality',     null),
  (7,  1, 'street_name', 'Street name',         'thoroughfare', null),
  (8,  1, 'plot_number', 'House / plot number', 'number',       null),
  (9,  1, 'block',       'Block',               'unit',         null),
  (10, 1, 'floor',       'Floor',               'unit',         null),
  (11, 1, 'wing',        'Wing',                'unit',         null),
  (12, 1, 'unit',        'Unit',                'unit',         null),
  (13, 1, 'room',        'Room',                'unit',         null),
  (14, 1, 'community',   'Community / locality', 'locality',    null);

insert into public.class_components (class_id, component_type_id, position, required) values
  -- community (rural): region and community are the minimum
  (2, 1, 1, true), (2, 14, 2, true), (2, 2, 3, false), (2, 3, 4, false), (2, 4, 5, false), (2, 5, 6, false),
  -- street
  (1, 1, 1, true), (1, 14, 2, true), (1, 6, 3, false), (1, 7, 4, true), (1, 8, 5, true),
  (1, 9, 6, false), (1, 10, 7, false), (1, 11, 8, false), (1, 12, 9, false), (1, 13, 10, false),
  -- informal settlement
  (3, 1, 1, true), (3, 14, 2, true), (3, 8, 3, false);

insert into public.admin_units (parent_id, component_type_id, name, official_code) values
  (null, 1, 'Hhohho',     'H'),
  (null, 1, 'Manzini',    'M'),
  (null, 1, 'Lubombo',    'L'),
  (null, 1, 'Shiselweni', 'S');

insert into public.postcodes (code, place_name, region_id)
select v.code, v.place, a.id
from (values ('H100', 'Mbabane', 'H'), ('H101', 'Swazi Plaza', 'H'), ('M200', 'Manzini', 'M'),
             ('M202', 'Matsapha', 'M'), ('L300', 'Siteki', 'L'), ('S400', 'Nhlangano', 'S')) as v(code, place, rc)
join public.admin_units a on a.official_code = v.rc and a.component_type_id = 1;

-- Reference tables are readable by signed-in users and writable only by the service role (migrations).
alter table public.address_profiles enable row level security;
alter table public.address_classes  enable row level security;
alter table public.component_types  enable row level security;
alter table public.class_components enable row level security;
alter table public.admin_units      enable row level security;
alter table public.postcodes        enable row level security;

create policy ref_read on public.address_profiles  for select to authenticated using (true);
create policy ref_read on public.address_classes   for select to authenticated using (true);
create policy ref_read on public.component_types   for select to authenticated using (true);
create policy ref_read on public.class_components  for select to authenticated using (true);
create policy ref_read on public.admin_units       for select to authenticated using (true);
create policy ref_read on public.postcodes         for select to authenticated using (true);

revoke all on table public.address_profiles, public.address_classes, public.component_types,
  public.class_components, public.admin_units, public.postcodes from anon, authenticated;
grant select on public.address_profiles, public.address_classes, public.component_types,
  public.class_components, public.admin_units, public.postcodes to authenticated;
