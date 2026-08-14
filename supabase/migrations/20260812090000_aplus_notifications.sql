begin;

-- Per-user "A+ entries only" push filter: when on, a journey only notifies if
-- its breakout candle carried trend_entry — the backtested A+ setup (fresh
-- 55-high breakout with regime and momentum aligned). Ships off.

alter table public.profiles
  add column if not exists aplus_entries_only boolean not null default false;

comment on column public.profiles.aplus_entries_only is
  'When true, only journeys whose breakout candle was the A+ setup (breakout_signals.trend_entry) produce pushes for this user.';

-- Same function as 20260811230000 with the A+ gate added. The gate reads the
-- journey''s trigger event, not the live row: trend_entry is true only on the
-- breakout candle itself, and later transitions (hold, invalidation) of an A+
-- journey must still notify.
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
  journey_is_aplus boolean;
begin
  journey_is_aplus := new.trend_entry or exists (
    select 1 from public.signal_journey_events e
    where e.journey_id = new.journey_id and e.trend_entry
  );

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
      and coalesce(new.trend_score, 100) >= p.minimum_signal_strength
      and (not p.aplus_entries_only or journey_is_aplus)
      and new.false_breakout_risk <= p.maximum_false_breakout_risk
      and coalesce(new.volume_ratio, 0) >= p.minimum_volume_ratio
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
      from public.breakout_notification_text(new.id, matched.user_id, new.status) copy
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
    on conflict (deduplication_key) where deduplication_key is not null do nothing
    returning id into notification_id;

    if notification_id is not null then
      insert into public.notification_queue(notification_id, deduplication_key)
      values (notification_id, dedup_key)
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
