'use client';

import { useCallback, useEffect, useState } from 'react';
import { toast } from 'sonner';
import { Building2, RefreshCw, ShieldAlert, Users, CalendarClock, CreditCard } from 'lucide-react';
import { Button } from '@/components/ui/button';

interface TenantRow {
  id: string;
  name: string;
  created_at: string;
  plan: string;
  plan_name: string;
  subscription_status: string;
  trial_ends_at: string | null;
  messages_used_today: number;
}

interface Overview {
  summary: { tenants: number; active_trials: number; paid_subscriptions: number; free_tenants: number };
  usage_date: string;
  tenants: TenantRow[];
}

function dateLabel(value: string | null): string {
  if (!value) return '—';
  return new Intl.DateTimeFormat('en-IN', { dateStyle: 'medium', timeZone: 'Asia/Kolkata' }).format(new Date(value));
}

export default function PlatformAdminPage() {
  const [overview, setOverview] = useState<Overview | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [extending, setExtending] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const response = await fetch('/api/platform/overview', { cache: 'no-store' });
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.error || 'Unable to load platform dashboard');
      setOverview(payload as Overview);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unable to load platform dashboard');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { void load(); }, [load]);

  async function extendTrial(accountId: string) {
    setExtending(accountId);
    try {
      const response = await fetch(`/api/platform/tenants/${accountId}/trial-extension`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ days: 7 }),
      });
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.error || 'Trial extension failed');
      toast.success(`Trial extended until ${dateLabel(payload.trial_ends_at)}`);
      await load();
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Trial extension failed');
    } finally {
      setExtending(null);
    }
  }

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <div className="flex items-center gap-2"><ShieldAlert className="size-5 text-primary" /><h1 className="text-2xl font-bold text-foreground">CoLAB Connect · Platform Admin</h1></div>
          <p className="mt-1 text-sm text-muted-foreground">Tenant, trial and subscription oversight. This page is restricted to explicitly provisioned platform administrators.</p>
        </div>
        <Button variant="outline" onClick={() => void load()} disabled={loading}><RefreshCw className="mr-2 size-4" />Refresh</Button>
      </div>

      {error && <div className="rounded-xl border border-destructive/30 bg-card p-4 text-sm text-destructive">{error}</div>}
      {loading && !overview && <div className="rounded-xl border border-border bg-card p-6 text-sm text-muted-foreground">Loading tenant data…</div>}

      {overview && <>
        <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
          {[
            { label: 'Tenants', value: overview.summary.tenants, icon: Building2 },
            { label: 'Active trials', value: overview.summary.active_trials, icon: CalendarClock },
            { label: 'Paid subscriptions', value: overview.summary.paid_subscriptions, icon: CreditCard },
            { label: 'Free tenants', value: overview.summary.free_tenants, icon: Users },
          ].map((item) => <div key={item.label} className="rounded-xl border border-border bg-card p-4"><div className="flex items-center justify-between"><p className="text-xs text-muted-foreground">{item.label}</p><item.icon className="size-4 text-primary" /></div><p className="mt-2 text-2xl font-semibold tabular-nums text-foreground">{item.value}</p></div>)}
        </div>

        <div className="overflow-hidden rounded-xl border border-border bg-card">
          <div className="flex items-center justify-between border-b border-border px-4 py-3"><h2 className="text-sm font-semibold text-foreground">Customer workspaces</h2><span className="text-xs text-muted-foreground">Usage date: {overview.usage_date} (IST)</span></div>
          <div className="overflow-x-auto">
            <table className="w-full min-w-[760px] text-left text-sm">
              <thead className="bg-muted/40 text-xs text-muted-foreground"><tr><th className="px-4 py-3 font-medium">Workspace</th><th className="px-4 py-3 font-medium">Plan</th><th className="px-4 py-3 font-medium">Status</th><th className="px-4 py-3 font-medium">Trial ends</th><th className="px-4 py-3 font-medium">Messages today</th><th className="px-4 py-3 font-medium">Action</th></tr></thead>
              <tbody>{overview.tenants.map((tenant) => <tr key={tenant.id} className="border-t border-border"><td className="px-4 py-3"><p className="font-medium text-foreground">{tenant.name}</p><p className="text-[11px] text-muted-foreground">{tenant.id}</p></td><td className="px-4 py-3 text-muted-foreground">{tenant.plan_name}</td><td className="px-4 py-3 capitalize text-muted-foreground">{tenant.subscription_status.replaceAll('_', ' ')}</td><td className="px-4 py-3 text-muted-foreground">{dateLabel(tenant.trial_ends_at)}</td><td className="px-4 py-3 tabular-nums text-muted-foreground">{tenant.messages_used_today}</td><td className="px-4 py-3">{['trialing', 'expired'].includes(tenant.subscription_status) && tenant.plan !== 'legacy' ? <Button size="sm" variant="outline" disabled={extending === tenant.id} onClick={() => void extendTrial(tenant.id)}>{extending === tenant.id ? 'Extending…' : 'Add 7 trial days'}</Button> : <span className="text-xs text-muted-foreground">—</span>}</td></tr>)}</tbody>
            </table>
          </div>
        </div>
      </>}
    </div>
  );
}
