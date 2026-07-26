-- Notification body reads the confidence out of 100 with labeled compact
-- volume and labeled price:
--
--   Confidence 60/100 · Vol. $4.13M · Price $0.001812
--   Güven 60/100 · Hacim $4.13M · Fiyat $0.001812
--
-- Replaces the "78/100 · 24h volume ..." wording. Only the body line changes;
-- titles, phase names and the formatting helpers stay as they are. The mirror
-- in functions/_shared/notification-text.ts must match — its tests lock this
-- exact string.

begin;

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
    v_price numeric;
    v_confidence integer;
    v_slug text;
    v_status text;
    v_language text;
    v_bearish boolean;
    v_phase text;
begin
    select s.base_asset,
           coalesce(s.quote_volume_24h, 0),
           coalesce(bs.signal_price, s.current_price, 0),
           coalesce(bs.breakout_confidence_score, 0),
           am.slug,
           coalesce(p_signal_status, bs.status)
      into v_base_asset, v_volume, v_price, v_confidence, v_slug, v_status
      from public.breakout_signals bs
      join public.symbols s on s.id = bs.symbol_id
      left join public.analysis_models am on am.id = bs.analysis_model_id
     where bs.id = p_breakout_signal_id;

    if v_base_asset is null then
        return;
    end if;

    select coalesce(pr.preferred_language, 'tr') into v_language
      from public.profiles pr where pr.id = p_user_id;
    v_language := coalesce(v_language, 'tr');
    v_bearish := v_slug = 'double-top-v1';

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
        when 'retest' then
            case when v_language = 'tr' then 'Seviye test ediliyor' else 'Level being tested' end
        when 'failed' then
            case when v_language = 'tr' then 'Sinyal geçersiz oldu' else 'Signal invalidated' end
        when 'expired' then
            case when v_language = 'tr' then 'Takip tamamlandı' else 'Tracking complete' end
        else coalesce(v_status, '')
    end;

    title := v_base_asset || ' · ' || v_phase;
    body := case when v_language = 'tr'
        then 'Güven ' || v_confidence || '/100 · Hacim '
             || public.format_usd_compact(v_volume) || ' · Fiyat ' || public.format_usd_price(v_price)
        else 'Confidence ' || v_confidence || '/100 · Vol. '
             || public.format_usd_compact(v_volume) || ' · Price ' || public.format_usd_price(v_price)
    end;
    return next;
end;
$$;

-- Rewrite alerts already in the table so the in-app list shows the new wording.
-- Pushes already delivered on a device cannot be changed.
update public.notifications n
set title = t.title,
    body = t.body
from (
    select source.id, composed.title, composed.body
      from public.notifications source
      cross join lateral public.breakout_notification_text(
          source.breakout_signal_id, source.user_id, source.signal_status
      ) as composed
     where source.notification_type = 'breakout_signal'
       and source.breakout_signal_id is not null
) as t
where n.id = t.id;

commit;

-- Verify:
-- select title, body from public.notifications
--  where notification_type = 'breakout_signal' order by created_at desc limit 5;
