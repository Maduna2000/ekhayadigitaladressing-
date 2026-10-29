# Ekhaya screen-by-screen spec

Status: planning draft. Covers the customer verification flow (from the mockups), plus new screens proposed to fill the gaps. Nothing here is built.

Conventions
- **Source** column: M = in the mockups, N = new in this spec.
- Case statuses follow the brief: `draft`, `pending_consent`, `in_progress`, `pending_review`, `verified`, `unable_to_verify`, `rejected`, `expired`, `revoked`, `cancelled`.
- "Business-configurable" means the requesting organisation sets it per request type.
- Copy rules: short sentences, no legal or compliance claims, siSwati and English, never call a result "fraud". GPS is never described as proof of residence.

## 0. Global rules (apply to every customer screen)

1. **Header:** back arrow, Ekhaya wordmark, a "Secure" badge. No bit-length or "compliant" claims.
2. **Footer:** "Need help? Contact Ekhaya Support" on every screen. Use "Ekhaya Verification", with no "Civic", "Kingdom of Eswatini" or "official" wording unless a government source was matched.
3. **Progress:** one scheme for the whole flow, 4 steps: Consent, Address, Evidence, Review. The landing and the result screens sit outside the steps.
4. **Language switch** (English / siSwati) in the header menu on every screen.
5. **Save and continue later** on Address and Evidence. The link expiry is shown wherever the draft is shown.
6. **Disabled buttons** show a one-line reason beneath them.
7. **Low data:** no step needs more than one image load. Uploads resume after a lost connection. Text works before the map loads.
8. **Accessibility:** WCAG AA contrast, 44 px minimum tap targets, labels always visible (no placeholder-only labels), screen-reader order matches visual order.
9. **Images:** every illustration has a text fallback that never shows raw alt text.
10. **Logging:** no address, document or coordinate content in analytics or error reports.

## 1. Customer flow

### C1. Request landing (M, screen 1)
- **Purpose:** show who is asking and why, before anything is collected.
- **Shows:** requesting organisation name and its "Approved by Ekhaya" mark with approval date; request reference; what is asked (one description, same wording as C2); validity countdown; short privacy line.
- **Actions:** Continue; "I don't recognise this request" (goes to C10).
- **States:** valid, expired (C12), cancelled (C12), already completed (shows status, C8).
- **Rules:** the "verified" mark must link to what it means (organisation approved by Ekhaya on a date). The link token is single-customer and time-limited.

### C2. Consent and context (M, screen 2; step 1)
- **Shows:** requested by, purpose, data requested, who receives the result, how long it is kept, link to the full privacy notice.
- **Actions:** two exclusive options (agree, do not agree); Continue stays disabled until one is chosen, with the reason shown.
- **If "do not agree":** go to C10 with "Declined" and no data stored beyond the decision.
- **Records:** consent record with purpose, wording version, timestamp, language, notice version.
- **Rule:** consent text is specific ("Share my address and the evidence I upload with [business] for [purpose]. Kept for [period].") and is not treated as the only legal basis.

### C3. Address details (M, screen 3; step 2a)
- **Fields:** Region (required, the four regions only); Community or locality (required); Town or urban area; Inkhundla / chiefdom; Street name, House / plot, Postcode (all optional, shown as "if available").
- **Logic:** fields shown follow the address class (rural vs street vs informal). A rural address needs no street. Postcode suggestions come from the reference data and are labelled as suggestions.
- **Actions:** Next, Save and continue later, Back.
- **Validation:** inline, plain wording; nothing blocks on missing optional fields.

### C4. Landmark, directions and pin (M, screen 4; step 2b)
- **Fields:** Prominent landmark (required); Directions (recommended, with an example); optional pin: "Use my current location" or "Choose on map".
- **Shows after capture:** coordinates, accuracy in metres, and how captured (device GPS or manual pin). Warns if accuracy is poor or the pin is outside the chosen region.
- **Rule:** the note "GPS alone does not prove residence" stays. Location permission is optional and asked only when the customer taps the button.
- **States:** GPS denied, GPS unavailable, offline map (text-only fallback).

### C5. Supporting evidence (M, screens 5-7; step 3)
- **Shows:** evidence type requested, the list of acceptable documents set by the business (not "follow instructions"), status.
- **Actions:** Take photo, Choose file (JPG, PNG, PDF, max 10 MB, business-configurable); Replace; Remove; Continue; "I cannot provide this evidence"; Back.
- **Default state:** empty, with Continue disabled until at least one file is added or the customer uses the "cannot provide" path.
- **"Cannot provide":** opens C6.
- **Rules:** tell the customer to crop out anything not needed; files go to private storage; only the requested evidence is accepted. The mock sample file is a design placeholder only.
- **States:** uploading with progress, upload failed with retry, file too large, unsupported type.

### C6. Cannot provide evidence (N)
- **Purpose:** an honest alternative route, not a dead end.
- **Options (business-configurable):** reason (no document in my name / document is old / other); ask someone to confirm my address (goes to C7); describe my situation in a text box; continue without evidence.
- **Outcome:** case continues and will likely be "unable to verify" or go to review. Copy states this plainly and does not call it a failure.

### C7. Ask someone to confirm (attestation request) (N)
- **Purpose:** collect a neighbour, chief's office or umphakatsi confirmation.
- **Fields:** attester name, relationship (neighbour, chief's office, employer, landlord, other), phone number.
- **Actions:** Send request (SMS or WhatsApp link, subject to cost and provider decision); Skip.
- **Rules:** the attester gets a separate flow (A1-A3 below). The customer sees "Waiting for [name]" and can resend or cancel. The attester can decline.

### C8. Review and submit (M, screens 8-9; step 4)
- **Shows:** address summary with Edit; landmark and directions shown separately; GPS with accuracy and how captured (or "not provided"); evidence list with Edit; attestation requests with their status.
- **Actions:** confirmation checkbox; Submit disabled until ticked, with the reason shown; Go back and edit.
- **Copy:** keep "Submitting starts the review. It does not mean your address has been verified."

### C9. Submitted and status (N)
- **Shows:** reference, submitted time, current status in plain words, a timeline of events (submitted, attestation received, in review, more information needed, decision).
- **Statuses shown to the customer:** Received, In review, More information needed, Completed, Could not be completed, Expired. Internal statuses map to these.
- **Actions:** add information when asked (opens only the requested part); correct my details; withdraw my request; make a complaint or ask for review; contact support.
- **Rule:** "Could not be completed" explains the reason category and next step. It never implies dishonesty.

### C10. Declined or don't recognise (N)
- **Two paths:** "I don't want to do this" (records the decline) and "I don't recognise this request" (records a suspicious-request report).
- **Shows:** confirmation, what happens next (the business is told the request was not completed, without personal data), how to report to Ekhaya.
- **Rule:** the suspicious-request path flags the case for platform admin review and pauses further messages on that link.

### C11. Errors and connectivity (N)
- Offline banner with "Your answers are saved on this device" and automatic retry.
- Upload failure: retry or choose another file.
- Session timeout: re-authenticate and return to the same step.
- Server error: reference code for support, no technical detail.

### C12. Expired, cancelled or revoked link (N)
- **Shows:** what happened, whether the business can send a new request, support contact.
- **Rule:** never reveals case contents to an unauthenticated visitor.

### C13. Result and data rights (N)
- **Shows:** when completed, what was shared with the business and when; how long data is kept.
- **Actions:** request a copy, correct data, withdraw consent for future sharing, ask for deletion where applicable, complain.
- **Rule:** wording is checked against the Data Protection Act by counsel before launch.

## 2. Attester flow (new; separate link, no account)

### A1. Attestation request
- Shows who is asking (customer's name as they gave it), what is being confirmed ("Does [name] live at [community, landmark]?"), what the attester shares, privacy notice.
- Actions: Continue, Decline, "I don't know this person".

### A2. Confirmation
- Questions: how long you have known this person at this address; yes / no / not sure; optional comment.
- Records attester name, phone, timestamp, answer, the wording version.
- Rule: attestation is evidence, not proof. An attester is not told the result of the case.

### A3. Thanks
- Confirms submission; offers to report a misuse of their details.

## 3. Business console

### B1. Sign in and organisation (N)
- Email sign in with MFA for reviewers and admins; organisation switcher; role shown (owner, admin, reviewer, analyst, developer).

### B2. Case list (N)
- **Columns:** reference, customer reference, type, status, created, due, assigned reviewer, evidence count, flags.
- **Filters:** status, type, date, reviewer, flagged.
- **Actions:** search by reference or customer reference; bulk assign; export (permission-gated).
- **Rule:** shows only that organisation's cases.

### B3. Create request (N)
- **Fields:** verification type, customer reference, purpose, customer contact (phone or email), expiry, evidence requirements (accepted documents, whether attestation is allowed or required).
- **Actions:** send link; copy link; save draft.
- **Rule:** purpose is required and is shown to the customer unchanged.

### B4. Case detail (N)
- **Tabs:** Summary, Address, Evidence, Attestations, Checks, Timeline, Audit.
- **Address tab:** submitted address; source label (customer-submitted, reference-matched, officially matched) kept separate; map with pin and accuracy; version history.
- **Evidence tab:** files via short-lived signed access; every view is audited.
- **Checks tab:** each rule's result, reason and the policy version; no single score as the headline.
- **Rule:** the page shows what the business is allowed to see, not everything Ekhaya holds.

### B5. Reviewer queue and decision (N)
- Queue of `pending_review` cases, with oldest first and an SLA indicator.
- Decision form: outcome (verified, unable to verify, rejected), reason code, notes, required checklist (evidence reviewed, address consistent, attestation considered).
- Rules: decision is recorded with reviewer, policy version and timestamp; "unable to verify" is the default for missing evidence; reviewers cannot decide cases from their own organisation's customers unless allowed by policy; a second reviewer is required for rejections.

### B6. Result view (N)
- What the business receives: status, method, timestamp, limitations text, audit reference. For example: "Customer-submitted address, reviewed by [org] on [date]. Location evidence does not prove residence."

### B7. Team and roles (N)
- Invite, change role, suspend. Shows last sign-in. Every change is audited.

### B8. Developer and API (N)
- API keys (shown once, stored as hashes), scopes, rotate and revoke; sandbox switch; webhook endpoints with signing secret and delivery history; usage; request log with no personal data.

### B9. Reports and usage (N)
- Volume, completion rate, median time to result, manual review rate, unable-to-verify rate, billing usage. No personal data in exports unless permitted.

### B10. Organisation settings (N)
- Evidence requirements, default expiry, retention period (within platform limits), branding shown to customers (name and logo only), notification settings.

## 4. Platform admin (Ekhaya staff)

### P1. Organisation approvals
- Review applications, documents and contacts; approve, reject or suspend. The approval date feeds the customer-facing "Approved by Ekhaya" mark.

### P2. Reviewer management and QA
- Assign reviewers, sample decisions for second review, track agreement and correction rates.

### P3. Complaints and suspicious reports
- Queue from C9 and C10. Statuses: new, investigating, resolved. Links to the case audit trail.

### P4. Policy configuration
- Versioned verification policies (rules, thresholds, escalation). Changes are drafted, reviewed, then published with a version number that every decision records.

### P5. Audit explorer
- Search audit events by actor, case, organisation or time. Read-only. Access to this screen is itself audited.

### P6. System health
- Webhook failures, queue depth, error rates, storage and SMS usage.

## 5. State map (customer-visible vs internal)

| Internal status | Customer sees |
|---|---|
| `draft`, `pending_consent` | Not started |
| `in_progress` | In progress |
| `pending_review` | In review |
| `verified` | Completed |
| `unable_to_verify`, `rejected` | Could not be completed |
| `expired` | Expired |
| `revoked`, `cancelled` | Cancelled |

## 6. Open questions for these screens

1. Customer authentication in C1-C2: link token only, SMS one-time code, or both? (Brief says "proportionate".)
2. SMS vs WhatsApp for customer and attester messages: cost, delivery and consent rules.
3. Can the customer create a reusable address profile (ownership model) in this version, or is each case standalone?
4. What does "Approved by Ekhaya" require from a business?
5. Which attester types count, and does the chief's office need an account?
6. Exact retention periods and what the customer can delete.
7. Who sees the result: only the requesting business, or also the customer's copy?

## 7. Issues from the mockups that this spec resolves

Compliance and "Civic / Kingdom of Eswatini" wording removed; one step scheme; one consistent request description; official region names; GPS accuracy and capture method shown; landmark and directions kept separate; attestation route added; evidence requirements made concrete; empty evidence default; status, declined, expired and error screens added.
