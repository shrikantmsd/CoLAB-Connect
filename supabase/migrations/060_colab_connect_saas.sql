-- ============================================================
-- 060_colab_connect_saas.sql
-- CoLAB Connect SaaS foundation
--
-- Adds trial + Free-tier entitlements, usage metering, billing records,
-- platform administration hooks and contact activation limits.
--
-- Important rollout behavior:
--   * Existing accounts are grandfathered onto the hidden `legacy`
--     plan so this migration does not unexpectedly restrict an existing
--     WACRM installation.
--   * Accounts created after this migration automatically receive a
--     30-calendar-day trial.
--   * Once a trial expires, access resolves to the permanent Free plan.
--     Existing contacts are never deleted; contacts beyond the five
--     active-contact allowance are marked inactive.
--   * All Free-plan features remain enabled. Only the agreed limits are
--     applied: 5 active contacts and 5 outbound WhatsApp messages/day.
--   * Daily message usage is calculated in Asia/Kolkata (IST).
-- ============================================================

-- ------------------------------------------------------------
-- Plans and feature entitlements
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.subscription_plans (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  plan_type TEXT NOT NULL CHECK (plan_type IN ('trial', 'free', 'legacy', 'paid')),
  currency CHAR(3) NOT NULL DEFAULT 'INR',
  price_minor BIGINT NOT NULL DEFAULT 0 CHECK (price_minor >= 0),
  billing_interval TEXT CHECK (billing_interval IN ('monthly', 'yearly', 'none')),
  is_public BOOLEAN NOT NULL DEFAULT FALSE,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.plan_features (
  plan_id UUID NOT NULL REFERENCES public.subscription_plans(id) ON DELETE CASCADE,
  feature_key TEXT NOT NULL,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  limit_value BIGINT,
  unit TEXT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (plan_id, feature_key),
  CHECK (limit_value IS NULL OR limit_value >= 0)
);

INSERT INTO public.subscription_plans
  (code, name, plan_type, currency, price_minor, billing_interval, is_public, is_active)
VALUES
  ('trial_30d', '30-Day Full Access Trial', 'trial', 'INR', 0, 'none', FALSE, TRUE),
  ('free', 'Free', 'free', 'INR', 0, 'none', TRUE, TRUE),
  ('legacy', 'Legacy / Existing Installation', 'legacy', 'INR', 0, 'none', FALSE, TRUE)
ON CONFLICT (code) DO UPDATE SET
  name = EXCLUDED.name,
  plan_type = EXCLUDED.plan_type,
  is_active = TRUE,
  updated_at = NOW();

-- All current modules remain available on Trial and Free. The only
-- Free-tier restrictions in this release are the two agreed quotas.
WITH plan_rows AS (
  SELECT id, code FROM public.subscription_plans
  WHERE code IN ('trial_30d', 'free', 'legacy')
), feature_rows(feature_key, unit) AS (
  VALUES
    ('inbox', 'feature'),
    ('contacts', 'contacts'),
    ('pipelines', 'feature'),
    ('broadcasts', 'feature'),
    ('automations', 'feature'),
    ('flows', 'feature'),
    ('ai_assistant', 'feature'),
    ('analytics', 'feature'),
    ('team_members', 'feature'),
    ('whatsapp_numbers', 'feature'),
    ('api_access', 'feature'),
    ('whatsapp_messages_daily', 'messages/day')
)
INSERT INTO public.plan_features (plan_id, feature_key, enabled, limit_value, unit)
SELECT p.id,
       f.feature_key,
       TRUE,
       CASE
         WHEN p.code = 'free' AND f.feature_key IN ('contacts', 'whatsapp_messages_daily') THEN 5
         ELSE NULL
       END,
       f.unit
FROM plan_rows p
CROSS JOIN feature_rows f
ON CONFLICT (plan_id, feature_key) DO UPDATE SET
  enabled = EXCLUDED.enabled,
  limit_value = EXCLUDED.limit_value,
  unit = EXCLUDED.unit,
  updated_at = NOW();

-- ------------------------------------------------------------
-- Subscription lifecycle
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.subscriptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID NOT NULL UNIQUE REFERENCES public.accounts(id) ON DELETE CASCADE,
  plan_id UUID NOT NULL REFERENCES public.subscription_plans(id),
  status TEXT NOT NULL CHECK (status IN ('pending', 'trialing', 'active', 'past_due', 'suspended', 'cancelled', 'expired')),
  trial_started_at TIMESTAMPTZ,
  trial_ends_at TIMESTAMPTZ,
  converted_at TIMESTAMPTZ,
  current_period_start TIMESTAMPTZ,
  current_period_end TIMESTAMPTZ,
  cancel_at_period_end BOOLEAN NOT NULL DEFAULT FALSE,
  provider TEXT,
  provider_customer_id TEXT,
  provider_subscription_id TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (trial_ends_at IS NULL OR trial_started_at IS NULL OR trial_ends_at > trial_started_at)
);

CREATE INDEX IF NOT EXISTS idx_subscriptions_status_period
  ON public.subscriptions(status, current_period_end);
CREATE INDEX IF NOT EXISTS idx_subscriptions_trial_end
  ON public.subscriptions(trial_ends_at) WHERE status = 'trialing';

-- Existing installations are explicitly grandfathered. New accounts
-- created after this migration are provisioned by the account trigger.
INSERT INTO public.subscriptions (account_id, plan_id, status)
SELECT a.id, p.id, 'active'
FROM public.accounts a
CROSS JOIN public.subscription_plans p
WHERE p.code = 'legacy'
  AND NOT EXISTS (SELECT 1 FROM public.subscriptions s WHERE s.account_id = a.id)
ON CONFLICT (account_id) DO NOTHING;

-- ------------------------------------------------------------
-- Billing, payment and webhook idempotency records
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.billing_customers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  provider TEXT NOT NULL,
  provider_customer_id TEXT NOT NULL,
  billing_name TEXT,
  billing_email TEXT,
  billing_phone TEXT,
  billing_address JSONB NOT NULL DEFAULT '{}'::jsonb,
  gstin TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (provider, provider_customer_id),
  UNIQUE (account_id, provider)
);

CREATE TABLE IF NOT EXISTS public.billing_invoices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  subscription_id UUID REFERENCES public.subscriptions(id) ON DELETE SET NULL,
  provider TEXT,
  provider_invoice_id TEXT,
  invoice_number TEXT,
  currency CHAR(3) NOT NULL DEFAULT 'INR',
  subtotal_minor BIGINT NOT NULL DEFAULT 0,
  tax_minor BIGINT NOT NULL DEFAULT 0,
  total_minor BIGINT NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'issued', 'paid', 'overdue', 'void', 'refunded')),
  invoice_url TEXT,
  due_at TIMESTAMPTZ,
  paid_at TIMESTAMPTZ,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (provider, provider_invoice_id)
);

CREATE TABLE IF NOT EXISTS public.payment_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  subscription_id UUID REFERENCES public.subscriptions(id) ON DELETE SET NULL,
  provider TEXT NOT NULL,
  provider_payment_id TEXT,
  provider_order_id TEXT,
  currency CHAR(3) NOT NULL DEFAULT 'INR',
  amount_minor BIGINT NOT NULL CHECK (amount_minor >= 0),
  status TEXT NOT NULL CHECK (status IN ('created', 'authorized', 'captured', 'failed', 'refunded')),
  failure_reason TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (provider, provider_payment_id)
);

CREATE TABLE IF NOT EXISTS public.payment_webhook_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider TEXT NOT NULL,
  provider_event_id TEXT NOT NULL,
  event_type TEXT NOT NULL,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  processing_status TEXT NOT NULL DEFAULT 'received' CHECK (processing_status IN ('received', 'processing', 'processed', 'failed')),
  processing_error TEXT,
  received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  processed_at TIMESTAMPTZ,
  UNIQUE (provider, provider_event_id)
);

-- ------------------------------------------------------------
-- Usage metering and tenant audit
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.daily_usage (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  metric_key TEXT NOT NULL,
  usage_date DATE NOT NULL,
  used_count BIGINT NOT NULL DEFAULT 0 CHECK (used_count >= 0),
  reserved_count BIGINT NOT NULL DEFAULT 0 CHECK (reserved_count >= 0),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (account_id, metric_key, usage_date)
);

CREATE TABLE IF NOT EXISTS public.usage_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id UUID NOT NULL UNIQUE,
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  metric_key TEXT NOT NULL,
  usage_date DATE NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('reserved', 'accepted', 'failed')),
  quota_reserved BOOLEAN NOT NULL DEFAULT FALSE,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  finalized_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_daily_usage_account_date
  ON public.daily_usage(account_id, usage_date DESC);
CREATE INDEX IF NOT EXISTS idx_usage_events_account_created
  ON public.usage_events(account_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.tenant_audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  actor_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  event_type TEXT NOT NULL,
  entity_type TEXT,
  entity_id TEXT,
  details JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_tenant_audit_account_created
  ON public.tenant_audit_logs(account_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.platform_admins (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  role TEXT NOT NULL DEFAULT 'super_admin' CHECK (role IN ('super_admin', 'support_admin', 'billing_admin')),
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS public.platform_audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  event_type TEXT NOT NULL,
  account_id UUID REFERENCES public.accounts(id) ON DELETE SET NULL,
  entity_type TEXT,
  entity_id TEXT,
  details JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.onboarding_progress (
  account_id UUID PRIMARY KEY REFERENCES public.accounts(id) ON DELETE CASCADE,
  business_profile_completed_at TIMESTAMPTZ,
  whatsapp_connected_at TIMESTAMPTZ,
  first_contact_created_at TIMESTAMPTZ,
  first_message_sent_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Contact activation preserves trial data after downgrade. Inbound
-- webhook contacts over quota are retained but marked inactive, allowing
-- the inbound conversation itself to be processed without losing data.
ALTER TABLE public.contacts
  ADD COLUMN IF NOT EXISTS is_active BOOLEAN NOT NULL DEFAULT TRUE;
CREATE INDEX IF NOT EXISTS idx_contacts_account_active_created
  ON public.contacts(account_id, is_active, created_at);

-- ------------------------------------------------------------
-- Platform administrator check
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_platform_admin()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.platform_admins pa
    WHERE pa.user_id = auth.uid() AND pa.is_active = TRUE
  );
$$;
ALTER FUNCTION public.is_platform_admin() OWNER TO postgres;
GRANT EXECUTE ON FUNCTION public.is_platform_admin() TO authenticated, service_role;

-- ------------------------------------------------------------
-- Expiry transition: no cron is required for entitlements to expire.
-- The first entitlement/usage/contact action after the deadline applies
-- the downgrade and marks contacts beyond the 5-contact Free allowance
-- inactive (never deletes them).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_account_trial_expiry(p_account_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_expired BOOLEAN := FALSE;
BEGIN
  IF auth.role() <> 'service_role'
     AND NOT public.is_account_member(p_account_id, 'viewer'::public.account_role_enum) THEN
    RAISE EXCEPTION 'Not authorized for this account' USING ERRCODE = '42501';
  END IF;

  SELECT TRUE INTO v_expired
  FROM public.subscriptions s
  WHERE s.account_id = p_account_id
    AND s.status = 'trialing'
    AND s.trial_ends_at IS NOT NULL
    AND s.trial_ends_at <= NOW()
  FOR UPDATE;

  IF COALESCE(v_expired, FALSE) THEN
    UPDATE public.subscriptions
    SET status = 'expired', updated_at = NOW()
    WHERE account_id = p_account_id AND status = 'trialing';

    WITH ranked AS (
      SELECT id, ROW_NUMBER() OVER (ORDER BY created_at ASC, id ASC) AS rn
      FROM public.contacts
      WHERE account_id = p_account_id AND is_active = TRUE
    )
    UPDATE public.contacts c
    SET is_active = FALSE
    FROM ranked r
    WHERE c.id = r.id AND r.rn > 5;

    INSERT INTO public.tenant_audit_logs (account_id, event_type, details)
    VALUES (
      p_account_id,
      'subscription.trial_expired',
      jsonb_build_object('effective_plan', 'free', 'active_contact_limit', 5, 'daily_message_limit', 5)
    );
  END IF;
END;
$$;
ALTER FUNCTION public.sync_account_trial_expiry(UUID) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.sync_account_trial_expiry(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sync_account_trial_expiry(UUID) TO authenticated, service_role;

-- Returns the account's currently effective entitlement bundle. The
-- caller cannot inspect another tenant unless it is a service role.
CREATE OR REPLACE FUNCTION public.get_account_entitlements(p_account_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_plan_id UUID;
  v_plan_code TEXT;
  v_plan_name TEXT;
  v_status TEXT;
  v_trial_started_at TIMESTAMPTZ;
  v_trial_ends_at TIMESTAMPTZ;
  v_features JSONB;
  v_limits JSONB;
BEGIN
  IF auth.role() <> 'service_role'
     AND NOT public.is_account_member(p_account_id, 'viewer'::public.account_role_enum) THEN
    RAISE EXCEPTION 'Not authorized for this account' USING ERRCODE = '42501';
  END IF;

  PERFORM public.sync_account_trial_expiry(p_account_id);

  SELECT s.plan_id, s.status, s.trial_started_at, s.trial_ends_at
  INTO v_plan_id, v_status, v_trial_started_at, v_trial_ends_at
  FROM public.subscriptions s
  WHERE s.account_id = p_account_id
    AND (
      (s.status = 'trialing' AND s.trial_ends_at > NOW())
      OR (s.status = 'active' AND (s.current_period_start IS NULL OR s.current_period_start <= NOW())
          AND (s.current_period_end IS NULL OR s.current_period_end > NOW()))
    )
  LIMIT 1;

  IF v_plan_id IS NULL THEN
    SELECT id INTO v_plan_id FROM public.subscription_plans WHERE code = 'free';
    v_status := 'free';
    v_trial_started_at := NULL;
    v_trial_ends_at := NULL;
  END IF;

  SELECT code, name INTO v_plan_code, v_plan_name
  FROM public.subscription_plans WHERE id = v_plan_id;

  SELECT COALESCE(jsonb_object_agg(feature_key, enabled), '{}'::jsonb)
  INTO v_features
  FROM public.plan_features WHERE plan_id = v_plan_id;

  SELECT COALESCE(jsonb_object_agg(feature_key, jsonb_build_object('limit', limit_value, 'unit', unit)), '{}'::jsonb)
  INTO v_limits
  FROM public.plan_features
  WHERE plan_id = v_plan_id AND limit_value IS NOT NULL;

  RETURN jsonb_build_object(
    'account_id', p_account_id,
    'plan_code', v_plan_code,
    'plan_name', v_plan_name,
    'subscription_status', v_status,
    'trial_started_at', v_trial_started_at,
    'trial_ends_at', v_trial_ends_at,
    'features', v_features,
    'limits', v_limits,
    'timezone', 'Asia/Kolkata'
  );
END;
$$;
ALTER FUNCTION public.get_account_entitlements(UUID) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_account_entitlements(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_account_entitlements(UUID) TO authenticated, service_role;

-- Atomically reserve one outbound WhatsApp message. A Free-tier send
-- consumes capacity only after Meta accepts it; definitive failures
-- release the reservation. The caller supplies a fresh UUID per attempt.
CREATE OR REPLACE FUNCTION public.reserve_outbound_whatsapp_message(
  p_account_id UUID,
  p_reservation_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_plan_id UUID;
  v_plan_code TEXT;
  v_limit BIGINT;
  v_used BIGINT := 0;
  v_reserved BIGINT := 0;
  v_usage_date DATE := (NOW() AT TIME ZONE 'Asia/Kolkata')::DATE;
  v_existing public.usage_events%ROWTYPE;
  v_quota_reserved BOOLEAN := FALSE;
BEGIN
  IF auth.role() <> 'service_role'
     AND NOT public.is_account_member(p_account_id, 'agent'::public.account_role_enum) THEN
    RAISE EXCEPTION 'Not authorized to send messages for this account' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_existing
  FROM public.usage_events
  WHERE reservation_id = p_reservation_id;
  IF FOUND THEN
    IF v_existing.account_id <> p_account_id THEN
      RAISE EXCEPTION 'Reservation does not belong to this account' USING ERRCODE = '42501';
    END IF;
    RETURN jsonb_build_object(
      'allowed', v_existing.status <> 'failed',
      'plan_code', NULL,
      'limit', NULL,
      'remaining', NULL,
      'duplicate', TRUE,
      'usage_date', v_existing.usage_date
    );
  END IF;

  PERFORM public.sync_account_trial_expiry(p_account_id);

  SELECT s.plan_id INTO v_plan_id
  FROM public.subscriptions s
  WHERE s.account_id = p_account_id
    AND (
      (s.status = 'trialing' AND s.trial_ends_at > NOW())
      OR (s.status = 'active' AND (s.current_period_start IS NULL OR s.current_period_start <= NOW())
          AND (s.current_period_end IS NULL OR s.current_period_end > NOW()))
    )
  LIMIT 1;

  IF v_plan_id IS NULL THEN
    SELECT id INTO v_plan_id FROM public.subscription_plans WHERE code = 'free';
  END IF;

  SELECT code INTO v_plan_code FROM public.subscription_plans WHERE id = v_plan_id;
  SELECT limit_value INTO v_limit
  FROM public.plan_features
  WHERE plan_id = v_plan_id AND feature_key = 'whatsapp_messages_daily' AND enabled = TRUE;

  IF v_limit IS NOT NULL THEN
    INSERT INTO public.daily_usage (account_id, metric_key, usage_date)
    VALUES (p_account_id, 'whatsapp_messages_daily', v_usage_date)
    ON CONFLICT (account_id, metric_key, usage_date) DO NOTHING;

    UPDATE public.daily_usage
    SET reserved_count = reserved_count + 1, updated_at = NOW()
    WHERE account_id = p_account_id
      AND metric_key = 'whatsapp_messages_daily'
      AND usage_date = v_usage_date
      AND used_count + reserved_count < v_limit
    RETURNING used_count, reserved_count INTO v_used, v_reserved;

    IF NOT FOUND THEN
      SELECT used_count, reserved_count INTO v_used, v_reserved
      FROM public.daily_usage
      WHERE account_id = p_account_id
        AND metric_key = 'whatsapp_messages_daily'
        AND usage_date = v_usage_date;

      RETURN jsonb_build_object(
        'allowed', FALSE,
        'plan_code', v_plan_code,
        'limit', v_limit,
        'used', COALESCE(v_used, 0),
        'reserved', COALESCE(v_reserved, 0),
        'remaining', 0,
        'resets_at', ((v_usage_date + 1)::timestamp AT TIME ZONE 'Asia/Kolkata'),
        'usage_date', v_usage_date
      );
    END IF;
    v_quota_reserved := TRUE;
  END IF;

  INSERT INTO public.usage_events (
    reservation_id, account_id, metric_key, usage_date, status, quota_reserved
  ) VALUES (
    p_reservation_id, p_account_id, 'whatsapp_messages_daily', v_usage_date, 'reserved', v_quota_reserved
  );

  RETURN jsonb_build_object(
    'allowed', TRUE,
    'plan_code', v_plan_code,
    'limit', v_limit,
    'used', COALESCE(v_used, 0),
    'reserved', COALESCE(v_reserved, 0),
    'remaining', CASE WHEN v_limit IS NULL THEN NULL ELSE GREATEST(v_limit - COALESCE(v_used, 0) - COALESCE(v_reserved, 0), 0) END,
    'resets_at', CASE WHEN v_limit IS NULL THEN NULL ELSE ((v_usage_date + 1)::timestamp AT TIME ZONE 'Asia/Kolkata') END,
    'usage_date', v_usage_date
  );
END;
$$;
ALTER FUNCTION public.reserve_outbound_whatsapp_message(UUID, UUID) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.reserve_outbound_whatsapp_message(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reserve_outbound_whatsapp_message(UUID, UUID) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.finalize_outbound_whatsapp_message(
  p_reservation_id UUID,
  p_result TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_event public.usage_events%ROWTYPE;
BEGIN
  IF p_result NOT IN ('accepted', 'failed') THEN
    RAISE EXCEPTION 'Invalid reservation result' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_event
  FROM public.usage_events
  WHERE reservation_id = p_reservation_id
  FOR UPDATE;

  IF NOT FOUND OR v_event.status <> 'reserved' THEN
    RETURN FALSE;
  END IF;

  IF auth.role() <> 'service_role'
     AND NOT public.is_account_member(v_event.account_id, 'agent'::public.account_role_enum) THEN
    RAISE EXCEPTION 'Not authorized to finalize this message reservation' USING ERRCODE = '42501';
  END IF;

  IF v_event.quota_reserved THEN
    UPDATE public.daily_usage
    SET reserved_count = GREATEST(reserved_count - 1, 0),
        used_count = used_count + CASE WHEN p_result = 'accepted' THEN 1 ELSE 0 END,
        updated_at = NOW()
    WHERE account_id = v_event.account_id
      AND metric_key = v_event.metric_key
      AND usage_date = v_event.usage_date;
  END IF;

  UPDATE public.usage_events
  SET status = p_result, finalized_at = NOW()
  WHERE reservation_id = p_reservation_id;

  RETURN TRUE;
END;
$$;
ALTER FUNCTION public.finalize_outbound_whatsapp_message(UUID, TEXT) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.finalize_outbound_whatsapp_message(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.finalize_outbound_whatsapp_message(UUID, TEXT) TO authenticated, service_role;

-- Atomic contact-cap assertion used by service-role API-key writes.
-- Authenticated app writes are additionally protected by the trigger below.
CREATE OR REPLACE FUNCTION public.assert_contact_capacity(p_account_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_plan_id UUID;
  v_limit BIGINT;
  v_count BIGINT;
BEGIN
  IF auth.role() <> 'service_role'
     AND NOT public.is_account_member(p_account_id, 'agent'::public.account_role_enum) THEN
    RAISE EXCEPTION 'Not authorized to create contacts for this account' USING ERRCODE = '42501';
  END IF;

  PERFORM public.sync_account_trial_expiry(p_account_id);
  PERFORM pg_advisory_xact_lock(hashtextextended(p_account_id::TEXT, 0));

  SELECT s.plan_id INTO v_plan_id
  FROM public.subscriptions s
  WHERE s.account_id = p_account_id
    AND (
      (s.status = 'trialing' AND s.trial_ends_at > NOW())
      OR (s.status = 'active' AND (s.current_period_start IS NULL OR s.current_period_start <= NOW())
          AND (s.current_period_end IS NULL OR s.current_period_end > NOW()))
    )
  LIMIT 1;
  IF v_plan_id IS NULL THEN
    SELECT id INTO v_plan_id FROM public.subscription_plans WHERE code = 'free';
  END IF;

  SELECT limit_value INTO v_limit
  FROM public.plan_features
  WHERE plan_id = v_plan_id AND feature_key = 'contacts' AND enabled = TRUE;

  IF v_limit IS NULL THEN RETURN; END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.contacts
  WHERE account_id = p_account_id AND is_active = TRUE;

  IF v_count >= v_limit THEN
    RAISE EXCEPTION 'FREE_TIER_CONTACT_LIMIT_REACHED: this plan allows % active contacts. Upgrade or deactivate an existing contact.', v_limit
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;
ALTER FUNCTION public.assert_contact_capacity(UUID) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.assert_contact_capacity(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.assert_contact_capacity(UUID) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.enforce_contact_activation_limit()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_plan_id UUID;
  v_limit BIGINT;
  v_count BIGINT;
  v_exclude_id UUID;
BEGIN
  -- Existing active rows are unaffected by unrelated writes. The trigger
  -- also runs on UPDATE OF is_active so a direct Supabase update cannot
  -- bypass the cap and reactivate a sixth contact.
  IF TG_OP = 'UPDATE' THEN
    IF NEW.is_active IS NOT DISTINCT FROM OLD.is_active THEN
      RETURN NEW;
    END IF;
    v_exclude_id := NEW.id;
  END IF;

  -- Authenticated clients cannot create inactive records to evade the
  -- allowance. Inbound service-role webhooks may retain over-limit
  -- contacts as inactive so no incoming conversation is discarded.
  IF TG_OP = 'INSERT' AND NEW.is_active IS DISTINCT FROM TRUE AND auth.role() <> 'service_role' THEN
    NEW.is_active := TRUE;
  END IF;

  IF NEW.is_active IS DISTINCT FROM TRUE THEN
    RETURN NEW;
  END IF;

  PERFORM public.sync_account_trial_expiry(NEW.account_id);
  PERFORM pg_advisory_xact_lock(hashtextextended(NEW.account_id::TEXT, 0));

  SELECT s.plan_id INTO v_plan_id
  FROM public.subscriptions s
  WHERE s.account_id = NEW.account_id
    AND (
      (s.status = 'trialing' AND s.trial_ends_at > NOW())
      OR (s.status = 'active' AND (s.current_period_start IS NULL OR s.current_period_start <= NOW())
          AND (s.current_period_end IS NULL OR s.current_period_end > NOW()))
    )
  LIMIT 1;
  IF v_plan_id IS NULL THEN
    SELECT id INTO v_plan_id FROM public.subscription_plans WHERE code = 'free';
  END IF;

  SELECT limit_value INTO v_limit
  FROM public.plan_features
  WHERE plan_id = v_plan_id AND feature_key = 'contacts' AND enabled = TRUE;
  IF v_limit IS NULL THEN RETURN NEW; END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.contacts
  WHERE account_id = NEW.account_id
    AND is_active = TRUE
    AND (v_exclude_id IS NULL OR id <> v_exclude_id);

  IF v_count >= v_limit THEN
    IF auth.role() = 'service_role' THEN
      -- An inbound webhook must not drop a real incoming customer message.
      -- Retain the contact/conversation but keep it outside the active cap.
      NEW.is_active := FALSE;
    ELSE
      RAISE EXCEPTION 'FREE_TIER_CONTACT_LIMIT_REACHED: this plan allows % active contacts. Upgrade or deactivate an existing contact.', v_limit
        USING ERRCODE = 'P0001';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;
ALTER FUNCTION public.enforce_contact_activation_limit() OWNER TO postgres;
DROP TRIGGER IF EXISTS contacts_enforce_activation_limit ON public.contacts;
CREATE TRIGGER contacts_enforce_activation_limit
  BEFORE INSERT OR UPDATE OF is_active ON public.contacts
  FOR EACH ROW EXECUTE FUNCTION public.enforce_contact_activation_limit();

-- ------------------------------------------------------------
-- Automatic 30-day trial for newly-created customer accounts
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.provision_account_trial()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_trial_plan_id UUID;
  v_started_at TIMESTAMPTZ := NOW();
BEGIN
  SELECT id INTO v_trial_plan_id FROM public.subscription_plans WHERE code = 'trial_30d';
  IF v_trial_plan_id IS NULL THEN
    RAISE EXCEPTION '30-day trial plan is not configured';
  END IF;

  INSERT INTO public.subscriptions (
    account_id, plan_id, status, trial_started_at, trial_ends_at
  ) VALUES (
    NEW.id, v_trial_plan_id, 'trialing', v_started_at, v_started_at + INTERVAL '30 days'
  )
  ON CONFLICT (account_id) DO NOTHING;

  INSERT INTO public.onboarding_progress (account_id)
  VALUES (NEW.id)
  ON CONFLICT (account_id) DO NOTHING;

  INSERT INTO public.tenant_audit_logs (account_id, event_type, details)
  VALUES (
    NEW.id,
    'subscription.trial_started',
    jsonb_build_object('duration_days', 30, 'trial_ends_at', v_started_at + INTERVAL '30 days')
  );

  RETURN NEW;
END;
$$;
ALTER FUNCTION public.provision_account_trial() OWNER TO postgres;
DROP TRIGGER IF EXISTS accounts_provision_trial ON public.accounts;
CREATE TRIGGER accounts_provision_trial
  AFTER INSERT ON public.accounts
  FOR EACH ROW EXECUTE FUNCTION public.provision_account_trial();

-- ------------------------------------------------------------
-- RLS and indexes
-- ------------------------------------------------------------
ALTER TABLE public.subscription_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.plan_features ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.billing_customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.billing_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_webhook_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.daily_usage ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.usage_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tenant_audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.platform_admins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.platform_audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.onboarding_progress ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS subscription_plans_public_read ON public.subscription_plans;
CREATE POLICY subscription_plans_public_read ON public.subscription_plans
  FOR SELECT TO anon, authenticated USING (is_active = TRUE AND is_public = TRUE);
DROP POLICY IF EXISTS plan_features_public_read ON public.plan_features;
CREATE POLICY plan_features_public_read ON public.plan_features
  FOR SELECT TO anon, authenticated USING (
    EXISTS (SELECT 1 FROM public.subscription_plans p WHERE p.id = plan_id AND p.is_active = TRUE AND p.is_public = TRUE)
  );
DROP POLICY IF EXISTS subscriptions_member_read ON public.subscriptions;
CREATE POLICY subscriptions_member_read ON public.subscriptions
  FOR SELECT TO authenticated USING (public.is_account_member(account_id, 'viewer'::public.account_role_enum));
DROP POLICY IF EXISTS billing_customers_admin_read ON public.billing_customers;
CREATE POLICY billing_customers_admin_read ON public.billing_customers
  FOR SELECT TO authenticated USING (public.is_account_member(account_id, 'admin'::public.account_role_enum));
DROP POLICY IF EXISTS billing_invoices_admin_read ON public.billing_invoices;
CREATE POLICY billing_invoices_admin_read ON public.billing_invoices
  FOR SELECT TO authenticated USING (public.is_account_member(account_id, 'admin'::public.account_role_enum));
DROP POLICY IF EXISTS payment_transactions_admin_read ON public.payment_transactions;
CREATE POLICY payment_transactions_admin_read ON public.payment_transactions
  FOR SELECT TO authenticated USING (public.is_account_member(account_id, 'admin'::public.account_role_enum));
DROP POLICY IF EXISTS daily_usage_member_read ON public.daily_usage;
CREATE POLICY daily_usage_member_read ON public.daily_usage
  FOR SELECT TO authenticated USING (public.is_account_member(account_id, 'viewer'::public.account_role_enum));
DROP POLICY IF EXISTS usage_events_admin_read ON public.usage_events;
CREATE POLICY usage_events_admin_read ON public.usage_events
  FOR SELECT TO authenticated USING (public.is_account_member(account_id, 'admin'::public.account_role_enum));
DROP POLICY IF EXISTS tenant_audit_admin_read ON public.tenant_audit_logs;
CREATE POLICY tenant_audit_admin_read ON public.tenant_audit_logs
  FOR SELECT TO authenticated USING (public.is_account_member(account_id, 'admin'::public.account_role_enum));
DROP POLICY IF EXISTS platform_admins_self_read ON public.platform_admins;
CREATE POLICY platform_admins_self_read ON public.platform_admins
  FOR SELECT TO authenticated USING (user_id = auth.uid());
DROP POLICY IF EXISTS platform_audit_admin_read ON public.platform_audit_logs;
CREATE POLICY platform_audit_admin_read ON public.platform_audit_logs
  FOR SELECT TO authenticated USING (public.is_platform_admin());
DROP POLICY IF EXISTS onboarding_member_read ON public.onboarding_progress;
CREATE POLICY onboarding_member_read ON public.onboarding_progress
  FOR SELECT TO authenticated USING (public.is_account_member(account_id, 'viewer'::public.account_role_enum));
DROP POLICY IF EXISTS onboarding_admin_update ON public.onboarding_progress;
CREATE POLICY onboarding_admin_update ON public.onboarding_progress
  FOR UPDATE TO authenticated USING (public.is_account_member(account_id, 'admin'::public.account_role_enum))
  WITH CHECK (public.is_account_member(account_id, 'admin'::public.account_role_enum));

-- No direct client writes to commercial records, usage or webhook data.
-- These are changed by vetted SECURITY DEFINER RPCs / service-role routes.
REVOKE INSERT, UPDATE, DELETE ON public.subscriptions, public.subscription_plans,
  public.plan_features, public.billing_customers, public.billing_invoices,
  public.payment_transactions, public.payment_webhook_events, public.daily_usage,
  public.usage_events, public.platform_admins, public.platform_audit_logs
FROM anon, authenticated;

-- Only a platform administrator may use the Boolean check to unlock
-- privileged server routes. Bootstrap the first admin explicitly with
-- an INSERT into platform_admins after the migration is reviewed.
COMMENT ON TABLE public.platform_admins IS
  'Global CoLAB Connect platform administrators. Bootstrap first user manually; never expose public self-registration.';
COMMENT ON FUNCTION public.get_account_entitlements(UUID) IS
  'Returns effective account entitlements; transitions an expired trial to Free on first access.';
COMMENT ON FUNCTION public.reserve_outbound_whatsapp_message(UUID, UUID) IS
  'Atomic outbound WhatsApp message quota reservation; IST day boundary.';
