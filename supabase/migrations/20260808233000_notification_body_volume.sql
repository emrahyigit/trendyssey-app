begin;

-- Product decision: the push body carries exactly two facts — signal strength
-- and 24h dollar volume. Enough to judge the alert from the lock screen,
-- nothing else.
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
    when 'retest' then case when v_language = 'tr' then 'Seviye test ediliyor' else 'Level being tested' end
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

commit;
