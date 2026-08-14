begin;

-- Trend score becomes the single headline quality metric. The old
-- "signal strength" (live_signal_strength: the 30-day rate of +1%-holds)
-- measured the old +1%/-5% lifecycle, whose ~88% rates the Aug 2026 backtest
-- showed to be economically near-meaningless (break-even sits at 83.3%).
-- Pushes and the per-user notification threshold now speak trend score;
-- the win-rate RPC retires.

-- 1) Push copy: lead with the signal's live trend score.
--    Same function as 20260809030000 with the strength line replaced.
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
  v_trend integer;
  v_volume numeric;
  v_status text;
  v_language text;
  v_bearish boolean;
  v_phase text;
  v_trend_text text;
begin
  select s.base_asset,
         coalesce(s.quote_volume_24h, 0),
         coalesce(p_signal_status, bs.status),
         coalesce(bs.direction = 'down' or am.slug = 'double-top-v1', false),
         bs.trend_score
    into v_base_asset, v_volume, v_status, v_bearish, v_trend
    from public.breakout_signals bs
    join public.symbols s on s.id = bs.symbol_id
    left join public.analysis_models am on am.id = bs.analysis_model_id
   where bs.id = p_breakout_signal_id;

  if v_base_asset is null then return; end if;

  select coalesce(pr.preferred_language, 'tr') into v_language
    from public.profiles pr where pr.id = p_user_id;
  v_language := coalesce(v_language, 'tr');

  v_phase := case v_status
    when 'pre_breakout' then
      case when v_language = 'tr'
        then case when v_bearish then 'Düşüş bekleniyor' else 'Kırılım bekleniyor' end
        else case when v_bearish then 'Waiting for breakdown' else 'Waiting for breakout' end end
    when 'breakout_detected' then
      case when v_language = 'tr'
        then case when v_bearish then 'Düşüş başladı' else 'Kırılım başladı' end
        else case when v_bearish then 'Breakdown started' else 'Breakout started' end end
    when 'confirmed' then
      case when v_language = 'tr'
        then case when v_bearish then 'Düşüş tuttu (-%1)' else 'Kırılım tuttu (+%1)' end
        else case when v_bearish then 'Breakdown held (-1%)' else 'Breakout held (+1%)' end end
    when 'failed' then case when v_language = 'tr' then 'Sinyal geçersiz oldu' else 'Signal invalidated' end
    when 'expired' then case when v_language = 'tr' then 'Takip tamamlandı' else 'Tracking complete' end
    else coalesce(v_status, '')
  end;

  v_trend_text := case
    when v_trend is null then
      case when v_language = 'tr'
        then 'Trend puanı henüz ölçülmedi'
        else 'Trend score not yet measured' end
    else
      case when v_language = 'tr'
        then 'Trend puanı ' || v_trend || '/100'
        else 'Trend score ' || v_trend || '/100' end
  end;

  title := v_base_asset || ' · ' || v_phase;
  body := case when v_language = 'tr'
    then v_trend_text || ' · 24s hacim ' || public.format_usd_compact(v_volume)
    else v_trend_text || ' · 24h volume ' || public.format_usd_compact(v_volume)
  end;
  return next;
end;
$$;

-- 2) The per-user push threshold now gates on trend score. The profiles
--    column keeps its historical name; the app relabels the setting.
--    Same function as 20260808220000 with the gate switched.
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
  success_rate integer;
begin
  success_rate := public.symbol_success_rate(new.analysis_model_id, new.symbol_id, new.timeframe);

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
      and coalesce(success_rate, 100) >= p.minimum_success_rate
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

-- 3) The win-rate RPC retires with its last two callers gone (push copy
--    above, executor gate removed in the same deploy).
drop function if exists public.live_signal_strength(uuid);

commit;
