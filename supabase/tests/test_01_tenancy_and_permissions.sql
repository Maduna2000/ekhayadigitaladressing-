-- Tenant isolation, roles and audit.
\set alice '11111111-1111-1111-1111-111111111111'
\set bob   '22222222-2222-2222-2222-222222222222'
\set ana   '33333333-3333-3333-3333-333333333333'
\set rev   '44444444-4444-4444-4444-444444444444'

insert into auth.users (id, email) values
  (:'alice', 'alice@a.test'), (:'bob', 'bob@b.test'), (:'ana', 'ana@a.test'), (:'rev', 'rev@a.test');

select t.ok((select count(*) from public.profiles) = 4, 'profile created for each new auth user');

-- Each user creates their own organisation and becomes its owner.
select t.as_user(:'alice');
select set_config('t.org_a', public.create_organisation('Org A Financial')::text, false);
select t.as_user(:'bob');
select set_config('t.org_b', public.create_organisation('Org B Couriers')::text, false);
select t.reset();

select t.ok((select status from public.organisations where id = current_setting('t.org_a')::uuid) = 'pending',
  'new organisation starts pending');

-- Extra members of org A added by Ekhaya staff (member invitation flow comes later).
insert into public.organisation_members (org_id, user_id, role) values
  (current_setting('t.org_a')::uuid, :'ana', 'analyst'),
  (current_setting('t.org_a')::uuid, :'rev', 'reviewer');

-- Visibility ---------------------------------------------------------------------------
select t.as_user(:'alice');
select t.ok(t.count('select 1 from public.organisations') = 1, 'alice sees exactly one organisation');
select t.ok((select name from public.organisations) = 'Org A Financial', 'alice sees her own organisation');
select t.ok(t.count('select 1 from public.organisation_members') = 3, 'alice sees the three members of her org');
select t.as_user(:'bob');
select t.ok((select name from public.organisations) = 'Org B Couriers' and t.count('select 1 from public.organisations') = 1,
  'bob sees only his organisation');
select t.ok(t.count('select 1 from public.organisation_members') = 1, 'bob does not see org A members');
select t.reset();

-- Anonymous and direct writes ------------------------------------------------------------
select t.as_anon();
select t.fails('select * from public.organisations', '%permission denied%', 'anon cannot read organisations');
select t.fails('select * from public.customers', '%permission denied%', 'anon cannot read customers');
select t.fails('select * from public.verification_cases', '%permission denied%', 'anon cannot read cases');
select t.fails('select * from public.address_versions', '%permission denied%', 'anon cannot read address versions');
select t.fails('select * from public.audit_events', '%permission denied%', 'anon cannot read the audit log');
select t.fails($$select public.create_organisation('Anon Org')$$, '%permission denied%', 'anon cannot create an organisation');

select t.as_user(:'alice');
select t.fails($$insert into public.organisations (name) values ('Sneaky')$$, '%permission denied%',
  'authenticated cannot insert organisations directly');
select t.fails($$update public.organisations set status = 'approved'$$, '%permission denied%',
  'owner cannot approve their own organisation');
select t.fails($$update public.organisation_members set role = 'owner'$$, '%permission denied%',
  'members cannot change roles directly');
select t.fails($$insert into public.organisation_members (org_id, user_id, role)
  values (current_setting('t.org_b')::uuid, '11111111-1111-1111-1111-111111111111', 'owner')$$,
  '%permission denied%', 'a user cannot add themselves to another organisation');
select t.fails($$insert into public.audit_events (action) values ('fake.event')$$, '%permission denied%',
  'authenticated cannot write audit events');
select t.reset();

-- Audit ----------------------------------------------------------------------------------
select t.ok((select count(*) from public.audit_events where action = 'organisation.created') = 2,
  'organisation creation is audited');
select t.as_user(:'alice');
select t.ok(t.count('select 1 from public.audit_events') = 1, 'owner sees only own organisation audit events');
select t.as_user(:'ana');
select t.ok(t.count('select 1 from public.audit_events') = 0, 'analyst cannot read the audit log');
select t.reset();
select t.fails($$update public.audit_events set action = 'x.y.z'$$, '%append-only%', 'audit events cannot be updated');
select t.fails($$delete from public.audit_events$$, '%append-only%', 'audit events cannot be deleted');

-- Suspended members lose access -------------------------------------------------------------
update public.organisation_members set status = 'suspended' where user_id = :'rev';
select t.as_user(:'rev');
select t.ok(t.count('select 1 from public.organisations') = 0, 'suspended member sees nothing');
select t.reset();
update public.organisation_members set status = 'active' where user_id = :'rev';
