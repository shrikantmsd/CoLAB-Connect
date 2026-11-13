import { NextResponse } from 'next/server';

import { requireRole, toErrorResponse } from '@/lib/auth/account';
import { assertContactCapacity, PlanLimitError } from '@/lib/saas/entitlements';
import { supabaseAdmin } from '@/lib/flows/admin-client';

export async function PATCH(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
) {
  try {
    const ctx = await requireRole('agent');
    const { id } = await params;
    const body = (await request.json().catch(() => null)) as { is_active?: unknown } | null;
    if (typeof body?.is_active !== 'boolean') {
      return NextResponse.json({ error: '`is_active` must be a boolean' }, { status: 400 });
    }

    const { data: current, error: readError } = await ctx.supabase
      .from('contacts')
      .select('id, is_active')
      .eq('id', id)
      .eq('account_id', ctx.accountId)
      .maybeSingle();
    if (readError || !current) {
      return NextResponse.json({ error: 'Contact not found' }, { status: 404 });
    }

    if (body.is_active && !current.is_active) {
      await assertContactCapacity(ctx.supabase, ctx.accountId);
    }

    const { data, error } = await ctx.supabase
      .from('contacts')
      .update({ is_active: body.is_active })
      .eq('id', id)
      .eq('account_id', ctx.accountId)
      .select('id, is_active')
      .single();
    if (error || !data) {
      console.error('[contacts/activation] update failed:', error?.message);
      return NextResponse.json({ error: 'Unable to update contact status' }, { status: 500 });
    }

    await supabaseAdmin().from('tenant_audit_logs').insert({
      account_id: ctx.accountId,
      actor_user_id: ctx.userId,
      event_type: body.is_active ? 'contact.activated' : 'contact.deactivated',
      entity_type: 'contact',
      entity_id: id,
    });

    return NextResponse.json({ contact: data });
  } catch (error) {
    if (error instanceof PlanLimitError) {
      return NextResponse.json({ error: error.message, code: error.code }, { status: error.status });
    }
    return toErrorResponse(error);
  }
}
