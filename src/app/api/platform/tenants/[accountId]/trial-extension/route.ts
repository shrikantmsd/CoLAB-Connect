import { NextResponse } from 'next/server';

import { getCurrentAccount, toErrorResponse } from '@/lib/auth/account';
import { supabaseAdmin } from '@/lib/flows/admin-client';

export async function POST(
  request: Request,
  { params }: { params: Promise<{ accountId: string }> },
) {
  try {
    const ctx = await getCurrentAccount();
    const { data: allowed, error: accessError } = await ctx.supabase.rpc('is_platform_admin');
    if (accessError || allowed !== true) {
      return NextResponse.json({ error: 'Platform administrator access required' }, { status: 403 });
    }

    const { accountId } = await params;
    const body = (await request.json().catch(() => null)) as { days?: unknown } | null;
    const days = Number(body?.days ?? 7);
    if (!Number.isInteger(days) || days < 1 || days > 30) {
      return NextResponse.json({ error: 'Trial extension must be between 1 and 30 days' }, { status: 400 });
    }

    const admin = supabaseAdmin();
    const { data: subscription, error: readError } = await admin
      .from('subscriptions')
      .select('id, status, trial_started_at, trial_ends_at')
      .eq('account_id', accountId)
      .maybeSingle();
    if (readError || !subscription || !['trialing', 'expired'].includes(subscription.status)) {
      return NextResponse.json({ error: 'An eligible trial subscription was not found' }, { status: 404 });
    }

    const now = new Date();
    const priorEnd = subscription.trial_ends_at ? new Date(subscription.trial_ends_at) : now;
    const anchor = priorEnd > now ? priorEnd : now;
    const nextEnd = new Date(anchor.getTime() + days * 86_400_000).toISOString();

    const { error: updateError } = await admin
      .from('subscriptions')
      .update({
        status: 'trialing',
        trial_started_at: subscription.trial_started_at ?? now.toISOString(),
        trial_ends_at: nextEnd,
        updated_at: now.toISOString(),
      })
      .eq('id', subscription.id);
    if (updateError) {
      console.error('[platform/trial-extension] update failed:', updateError.message);
      return NextResponse.json({ error: 'Unable to extend trial' }, { status: 500 });
    }

    await admin.from('platform_audit_logs').insert({
      actor_user_id: ctx.userId,
      account_id: accountId,
      event_type: 'subscription.trial_extended',
      entity_type: 'subscription',
      entity_id: subscription.id,
      details: { days_added: days, trial_ends_at: nextEnd },
    });

    return NextResponse.json({ success: true, trial_ends_at: nextEnd });
  } catch (error) {
    return toErrorResponse(error);
  }
}
