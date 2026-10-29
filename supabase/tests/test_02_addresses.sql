-- Customers, addresses, provenance, immutability and cross-tenant integrity. Continues test_01's session.

-- Ekhaya staff approve both organisations (service-role action; no user can do this).
update public.organisations set status = 'approved', approved_at = now()
  where id in (current_setting('t.org_a')::uuid, current_setting('t.org_b')::uuid);

-- Roles ----------------------------------------------------------------------------------
select t.as_user(:'ana');   -- analyst: read only
select t.fails($$select public.create_customer(current_setting('t.org_a')::uuid, 'CLIENT-X')$$,
  '%not allowed%', 'analyst cannot create customers');
select t.as_user(:'rev');   -- reviewer: cannot create requests or customers
select t.fails($$select public.create_customer(current_setting('t.org_a')::uuid, 'CLIENT-X')$$,
  '%not allowed%', 'reviewer cannot create customers');
select t.as_user(:'bob');
select t.fails($$select public.create_customer(current_setting('t.org_a')::uuid, 'CLIENT-X')$$,
  '%not allowed%', 'another organisation cannot create customers in org A');

-- Customers ------------------------------------------------------------------------------
select t.as_user(:'alice');
select set_config('t.cust_a', public.create_customer(current_setting('t.org_a')::uuid, 'CLIENT-1042')::text, false);
select t.fails($$select public.create_customer(current_setting('t.org_a')::uuid, 'CLIENT-1042')$$,
  '%duplicate key%', 'external reference is unique within an organisation');
select t.as_user(:'bob');
select set_config('t.cust_b', public.create_customer(current_setting('t.org_b')::uuid, 'CLIENT-1042')::text, false);
select t.ok(true, 'the same external reference can exist in a different organisation');
select t.ok(t.count('select 1 from public.customers') = 1, 'bob sees only his own customer');
select t.as_user(:'alice');
select t.ok(t.count('select 1 from public.customers') = 1, 'alice sees only her own customer');

-- Addresses: required components ------------------------------------------------------------
select set_config('t.addr_a', public.submit_address(
  current_setting('t.cust_a')::uuid, 'rural',
  '{"region":"Hhohho","community":"Ezulwini Valley"}'::jsonb,
  'Ezulwini Catholic Clinic', 'Right past the white water tank')::text, false);
select t.ok(true, 'rural address needs only region and community (no street, no house number)');

select t.fails($$select public.submit_address(current_setting('t.cust_a')::uuid, 'rural', '{"region":"Hhohho"}'::jsonb)$$,
  '%missing required components: community%', 'community is required');
select t.fails($$select public.submit_address(current_setting('t.cust_a')::uuid, 'rural',
  '{"region":"Hhohho","community":"X","not_a_field":"y"}'::jsonb)$$,
  '%not used by this address class%', 'unknown component codes are rejected');
select t.fails($$select public.submit_address(current_setting('t.cust_a')::uuid, 'rural',
  '{"region":"Hhohho","community":"   "}'::jsonb)$$, '%non-empty text%', 'blank components are rejected');
select t.fails($$select public.submit_address(current_setting('t.cust_a')::uuid, 'street',
  '{"region":"Manzini","community":"Matsapha"}'::jsonb)$$,
  '%missing required components: street_name, plot_number%', 'street class requires street and plot');
select t.ok(public.submit_address(current_setting('t.cust_a')::uuid, 'street',
  '{"region":"Manzini","community":"Matsapha","street_name":"Example Street","plot_number":"12","unit":"4"}'::jsonb) is not null,
  'a full street address is accepted');
select t.fails($$select public.submit_address(current_setting('t.cust_a')::uuid, 'nonsense', '{}'::jsonb)$$,
  '%unknown address class%', 'unknown address class is rejected');

-- Provenance -------------------------------------------------------------------------------
select t.ok((select provenance from public.current_address_versions where address_id = current_setting('t.addr_a')::uuid)
  = 'customer_submitted', 'submitted address is customer_submitted');
select t.reset();
select t.fails($$insert into public.address_versions (address_id, org_id, version_no, source_id, provenance, official_address_id)
  values (current_setting('t.addr_a')::uuid, current_setting('t.org_a')::uuid, 9, 1, 'officially_matched', 'SZ-1')$$,
  '%does not match source kind%', 'officially_matched cannot use the customer source');
select t.fails($$insert into public.address_versions (address_id, org_id, version_no, source_id, provenance)
  values (current_setting('t.addr_a')::uuid, current_setting('t.org_a')::uuid, 9, 2, 'officially_matched')$$,
  '%does not match source kind%', 'officially_matched without an official source is rejected');
select t.fails($$insert into public.address_versions (address_id, org_id, version_no, source_id, provenance, official_address_id)
  values (current_setting('t.addr_a')::uuid, current_setting('t.org_a')::uuid, 9, 2, 'officially_matched', 'SZ-1')$$,
  '%does not match source kind%', 'officially_matched cannot use a reference source (no official source exists)');
select t.fails($$insert into public.address_versions (address_id, org_id, version_no, source_id, provenance)
  values (current_setting('t.addr_a')::uuid, current_setting('t.org_a')::uuid, 9, 1, 'reference_matched')$$,
  '%does not match source kind%', 'reference_matched cannot use the customer source');
select t.ok((select count(*) from public.address_sources where kind = 'official_national') = 0,
  'no official national source is configured');

-- GPS -------------------------------------------------------------------------------------
select t.as_user(:'alice');
select set_config('t.addr_gps', public.submit_address(current_setting('t.cust_a')::uuid, 'rural',
  '{"region":"Hhohho","community":"Lobamba"}'::jsonb, 'Royal kraal', null, null, -26.4194, 31.1842, 12, 'device_gps')::text, false);
select t.ok((select provenance from public.current_address_versions where address_id = current_setting('t.addr_gps')::uuid)
  = 'customer_submitted', 'GPS coordinates do not change provenance');
select t.fails($$select public.submit_address(current_setting('t.cust_a')::uuid, 'rural',
  '{"region":"Hhohho","community":"Lobamba"}'::jsonb, null, null, null, 31.18, -26.41, 10, 'device_gps')$$,
  '%violates check constraint%', 'swapped latitude/longitude is rejected');
select t.fails($$select public.submit_address(current_setting('t.cust_a')::uuid, 'rural',
  '{"region":"Hhohho","community":"Lobamba"}'::jsonb, null, null, null, -26.41, null, 10, 'device_gps')$$,
  '%violates check constraint%', 'latitude without longitude is rejected');
select t.fails($$select public.submit_address(current_setting('t.cust_a')::uuid, 'rural',
  '{"region":"Hhohho","community":"Lobamba"}'::jsonb, null, null, null, -26.41, 31.18, 10, null)$$,
  '%violates check constraint%', 'coordinates without a capture method are rejected');
select t.fails($$select public.submit_address(current_setting('t.cust_a')::uuid, 'rural',
  '{"region":"Hhohho","community":"Lobamba"}'::jsonb, null, null, 'Z999')$$,
  '%violates foreign key%', 'an unknown postcode is rejected');

-- Corrections and immutability ----------------------------------------------------------------
select t.ok(public.correct_address(current_setting('t.addr_a')::uuid,
  '{"region":"Hhohho","community":"Ezulwini Valley","inkhundla":"Lobamba"}'::jsonb, 'Ezulwini Catholic Clinic') = 2,
  'a correction creates version 2');
select t.ok((select version_no from public.current_address_versions where address_id = current_setting('t.addr_a')::uuid) = 2,
  'current version is the latest');
select t.ok(t.count('select 1 from public.address_versions where address_id = ''' || current_setting('t.addr_a') || '''') = 2,
  'version 1 is kept');
select t.reset();
select t.fails($$update public.address_versions set landmark = 'changed'$$, '%immutable%', 'address versions cannot be updated');
select t.fails($$delete from public.address_versions$$, '%immutable%', 'address versions cannot be deleted');

-- Cross-tenant ---------------------------------------------------------------------------------
select t.as_user(:'bob');
select t.fails($$select public.correct_address(current_setting('t.addr_a')::uuid, '{"region":"Hhohho","community":"X"}'::jsonb)$$,
  '%not allowed%', 'another organisation cannot correct org A''s address');
select t.fails($$select public.submit_address(current_setting('t.cust_a')::uuid, 'rural',
  '{"region":"Hhohho","community":"X"}'::jsonb)$$, '%not allowed%', 'another organisation cannot add addresses to org A customers');
select t.ok(t.count('select 1 from public.addresses') = 0, 'bob sees none of org A''s addresses');
select t.ok(t.count('select 1 from public.address_versions') = 0, 'bob sees none of org A''s address versions');
select t.ok(t.count('select 1 from public.current_address_versions') = 0, 'the current-version view respects tenancy');
select t.reset();
select t.fails($$insert into public.addresses (org_id, customer_id, class_id)
  values (current_setting('t.org_b')::uuid, current_setting('t.cust_a')::uuid, 2)$$,
  '%violates foreign key%', 'an address cannot point at another organisation''s customer, even for staff');
