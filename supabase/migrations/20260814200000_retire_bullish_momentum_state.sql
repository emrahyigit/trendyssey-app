-- Retire the Strong Bullish Momentum state.
--
-- The product hunts reversals. A coin already advancing has nothing left to
-- turn around, so continuation is no longer a declared state: the engine
-- resolves that structure to neutral and the momentum component score that
-- existed only to classify it is gone with it.
--
-- Stored rows carrying the retired state are rewritten to neutral rather than
-- deleted, so history stays contiguous for the scenario replay's transition
-- detection. Those rows belong to the retired market-state-v3.1 scoring
-- version, which the current engine no longer writes to.

begin;

update public.market_state_history
set state = 'neutral', state_score = 0
where state = 'bullish_momentum';

delete from public.market_state_current where state = 'bullish_momentum';

update public.signal_journey_events
set market_state = null
where market_state = 'bullish_momentum';

update public.notifications
set market_state = null
where market_state = 'bullish_momentum';

alter table public.market_state_current
  drop constraint if exists market_state_current_bullish_momentum_check,
  drop constraint if exists market_state_current_bullish_momentum_change_check,
  drop column if exists bullish_momentum,
  drop column if exists bullish_momentum_change;

alter table public.market_state_history
  drop constraint if exists market_state_history_bullish_momentum_check,
  drop constraint if exists market_state_history_bullish_momentum_change_check,
  drop column if exists bullish_momentum,
  drop column if exists bullish_momentum_change;

alter table public.market_state_current
  drop constraint if exists market_state_current_state_check,
  add constraint market_state_current_state_check check (state in (
    'neutral', 'selling_dominant', 'seller_impact_fading',
    'buy_side_absorption', 'bounce_attempt', 'bullish_confirmation',
    'breakdown_risk'
  ));

alter table public.market_state_history
  drop constraint if exists market_state_history_state_check,
  add constraint market_state_history_state_check check (state in (
    'neutral', 'selling_dominant', 'seller_impact_fading',
    'buy_side_absorption', 'bounce_attempt', 'bullish_confirmation',
    'breakdown_risk'
  ));

alter table public.signal_journey_events
  drop constraint if exists signal_journey_events_market_state_check,
  add constraint signal_journey_events_market_state_check check (
    market_state is null or market_state in (
      'neutral', 'selling_dominant', 'seller_impact_fading',
      'buy_side_absorption', 'bounce_attempt', 'bullish_confirmation',
      'breakdown_risk'
    )
  );

alter table public.notifications
  drop constraint if exists notifications_market_state_check,
  add constraint notifications_market_state_check check (
    market_state is null or market_state in (
      'neutral', 'selling_dominant', 'seller_impact_fading',
      'buy_side_absorption', 'bounce_attempt', 'bullish_confirmation',
      'breakdown_risk'
    )
  );

-- Alert selections: drop the retired state before the narrower constraint is
-- validated. A profile that had selected nothing else keeps an empty list,
-- which simply means no state alerts — the column has no cardinality floor.
update public.profiles
set notification_market_states = array_remove(notification_market_states, 'bullish_momentum')
where 'bullish_momentum' = any(notification_market_states);

alter table public.profiles
  alter column notification_market_states set default array[
    'neutral', 'selling_dominant', 'seller_impact_fading',
    'buy_side_absorption', 'bounce_attempt', 'bullish_confirmation',
    'breakdown_risk'
  ]::text[];

alter table public.profiles
  drop constraint if exists profiles_notification_market_states_check,
  add constraint profiles_notification_market_states_check check (
    notification_market_states <@ array[
      'neutral', 'selling_dominant', 'seller_impact_fading',
      'buy_side_absorption', 'bounce_attempt', 'bullish_confirmation',
      'breakdown_risk'
    ]::text[]
  );

-- The trader's filter must stay non-empty, so a config left with nothing after
-- the removal falls back to the conservative reversal entry.
update public.trade_config
set allowed_market_states = case
      when cardinality(array_remove(allowed_market_states, 'bullish_momentum')) = 0
        then array['bullish_confirmation']::text[]
      else array_remove(allowed_market_states, 'bullish_momentum')
    end,
    updated_at = now()
where 'bullish_momentum' = any(allowed_market_states);

alter table public.trade_config
  drop constraint if exists trade_config_allowed_market_states_check,
  add constraint trade_config_allowed_market_states_check check (
    cardinality(allowed_market_states) > 0 and allowed_market_states <@ array[
      'neutral', 'selling_dominant', 'seller_impact_fading',
      'buy_side_absorption', 'bounce_attempt', 'bullish_confirmation',
      'breakdown_risk'
    ]::text[]
  );

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

revoke all on function public.update_trade_market_state_rules(text[], integer)
  from public, anon;
grant execute on function public.update_trade_market_state_rules(text[], integer)
  to authenticated;

create or replace function public.update_trade_market_states(
  p_allowed_market_states text[]
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

  update public.trade_config
  set allowed_market_states = array(select distinct unnest(p_allowed_market_states)),
      require_trend_entry = false,
      minimum_trend_score = 0,
      updated_at = now()
  where id;
end;
$$;

revoke all on function public.update_trade_market_states(text[]) from public, anon;
grant execute on function public.update_trade_market_states(text[]) to authenticated;

create or replace function public.enqueue_market_state_notifications()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  matched record;
  notification_id uuid;
  dedup_key text;
  state_text text;
  strength_text text;
  change_text text;
  volume_value numeric;
  base_asset_value text;
begin
  if tg_op = 'UPDATE' and old.state is not distinct from new.state then
    return new;
  end if;

  select s.base_asset, coalesce(new.quote_volume_24h, s.quote_volume_24h, 0)
    into base_asset_value, volume_value
  from public.symbols s where s.id = new.symbol_id;

  for matched in
    select p.id as user_id, coalesce(p.preferred_language, 'tr') as language
    from public.profiles p
    where p.notifications_enabled
      and exists (
        select 1 from public.subscription_entitlements e
        where e.user_id = p.id and e.is_active and e.expires_at > now()
      )
      and p.preferred_timeframe = new.timeframe
      and new.state = any(p.notification_market_states)
      and new.state_score >= p.minimum_state_score
      and volume_value >= p.minimum_quote_volume_24h
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
    state_text := case new.state
      when 'neutral' then case when matched.language = 'tr' then 'Nötr' else 'Neutral' end
      when 'selling_dominant' then case when matched.language = 'tr' then 'Satış baskın' else 'Selling dominant' end
      when 'seller_impact_fading' then case when matched.language = 'tr' then 'Satıcı etkisi zayıflıyor' else 'Seller impact fading' end
      when 'buy_side_absorption' then case when matched.language = 'tr' then 'Alıcı absorpsiyonu' else 'Buy-side absorption' end
      when 'bounce_attempt' then case when matched.language = 'tr' then 'Tepki denemesi' else 'Bounce attempt' end
      when 'bullish_confirmation' then case when matched.language = 'tr' then 'Yukarı yönlü teyit' else 'Bullish confirmation' end
      when 'breakdown_risk' then case when matched.language = 'tr' then 'Aşağı kırılım riski' else 'Breakdown risk' end
    end;
    strength_text := case
      when new.state = 'neutral' then case when matched.language = 'tr' then 'Aktif durum yok' else 'No active state' end
      else (case when matched.language = 'tr' then 'Güç ' else 'Strength ' end) || new.state_score || '/100'
    end;
    change_text := case
      when new.state_score_change is null then case when matched.language = 'tr' then 'İlk ölçüm' else 'First reading' end
      when new.state_score_change = 0 then case when matched.language = 'tr' then 'Değişim yok' else 'No change' end
      else (case when matched.language = 'tr' then 'Değişim ' else 'Change ' end)
        || case when new.state_score_change > 0 then '+' else '' end || new.state_score_change
    end;

    dedup_key := matched.user_id::text || ':' || new.symbol_id::text || ':'
      || new.timeframe || ':' || new.state || ':' || new.state_since::text;
    insert into public.notifications(
      user_id, symbol_id, timeframe, market_state, market_state_score,
      market_state_change, title, body, notification_type,
      deduplication_key, breakout_signal_id, signal_status
    ) values (
      matched.user_id, new.symbol_id, new.timeframe, new.state, new.state_score,
      new.state_score_change, base_asset_value || ' · ' || state_text,
      strength_text || ' · ' || change_text || ' · '
        || case when matched.language = 'tr' then '24s hacim ' else '24h volume ' end
        || public.format_usd_compact(volume_value),
      'market_state', dedup_key, null, null
    )
    on conflict (deduplication_key) where deduplication_key is not null do nothing
    returning id into notification_id;

    if notification_id is not null then
      insert into public.notification_queue(notification_id, deduplication_key)
      values (notification_id, dedup_key)
      on conflict (deduplication_key) do nothing;
    end if;
    notification_id := null;
  end loop;
  return new;
end;
$$;

commit;
