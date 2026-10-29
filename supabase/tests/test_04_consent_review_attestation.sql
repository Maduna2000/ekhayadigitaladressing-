-- Consent, review decisions (second reviewer for rejection) and attestations. Continues test_03's session.
\set rev2 '55555555-5555-5555-5555-555555555555'
insert into auth.users (id, email) values (:'rev2', 'rev2@a.test');
insert into public.organisation_members (org_id, user_id, role) values (current_setting('t.org_a')::uuid, :'rev2', 'reviewer');

-- Cases to work with, created by alice (owner) -----------------------------------------------------
select t.as_user(:'alice');
select set_config('t.c1', public.create_case(current_setting('t.cust_a')::uuid, 'Consent test')::text, false);
select set_config('t.c2', public.create_case(current_setting('t.cust_a')::uuid, 'Rejection test')::text, false);
select set_config('t.c3', public.create_case(current_setting('t.cust_a')::uuid, 'Own case test')::text, false);
select public.transition_case(current_setting('t.c1')::uuid, 'pending_consent');
select public.transition_case(current_setting('t.c2')::uuid, 'pending_consent');
select public.transition_case(current_setting('t.c3')::uuid, 'pending_consent');

-- Consent -----------------------------------------------------------------------------------------
select t.fails($$select public.record_consent(current_setting('t.c1')::uuid, true, 'notice-3', 'wording-2', 'en')$$,
  '%permission denied%', 'users cannot record consent on the customer''s behalf');
select t.as_service();
select t.fails($$select public.record_consent(current_setting('t.c1')::uuid, true, 'notice-3', 'wording-2', 'fr')$$,
  '%violates check constraint%', 'only supported languages are accepted');
select t.ok(public.record_consent(current_setting('t.c1')::uuid, true, 'notice-3', 'wording-2', 'ss') = 'in_progress',
  'granted consent moves the case to in_progress');
select t.fails($$select public.record_consent(current_setting('t.c1')::uuid, false, 'notice-3', 'wording-2', 'en')$$,
  '%not awaiting consent%', 'consent cannot be recorded twice');
select t.ok((select purpose from public.consent_records where case_id = current_setting('t.c1')::uuid) = 'Consent test',
  'consent snapshots the purpose shown to the customer');
select t.ok(public.record_consent(current_setting('t.c3')::uuid, false, 'notice-3', 'wording-2', 'en') = 'cancelled',
  'declined consent cancels the case');
select t.ok((select metadata ->> 'reason_code' from public.audit_events where object_id = current_setting('t.c3')
  and action = 'case.status_changed' and metadata ->> 'to' = 'cancelled') = 'customer_declined', 'a decline is audited with its reason');
select t.reset();
select t.fails($$update public.consent_records set granted = false$$, '%append-only%', 'consent records cannot be edited');
select t.fails($$delete from public.consent_records$$, '%append-only%', 'consent records cannot be deleted');
select t.as_user(:'bob');
select t.ok(t.count('select 1 from public.consent_records') = 0, 'other organisations cannot see consent records');
select t.as_user(:'alice');
select t.ok(t.count('select 1 from public.consent_records') = 2, 'owner sees the organisation''s consent records');

-- Move c2 into review (customer submission is recorded by trusted server code) ----------------------------
select t.as_service();
select public.record_consent(current_setting('t.c2')::uuid, true, 'notice-3', 'wording-2', 'en');
select public.transition_case(current_setting('t.c2')::uuid, 'pending_review');
select t.reset();

-- Review decisions ----------------------------------------------------------------------------------
select t.as_user(:'alice');
select t.fails($$select public.decide_case(current_setting('t.c2')::uuid, 'verified', 'evidence_consistent', '1.2')$$,
  '%you created this case%', 'the creator of a case cannot decide it');
select t.as_user(:'rev');
select t.fails($$select public.decide_case(current_setting('t.c2')::uuid, 'verified', null, '1.2')$$,
  '%reason code is required%', 'a decision needs a reason code');
select t.fails($$select public.decide_case(current_setting('t.c2')::uuid, 'verified', 'Looks fine to me', '1.2')$$,
  '%reason code is required%', 'a decision reason cannot be free text');
select t.fails($$select public.decide_case(current_setting('t.c2')::uuid, 'approved', 'ok', '1.2')$$,
  '%unknown outcome%', 'unknown outcomes are rejected');
select t.fails($$select public.decide_case(current_setting('t.c1')::uuid, 'verified', 'ok', '1.2')$$,
  '%not awaiting review%', 'a case not in review cannot be decided');

-- Rejection needs two different reviewers
select t.ok(public.decide_case(current_setting('t.c2')::uuid, 'rejected', 'evidence_inconsistent', '1.2') = 'pending_review',
  'a first rejection is only a proposal');
select t.ok((select status from public.verification_cases where id = current_setting('t.c2')::uuid) = 'pending_review',
  'the case stays in review after a rejection proposal');
select t.fails($$select public.decide_case(current_setting('t.c2')::uuid, 'rejected', 'evidence_inconsistent', '1.2')$$,
  '%second reviewer is required%', 'the same reviewer cannot confirm their own rejection');
select t.as_user(:'rev2');
select t.ok(public.decide_case(current_setting('t.c2')::uuid, 'rejected', 'evidence_inconsistent', '1.2') = 'rejected',
  'a second reviewer can confirm the rejection');
select t.ok((select count(*) from public.review_decisions where case_id = current_setting('t.c2')::uuid) = 2,
  'both decisions are kept');
select t.ok((select policy_version from public.verification_cases where id = current_setting('t.c2')::uuid) = '1.2',
  'the case records the policy version used');
select t.fails($$select public.decide_case(current_setting('t.c2')::uuid, 'verified', 'ok', '1.2')$$,
  '%not awaiting review%', 'a rejected case is final');
select t.reset();
select t.fails($$update public.review_decisions set outcome = 'verified'$$, '%append-only%', 'decisions cannot be edited');
select t.as_user(:'ana');
select t.ok(t.count('select 1 from public.review_decisions') = 3, 'analysts can read decisions (not make them)');
select t.as_user(:'bob');
select t.ok(t.count('select 1 from public.review_decisions') = 0, 'other organisations cannot read decisions');

-- Attestations ------------------------------------------------------------------------------------------
select t.as_user(:'ana');
select t.fails($$select public.request_attestation(current_setting('t.c1')::uuid, 'Nomsa Dlamini', 'neighbour', '+26876123456',
  repeat('a', 64), now() + interval '2 days')$$, '%not allowed%', 'analyst cannot request an attestation');
select t.as_user(:'alice');
select t.fails($$select public.request_attestation(current_setting('t.c1')::uuid, 'Nomsa Dlamini', 'cousin', '+26876123456',
  repeat('a', 64), now() + interval '2 days')$$, '%violates check constraint%', 'relationship must be a known type');
select t.fails($$select public.request_attestation(current_setting('t.c1')::uuid, 'Nomsa Dlamini', 'neighbour', '+26876123456',
  'not-a-hash', now() + interval '2 days')$$, '%violates check constraint%', 'only a token hash is stored, never the token');
select t.fails($$select public.request_attestation(current_setting('t.c1')::uuid, 'Nomsa Dlamini', 'neighbour', '+26876123456',
  repeat('a', 64), now() - interval '1 day')$$, '%expiry must be in the future%', 'expiry must be in the future');
select set_config('t.att1', public.request_attestation(current_setting('t.c1')::uuid, 'Nomsa Dlamini', 'neighbour',
  '+26876123456', repeat('a', 64), now() + interval '2 days')::text, false);
select t.ok(true, 'an attestation can be requested while the case is in progress');
select t.fails($$select public.request_attestation(current_setting('t.c1')::uuid, 'Someone Else', 'employer', '+26876000000',
  repeat('a', 64), now() + interval '2 days')$$, '%duplicate key%', 'a token hash cannot be reused');
select t.fails($$select public.request_attestation(current_setting('t.c2')::uuid, 'Nomsa Dlamini', 'neighbour', '+26876123456',
  repeat('b', 64), now() + interval '2 days')$$, '%cannot be requested in status rejected%', 'no attestations on a decided case');

-- Visibility of the attester's personal data
select t.ok(t.count('select 1 from public.attestation_requests') = 1, 'owner can see attestation requests');
select t.fails($$select token_hash from public.attestation_requests$$, '%permission denied%', 'the token hash is not readable by users');
select t.as_user(:'ana');
select t.ok(t.count('select 1 from public.attestation_requests') = 0, 'analyst cannot see the attester''s personal data');
select t.as_user(:'bob');
select t.ok(t.count('select 1 from public.attestation_requests') = 0, 'other organisations cannot see attestations');

-- The attester answers through server code
select t.as_user(:'alice');
select t.fails($$select public.record_attestation(repeat('a', 64), 'yes')$$, '%permission denied%', 'users cannot answer for the attester');
select t.as_service();
select t.fails($$select public.record_attestation(repeat('f', 64), 'yes')$$, '%not found or no longer open%', 'a wrong token finds nothing');
select t.fails($$select public.record_attestation(repeat('a', 64), 'maybe')$$, '%unknown answer%', 'unknown answers are rejected');
select public.record_attestation(repeat('a', 64), 'yes', 'over_2_years', 'My neighbour across the path');
select t.ok((select answer from public.attestation_requests where id = current_setting('t.att1')::uuid) = 'yes', 'the answer is recorded');
select t.fails($$select public.record_attestation(repeat('a', 64), 'no')$$, '%not found or no longer open%', 'a token works only once');
select t.reset();
select t.fails($$update public.attestation_requests set answer = 'no'$$, '%cannot be changed%', 'an answered attestation is final');
select t.fails($$delete from public.attestation_requests$$, '%cannot be deleted%', 'attestation requests cannot be deleted');
select t.ok(not exists (select 1 from public.audit_events where metadata::text ~* '(nomsa|dlamini|2687|neighbour across)'),
  'the attester''s name, number and comment never reach the audit log');

-- Expiry
select t.as_user(:'alice');
select set_config('t.att2', public.request_attestation(current_setting('t.c1')::uuid, 'Sipho Nkosi', 'chiefs_office',
  'sipho@chief.test', repeat('c', 64), now() + interval '1 hour')::text, false);
select t.reset();
update public.attestation_requests set expires_at = now() - interval '1 minute' where id = current_setting('t.att2')::uuid;
select t.as_service();
select t.fails($$select public.record_attestation(repeat('c', 64), 'yes')$$, '%not found or no longer open%', 'an expired link is refused');
select t.reset();
