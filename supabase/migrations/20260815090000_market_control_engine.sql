-- Market-control engine: symmetric metrics and a control-transfer state cycle.
--
-- The engine could only describe a sell-off. Of 14,214 recorded observations
-- 72.6% were neutral, 24.4% were a seller state, and bounce_attempt fired six
-- times in the entire history. Pressure, efficiency, response and absorption
-- now exist for both sides, so a market topping out is as describable as one
-- bottoming out.
--
-- Pressure is each side's own taker flow against its own baseline, never its
-- share of volume: share is a complement, so a share-based pair could never
-- show both sides swinging hard at once.
--
-- Naming follows the pairs. selling_pressure becomes seller_pressure,
-- absorption becomes buy_side_absorption and confirmation becomes
-- bullish_confirmation, each gaining its mirror. efficiency_change was always
-- the seller-efficiency slope rather than a close-to-close delta, so it is
-- renamed to seller_efficiency_trend to stop it reading as a change badge.

begin;

do $$
declare
  target text;
begin
  foreach target in array array['market_state_current', 'market_state_history'] loop
    execute format('alter table public.%I rename column selling_pressure to seller_pressure', target);
    execute format('alter table public.%I rename column selling_pressure_change to seller_pressure_change', target);
    execute format('alter table public.%I rename column absorption to buy_side_absorption', target);
    execute format('alter table public.%I rename column absorption_change to buy_side_absorption_change', target);
    execute format('alter table public.%I rename column confirmation to bullish_confirmation', target);
    execute format('alter table public.%I rename column confirmation_change to bullish_confirmation_change', target);
    execute format('alter table public.%I rename column efficiency_change to seller_efficiency_trend', target);
  end loop;
end $$;

do $$
declare
  target text;
begin
  foreach target in array array['market_state_current', 'market_state_history'] loop
    execute format($f$
      alter table public.%I
        add column if not exists buyer_pressure smallint not null default 0,
        add column if not exists buyer_pressure_change smallint,
        add column if not exists buyer_efficiency smallint not null default 0,
        add column if not exists buyer_efficiency_change smallint,
        add column if not exists upside_response smallint not null default 0,
        add column if not exists upside_response_change smallint,
        add column if not exists sell_side_absorption smallint not null default 0,
        add column if not exists sell_side_absorption_change smallint,
        add column if not exists bearish_confirmation smallint not null default 0,
        add column if not exists bearish_confirmation_change smallint,
        add column if not exists rollover_readiness smallint not null default 0,
        add column if not exists rollover_readiness_change smallint,
        add column if not exists buyer_efficiency_trend smallint not null default 0,
        add column if not exists seller_pressure_trend smallint not null default 0,
        add column if not exists buyer_pressure_trend smallint not null default 0
    $f$, target);
    -- Price resilience is withheld when selling never tested price, so it can
    -- no longer be non-null.
    execute format('alter table public.%I alter column price_resilience drop not null', target);
  end loop;
end $$;

-- The old vocabulary is about to be rewritten, so its constraint comes off
-- first and the new one goes on once every row speaks the new language.
do $$
declare
  target text;
begin
  foreach target in array array['market_state_current', 'market_state_history'] loop
    execute format('alter table public.%I drop constraint if exists %I', target, target || '_state_check');
  end loop;
end $$;

-- Map the retired vocabulary onto the cycle. Dominance absorbs breakdown_risk
-- because intensity is now the state score rather than a separate state, and
-- both former reversal states land on the takeover they were describing.
-- A neutral row is re-read by the pressure it recorded: a quiet market is
-- low participation, an active one without a claim is balanced.
do $$
declare
  target text;
begin
  foreach target in array array['market_state_current', 'market_state_history'] loop
    execute format($f$
      update public.%I set state = case state
        when 'selling_dominant' then 'seller_dominance'
        when 'breakdown_risk' then 'seller_dominance'
        when 'seller_impact_fading' then 'seller_impact_fading'
        when 'buy_side_absorption' then 'buy_side_absorption'
        when 'bounce_attempt' then 'buyer_takeover'
        when 'bullish_confirmation' then 'buyer_takeover'
        when 'neutral' then case when seller_pressure < 40 then 'low_participation' else 'balanced' end
        else state end
      where state in (
        'selling_dominant', 'breakdown_risk', 'seller_impact_fading',
        'buy_side_absorption', 'bounce_attempt', 'bullish_confirmation', 'neutral'
      )
    $f$, target);
  end loop;
end $$;

do $$
declare
  target text;
begin
  foreach target in array array['market_state_current', 'market_state_history'] loop
    execute format($f$
      alter table public.%I add constraint %I check (state in (
        'seller_dominance', 'seller_impact_fading', 'buy_side_absorption',
        'seller_exhaustion', 'buyer_takeover', 'buyer_dominance',
        'buyer_impact_fading', 'sell_side_absorption', 'buyer_exhaustion',
        'seller_takeover', 'balanced', 'low_participation'
      ))
    $f$, target, target || '_state_check');
  end loop;
end $$;

alter table public.signal_journey_events
  drop constraint if exists signal_journey_events_market_state_check;

update public.signal_journey_events
set market_state = case market_state
  when 'selling_dominant' then 'seller_dominance'
  when 'breakdown_risk' then 'seller_dominance'
  when 'bounce_attempt' then 'buyer_takeover'
  when 'bullish_confirmation' then 'buyer_takeover'
  when 'neutral' then 'balanced'
  else market_state end
where market_state is not null;

alter table public.notifications
  drop constraint if exists notifications_market_state_check;

update public.notifications
set market_state = case market_state
  when 'selling_dominant' then 'seller_dominance'
  when 'breakdown_risk' then 'seller_dominance'
  when 'bounce_attempt' then 'buyer_takeover'
  when 'bullish_confirmation' then 'buyer_takeover'
  when 'neutral' then 'balanced'
  else market_state end
where market_state is not null;

alter table public.signal_journey_events
  drop constraint if exists signal_journey_events_market_state_check,
  add constraint signal_journey_events_market_state_check check (
    market_state is null or market_state in (
      'seller_dominance', 'seller_impact_fading', 'buy_side_absorption',
      'seller_exhaustion', 'buyer_takeover', 'buyer_dominance',
      'buyer_impact_fading', 'sell_side_absorption', 'buyer_exhaustion',
      'seller_takeover', 'balanced', 'low_participation'
    )
  );

alter table public.notifications
  drop constraint if exists notifications_market_state_check,
  add constraint notifications_market_state_check check (
    market_state is null or market_state in (
      'seller_dominance', 'seller_impact_fading', 'buy_side_absorption',
      'seller_exhaustion', 'buyer_takeover', 'buyer_dominance',
      'buyer_impact_fading', 'sell_side_absorption', 'buyer_exhaustion',
      'seller_takeover', 'balanced', 'low_participation'
    )
  );

-- Alert selections and the trader's filter follow the same rename. A selection
-- that collapses to nothing keeps the user subscribed to the state their old
-- choice was really about.
alter table public.profiles drop constraint if exists profiles_notification_market_states_check;

update public.profiles
set notification_market_states = (
  select coalesce(array_agg(distinct mapped), array[]::text[])
  from unnest(notification_market_states) as old
  cross join lateral (select case old
    when 'selling_dominant' then 'seller_dominance'
    when 'breakdown_risk' then 'seller_dominance'
    when 'bounce_attempt' then 'buyer_takeover'
    when 'bullish_confirmation' then 'buyer_takeover'
    when 'neutral' then 'balanced'
    else old end) as m(mapped)
);

alter table public.profiles
  alter column notification_market_states set default array[
    'seller_dominance', 'seller_impact_fading', 'buy_side_absorption',
    'seller_exhaustion', 'buyer_takeover', 'buyer_dominance',
    'buyer_impact_fading', 'sell_side_absorption', 'buyer_exhaustion',
    'seller_takeover'
  ]::text[];

alter table public.profiles
  drop constraint if exists profiles_notification_market_states_check,
  add constraint profiles_notification_market_states_check check (
    notification_market_states <@ array[
      'seller_dominance', 'seller_impact_fading', 'buy_side_absorption',
      'seller_exhaustion', 'buyer_takeover', 'buyer_dominance',
      'buyer_impact_fading', 'sell_side_absorption', 'buyer_exhaustion',
      'seller_takeover', 'balanced', 'low_participation'
    ]::text[]
  );

alter table public.trade_config drop constraint if exists trade_config_allowed_market_states_check;

update public.trade_config
set allowed_market_states = (
  select coalesce(
    nullif(array_agg(distinct mapped), array[]::text[]),
    array['buyer_takeover']::text[]
  )
  from unnest(allowed_market_states) as old
  cross join lateral (select case old
    when 'selling_dominant' then 'seller_dominance'
    when 'breakdown_risk' then 'seller_dominance'
    when 'bounce_attempt' then 'buyer_takeover'
    when 'bullish_confirmation' then 'buyer_takeover'
    when 'neutral' then 'balanced'
    else old end) as m(mapped)
),
updated_at = now();

alter table public.trade_config
  drop constraint if exists trade_config_allowed_market_states_check,
  add constraint trade_config_allowed_market_states_check check (
    cardinality(allowed_market_states) > 0 and allowed_market_states <@ array[
      'seller_dominance', 'seller_impact_fading', 'buy_side_absorption',
      'seller_exhaustion', 'buyer_takeover', 'buyer_dominance',
      'buyer_impact_fading', 'sell_side_absorption', 'buyer_exhaustion',
      'seller_takeover', 'balanced', 'low_participation'
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
        'seller_dominance', 'seller_impact_fading', 'buy_side_absorption',
        'seller_exhaustion', 'buyer_takeover', 'buyer_dominance',
        'buyer_impact_fading', 'sell_side_absorption', 'buyer_exhaustion',
        'seller_takeover', 'balanced', 'low_participation'
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
        'seller_dominance', 'seller_impact_fading', 'buy_side_absorption',
        'seller_exhaustion', 'buyer_takeover', 'buyer_dominance',
        'buyer_impact_fading', 'sell_side_absorption', 'buyer_exhaustion',
        'seller_takeover', 'balanced', 'low_participation'
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
      when 'seller_dominance' then case when matched.language = 'tr' then 'Satıcılar kontrolde' else 'Sellers in control' end
      when 'seller_impact_fading' then case when matched.language = 'tr' then 'Satışın etkisi zayıflıyor' else 'Selling impact fading' end
      when 'buy_side_absorption' then case when matched.language = 'tr' then 'Alıcılar satışı topluyor' else 'Buyers absorbing the selling' end
      when 'seller_exhaustion' then case when matched.language = 'tr' then 'Satış gücü tükeniyor' else 'Selling force running out' end
      when 'buyer_takeover' then case when matched.language = 'tr' then 'Kontrol alıcılara geçiyor' else 'Buyers taking control' end
      when 'buyer_dominance' then case when matched.language = 'tr' then 'Alıcılar kontrolde' else 'Buyers in control' end
      when 'buyer_impact_fading' then case when matched.language = 'tr' then 'Alımın etkisi zayıflıyor' else 'Buying impact fading' end
      when 'sell_side_absorption' then case when matched.language = 'tr' then 'Satıcılar alımı karşılıyor' else 'Sellers meeting the buying' end
      when 'buyer_exhaustion' then case when matched.language = 'tr' then 'Alım gücü tükeniyor' else 'Buying force running out' end
      when 'seller_takeover' then case when matched.language = 'tr' then 'Kontrol satıcılara geçiyor' else 'Sellers taking control' end
      when 'balanced' then case when matched.language = 'tr' then 'İki taraf da sahada' else 'Both sides active' end
      when 'low_participation' then case when matched.language = 'tr' then 'Piyasa durgun' else 'Market is quiet' end
    end;
    strength_text := case
      when new.state = 'low_participation' then case when matched.language = 'tr' then 'Aktif taraf yok' else 'Neither side active' end
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
