begin;

-- The push used to read relative_strength_score, which refresh_relative_
-- strength() only recomputes at the END of a scan — while the notification
-- trigger fires DURING the scan's row writes. Every push therefore carried
-- the previous cycle's percentile and disagreed with the score the app showed
-- moments later. Both the push body and the strength filter now rank the
-- signal's just-written raw scalar against the freshest raw per symbol at
-- composition time, mirroring refresh_relative_strength()'s percent_rank
-- (count of strictly smaller values over N−1).

create or replace function public.live_signal_strength(p_breakout_signal_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
with target as (
  select bs.timeframe, bs.relative_strength_raw
    from public.breakout_signals bs
   where bs.id = p_breakout_signal_id
),
fresh as (
  select distinct on (bs.symbol_id) bs.relative_strength_raw
    from public.breakout_signals bs
    join target t on bs.timeframe = t.timeframe
   where bs.relative_strength_raw is not null
     and bs.candle_close_time >= now() - (case t.timeframe
           when '15m' then interval '2 hours'
           when '1h' then interval '8 hours'
           when '4h' then interval '1 day'
           else interval '4 days'
         end)
   order by bs.symbol_id, bs.candle_close_time desc
)
select case
  when (select relative_strength_raw from target) is null then null
  else round(
    100.0 * (select count(*) from fresh
              where relative_strength_raw < (select relative_strength_raw from target))
    / greatest((select count(*) from fresh) - 1, 1)
  )::integer
end;
$$;

revoke all on function public.live_signal_strength(uuid) from public;

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
  v_strength integer;
  v_volume numeric;
  v_status text;
  v_language text;
  v_bearish boolean;
  v_phase text;
  v_strength_text text;
begin
  select s.base_asset,
         coalesce(s.quote_volume_24h, 0),
         coalesce(p_signal_status, bs.status),
         coalesce(bs.direction = 'down' or am.slug = 'double-top-v1', false)
    into v_base_asset, v_volume, v_status, v_bearish
    from public.breakout_signals bs
    join public.symbols s on s.id = bs.symbol_id
    left join public.analysis_models am on am.id = bs.analysis_model_id
   where bs.id = p_breakout_signal_id;

  if v_base_asset is null then return; end if;

  v_strength := public.live_signal_strength(p_breakout_signal_id);

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
        then case when v_bearish then 'Düşüş güçleniyor' else 'Kırılım güçleniyor' end
        else case when v_bearish then 'Breakdown strengthening' else 'Breakout strengthening' end end
    when 'failed' then case when v_language = 'tr' then 'Sinyal geçersiz oldu' else 'Signal invalidated' end
    when 'expired' then case when v_language = 'tr' then 'Takip tamamlandı' else 'Tracking complete' end
    else coalesce(v_status, '')
  end;

  v_strength_text := case
    when v_strength is null then
      case when v_language = 'tr'
        then 'Sinyal gücü henüz ölçülmedi'
        else 'Signal strength not yet measured' end
    else
      case when v_language = 'tr'
        then 'Sinyal gücü ' || v_strength || '/100'
        else 'Signal strength ' || v_strength || '/100' end
  end;

  title := v_base_asset || ' · ' || v_phase;
  body := case when v_language = 'tr'
    then v_strength_text || ' · 24s hacim ' || public.format_usd_compact(v_volume)
    else v_strength_text || ' · 24h volume ' || public.format_usd_compact(v_volume)
  end;
  return next;
end;
$$;

-- The filter uses the same live value the body prints, so a user's minimum
-- never lets through a push whose visible score sits below it.
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
  live_strength integer;
begin
  success_rate := public.symbol_success_rate(new.analysis_model_id, new.symbol_id, new.timeframe);
  live_strength := public.live_signal_strength(new.id);

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
      -- Unmeasured strength passes: a coin is not silenced for missing data.
      and coalesce(live_strength, 100) >= p.minimum_signal_strength
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

commit;
