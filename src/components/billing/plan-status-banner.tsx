'use client';

import { useEffect, useState } from 'react';
import Link from 'next/link';
import { AlertCircle, Clock3, Sparkles } from 'lucide-react';

interface BillingSummary {
  entitlements: {
    plan_code: string;
    plan_name: string;
    trial_ends_at: string | null;
  };
  usage: {
    contacts: { active: number; limit: number | null };
    whatsapp_messages_daily: { used: number; limit: number | null; remaining: number | null };
  };
}

export function PlanStatusBanner() {
  const [summary, setSummary] = useState<BillingSummary | null>(null);

  useEffect(() => {
    let cancelled = false;
    fetch('/api/billing/entitlements', { cache: 'no-store' })
      .then(async (response) => (response.ok ? (await response.json()) as BillingSummary : null))
      .then((data) => { if (!cancelled && data) setSummary(data); })
      .catch(() => undefined);
    return () => { cancelled = true; };
  }, []);

  if (!summary) return null;

  const isTrial = summary.entitlements.plan_code === 'trial_30d';
  const isLegacy = summary.entitlements.plan_code === 'legacy';
  const isFree = summary.entitlements.plan_code === 'free';
  const messageLimit = summary.usage.whatsapp_messages_daily.limit;
  const contactLimit = summary.usage.contacts.limit;
  const daysRemaining = summary.entitlements.trial_ends_at
    ? Math.max(0, Math.ceil((new Date(summary.entitlements.trial_ends_at).getTime() - Date.now()) / 86_400_000))
    : 0;

  return (
    <div className="mb-4 flex flex-col gap-2 rounded-xl border border-border bg-card px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
      <div className="flex items-start gap-3">
        {isTrial ? <Sparkles className="mt-0.5 size-4 shrink-0 text-primary" /> : <AlertCircle className="mt-0.5 size-4 shrink-0 text-muted-foreground" />}
        <div>
          <p className="text-sm font-semibold text-foreground">
            {isTrial
              ? `30-day full-access trial · ${daysRemaining} day${daysRemaining === 1 ? '' : 's'} remaining`
              : isLegacy
                ? 'Existing installation · grandfathered plan'
                : isFree
                  ? 'Free plan'
                  : summary.entitlements.plan_name}
          </p>
          <p className="text-xs text-muted-foreground">
            {isTrial
              ? 'All CoLAB Connect features are enabled during your trial. Meta and third-party provider charges remain separate.'
              : isLegacy
                ? 'This existing workspace is not subject to the new Free-tier limits.'
                : `${summary.usage.contacts.active}/${contactLimit ?? '∞'} active contacts · ${summary.usage.whatsapp_messages_daily.used}/${messageLimit ?? '∞'} WhatsApp messages used today (IST)`}
          </p>
        </div>
      </div>
      <Link href="/settings?tab=billing" className="inline-flex items-center gap-1 self-start text-xs font-semibold text-primary hover:underline sm:self-center">
        <Clock3 className="size-3.5" /> View plan
      </Link>
    </div>
  );
}
