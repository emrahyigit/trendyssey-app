begin;

-- Close-to-close comparison is product data, not a UI inference. Keeping the
-- previous reading beside the current row makes every client show the same
-- change and keeps re-scans of one candle idempotent.
alter table public.market_state_current
  add column if not exists previous_state_score smallint,
  add column if not exists state_score_change smallint;

alter table public.market_state_history
  add column if not exists previous_state_score smallint,
  add column if not exists state_score_change smallint;

alter table public.market_state_current
  drop constraint if exists market_state_current_previous_score_check,
  add constraint market_state_current_previous_score_check
    check (previous_state_score is null or previous_state_score between 0 and 100),
  drop constraint if exists market_state_current_score_change_check,
  add constraint market_state_current_score_change_check
    check (state_score_change is null or state_score_change between -100 and 100);

alter table public.market_state_history
  drop constraint if exists market_state_history_previous_score_check,
  add constraint market_state_history_previous_score_check
    check (previous_state_score is null or previous_state_score between 0 and 100),
  drop constraint if exists market_state_history_score_change_check,
  add constraint market_state_history_score_change_check
    check (state_score_change is null or state_score_change between -100 and 100);

with ranked as (
  select symbol_id, timeframe, candle_close_time, scoring_version,
         lag(state_score) over (
           partition by symbol_id, timeframe, scoring_version
           order by candle_close_time
         ) as previous_score
  from public.market_state_history
)
update public.market_state_history h
set previous_state_score = r.previous_score,
    state_score_change = case when r.previous_score is null then null else h.state_score - r.previous_score end
from ranked r
where r.symbol_id = h.symbol_id
  and r.timeframe = h.timeframe
  and r.candle_close_time = h.candle_close_time
  and r.scoring_version = h.scoring_version;

with previous as (
  select c.symbol_id, c.timeframe, p.state_score as previous_score
  from public.market_state_current c
  left join lateral (
    select h.state_score
    from public.market_state_history h
    where h.symbol_id = c.symbol_id
      and h.timeframe = c.timeframe
      and h.scoring_version = c.scoring_version
      and h.candle_close_time < c.candle_close_time
    order by h.candle_close_time desc
    limit 1
  ) p on true
)
update public.market_state_current c
set previous_state_score = p.previous_score,
    state_score_change = case when p.previous_score is null then null else c.state_score - p.previous_score end
from previous p
where p.symbol_id = c.symbol_id and p.timeframe = c.timeframe;

-- Freeze state at a scenario/trade decision so historical screens never use
-- today's state to judge yesterday's entry.
alter table public.signal_journey_events
  add column if not exists market_state text,
  add column if not exists market_state_score smallint,
  add column if not exists market_state_change smallint;

alter table public.signal_journey_events
  drop constraint if exists signal_journey_events_market_state_check,
  add constraint signal_journey_events_market_state_check check (
    market_state is null or market_state in (
      'neutral', 'selling_dominant', 'seller_impact_fading',
      'buy_side_absorption', 'bounce_attempt', 'bullish_confirmation',
      'breakdown_risk'
    )
  );

update public.signal_journey_events e
set market_state = h.state,
    market_state_score = h.state_score,
    market_state_change = h.state_score_change
from public.market_state_history h
where h.symbol_id = e.symbol_id
  and h.timeframe = e.timeframe
  and h.candle_close_time = e.candle_close_time
  and e.market_state is null;

create or replace function public.record_signal_journey_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_market_state text;
  v_market_state_score smallint;
  v_market_state_change smallint;
begin
  if tg_op = 'UPDATE'
    and old.status is not distinct from new.status
    and old.journey_id is not distinct from new.journey_id then
    return new;
  end if;

  select m.state, m.state_score, m.state_score_change
    into v_market_state, v_market_state_score, v_market_state_change
  from public.market_state_current m
  where m.symbol_id = new.symbol_id and m.timeframe = new.timeframe;

  insert into public.signal_journey_events(
    analysis_model_id, journey_id, breakout_signal_id, symbol_id, timeframe,
    status, candle_close_time, price, breakout_level, confidence,
    false_breakout_risk, volume_ratio,
    regime_score, readiness_score, breakout_quality_score,
    confirmation_score, relative_strength_score, relative_strength_raw,
    breakout_triggered, scoring_version, quote_volume_24h,
    trend_score, trend_entry,
    market_state, market_state_score, market_state_change
  ) values (
    new.analysis_model_id, new.journey_id, new.id, new.symbol_id, new.timeframe,
    new.status, new.candle_close_time, new.signal_price, new.breakout_level,
    new.breakout_confidence_score, new.false_breakout_risk, new.volume_ratio,
    new.regime_score, new.readiness_score, new.breakout_quality_score,
    new.confirmation_score, new.relative_strength_score, new.relative_strength_raw,
    new.breakout_triggered, new.scoring_version,
    (select s.quote_volume_24h from public.symbols s where s.id = new.symbol_id),
    new.trend_score, new.trend_entry,
    v_market_state, v_market_state_score, v_market_state_change
  )
  on conflict (breakout_signal_id, journey_id, status, candle_close_time) do nothing;
  return new;
end;
$$;

-- Notification preferences now name current states. Old phase and A+ filters
-- are reset so a control that disappeared cannot silently suppress alerts.
alter table public.profiles
  add column if not exists notification_market_states text[] not null default array[
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

update public.profiles
set aplus_entries_only = false,
    notification_statuses = array['pre_breakout','breakout_detected','confirmed','failed']::text[];

-- Notification copy names the state in the title, then keeps current strength
-- and close-to-close change visibly separate in the body.
create or replace function public.breakout_notification_text(
  p_breakout_signal_id uuid,
  p_user_id uuid,
  p_signal_status text
)
returns table (title text, body text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_base_asset text;
  v_volume numeric;
  v_language text;
  v_state text;
  v_score integer;
  v_change integer;
  v_state_text text;
  v_strength_text text;
  v_change_text text;
begin
  select s.base_asset, coalesce(s.quote_volume_24h, 0),
         m.state, m.state_score, m.state_score_change
    into v_base_asset, v_volume, v_state, v_score, v_change
  from public.breakout_signals bs
  join public.symbols s on s.id = bs.symbol_id
  left join public.market_state_current m
    on m.symbol_id = bs.symbol_id and m.timeframe = bs.timeframe
  where bs.id = p_breakout_signal_id;

  if v_base_asset is null then return; end if;

  select coalesce(p.preferred_language, 'tr') into v_language
  from public.profiles p where p.id = p_user_id;
  v_language := coalesce(v_language, 'tr');

  v_state_text := case v_state
    when 'neutral' then case when v_language = 'tr' then 'Nötr' else 'Neutral' end
    when 'selling_dominant' then case when v_language = 'tr' then 'Satış baskın' else 'Selling dominant' end
    when 'seller_impact_fading' then case when v_language = 'tr' then 'Satıcı etkisi zayıflıyor' else 'Seller impact fading' end
    when 'buy_side_absorption' then case when v_language = 'tr' then 'Alıcı absorpsiyonu' else 'Buy-side absorption' end
    when 'bounce_attempt' then case when v_language = 'tr' then 'Tepki denemesi' else 'Bounce attempt' end
    when 'bullish_confirmation' then case when v_language = 'tr' then 'Yukarı yönlü teyit' else 'Bullish confirmation' end
    when 'breakdown_risk' then case when v_language = 'tr' then 'Aşağı kırılım riski' else 'Breakdown risk' end
    else case when v_language = 'tr' then 'Durum güncelleniyor' else 'State updating' end
  end;

  v_strength_text := case
    when v_state = 'neutral' then case when v_language = 'tr' then 'Aktif durum yok' else 'No active state' end
    when v_score is null then case when v_language = 'tr' then 'Güç ölçülüyor' else 'Strength updating' end
    else case when v_language = 'tr' then 'Güç ' else 'Strength ' end || v_score || '/100'
  end;
  v_change_text := case
    when v_change is null then case when v_language = 'tr' then 'İlk ölçüm' else 'First reading' end
    when v_change = 0 then case when v_language = 'tr' then 'Değişim yok' else 'No change' end
    else (case when v_language = 'tr' then 'Değişim ' else 'Change ' end)
      || case when v_change > 0 then '+' else '' end || v_change
  end;

  title := v_base_asset || ' · ' || v_state_text;
  body := v_strength_text || ' · ' || v_change_text || ' · '
    || case when v_language = 'tr' then '24s hacim ' else '24h volume ' end
    || public.format_usd_compact(v_volume);
  return next;
end;
$$;

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
      and new.false_breakout_risk <= p.maximum_false_breakout_risk
      and coalesce(new.volume_ratio, 0) >= p.minimum_volume_ratio
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

-- The auto trader consumes the same entry-state rule as the Scenario page.
alter table public.trade_config
  add column if not exists allowed_market_states text[] not null
    default array['bullish_confirmation']::text[];

alter table public.trade_config
  drop constraint if exists trade_config_allowed_market_states_check,
  add constraint trade_config_allowed_market_states_check check (
    cardinality(allowed_market_states) > 0 and allowed_market_states <@ array[
      'neutral', 'selling_dominant', 'seller_impact_fading',
      'buy_side_absorption', 'bounce_attempt', 'bullish_confirmation',
      'breakdown_risk'
    ]::text[]
  );

update public.trade_config
set require_trend_entry = false,
    minimum_trend_score = 0,
    allowed_market_states = array['bullish_confirmation']::text[];

alter table public.live_trades
  add column if not exists entry_market_state text,
  add column if not exists entry_market_state_score smallint,
  add column if not exists entry_market_state_change smallint;

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

-- Leaderboard rows include each predictor's three newest votes so Overview can
-- show what they are watching without issuing ten extra client queries.
create or replace function public.get_top_predictors_with_recent_votes(
  p_limit integer default 10
)
returns table (
  user_id uuid,
  display_name text,
  avatar_key text,
  resolved_count integer,
  correct_count integer,
  accuracy integer,
  skill numeric,
  recent_votes jsonb
)
language sql
stable
security definer
set search_path = public
as $$
select
  a.user_id,
  coalesce(nullif(p.display_name, ''), 'Trendyssey') as display_name,
  p.avatar_key,
  a.resolved_count::integer,
  a.correct_count::integer,
  round(100.0 * a.correct_count / a.resolved_count)::integer as accuracy,
  round((
    (a.correct_count::numeric / a.resolved_count + 1.9208 / a.resolved_count
      - 1.96 * sqrt((a.correct_count::numeric / a.resolved_count)
        * (1 - a.correct_count::numeric / a.resolved_count) / a.resolved_count
        + 0.9604 / (a.resolved_count * a.resolved_count)))
    / (1 + 3.8416 / a.resolved_count)
  ) * 100, 1) as skill,
  coalesce((
    select jsonb_agg(jsonb_build_object(
      'symbol', recent.symbol,
      'timeframe', recent.timeframe,
      'prediction', recent.prediction,
      'predicted_at', recent.predicted_at
    ) order by recent.predicted_at desc)
    from (
      select sp.symbol, sp.timeframe, sp.prediction, sp.predicted_at
      from public.signal_predictions sp
      where sp.user_id = a.user_id
      order by sp.predicted_at desc
      limit 3
    ) recent
  ), '[]'::jsonb) as recent_votes
from public.prediction_accuracy a
join public.profiles p on p.id = a.user_id
where a.resolved_count >= 5
order by skill desc, a.resolved_count desc
limit greatest(1, least(coalesce(p_limit, 10), 50));
$$;

revoke all on function public.get_top_predictors_with_recent_votes(integer) from public;
grant execute on function public.get_top_predictors_with_recent_votes(integer) to authenticated;

commit;
