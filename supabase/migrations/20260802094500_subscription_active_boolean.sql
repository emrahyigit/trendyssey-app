begin;

-- Product access is binary in the app. Keep expiry and Apple transaction
-- metadata, but replace the five-state string with the entitlement fact every
-- consumer actually uses.
alter table public.subscription_entitlements
  add column is_active boolean not null default false;

update public.subscription_entitlements
   set is_active = status in ('active', 'grace_period')
                   and expires_at > now();

alter table public.subscription_entitlements
  drop constraint subscription_entitlements_status_check,
  drop column status;

create or replace function public.enqueue_matching_signal_notifications()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  matched record;
  notification_id uuid;
  dedup_key text;
  notification_title text;
  notification_body text;
begin
  for matched in
    select p.id as user_id
    from public.profiles p
    where p.notifications_enabled
      and p.preferred_analysis_model_id = new.analysis_model_id
      and exists (
        select 1 from public.subscription_entitlements e
        where e.user_id = p.id
          and e.is_active
          and e.expires_at > now()
      )
      and p.preferred_timeframe = new.timeframe
      and coalesce(new.regime_score, 0) >= p.minimum_regime_score
      and coalesce(new.readiness_score, 0) >= p.minimum_readiness_score
      and coalesce(new.breakout_quality_score, new.breakout_confidence_score, 0)
            >= p.minimum_breakout_quality_score
      and coalesce(new.confirmation_score, 0) >= p.minimum_confirmation_score
      and new.false_breakout_risk <= p.maximum_false_breakout_risk
      and coalesce(new.volume_ratio, 0) >= p.minimum_volume_ratio
      and coalesce((
        select symbol.quote_volume_24h
        from public.symbols symbol
        where symbol.id = new.symbol_id
      ), 0) >= p.minimum_quote_volume_24h
      and new.status = any(p.notification_statuses)
      and (
        p.notification_scope = 'all'
        or exists (
          select 1
          from public.watchlists w
          join public.watchlist_items wi on wi.watchlist_id = w.id
          where w.user_id = p.id and wi.symbol_id = new.symbol_id
        )
      )
  loop
    select copy.title, copy.body
      into notification_title, notification_body
      from public.breakout_notification_text(
        new.id,
        matched.user_id,
        new.status
      ) copy
      limit 1;
    if notification_title is null then continue; end if;

    dedup_key := matched.user_id::text || ':' || new.id::text || ':'
      || new.candle_close_time::text || ':' || new.status;
    insert into public.notifications(
      user_id, breakout_signal_id, title, body, notification_type,
      deduplication_key, signal_status
    ) values (
      matched.user_id, new.id, notification_title,
      notification_body, 'breakout_signal', dedup_key, new.status
    )
    on conflict (deduplication_key) where deduplication_key is not null
      do nothing
    returning id into notification_id;

    if notification_id is not null then
      insert into public.notification_queue(
        notification_id,
        deduplication_key
      ) values (
        notification_id,
        dedup_key
      )
      on conflict (deduplication_key) do nothing;
    end if;
    notification_id := null;
    notification_title := null;
    notification_body := null;
  end loop;
  return new;
end;
$$;

commit;
