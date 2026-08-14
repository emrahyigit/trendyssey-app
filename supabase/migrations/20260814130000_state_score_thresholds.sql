begin;

-- Notification, Scenario and Auto Trader now share the same 0-100 market
-- state threshold. Zero means that the optional threshold is disabled.
alter table public.profiles
  add column if not exists minimum_state_score smallint not null default 0;

alter table public.profiles
  drop constraint if exists profiles_minimum_state_score_check,
  add constraint profiles_minimum_state_score_check
    check (minimum_state_score between 0 and 100);

alter table public.trade_config
  add column if not exists minimum_state_score smallint not null default 0;

alter table public.trade_config
  drop constraint if exists trade_config_minimum_state_score_check,
  add constraint trade_config_minimum_state_score_check
    check (minimum_state_score between 0 and 100);

-- Extra-percent entry triggers have left the product. Legacy pending orders
-- can still reconcile, but every new entry is immediate after state filters.
update public.trade_config
set entry_trigger_percent = 0,
    minimum_state_score = 0,
    updated_at = now()
where id;

create or replace function public.update_trade_market_state_rules(
  p_allowed_market_states text[],
  p_minimum_state_score integer
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_allowed_market_states is null
    or cardinality(p_allowed_market_states) = 0
    or exists (
      select 1 from unnest(p_allowed_market_states) state
      where state <> all(array[
        'neutral', 'selling_dominant', 'seller_impact_fading',
        'buy_side_absorption', 'bounce_attempt', 'bullish_confirmation',
        'breakdown_risk'
      ]::text[])
    ) then
    raise exception 'Invalid market-state filter';
  end if;

  if p_minimum_state_score is null or p_minimum_state_score not between 0 and 100 then
    raise exception 'Invalid minimum market-state score';
  end if;

  update public.trade_config
  set allowed_market_states = array(select distinct unnest(p_allowed_market_states)),
      minimum_state_score = p_minimum_state_score,
      entry_trigger_percent = 0,
      require_trend_entry = false,
      minimum_trend_score = 0,
      updated_at = now()
  where id;
end;
$$;

revoke all on function public.update_trade_market_state_rules(text[], integer) from public, anon;
grant execute on function public.update_trade_market_state_rules(text[], integer) to authenticated;

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
    select p.id as user_id, m.state, m.state_since
    from public.profiles p
    join public.market_state_current m
      on m.symbol_id = new.symbol_id and m.timeframe = new.timeframe
    where p.notifications_enabled
      and p.preferred_analysis_model_id = new.analysis_model_id
      and exists (
        select 1 from public.subscription_entitlements e
        where e.user_id = p.id and e.is_active and e.expires_at > now()
      )
      and p.preferred_timeframe = new.timeframe
      and m.state = any(p.notification_market_states)
      and m.state_since = new.candle_close_time
      and m.state_score >= p.minimum_state_score
      and new.false_breakout_risk <= p.maximum_false_breakout_risk
      and coalesce(new.volume_ratio, 0) >= p.minimum_volume_ratio
      and coalesce((
        select s.quote_volume_24h from public.symbols s where s.id = new.symbol_id
      ), 0) >= p.minimum_quote_volume_24h
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

    dedup_key := matched.user_id::text || ':' || new.symbol_id::text || ':'
      || new.timeframe || ':' || matched.state || ':' || matched.state_since::text;
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
