begin;

-- The retest lifecycle phase is retired everywhere. The single-EMA engine
-- never emits it; the only rows that ever carried it came from a 15-minute
-- window of an intermediate deployment on 2026-08-08. Notification defaults,
-- user selections, the push text and the state projection all drop it, and
-- the orphan rows are deleted.

alter table public.profiles
  alter column notification_statuses
    set default array['pre_breakout', 'breakout_detected', 'confirmed'];

update public.profiles
   set notification_statuses = array_remove(notification_statuses, 'retest')
 where 'retest' = any(notification_statuses);

delete from public.signal_journey_events where status = 'retest';
delete from public.journey_state where status = 'retest';
update public.breakout_signals set status = 'watching' where status = 'retest';

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
         bs.relative_strength_score,
         coalesce(s.quote_volume_24h, 0),
         coalesce(p_signal_status, bs.status),
         coalesce(bs.direction = 'down' or am.slug = 'double-top-v1', false)
    into v_base_asset, v_strength, v_volume, v_status, v_bearish
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

create or replace function public.sync_journey_state()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.journey_state (
    symbol_id, analysis_model_id, timeframe, status,
    confidence, false_breakout_risk, volume_ratio, price,
    candle_close_time, updated_at,
    regime_score, readiness_score, breakout_quality_score,
    confirmation_score, breakout_triggered, scoring_version
  ) values (
    new.symbol_id, new.analysis_model_id, new.timeframe, new.status,
    coalesce(new.confidence, 0), new.false_breakout_risk, new.volume_ratio, new.price,
    new.candle_close_time, now(),
    coalesce(new.regime_score, 0), coalesce(new.readiness_score, 0),
    coalesce(new.breakout_quality_score, new.confidence, 0),
    coalesce(new.confirmation_score, 0),
    coalesce(new.breakout_triggered, new.status in ('breakout_detected', 'confirmed')),
    coalesce(new.scoring_version, 'legacy')
  )
  on conflict (symbol_id, analysis_model_id, timeframe) do update
  set status = excluded.status,
      confidence = excluded.confidence,
      false_breakout_risk = excluded.false_breakout_risk,
      volume_ratio = excluded.volume_ratio,
      price = excluded.price,
      candle_close_time = excluded.candle_close_time,
      regime_score = excluded.regime_score,
      readiness_score = excluded.readiness_score,
      breakout_quality_score = excluded.breakout_quality_score,
      confirmation_score = excluded.confirmation_score,
      breakout_triggered = excluded.breakout_triggered,
      scoring_version = excluded.scoring_version,
      updated_at = now()
  where public.journey_state.candle_close_time <= excluded.candle_close_time;
  return new;
end;
$$;

commit;
