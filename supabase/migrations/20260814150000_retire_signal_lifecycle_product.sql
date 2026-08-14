begin;

-- Market State is now the product's only decision event. Keep the price and
-- liquidity that existed at each closed candle so Scenario, notifications and
-- Auto Trader never have to borrow a legacy breakout row.
alter table public.market_state_current
  add column if not exists close_price numeric,
  add column if not exists quote_volume_24h numeric;

alter table public.market_state_history
  add column if not exists close_price numeric,
  add column if not exists quote_volume_24h numeric;

update public.market_state_current m
set quote_volume_24h = s.quote_volume_24h
from public.symbols s
where s.id = m.symbol_id and m.quote_volume_24h is null;

update public.market_state_history m
set quote_volume_24h = s.quote_volume_24h
from public.symbols s
where s.id = m.symbol_id and m.quote_volume_24h is null;

-- Returns state TRANSITIONS, not one row per candle. The lag is calculated
-- before applying the requested window so the first row in a window is only
-- returned when it really differs from the preceding state.
create or replace function public.market_state_scenario_entries(
  p_timeframe text,
  p_since timestamptz,
  p_limit integer default 800
)
returns table (
  symbol_id uuid,
  symbol text,
  state text,
  state_score smallint,
  state_score_change smallint,
  candle_close_time timestamptz,
  close_price numeric,
  quote_volume_24h numeric
)
language sql
stable
security definer
set search_path = public
as $$
  with ordered as (
    select h.symbol_id, h.timeframe, h.state, h.state_score,
           h.state_score_change, h.candle_close_time, h.close_price,
           h.quote_volume_24h,
           lag(h.state) over (
             partition by h.symbol_id, h.timeframe, h.scoring_version
             order by h.candle_close_time
           ) as previous_state
    from public.market_state_history h
    where h.timeframe = p_timeframe
  )
  select o.symbol_id, s.symbol, o.state, o.state_score,
         o.state_score_change, o.candle_close_time, o.close_price,
         coalesce(o.quote_volume_24h, s.quote_volume_24h, 0)
  from ordered o
  join public.symbols s on s.id = o.symbol_id
  where o.candle_close_time >= p_since
    and o.state is distinct from o.previous_state
  order by o.candle_close_time desc, coalesce(o.quote_volume_24h, s.quote_volume_24h, 0) desc
  limit greatest(1, least(coalesce(p_limit, 800), 2000));
$$;

revoke all on function public.market_state_scenario_entries(text, timestamptz, integer) from public, anon;
grant execute on function public.market_state_scenario_entries(text, timestamptz, integer) to authenticated;

-- Notifications point at the state transition itself. No lifecycle status or
-- breakout signal is needed to render or route a state alert.
alter table public.notifications
  add column if not exists symbol_id uuid references public.symbols(id) on delete set null,
  add column if not exists timeframe text,
  add column if not exists market_state text,
  add column if not exists market_state_score smallint,
  add column if not exists market_state_change smallint;

alter table public.notifications
  drop constraint if exists notifications_market_state_check,
  add constraint notifications_market_state_check check (
    market_state is null or market_state in (
      'neutral', 'selling_dominant', 'seller_impact_fading',
      'buy_side_absorption', 'bounce_attempt', 'bullish_confirmation',
      'breakdown_risk'
    )
  );

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
  -- Re-scanning the same candle or changing component scores inside the same
  -- state is not a new alert. Only a genuine named-state transition qualifies.
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

drop trigger if exists breakout_signal_notification_matcher on public.breakout_signals;
drop trigger if exists breakout_signal_notification_matcher_insert on public.breakout_signals;
drop trigger if exists breakout_signal_notification_matcher_update on public.breakout_signals;
drop trigger if exists market_state_notification_matcher_insert on public.market_state_current;
drop trigger if exists market_state_notification_matcher_update on public.market_state_current;

create trigger market_state_notification_matcher_insert
  after insert on public.market_state_current
  for each row execute function public.enqueue_market_state_notifications();

create trigger market_state_notification_matcher_update
  after update of state on public.market_state_current
  for each row when (old.state is distinct from new.state)
  execute function public.enqueue_market_state_notifications();

-- A trade is uniquely tied to a state transition, not a journey or breakout
-- row. Legacy foreign keys remain nullable only so existing ledger history is
-- readable during the rollout.
alter table public.live_trades
  add column if not exists entry_timeframe text,
  add column if not exists market_state_since timestamptz;

create index if not exists live_trades_state_event_idx
  on public.live_trades (symbol, entry_timeframe, market_state_since, is_testnet);

commit;
