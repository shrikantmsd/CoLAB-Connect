# CoLAB Connect SaaS rollout notes

This branch/archive is an incremental CoLAB Connect foundation built on the existing WACRM codebase. It keeps the existing CRM, account membership model, inbox and WhatsApp integration. It is not a verified production deployment.

## Product rules implemented in this change

- A newly-created customer workspace receives a 30-day full-feature trial.
- When the trial deadline passes without an active paid subscription, effective entitlements resolve to the Free plan.
- The Free plan keeps the current feature switches enabled and applies only the two agreed limits: five active contacts and five outbound WhatsApp messages per India calendar day.
- The daily message window uses `Asia/Kolkata` and resets at midnight IST.
- Incoming WhatsApp messages do not consume the outbound quota.
- A message is counted when the Meta send API accepts it. The system reserves quota atomically before the provider call and releases the reservation after a definitive send failure.
- Contacts above the Free active-contact limit are preserved. On expiry, the oldest five active records remain active; later records are marked inactive. An inactive record can be reactivated after another active record is deactivated or the workspace upgrades.
- Meta and other third-party charges are not included in a CoLAB subscription. In particular, the trial does not promise unlimited provider usage at no cost to CoLAB or to the customer.

## Rollout behavior for existing installations

Migration `060_colab_connect_saas.sql` deliberately places accounts that already exist when the migration runs on the non-public `legacy` plan. This prevents an upgrade from suddenly restricting current users. Accounts created after the migration receives a 30-day trial automatically.

For a fresh production database, all customer accounts created after the migration get the trial. For an existing live installation, review whether any pre-existing workspaces should be moved from `legacy` to `trial_30d` or to a paid plan. Do not bulk-change them without an approved customer migration policy.

## Database and application changes

Migration `060_colab_connect_saas.sql` adds:

- Plan and feature records: `subscription_plans`, `plan_features`.
- Subscription lifecycle: `subscriptions`.
- Billing records: `billing_customers`, `billing_invoices`, `payment_transactions`, `payment_webhook_events`.
- Usage metering: `daily_usage`, `usage_events`.
- Operations and audit: `tenant_audit_logs`, `platform_admins`, `platform_audit_logs`, `onboarding_progress`.
- `contacts.is_active`, with a database trigger protecting both inserts and reactivation updates.
- RPCs for entitlement resolution, trial expiry, atomic outbound-message quota reservation/finalization, contact capacity and platform-admin detection.

Application changes add quota enforcement to the shared dashboard/public-API send core, automation sends, flow sends and broadcast sends. The customer Settings page includes Subscription & Usage. A Platform Admin page and trial-extension endpoint are provided at `/platform` for users explicitly provisioned as platform administrators.

## Apply safely

1. Create a fresh backup of the Supabase database and confirm a restore path.
2. Deploy to a staging Supabase project first.
3. Review migration `060_colab_connect_saas.sql` with the database owner before applying it.
4. Apply migrations through the project's normal Supabase migration workflow (`supabase db push` after linking the intended staging project, or the team's established migration process).
5. Deploy the application code from the same release as the migration.
6. Verify trial creation with a brand-new test workspace, then verify a trial expiry by setting a test subscription's `trial_ends_at` to a past timestamp in staging.
7. Verify the Free contact and daily-message limits using the acceptance checklist below.
8. Only after staging acceptance, schedule a production rollout with a backup and rollback plan.

Do not run the migration directly against production without a reviewed backup and staging validation.

## Bootstrap the first CoLAB platform administrator

The platform-admin list is intentionally not self-service. After migration, identify the verified CoLAB operator's Supabase Auth user UUID, then insert that exact UUID from a trusted SQL session:

```sql
SELECT id, email
FROM auth.users
WHERE email = 'YOUR_VERIFIED_COLAB_OPERATOR_EMAIL';

INSERT INTO public.platform_admins (user_id, role)
VALUES ('YOUR_VERIFIED_AUTH_USER_UUID', 'super_admin')
ON CONFLICT (user_id) DO UPDATE
SET role = EXCLUDED.role, is_active = TRUE;
```

Do not place this bootstrap permission in public signup, browser code, or customer-facing APIs. Platform administrators can open `/platform`; their access is checked against `platform_admins` on the server.

## Acceptance checklist

- [ ] Creating a brand-new account creates one `trialing` subscription with `trial_started_at` and `trial_ends_at` 30 days apart.
- [ ] Trial entitlements expose all currently seeded feature keys and no CoLAB contact/message quota.
- [ ] An existing account that predates the migration remains on `legacy` and is not unexpectedly restricted.
- [ ] An expired trial resolves to Free without deleting contacts or conversations.
- [ ] Only five contacts remain active after trial expiry; the other records are retained as inactive.
- [ ] A sixth contact insert is rejected for an authenticated customer on Free.
- [ ] Reactivating an inactive contact is rejected when five contacts are already active; deactivating a contact permits reactivation.
- [ ] A sixth same-day outbound Free-tier send is blocked; the next IST calendar day allows five new accepted sends.
- [ ] Incoming messages do not consume the outbound allowance. Webhook-created over-limit contacts are retained as inactive.
- [ ] A definitive Meta send failure releases its reservation; a provider-accepted send consumes one slot.
- [ ] Concurrent send attempts cannot exceed the five accepted-message daily quota.
- [ ] Dashboard sends, public API sends, broadcasts, automations and flows all use the same quota service.
- [ ] Tenant A cannot read Tenant B's subscription, usage or audit rows through authenticated RLS.
- [ ] Only explicitly provisioned platform administrators can open the platform overview or extend trials.

## Not yet connected / production prerequisites

This release provides subscription data structures and enforcement, but it does **not** yet provide a production payment checkout or verified payment-webhook integration. Before accepting subscription payments, the implementation still needs:

- A CoLAB-owned Razorpay (or another selected provider) account and API keys.
- Server-side order/subscription creation and a checkout UI.
- Raw-body webhook signature validation, idempotent event processing and provider reconciliation.
- Upgrade, downgrade, cancellation, refund and failed-payment/grace-period policies.
- Invoice generation and review of GST/tax treatment by CoLAB's finance/CA team.

Meta Embedded Signup is also not wired in this release. It requires CoLAB's Meta app configuration, business verification/Tech Provider setup, approved permissions and tested onboarding. Existing WACRM WhatsApp connection flows remain the current way to connect numbers.

The trial-expiry transition is applied on the first entitlement, usage or contact-capacity operation after the deadline; this release does not configure a scheduled Supabase Cron job. The effective plan still resolves to Free when queried after expiry. Add a monitored scheduled expiry job before a production launch if strict timed data-state transitions and operational reporting are required.

No billing prices are hardcoded. The earlier suggested Starter/Growth/Business price points remain proposals until CoLAB approves them.

## Operational cautions

- Test the migration on a copy of the real schema and data before production.
- Do not use a service-role key in browser code. All platform-admin and usage writes are server-side.
- Review every new security-definer function and RLS policy as part of the deployment review.
- Monitor `usage_events` for reservations that remain in `reserved` after provider acceptance; the application logs finalization failures and errs conservatively by retaining the reservation.
- If a trial is extended after the expiry process has already inactivated excess contacts, the data remains intact but those records stay inactive until reactivated.
- This change has not been run against a live Supabase project or Meta account.
