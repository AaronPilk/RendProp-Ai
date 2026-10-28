# App Review demo-account runbook (historical funding draft, 2026-10-27)

**Access-path correction, 2026-10-28:** Do not execute the Apple Account handoff or paste its Notes template below. Native Sign in with Apple authenticates the iCloud account on the reviewer's device; an app-specific account cannot be selected by entering its Apple Account credentials in Rendprop. Apple's account-security guidance also says not to share an Apple Account. This document remains useful only as a reference for the finite `app_review` funding and media checks. The release access path and its unimplemented work are recorded in [reviewer-access-path-20261028.md](reviewer-access-path-20261028.md). The current `review_notes.txt` is still a draft and does not establish full reviewer access.

**Status: STOP before App Store submission.** No dedicated Apple Account or Rendprop demo workspace exists. This document records the smallest operator sequence for the existing service-owned `app_review` grant; it is not proof of full reviewer access. Do not run the write examples or change App Store Connect (ASC) until the stop gates below pass against the exact deployed backend and submitted iPhone build. No credentials, live account, database row, or ASC field were created for this draft.

Apple asks for working demo credentials at submission, an expired-subscription demo account for an auto-renewable subscription, and any authentication code in Review Notes in advance. Credentials that expire before review can cause rejection. Its guidelines require full app access, live backend services, on-device testing, and visible, functional in-app purchases. [Review information](https://developer.apple.com/help/app-review/before-submitting-for-review/complete-review/); [App Review Guidelines §§2.1(a)–(b)](https://developer.apple.com/app-store/review/guidelines/#performance).

## Stop gates

1. **Apple Account handoff is unresolved.** Rendprop only offers Sign in with Apple (SIWA), so a Rendprop database user cannot be entered with an app password. A reviewer using the proposed demo identity would need to authenticate that ordinary Apple Account on their own device. SIWA requires two-factor authentication; a new-device sign-in can demand a changing six-digit code from the owner's trusted device/phone. A static ASC password or prewritten code cannot guarantee this handoff. The owner must rehearse it on a clean second iPhone and get an accepted App Review contact/2FA arrangement before treating the account as review-ready. Do not put the owner's personal Apple Account in ASC. [SIWA on iPhone](https://support.apple.com/guide/iphone/sign-in-with-apple-iph238921d37/ios); [Apple Account two-factor authentication](https://support.apple.com/en-us/102660).
2. **Seven days cannot guarantee the review window.** `provision_serving_funding(..., 'app_review', ...)` permits at most seven days and refuses a second lifetime review grant to the same actor. Funding just before submission can expire in the review queue; an expired grant cannot be renewed for this identity with a new reference. Confirm an Apple-accepted access plan that remains valid throughout review, or change and re-prove this finite authority before submission. A fresh account is not a reliable automatic retry strategy.
3. **The reviewer credit repair is source-only and unactivated.** Migration `20261028010346_reviewer_sandbox_shared_credit_budget.sql` and its Edge restore change allow only the named, funded `app_review` actor with a **signed, positive-price Sandbox subscription period**, current monthly Sandbox credit grant, and covering paid media account reserve to use credit-funded photo, Photo Motion, and aerial routes. The repair changes the old calendar-month review ceiling to one nonrenewable seven-day slice and shares its provider allowance with legacy work. It neither funds a reviewer nor activates a monthly catalog, tariff, or signed purchase. It does not turn Sandbox credits into Production credits or authorize ordinary Sandbox accounts. A signed **free trial** receipt grants no monthly credits; the dedicated account must actually reach a paid Sandbox period for those routes. Merge, deploy, and test this source and the exact binary on a physical iPhone before advertising these routes in ASC Notes. Its local disposable PostgreSQL and signed-Apple Edge checks are not live or device proof.
4. **Media needs two funded layers.** The review workspace needs its own `media_delivery_budgets` row tied to the exact `serving_funding.id`, and a covering `media_account_reserves` receipt with actual paid cash/tariff evidence. Without the org budget, original upload reservation fails `RP503`. A new account-level reserve has rounded fixed costs and may require more than $5 of distinct cash; do not count it as free or silently charge it outside the owner's launch ledger. The $5 reviewer sponsor is a single inclusive supplier-and-org-media liability; its media reserve components are subsets, not a second $5. If an already-paid account reserve covers the review interval, identify its receipt and remaining shared/QA allocation. The backend trial sponsor and paid retail cap do not create reviewer authority.
5. **Purchase-flow review remains separate.** An `app_review` grant is neither an expired Apple subscription nor a working new paid checkout. The current ordinary new-purchase path is gated. Apple asks for an expired-subscription demo account and functional IAP. Resolve and test that path before claiming the submission is complete. [Review information](https://developer.apple.com/help/app-review/before-submitting-for-review/complete-review/); [Guideline 2.1(b)](https://developer.apple.com/app-store/review/guidelines/#performance).

## Owner setup and identity handoff (no agent handles credentials)

1. The owner creates a dedicated **ordinary** Apple Account with a private mailbox they control, a strong password, two-factor authentication, and a continuously reachable trusted phone/device. Keep password, recovery keys, and live 2FA codes out of source, tickets, logs, and this runbook. An ASC Sandbox tester is only for testing purchases and cannot substitute for an ordinary App Store/SIWA identity. [Apple Sandbox account guidance](https://developer.apple.com/help/app-store-connect/test-in-app-purchases/create-a-sandbox-apple-account/).
2. On a physical iPhone, install the exact candidate build; sign the device into that ordinary Apple Account, then use **Sign in with Apple** inside Rendprop. Name the profile, allow Rendprop to create its own personal workspace, and verify it is the sole-member owner, not a guest, private-QA grant, or Production subscriber. Record only the resulting `auth.users.id` and `public.orgs.id` in the private operator change record. Do not infer an actor from email aliases: SIWA can hide email.
3. Before any grant, rehearse the reviewer handoff on a second clean iPhone **without** a trusted session for that Apple Account. Record whether the reviewer can actually select this account and receive the 2FA code without synchronous owner intervention. If the answer depends on a live code/call, ask App Review how it will authenticate; Apple's review-information page says an unprovided code may require a call that usually takes three to five business days. Do not enter a stale code in Notes or claim the handoff is reliable.
4. Keep the review fixture free of personal client data. If sharing the account is accepted, enter credentials only in ASC's private App Review information fields, managed by the owner; do not send them to an agent. Note the exact trusted-phone response process and a contact who can answer throughout the review. If Apple declines device-level account sharing, stop and use a separately approved fully featured demo mode or a proven reviewer-own-ID path.

## Finance and backend preflight

The operator must have the exact submitted migration set, including `20261006164721_funded_serving_and_app_review_authority.sql`, `20261007145000_pooled_media_startup.sql`, `20261027234243_paid_media_budget_cap.sql` if the launch uses it, and the independently reviewed `20261028010346_reviewer_sandbox_shared_credit_budget.sql` plus matching Edge restore code if reviewer credits are needed. The paid cap does **not** fund App Review or add credits. Record source commit, migration checksums, UTC timestamps, tariff version, supplier/provider hard limits, actual cash receipt, sponsor commitment and evidence SHA-256 in a private change record. Charge this grant's **maximum 500 cents** against the remaining owner-funded shared/QA launch allocation (or distinct paid cash); do not double count the same receipt against trial/retail commitments. If that envelope lacks 500 uncommitted cents, stop.

Read-only identity and authority preflight as a privileged operator (replace the two UUIDs):

```sql
select u.id actor_id, u.is_anonymous, o.id org_id, o.deleted_at,
       count(m.user_id) member_count,
       count(m.user_id) filter (where m.user_id = u.id and m.role = 'owner') owner_count
from auth.users u
join public.memberships owner_member on owner_member.user_id = u.id
  and owner_member.role = 'owner'
join public.orgs o on o.id = owner_member.org_id
join public.memberships m on m.org_id = o.id
where u.id = '<ACTOR_UUID>'::uuid and o.id = '<ORG_UUID>'::uuid
group by u.id, u.is_anonymous, o.id, o.deleted_at;

select count(*) prior_review_grants from public.serving_funding
where actor_id = '<ACTOR_UUID>'::uuid and source = 'app_review';
select count(*) active_or_grace_production_subscriptions from public.apple_subscriptions
where org_id = '<ORG_UUID>'::uuid and environment = 'Production'
  and status in ('active','grace');
select count(*) other_current_funding from public.serving_funding
where org_id = '<ORG_UUID>'::uuid and revoked_at is null and ends_at > now();
select count(*) pending_deletions from public.deletion_requests
where user_id = '<ACTOR_UUID>'::uuid and status in ('pending','processing');
select public.org_has_internal_testing_grant('<ORG_UUID>'::uuid) internal_unlimited,
       public.org_has_private_internal_testing('<ORG_UUID>'::uuid) private_unlimited;
```

Require exactly one named owner and one member, zero in all four counts, and both unlimited-authority booleans false. The grant RPC repeats these checks. It cannot create an identity or workspace.

Find one **already paid** account reserve covering the whole proposed seven-day interval and matching current conservative tariff; never reuse a cash evidence digest or create an overlapping receipt. If none exists, the owner-finance operator must first provision one with `public.provision_media_account_reserve(ref, '9c332c75b96cc642621dad5d86d4bf18', 'owner_paid_cash' | 'business_paid_cash', cash_evidence_sha256, starts_at, ends_at, cash_paid_cents, eight-key tariff_json, seven-key account_reserves_json)`. Its fixed/rounded boundary floor and total reserves must be covered by **distinct actual paid cash**. Provisioning returns no review grant. Check the exact signature/body after the paid-cap migration, which changes its overlap guard but not its arguments. The account tariff keys are `r2_a_cents_per_million`, `r2_b_cents_per_million`, `worker_cents_per_million`, `worker_cpu_cents_per_million_ms`, `edge_cents_per_million`, `db_cents`, `logs_cents`, and `storage_cents_per_gb_month`.

When all stop gates are resolved, grant and org media budget must succeed in **one transaction** under `service_role`, so an upload-capable but unfunded review identity cannot be left behind. Fill the placeholders from the private, independently checked cost worksheet; the seven serving reserve entries must sum to at most 500 cents and cover every enabled provider, retries/uncertain outcomes, storage, delivery, compute, email, support, retention and uncertainty. The four media reserve entries must fit inside their matching serving components. The request, byte, and physical-storage limits must cover the one fixture and Apple's plausible review while meeting the tariff floors. Do not use an example allocation as financial evidence.

```sql
begin;
set local role service_role;
do $review$
<<review>>
declare
  actor uuid := '<ACTOR_UUID>'::uuid;
  org uuid := '<ORG_UUID>'::uuid;
  funding_ref text := '<UNIQUE_REVIEW_FUNDING_REF_8_TO_200_CHARS>';
  media_ref text := '<UNIQUE_REVIEW_MEDIA_REF_8_TO_200_CHARS>';
  account_ref text := '<PAID_ACCOUNT_RESERVE_REF>';
  sponsor_evidence text := '<64_LOWERCASE_HEX_SHA256>';
  media_evidence text := '<64_LOWERCASE_HEX_SHA256>';
  serving_reserves jsonb := '<SEVEN_INTEGER_CENT_KEYS_JSON>'::jsonb;
  media_reserves jsonb := '<FOUR_INTEGER_CENT_KEYS_JSON>'::jsonb;
  request_limit bigint := <ATTESTED_REQUEST_LIMIT>;
  byte_limit bigint := <ATTESTED_BYTE_LIMIT>;
  storage_limit bigint := <ATTESTED_STORAGE_LIMIT>;
  starts_at timestamptz := transaction_timestamp();
  ends_at timestamptz := transaction_timestamp() + interval '7 days';
  account_row public.media_account_reserves;
  funding_result jsonb;
begin
  select * into strict account_row from public.media_account_reserves a
   where a.receipt_ref = review.account_ref and a.starts_at <= review.starts_at
     and a.ends_at >= review.ends_at;
  funding_result := public.provision_serving_funding(
    org, 'app_review', funding_ref, actor, 0, 500, starts_at, ends_at, 1,
    serving_reserves, sponsor_evidence);
  perform public.provision_media_delivery_budget(
    org, media_ref, (funding_result->>'funding_id')::uuid, starts_at, ends_at,
    request_limit, byte_limit, storage_limit, account_row.tariff,
    media_reserves, media_evidence, account_ref);
end $review$;
commit;
```

The template is intentionally non-runnable until every placeholder is replaced and independently reviewed. In particular, do not select a tariff or reserve amount merely to get an RPC to accept it. `p_starts_at` cannot be more than five minutes in the future; execute near submission, after the review timing problem is resolved. `retention_ends_at` equals the grant end for `app_review`, so this is only a seven-day media/retention authority.

Read back immediately after commit and again before submission and during review. Run the entire block as `service_role` in a read-only transaction. `reviewer_sandbox_signed_credit` deliberately returns `false` when called as `postgres` or any other role, even if the reviewer is funded; a privileged operator's default role is not a valid access check.

```sql
begin;
set transaction read only;
set local role service_role;
select id, org_id, actor_id, source, collection_ref, sponsored_cents,
       starts_at, ends_at, retention_ends_at, recurring_reserve_cents,
       reserve_components, evidence_sha256, revoked_at
from public.serving_funding where collection_ref = '<REVIEW_FUNDING_REF>';
select funding_id, slice_index, starts_at, ends_at, total_budget_cents,
       recurring_reserve_cents
from public.serving_funding_slices where funding_id = '<FUNDING_UUID>'::uuid;
select receipt_ref, account_id, starts_at, ends_at, cash_paid_cents,
       allocated_org_cents, tariff, reserves, cash_evidence_sha256
from public.media_account_reserves where receipt_ref = '<ACCOUNT_REF>';
select id, org_id, funding_id, account_reserve_ref, starts_at, ends_at,
       request_limit, used_requests, byte_limit, used_bytes, storage_limit,
       reserves, evidence_sha256
from public.media_delivery_budgets where receipt_ref = '<REVIEW_MEDIA_REF>';
select public.org_has_app_review_funding('<ORG_UUID>'::uuid) active,
       public.effective_plan('<ORG_UUID>'::uuid) plan,
       public.plan_serving_ceiling('<ORG_UUID>'::uuid) ceiling,
       public.credit_wallet_state('<ORG_UUID>'::uuid, 'Production') production_wallet,
       public.credit_wallet_state('<ORG_UUID>'::uuid, 'Sandbox') sandbox_wallet,
       public.reviewer_sandbox_signed_credit('<ORG_UUID>'::uuid) signed_reviewer_credit;
select budget_source, state, coalesce(sum(hold_cents), 0) held_cents
from public.serving_cost_reservations
where org_id = '<ORG_UUID>'::uuid group by budget_source, state;
select source, environment, granted_credits, remaining_credits,
       starts_at, expires_at, revoked_at
from public.credit_grants where org_id = '<ORG_UUID>'::uuid;
select operation, state, coalesce(sum(credits), 0) held_credits
from public.credit_holds where org_id = '<ORG_UUID>'::uuid
group by operation, state;
select bucket, coalesce(sum(bytes), 0) retained_bytes
from public.media_storage_receipts
where org_id = '<ORG_UUID>'::uuid and deleted_at is null group by bucket;
rollback;
```

Require one funding/slice/media row, matching actor/org/window, 500 total sponsor cents, seven reserve keys, media budget tied to that funding and account receipt, fresh request/byte counters, and a ceiling period equal to the seven-day grant without a month-boundary refill. For credit routes, require `signed_reviewer_credit=true`, a current positive-price Apple-signed Sandbox period, an active monthly catalog, the corresponding Sandbox grant and tariff, and zero accidental Production grants. The signed period must be obtained through the exact deployed Edge purchase or restore path; never insert a grant manually for the live reviewer. Track legacy and credit supplier holds, video holds, credit holds, media counters, uncertain outcomes and physical storage receipts against the same commitment. `revoke_serving_funding(org, funding_ref, revocation_evidence_sha256)` ends new authority; it does not erase incurred or uncertain liabilities.

## One fixture and iPhone rehearsal

On the dedicated account, use **Home > Get started** to create one clearly fictional listing with an authorized front-exterior photo and one interior photo; retain originals and rights evidence. Use the actual upload flow and verify `media_storage_receipts` for the workspace before spending on AI. Keep one listing ID in private Notes. On the exact submitted build and a physical iPhone, use SIWA from a clean session, open that listing, review one paid-equivalent photo edit, then **Make a video > Listing** with Photo Motion, **Aerial intro** from the original front exterior, and **Website design > Classic** with the selected Listing video. Check AI-consent prompts, result review, saved-item recovery, and public/private website behavior. Record pass/fail and the matching finite holds/counters; no simulator-only or mock response counts. Before Apple review, confirm enough unspent provider, credit, request, byte, and storage headroom remains for Apple to repeat at least one action. If the $5 envelope cannot cover that rehearsal and reviewer repetition, stop rather than top up the same lifetime grant.

Verify that an ordinary new Apple account gets only the public seven-day trial limits, cannot use the review fixture/workspace, cannot redeem any review-only authority, and reaches the ordinary purchase flow. Verify the expired/revoked demo grant loses new media/AI admissions and never creates retail credits. Separately test a Sandbox purchase and an expired-subscription demo identity for Apple's purchase-flow review; neither is supplied by the `app_review` grant.

## Private ASC information, only after every gate passes

In the version's **App Review Information** fields, the owner supplies the dedicated account's working username/password **only if Apple confirms the SIWA device/2FA handoff**, plus a reachable review contact. In private Notes, replace the current `docs/appstore/metadata/en-US/review_notes.txt` claim that the reviewer should use their own Apple ID with the verified demo path; identify the fixture listing and exact taps for photo edit, Listing video/Photo Motion, aerial intro, Classic website, Restore purchases, and the expired-subscription purchase-flow account. State honestly that the 7-day public trial is intentionally limited and that the finite demo authority is solely for review. State any region/device limits and the exact build tested. Never include live 2FA codes, recovery data, supplier keys, or cash evidence in public metadata or source.

Private Notes template to fill **only after** the stop gates pass (no credentials in this file):

> ACCESS: Rendprop uses Sign in with Apple. Use the dedicated Apple Account entered in the private Demo Account fields; its new-device two-factor handoff has been rehearsed and arranged with App Review as described here: [verified arrangement and reachable contact]. Do not use a Sandbox Apple Account for app sign-in. The account is a sole-owner demo workspace with time-limited, funded review access through [verified UTC end].<br>
> FIXTURE: Open Home > [fixture listing label]. To create from scratch, Home > Get started. Open the fixture > [verified photo edit path]; then Make a video > Listing > Photo Motion; Aerial intro uses the original front exterior; Website design > Classic publishes the included website with the selected Listing video. All media is authorized demonstration content.<br>
> BILLING: The ordinary seven-day Apple trial intentionally permits one draft and limited photo edits; paid video, aerial and website use begin after first paid renewal. For the full purchase-flow review, use the separately provided expired-subscription account [private field or verified path]. Account > Settings & plan > Plan & usage contains Restore purchases and Manage subscription. [List only IAPs actually visible and functional in this build.]<br>
> TESTED: [exact build], [physical iPhone model], [iOS version], [UTC test time], [relevant region]. Contact [reachable owner contact] if the agreed Apple Account authentication handoff fails.

If the reviewer cannot enter the demo Apple Account on their device without an unplanned live 2FA exchange, the grant expires during review, any listed route refuses, or checkout remains gated, do **not** submit Notes claiming full access. Contact App Review with the actual SIWA constraint and seek an accepted access arrangement; a fully featured built-in demo mode requires the conditions/prior approval in [Guideline 2.1(a)](https://developer.apple.com/app-store/review/guidelines/#performance). The old own-Apple-ID Notes are equally insufficient for paid paths until a safe own-ID entitlement exists.
