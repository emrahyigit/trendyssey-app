begin;

-- Trend Score remains stored for internal validation and historical analysis,
-- but it is no longer a product-facing notification or trading threshold.
update public.profiles
set minimum_signal_strength = 0
where minimum_signal_strength <> 0;

update public.trade_config
set minimum_trend_score = 0
where minimum_trend_score <> 0;

-- Lock-screen copy now leads with the named current market state. The signal
-- phase remains in the title; the body adds state context and liquidity.
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
  v_status text;
  v_language text;
  v_bearish boolean;
  v_phase text;
  v_state text;
  v_state_text text;
begin
  select s.base_asset,
         coalesce(s.quote_volume_24h, 0),
         coalesce(p_signal_status, bs.status),
         coalesce(bs.direction = 'down' or am.slug = 'double-top-v1', false),
         msc.state
    into v_base_asset, v_volume, v_status, v_bearish, v_state
    from public.breakout_signals bs
    join public.symbols s on s.id = bs.symbol_id
    left join public.analysis_models am on am.id = bs.analysis_model_id
    left join public.market_state_current msc
      on msc.symbol_id = bs.symbol_id and msc.timeframe = bs.timeframe
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
        then case when v_bearish then 'Düşüş tuttu' else 'Kırılım tuttu' end
        else case when v_bearish then 'Breakdown held' else 'Breakout held' end end
    when 'failed' then case when v_language = 'tr' then 'Sinyal geçersiz oldu' else 'Signal invalidated' end
    when 'expired' then case when v_language = 'tr' then 'Takip tamamlandı' else 'Tracking complete' end
    else coalesce(v_status, '')
  end;

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

  title := v_base_asset || ' · ' || v_phase;
  body := case when v_language = 'tr'
    then 'Durum: ' || v_state_text || ' · 24s hacim ' || public.format_usd_compact(v_volume)
    else 'State: ' || v_state_text || ' · 24h volume ' || public.format_usd_compact(v_volume)
  end;
  return next;
end;
$$;

-- Existing score thresholds cannot silently suppress notifications after the
-- control disappears from the app. A+ and volume remain explicit filters.
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
