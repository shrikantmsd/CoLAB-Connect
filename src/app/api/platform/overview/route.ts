import { NextResponse } from 'next/server';

import { getCurrentAccount, toErrorResponse } from '@/lib/auth/account';
import { supabaseAdmin } from '@/lib/flows/admin-client';

function istDateKey(now = new Date()): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Kolkata', year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(now);
}

export async function GET() {
  try {
    const ctx = await getCurrentAccount();
    const { data: allowed, error: accessError } = await ctx.supabase.rpc('is_platform_admin');
    if (accessError || allowed !== true) {
      return NextResponse.json({ error: 'Platform administrator access required' }, { status: 403 });
    }

    const admin = supabaseAdmin();
    const [accountsResult, subscriptionsResult, plansResult, usageResult] = await Promise.all([
      admin.from('accounts').select('id, name, owner_user_id, created_at').order('created_at', { ascending: false }).limit(500),
      admin.from('subscriptions').select('account_id, status, trial_started_at, trial_ends_at, current_period_end, plan_id, updated_at'),
      admin.from('subscription_plans').select('id, code, name, plan_type, price_minor, currency, is_active'),
      admin.from('daily_usage').select('account_id, used_count, reserved_count').eq('metric_key', 'whatsapp_messages_daily').eq('usage_date', istDateKey()),
    ]);

    const firstError = accountsResult.error || subscriptionsResult.error || plansResult.error || usageResult.error;
    if (firstError) {
      console.error('[platform/overview] query failed:', firstError.message);
      return NextResponse.json({ error: 'Unable to load platform overview' }, { status: 500 });
    }

    const plansById = new Map((plansResult.data ?? []).map((plan) => [plan.id, plan]));
    const subscriptionsByAccount = new Map((subscriptionsResult.data ?? []).map((subscription) => [subscription.account_id, subscription]));
    const usageByAccount = new Map((usageResult.data ?? []).map((usage) => [usage.account_id, usage]));

    const tenants = (accountsResult.data ?? []).map((account) => {
      const subscription = subscriptionsByAccount.get(account.id);
      const plan = subscription ? plansById.get(subscription.plan_id) : undefined;
      const usage = usageByAccount.get(account.id);
      return {
        ...account,
        plan: plan?.code ?? 'free',
        plan_name: plan?.name ?? 'Free',
        subscription_status: subscription?.status ?? 'free',
        trial_started_at: subscription?.trial_started_at ?? null,
        trial_ends_at: subscription?.trial_ends_at ?? null,
        current_period_end: subscription?.current_period_end ?? null,
        messages_used_today: Number(usage?.used_count ?? 0),
        messages_reserved_today: Number(usage?.reserved_count ?? 0),
      };
    });

    const today = istDateKey();
    return NextResponse.json({
      generated_at: new Date().toISOString(),
      usage_date: today,
      summary: {
        tenants: tenants.length,
        active_trials: tenants.filter((tenant) => tenant.subscription_status === 'trialing' && tenant.trial_ends_at && new Date(tenant.trial_ends_at) > new Date()).length,
        paid_subscriptions: tenants.filter((tenant) => tenant.subscription_status === 'active' && tenant.plan !== 'legacy').length,
        free_tenants: tenants.filter((tenant) => tenant.plan === 'free' || tenant.subscription_status === 'expired').length,
      },
      plans: plansResult.data ?? [],
      tenants,
    }, { headers: { 'Cache-Control': 'no-store' } });
  } catch (error) {
    return toErrorResponse(error);
  }
}
