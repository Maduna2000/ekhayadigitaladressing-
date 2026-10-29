# Ekhaya architecture (build, stages 1-2: database foundation)

Stack decision (from the project brief): React, TypeScript and Vite on the front end; Supabase Postgres, Auth and Storage; server logic in Edge Functions. The earlier Cloudflare D1 schema is archived in `legacy-d1/`.

## Layout

```
supabase/migrations/   Postgres schema, RLS, functions (the source of truth)
supabase/tests/        SQL tests + run.sh (throwaway local Postgres, no Docker)
legacy-d1/             Earlier SQLite/D1 schema, kept for reference only
docs/                  Research, screen spec, mockups, this file
```

## How the structure keeps tenants apart

1. **Every business-owned row has `org_id`.** Reads are allowed only to active members of that organisation (RLS, via `app.is_member`).
2. **Composite foreign keys** `(id, org_id)` link customers, addresses, address versions and cases. A row cannot point at another organisation's data, even through a bug or with staff access. Tests prove this.
3. **No direct writes from the browser roles.** `anon` and `authenticated` get `select` only. Every write goes through a `security definer` function that checks the caller's role and writes an audit event. Supabase grants new tables to these roles by default, so the migrations revoke it explicitly, and the test harness mimics that default to catch mistakes.
4. **One role check, one place.** `app.caller_role()` returns the member's role, or `system` for the service role. Permissions for case moves live in a table (`case_transitions`), not in code.
5. **Errors don't leak.** Acting on another organisation's case returns the same error as a missing one.

## Integrity rules enforced in the database

- Case status changes only through `transition_case()` and `decide_case()`. A trigger blocks every other path, including staff. Terminal states stay terminal.
- Decisions (verified, unable to verify, rejected) go only through `decide_case()`: it needs a reason code and policy version, bars the case's creator from deciding it, and requires a **second, different reviewer** to confirm a rejection.
- Consent is recorded only by trusted server code, with a snapshot of the purpose and notice version shown. Consent, decisions and attestations are append-only.
- Attestations store only a hash of the one-time link token. The attester's name and contact are visible to owners, admins and reviewers only and never enter the audit log.
- Address versions are immutable. A correction adds a version.
- `provenance` (customer-submitted, reference-matched, officially matched) must agree with the source's kind. No official source exists yet, so "officially matched" cannot be recorded. GPS never changes provenance.
- Required address components come from the address class (data), so a rural address needs only region and community.
- The audit log is append-only, and reason codes are restricted to short codes so personal data stays out of it.

## Scalability notes

- **Indexes** follow the access patterns: cases by `(org_id, status, created_at)`, addresses by org and customer, versions by `(address_id, version_no)`, audit by `(org_id, created_at)`.
- **Reference and policy as data**: address classes, components, case transitions and (later) verification policies change by migration or admin screen, not by redeploy.
- **Audit and address versions are append-only**, so they can be partitioned by time or organisation later without changing the model.
- **Stateless server code.** Business rules sit in the database and thin Edge Functions, so the front end and API can scale horizontally.
- **Open scaling decisions**: row counts that justify partitioning, a read replica for reporting, and storage layout for evidence files. These need pilot numbers, not guesses.

## What is verified and what is not

- Verified: all five migrations apply, and 139 SQL checks pass on a local Postgres 16 (`supabase/tests/run.sh`).
- Not verified: behaviour on real Supabase. The test harness uses a small stand-in for `auth.uid()` and the Supabase roles. Run the migrations on a real Supabase project (or the Supabase CLI) before relying on them.
- Not built yet: evidence file storage, API keys and webhooks, customer authentication, the React app, and organisation member invitation.

## Next stages

1. Supabase CLI config and a real-Supabase test run in CI.
2. Vite + React + TypeScript scaffold, sign-in and organisation shell, then the case list and detail.
3. Customer flow screens against Edge Functions that use the service role.
