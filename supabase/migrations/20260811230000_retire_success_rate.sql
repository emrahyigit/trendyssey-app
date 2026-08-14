begin;

-- The per-coin "breakout success rate" retires. It measured the old +1%/-5%
-- lifecycle — the Aug 2026 backtest showed those hit rates hover around the
-- 83.3% break-even line and carry no economic information, and the trend
-- score is the single quality metric now. The executor and the app stopped
-- reading it in the same deploy; this removes the notification gate and the
-- RPCs.

-- Same function as 20260811210000 with the success-rate gate removed.
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
      and coalesce(new.trend_score, 100) >= p.minimum_signal_strength
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

-- The success-rate RPC and the two journey-stat readers that only served the
-- retired track-record card, the scenario filter and the dashboard's
-- invalidation screen. (get_top_predictors stays — the prediction game is a
-- separate, user-vote feature.)
drop function if exists public.symbol_success_rate(uuid, uuid, text);
drop function if exists public.get_symbol_journey_stats(text, text, text, integer);
drop function if exists public.get_journey_invalidation_stats(text, text, integer);

commit;
