'use client';

import { useEffect, useState } from 'react';
import { Activity, CheckCircle2, Clock3, CreditCard, MessageSquare, Users } from 'lucide-react';
import { Button } from '@/components/ui/button';

interface BillingSummary {
  entitlements: {
    plan_code: string;
    plan_name: string;
    subscription_status: string;
    trial_started_at: string | null;
    trial_ends_at: string | null;
    features: Record<string, boolean>;
    limits: Record<string, { limit: number; unit: string | null }>;
  };
  usage: {
    contacts: { active: number; limit: number | null };
    whatsapp_messages_daily: { used: number; reserved: number; limit: number | null; remaining: number | null; usage_date: string; timezone: string };
  };
}

function formatDate(value: string | null): string {
  if (!value) return '—';
  return new Intl.DateTimeFormat('en-IN', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'Asia/Kolkata' }).format(new Date(value));
}

function UsageMeter({ label, value, limit, detail }: { label: string; value: number; limit: number | null; detail: string }) {
  const percentage = limit === null ? 0 : Math.min(100, Math.round((value / limit) * 100));
  return (
    <div className="rounded-xl border border-border bg-card p-4">
      <div className="flex items-center justify-between gap-3">
        <p className="text-sm font-medium text-foreground">{label}</p>
        <p className="text-sm tabular-nums text-foreground">{value}/{limit ?? 'Unlimited'}</p>
      </div>
      {limit !== null && <div className="mt-3 h-2 overflow-hidden rounded-full bg-muted"><div className="h-full rounded-full bg-primary transition-[width]" style={{ width: `${percentage}%` }} /></div>}
      <p className="mt-2 text-xs text-muted-foreground">{detail}</p>
    </div>
  );
}

export function BillingPanel() {
  const [summary, setSummary] = useState<BillingSummary | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  async function load() {
    setLoading(true);
    setError(null);
    try {
      const response = await fetch('/api/billing/entitlements', { cache: 'no-store' });
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.error || 'Unable to load subscription details');
      setSummary(payload as BillingSummary);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unable to load subscription details');
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => { void load(); }, []);

  if (loading) return <div className="rounded-xl border border-border bg-card p-6 text-sm text-muted-foreground">Loading subscription and usage…</div>;
  if (error) return <div className="rounded-xl border border-destructive/30 bg-card p-6"><p className="text-sm text-destructive">{error}</p><Button className="mt-3" variant="outline" size="sm" onClick={() => void load()}>Retry</Button></div>;
  if (!summary) return null;

  const { entitlements, usage } = summary;
  const isTrial = entitlements.plan_code === 'trial_30d';
  const isFree = entitlements.plan_code === 'free';

  return (
    <div className="space-y-5">
      <div className="rounded-xl border border-border bg-card p-5">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <div className="flex items-center gap-2"><CreditCard className="size-5 text-primary" /><h2 className="text-lg font-semibold text-foreground">{entitlements.plan_name}</h2></div>
            <p className="mt-1 text-sm text-muted-foreground">Status: <span className="capitalize text-foreground">{entitlements.subscription_status.replaceAll('_', ' ')}</span></p>
            {isTrial && <p className="mt-2 text-sm text-muted-foreground">Trial ends: <strong className="font-medium text-foreground">{formatDate(entitlements.trial_ends_at)}</strong></p>}
            {isFree && <p className="mt-2 text-sm text-muted-foreground">Your trial has ended. Your workspace and existing customer records are retained; records beyond the active-contact allowance are preserved as inactive.</p>}
            {entitlements.plan_code === 'legacy' && <p className="mt-2 text-sm text-muted-foreground">This existing installation is grandfathered during the SaaS rollout.</p>}
          </div>
          <span className="inline-flex items-center gap-1.5 self-start rounded-full border border-primary/30 bg-primary/10 px-3 py-1 text-xs font-semibold text-primary"><CheckCircle2 className="size-3.5" />{isTrial ? 'All features enabled' : 'Workspace available'}</span>
        </div>
      </div>

      <div className="grid gap-3 md:grid-cols-2">
        <UsageMeter label="Active contacts" value={usage.contacts.active} limit={usage.contacts.limit} detail={usage.contacts.limit === null ? 'No active-contact cap on this plan.' : 'You can keep up to 5 contacts active. Older records are not deleted.'} />
        <UsageMeter label="WhatsApp messages today" value={usage.whatsapp_messages_daily.used + usage.whatsapp_messages_daily.reserved} limit={usage.whatsapp_messages_daily.limit} detail={usage.whatsapp_messages_daily.limit === null ? 'No CoLAB daily message cap on this plan. Meta billing is separate.' : `Resets daily at midnight India time (${usage.whatsapp_messages_daily.timezone}). Incoming messages do not use this quota.`} />
      </div>

      <div className="rounded-xl border border-border bg-card p-5">
        <div className="flex items-center gap-2"><Activity className="size-4 text-primary" /><h3 className="text-sm font-semibold text-foreground">Feature access</h3></div>
        <div className="mt-3 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
          {Object.entries(entitlements.features).map(([key, enabled]) => (
            <div key={key} className="flex items-center gap-2 text-xs text-muted-foreground"><span className={enabled ? 'size-1.5 rounded-full bg-emerald-500' : 'size-1.5 rounded-full bg-muted-foreground'} />{key.replaceAll('_', ' ')}</div>
          ))}
        </div>
      </div>

      <div className="rounded-xl border border-border bg-muted/30 p-4 text-sm text-muted-foreground">
        {isTrial
          ? 'Your 30-day trial includes all current platform features. Charges imposed by Meta or other external providers are not included in a CoLAB subscription.'
          : 'Online plan upgrades and checkout are not enabled in this build yet. The subscription tables and entitlement enforcement are in place; payment gateway credentials and webhook verification must be configured before accepting payments.'}
      </div>
      <div className="flex items-center gap-2 text-xs text-muted-foreground"><Users className="size-3.5" /><span>Usage is scoped to this workspace. </span><MessageSquare className="ml-2 size-3.5" /><span>Daily message count uses successful provider acceptances.</span></div>
    </div>
  );
}
