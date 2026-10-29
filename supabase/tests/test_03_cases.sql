-- Cases and the status state machine. Continues test_02's session.

-- Approval gate ------------------------------------------------------------------------------
update public.organisations set status = 'pending', approved_at = null where id = current_setting('t.org_a')::uuid;
select t.as_user(:'alice');
select t.fails($$select public.create_case(current_setting('t.cust_a')::uuid, 'Account onboarding')$$,
  '%not approved%', 'a pending organisation cannot send requests');
select t.reset();
update public.organisations set status = 'approved', approved_at = now() where id = current_setting('t.org_a')::uuid;

-- Creating cases -----------------------------------------------------------------------------
select t.as_user(:'ana');
select t.fails($$select public.create_case(current_setting('t.cust_a')::uuid, 'Account onboarding')$$,
  '%not allowed%', 'analyst cannot create cases');
select t.as_user(:'bob');
select t.fails($$select public.create_case(current_setting('t.cust_a')::uuid, 'Account onboarding')$$,
  '%not allowed%', 'another organisation cannot create cases for org A customers');
select t.as_user(:'alice');
select set_config('t.case_a', public.create_case(current_setting('t.cust_a')::uuid, 'Account onboarding')::text, false);
select t.ok((select status from public.verification_cases where id = current_setting('t.case_a')::uuid) = 'draft',
  'a new case starts as draft');
select t.fails($$select public.create_case(current_setting('t.cust_a')::uuid, 'x')$$,
  '%violates check constraint%', 'purpose must be meaningful');

-- Visibility ---------------------------------------------------------------------------------
select t.as_user(:'bob');
select t.ok(t.count('select 1 from public.verification_cases') = 0, 'org B cannot see org A cases');
select t.fails($$select public.transition_case(current_setting('t.case_a')::uuid, 'pending_consent')$$,
  '%case not found%', 'transitioning another organisation''s case looks like it does not exist');
select t.fails($$select public.transition_case(gen_random_uuid(), 'pending_consent')$$,
  '%case not found%', 'a missing case gives the same error');

-- Status can only change via transition_case ------------------------------------------------------
select t.as_user(:'alice');
select t.fails($$update public.verification_cases set status = 'verified'$$, '%permission denied%',
  'users cannot update cases directly');
select t.fails($$delete from public.verification_cases$$, '%permission denied%', 'users cannot delete cases');
select t.reset();
select t.fails($$update public.verification_cases set status = 'verified'$$, '%only change through transition_case%',
  'even staff cannot bypass the state machine');
select t.fails($$delete from public.verification_cases$$, '%cannot be deleted%', 'cases cannot be deleted');
select t.fails($$update public.verification_cases set org_id = current_setting('t.org_b')::uuid$$,
  '%cannot change%', 'a case cannot move between organisations');

-- Transitions -------------------------------------------------------------------------------------
select t.as_user(:'alice');
select t.fails($$select public.transition_case(current_setting('t.case_a')::uuid, 'verified')$$,
  '%invalid transition from draft to verified%', 'draft cannot jump to verified');
select t.fails($$select public.transition_case(current_setting('t.case_a')::uuid, 'pending_consent', 'Jane Dlamini lives at plot 4')$$,
  '%reason code%', 'free text (possible personal data) is not accepted as a reason');
select t.ok(public.transition_case(current_setting('t.case_a')::uuid, 'pending_consent') = 'pending_consent',
  'owner can send a draft case to the customer');
select t.fails($$select public.transition_case(current_setting('t.case_a')::uuid, 'in_progress')$$,
  '%may not move%', 'users cannot record customer consent themselves');

-- The customer's consent and submission are recorded by trusted server code (service role).
select t.as_service();
select t.ok(public.transition_case(current_setting('t.case_a')::uuid, 'in_progress') = 'in_progress',
  'service role moves the case to in_progress');
select public.attach_address(current_setting('t.case_a')::uuid, current_setting('t.addr_a')::uuid);
select t.ok(public.transition_case(current_setting('t.case_a')::uuid, 'pending_review') = 'pending_review',
  'service role moves the case to pending_review');

-- Review ------------------------------------------------------------------------------------------
select t.as_user(:'ana');
select t.fails($$select public.decide_case(current_setting('t.case_a')::uuid, 'verified', 'evidence_consistent', '1.2')$$,
  '%not allowed%', 'analyst cannot decide a case');
select t.as_user(:'bob');
select t.fails($$select public.decide_case(current_setting('t.case_a')::uuid, 'verified', 'evidence_consistent', '1.2')$$,
  '%case not found%', 'another organisation''s owner cannot decide the case');
select t.as_user(:'rev');
select t.fails($$select public.transition_case(current_setting('t.case_a')::uuid, 'verified', 'evidence_consistent')$$,
  '%may not move%', 'a decision cannot bypass decide_case via transition_case');
select t.ok(public.decide_case(current_setting('t.case_a')::uuid, 'verified', 'evidence_consistent', '1.2') = 'verified',
  'reviewer can record a decision');
select t.fails($$select public.transition_case(current_setting('t.case_a')::uuid, 'revoked')$$,
  '%may not move%', 'reviewer cannot revoke');
select t.as_user(:'alice');
select t.ok(public.transition_case(current_setting('t.case_a')::uuid, 'revoked', 'customer_request') = 'revoked',
  'owner can revoke a verified result');
select t.fails($$select public.transition_case(current_setting('t.case_a')::uuid, 'verified')$$,
  '%invalid transition%', 'revoked is terminal');

-- Address cannot be swapped once decided / cannot be another organisation's ---------------------------
select t.as_user(:'bob');
select set_config('t.cust_b2', public.create_customer(current_setting('t.org_b')::uuid, 'CLIENT-2')::text, false);
select set_config('t.addr_b', public.submit_address(current_setting('t.cust_b2')::uuid, 'rural',
  '{"region":"Lubombo","community":"Siteki"}'::jsonb)::text, false);
select t.as_user(:'alice');
select set_config('t.case_a2', public.create_case(current_setting('t.cust_a')::uuid, 'Second request')::text, false);
select t.fails($$select public.attach_address(current_setting('t.case_a2')::uuid, current_setting('t.addr_b')::uuid)$$,
  '%violates foreign key%', 'a case cannot use another organisation''s address');
select t.as_user(:'alice');
select t.fails($$select public.attach_address(current_setting('t.case_a')::uuid, current_setting('t.addr_a')::uuid)$$,
  '%cannot be changed in status revoked%', 'a decided case''s address cannot be changed');

-- Audit trail ---------------------------------------------------------------------------------------
select t.reset();
select t.ok((select count(*) from public.audit_events where object_id = current_setting('t.case_a')
  and action = 'case.status_changed') = 5, 'every status change is audited');
select t.ok((select count(*) from public.audit_events where object_id = current_setting('t.case_a')
  and action = 'case.decision_recorded') = 1, 'the decision itself is audited');
select t.ok((select metadata ->> 'from' from public.audit_events where object_id = current_setting('t.case_a')
  and metadata ->> 'to' = 'verified') = 'pending_review', 'audit records the previous status');
select t.ok((select count(*) from public.audit_events where actor_type = 'system') = 3,
  'service-role actions are audited as system');
select t.ok(not exists (select 1 from public.audit_events where metadata::text ~* '(dlamini|ezulwini|plot|@)'),
  'audit metadata holds no names, places or emails');
