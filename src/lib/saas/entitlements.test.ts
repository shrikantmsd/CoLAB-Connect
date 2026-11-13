import { describe, expect, it, vi } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';

import { PlanLimitError, sendWithWhatsAppQuota } from './entitlements';

function quotaDb(reservation: Record<string, unknown>, finalizeError: { message: string } | null = null) {
  const rpc = vi.fn(async (name: string, _args?: Record<string, unknown>) => {
    if (name === 'reserve_outbound_whatsapp_message') {
      return { data: reservation, error: null };
    }
    return { data: true, error: finalizeError };
  });
  return { db: { rpc } as unknown as SupabaseClient, rpc };
}

describe('sendWithWhatsAppQuota', () => {
  it('reserves and finalizes an accepted provider send', async () => {
    const { db, rpc } = quotaDb({ allowed: true, limit: 5, remaining: 4 });
    const send = vi.fn(async () => 'wamid.accepted');

    await expect(sendWithWhatsAppQuota(db, 'account-1', send)).resolves.toBe('wamid.accepted');
    expect(send).toHaveBeenCalledOnce();
    expect(rpc).toHaveBeenCalledTimes(2);
    expect(rpc.mock.calls[1]?.[0]).toBe('finalize_outbound_whatsapp_message');
    expect(rpc.mock.calls[1]?.[1]).toMatchObject({ p_result: 'accepted' });
  });

  it('releases the reservation after a definitive provider failure', async () => {
    const { db, rpc } = quotaDb({ allowed: true, limit: 5, remaining: 4 });
    const send = vi.fn(async () => { throw new Error('Meta rejected the request'); });

    await expect(sendWithWhatsAppQuota(db, 'account-1', send)).rejects.toThrow('Meta rejected the request');
    expect(rpc.mock.calls[1]?.[0]).toBe('finalize_outbound_whatsapp_message');
    expect(rpc.mock.calls[1]?.[1]).toMatchObject({ p_result: 'failed' });
  });

  it('blocks when the Free daily allowance is exhausted', async () => {
    const { db, rpc } = quotaDb({ allowed: false, limit: 5, remaining: 0, resets_at: '2026-11-15T00:00:00+05:30' });
    const send = vi.fn(async () => 'should-not-send');

    await expect(sendWithWhatsAppQuota(db, 'account-1', send)).rejects.toBeInstanceOf(PlanLimitError);
    expect(send).not.toHaveBeenCalled();
    expect(rpc).toHaveBeenCalledOnce();
  });

  it('does not turn an accepted provider send into an application failure if metering finalization fails', async () => {
    const { db } = quotaDb({ allowed: true }, { message: 'temporary DB issue' });
    const send = vi.fn(async () => 'wamid.accepted');
    const error = vi.spyOn(console, 'error').mockImplementation(() => undefined);

    await expect(sendWithWhatsAppQuota(db, 'account-1', send)).resolves.toBe('wamid.accepted');
    error.mockRestore();
  });
});
