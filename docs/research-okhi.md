# Research: OkHi and comparable address-verification systems

Researched 29 October 2026 from public web sources. Company-reported figures are marked as such. Anything not found is listed under "Gaps".

## 1. OkHi

Sources: [How it works](https://www.okhi.com/howitworks), [docs overview](https://docs.okhi.com/v6.0.1/overview/master), [verification status API](https://docs.okhi.com/v6.0.1/verification-status/verification-status/verification-status-api), [Nairametrics interview (2021)](https://nairametrics.com/2021/10/20/timbo-drayson-is-solving-nigerias-address-verification-issues-through-okhi/), [Kuda customer guide](https://business-support.kuda.com/en/articles/13907523-kyc-address-verification-with-okhi).

### Structure
- A business embeds OkHi's SDK in its own mobile app (Android, iOS, Flutter, React Native).
- Results reach the business by webhook, the OkDash dashboard and a REST API.
- Products: **OkCollect** (capture an address with map pin, photo, landmark), **OkVerify** (verify against phone data), **OkGo** (navigate to an OkHi address).
- The web JavaScript library and WooCommerce plugin only create addresses. Address verification requires a mobile app.

### Verification flow
1. The customer creates an address inside the business's app.
2. A geofence is registered on the phone.
3. The OS notifies OkHi's servers when the phone enters or leaves it.
4. ML models estimate time spent at the location.
5. A status is sent to the business once one can be determined.

### Outputs
- Statuses: `verified`, `not_at_address`, `unknown`, `in_progress`, `cancelled`, `not_started`.
- No confidence score and no reason field appear in the documented API.
- Entries are digital or physical (`verification_method`), with `mode` of `first_time` or `continuous`. Physical entries can carry a `witness` (name, phone, comment).
- Subscription features: `proof_of_personhood`, `last_visit`, a downloadable proof-of-address certificate (KYC package), and re-verification.

### Timing and permissions
- Needs at least 1.5 days of location data, up to 8 days. OkHi's site claims 1.8 days on average (company-reported).
- Kuda tells customers up to 72 hours and requires "Allow All the Time" (Android) / "Always Allow" (iOS) location access for the whole verification.
- Failure is a normal outcome: `not_at_address` and `unknown` both occur when the signal is weak.

### Business model
- Businesses pay per verification. Consumers use their OkHi address free.
- OkHi says users own their address and control who it is shared with (a policy statement).
- Customers shown: Kuda, Standard Bank, Flutterwave, Sterling and others. Claimed coverage: 34 countries.

### Claims not independently verified
- Stanbic IBTC pilot: 29% more accurate, 4x faster, 52% cheaper (company-reported, 2021).
- "4x faster than agent in-person verification."

## 2. Other approaches

| Approach | Example | How it verifies | Weakness |
|---|---|---|---|
| Passive phone geofence | OkHi | Dwell time at the pinned location | Native app and background location needed; slow |
| Agent visit | [Dojah](https://docs.dojah.io/overview/user-verification/digital-address-verification) | Agent visits; returns GPS, photos, neighbour comment. Async: submit, get `reference_id`, poll | Slow, labour-heavy; documented for Nigeria |
| Document proof | [Veriff](https://www.veriff.com/product/proof-of-address-product) | Reads a bill or statement, checks issue date (about 90 days), flags tampering; webhook with a trust score | Many homes have no utility bill |
| Location code | [Ghana Post GPS](https://www.graphic.com.gh/news/general-news/how-the-national-digital-property-address-system-works.html), Plus Codes, what3words | Grid cell gives a code (Ghana: 5 m squares) | Names a place; does not prove who lives there |
| Aggregator | Smile ID, Youverify | Many checks behind one API | Address methods not found |

Every provider is passive and slow, human and slow, or document-based and weak where documents are scarce.

## 3. Implications for Ekhaya

1. A web-only product cannot reproduce OkHi's evidence, because a browser cannot track location in the background.
2. The real choice is a native Android app versus cheaper evidence: attestation by a neighbour or chief, courier delivery confirmation, and field agents.
3. Attestation and courier evidence may be Ekhaya's edge in Eswatini, using chiefdom structure and the courier pilot.
4. Return a status plus the evidence behind it. OkHi documents no reason field. Treat "unable to verify" as neutral, not as fraud.
5. A customer-owned address with a consent ledger is what enables reuse across businesses. It needs EDPA review.
6. Defer document OCR and trust scores.

## 4. Open decision

Native Android app from the start, or begin with attestation, courier evidence and agents and add the app only if a pilot shows the evidence is too weak? Current lean: the second.

## 5. Gaps

- OkHi FAQ and webhook pages were unreadable (docs site redirected), so the webhook payload and spoofing defences are unknown.
- No useful results on Smile ID or Loqate address methods.
- Not confirmed whether Bank of Ghana accepts a digital address as proof of address.
- All OkHi performance figures are company-reported.
