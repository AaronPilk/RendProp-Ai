# Photographer and videographer client delivery

This workflow keeps a photographer's account and project ownership separate
from the contact shown on each client's listing. The client needs no Rendprop
account. It also works for a business contact outside real estate.

## Using the workflow

1. In real estate onboarding, choose **Agent** or **Photographer / videographer**.
   The choice can be changed later in account settings. It changes guidance,
   never team permissions or subscription access.
2. Create a property. In its contact settings, choose **My client**, then enter
   the client's name, phone, public email and optional brokerage/business. Upload
   their photo separately from property photos. Additional contact links are optional.
3. Review the email that should receive inquiries. It normally matches the
   public contact email; a different private delivery address can be saved.
4. Save the contact, then publish. Unsaved changes, failed saves and conflicting
   phone/Studio revisions must be resolved before publishing. Changing a listing
   contact does not replace the photographer's account card or another client.
5. Use the marketing link for the client card and inquiry form. **Hide Rendprop
   logos and app promotions** removes promotional attribution, app banners and
   house partner advertisements. The rendprop.com address and truthful privacy
   disclosure remain. The separate MLS link removes all contact cards and forms.
6. New inquiries remain in the photographer's lead inbox and queue an email to
   the saved client. The email contains the inquiry details and listing link;
   it does not require a client login. Review the recipient before resending.
   Older inquiries have **Send to client** after a client is assigned; assigning
   a contact never automatically emails historical inquiries.

**Email sent** means the provider accepted the message, not that it reached the
inbox. Failed or skipped attempts show their status. A lost response retries the
same send request; a deliberate new resend uses a new request after the cooldown.
When a contact address changes, history retains the previous recipient and the
new confirmation shows the current saved recipient. Pending messages to the old
contact are canceled. An email already dispatched cannot be recalled.
Manual forwards allow one new request per inquiry per minute, and at most
20 per person or workspace in ten minutes. Retrying the same request does not
create another email or consume another allowance.

## Storage and access

- `profiles.real_estate_role` is an account preference. Existing profiles start
  as Agent; new profiles leave the choice unset until explicitly selected.
- `listing_client_contacts` stores the public card separately from its private
  recipient. It is not placed in the public `listing.details` JSON.
- Contact photos use the existing fenced upload transport with
  `role: contact_photo`, in a separate `renders/<org>/<listing>/contact-…` key.
  They are excluded from property galleries, cover/source choices and listing
  media exports. Only a verified uploaded asset can become the client photo.
- Contact revisions use optimistic concurrency. Offline native drafts stay
  account/workspace scoped; a failed refresh does not erase the saved draft.
- `client_lead_deliveries` and its outbox retain the recipient and message per
  send intention. Provider retry keys are stable and automatic retries stop
  before the provider's idempotency window expires.
- Both new tables have RLS with no client policies. Edge routes verify identity
  and workspace before calling service-only RPCs. Owner/admin/agent members can
  edit and resend; marketing members cannot acquire write permission by choosing
  Photographer in onboarding.

## APIs

| Route | Purpose |
| --- | --- |
| `GET /me` | Returns `user.real_estate_role`, nullable for an unselected preference. |
| `PATCH /me/profile` | Saves `real_estate_role: agent` or `photographer_videographer`. |
| `GET /listings/:id/client-contact` | Returns `{contact: null}` or the selected workspace's contact. |
| `PUT /listings/:id/client-contact` | Full contact replacement with `expected_revision`; returns the verified saved contact. |
| `GET /leads` | Adds private `client_delivery` status to the owning workspace's inbox. |
| `POST /leads/:id/send-to-client` | Requires a UUID `request_id` and `expected_recipient_email`; the server derives the destination from the saved contact. |
| `GET /tours/:slug` | Returns only the public client card and boolean display flags; no delivery email/history. |

## Verification and acceptance

The isolated browser fixtures use real components and synthetic contact photos,
properties and inquiries. They exercise save-before-publish, two-client isolation,
conflicting phone revisions, failed saves, confirmed resends and lost replies.
The public renderer tests preserve MLS stripping, property disclosures, original
photo links and opt-in fly-through playback. PostgreSQL fixtures test the actual
migration and authorization/recipient transactions on a disposable local database.

Use two of your own test listings with different contacts for phone-to-Studio
acceptance. Verify a permitted real inquiry's email in the intended inbox and its
matching account record, then confirm one explicit resend. Physical capture and
camera behavior require an iPhone. Mock transport does not prove inbox delivery.
Deployment and TestFlight receipts belong in the release handoff; these workflow
instructions alone do not establish that a particular build is live.
