import { NextResponse } from 'next/server';

import { getCurrentAccount, toErrorResponse } from '@/lib/auth/account';
import { getAccountEntitlements } from '@/lib/saas/entitlements';

function istDateKey(now = new Date()): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Kolkata',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(now);
}

export async function GET() {
  try {
    const ctx = await getCurrentAccount();
    const entitlements = await getAccountEntitlements(ctx.supabase, ctx.accountId);
    const today = istDateKey();

    const [contactsResult, usageResult] = await Promise.all([
      ctx.supabase
        .from('contacts')
        .select('id', { count: 'exact', head: true })
        .eq('account_id', ctx.accountId)
        .eq('is_active', true),
      ctx.supabase
        .from('daily_usage')
        .select('used_count, reserved_count')
        .eq('account_id', ctx.accountId)
        .eq('metric_key', 'whatsapp_messages_daily')
        .eq('usage_date', today)
        .maybeSingle(),
    ]);

    if (contactsResult.error || usageResult.error) {
      console.error('[billing/entitlements] usage read failed:', {
        contacts: contactsResult.error?.message,
        usage: usageResult.error?.message,
      });
      return NextResponse.json({ error: 'Unable to load current usage' }, { status: 500 });
    }

    const messageLimit = entitlements.limits.whatsapp_messages_daily?.limit ?? null;
    const messageUsed = Number(usageResult.data?.used_count ?? 0);
    const messageReserved = Number(usageResult.data?.reserved_count ?? 0);

    return NextResponse.json({
      entitlements,
      usage: {
        contacts: {
          active: contactsResult.count ?? 0,
          limit: entitlements.limits.contacts?.limit ?? null,
        },
        whatsapp_messages_daily: {
          used: messageUsed,
          reserved: messageReserved,
          limit: messageLimit,
          remaining: messageLimit === null ? null : Math.max(0, messageLimit - messageUsed - messageReserved),
          usage_date: today,
          timezone: 'Asia/Kolkata',
        },
      },
    }, { headers: { 'Cache-Control': 'no-store' } });
  } catch (error) {
    return toErrorResponse(error);
  }
}
