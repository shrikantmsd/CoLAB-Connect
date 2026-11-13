import type { SupabaseClient } from '@supabase/supabase-js';

export interface AccountEntitlements {
  account_id: string;
  plan_code: string;
  plan_name: string;
  subscription_status: string;
  trial_started_at: string | null;
  trial_ends_at: string | null;
  features: Record<string, boolean>;
  limits: Record<string, { limit: number; unit: string | null }>;
  timezone: 'Asia/Kolkata' | string;
}

export interface OutboundQuotaReservation {
  allowed: boolean;
  plan_code: string | null;
  limit: number | null;
  used: number | null;
  reserved: number | null;
  remaining: number | null;
  resets_at: string | null;
  duplicate?: boolean;
}

export class PlanLimitError extends Error {
  readonly code: 'daily_message_limit' | 'contact_limit';
  readonly status = 429;
  readonly limit: number | null;
  readonly remaining: number | null;
  readonly resetsAt: string | null;

  constructor(args: {
    code: 'daily_message_limit' | 'contact_limit';
    message: string;
    limit?: number | null;
    remaining?: number | null;
    resetsAt?: string | null;
  }) {
    super(args.message);
    this.name = 'PlanLimitError';
    this.code = args.code;
    this.limit = args.limit ?? null;
    this.remaining = args.remaining ?? null;
    this.resetsAt = args.resetsAt ?? null;
  }
}

/** Resolve the effective plan, applying a trial expiry transition first. */
export async function getAccountEntitlements(
  db: SupabaseClient,
  accountId: string,
): Promise<AccountEntitlements> {
  const { data, error } = await db.rpc('get_account_entitlements', {
    p_account_id: accountId,
  });
  if (error || !data) {
    console.error('[saas] get_account_entitlements failed:', error?.message);
    throw new Error('Unable to load subscription entitlements');
  }
  return data as unknown as AccountEntitlements;
}

/**
 * Wrap only the Meta API request, not subsequent local persistence. A
 * successful Meta acceptance consumes one Free-tier message; a definitive
 * provider failure releases the reservation. SQL performs the reservation
 * atomically so concurrent requests cannot exceed the daily allowance.
 */
export async function sendWithWhatsAppQuota<T>(
  db: SupabaseClient,
  accountId: string,
  send: () => Promise<T>,
): Promise<T> {
  const reservationId = globalThis.crypto.randomUUID();
  const { data, error } = await db.rpc('reserve_outbound_whatsapp_message', {
    p_account_id: accountId,
    p_reservation_id: reservationId,
  });

  if (error || !data) {
    console.error('[saas] WhatsApp quota reservation failed:', error?.message);
    throw new Error('Unable to verify the WhatsApp message allowance. Please retry.');
  }

  const reservation = data as unknown as OutboundQuotaReservation;
  if (!reservation.allowed) {
    throw new PlanLimitError({
      code: 'daily_message_limit',
      message: 'You have used all 5 WhatsApp messages available on the Free plan for today. Your allowance resets at midnight IST.',
      limit: reservation.limit,
      remaining: reservation.remaining,
      resetsAt: reservation.resets_at,
    });
  }

  try {
    const result = await send();
    const { error: finalizeError } = await db.rpc(
      'finalize_outbound_whatsapp_message',
      { p_reservation_id: reservationId, p_result: 'accepted' },
    );
    if (finalizeError) {
      // The provider has already accepted the message. Do not report a
      // successful send as failed; the reserved slot remains conservative
      // until the reservation can be reconciled.
      console.error('[saas] accepted WhatsApp quota finalization failed:', finalizeError.message);
    }
    return result;
  } catch (error) {
    const { error: finalizeError } = await db.rpc(
      'finalize_outbound_whatsapp_message',
      { p_reservation_id: reservationId, p_result: 'failed' },
    );
    if (finalizeError) {
      console.error('[saas] failed WhatsApp quota release:', finalizeError.message);
    }
    throw error;
  }
}

/** Explicit preflight for service-role API-key contact writes. */
export async function assertContactCapacity(
  db: SupabaseClient,
  accountId: string,
): Promise<void> {
  const { error } = await db.rpc('assert_contact_capacity', {
    p_account_id: accountId,
  });
  if (error) {
    if (error.message.includes('FREE_TIER_CONTACT_LIMIT_REACHED')) {
      throw new PlanLimitError({
        code: 'contact_limit',
        message: 'The Free plan allows 5 active contacts. Upgrade your plan or deactivate an existing contact before adding another.',
        limit: 5,
        remaining: 0,
      });
    }
    console.error('[saas] contact capacity check failed:', error.message);
    throw new Error('Unable to verify the contact allowance. Please retry.');
  }
}
