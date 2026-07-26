-- Forces the wording of breakout push notifications.
--
-- The lock-screen text is whatever sits in notifications.title / notifications.body.
-- The app only renders those two columns, so it cannot correct them; and the job
-- that writes them lives outside this repository, so it cannot be patched from
-- here either. A BEFORE INSERT trigger sidesteps both: whatever inserts the row,
-- the text is composed here.
--
-- The wording carries exactly three things:
--   * the confidence score out of 100
--   * 24-hour volume in DOLLARS, not a multiple of the previous candle
--   * the price, in dollars
-- False-breakout risk is deliberately absent.
--
-- Double Top is a bearish model, so its phases read as a breakdown. Language
-- follows profiles.preferred_language and falls back to Turkish.

begin;

-- 1234567890 -> $1.23B
create or replace function public.format_usd_compact(value numeric)
returns text
language plpgsql
immutable
as $$
declare
    v_scaled numeric;
    v_suffix text;
begin
    if value is null or value <= 0 then
        return '$0';
    elsif value >= 1e12 then
        v_scaled := value / 1e12; v_suffix := 'T';
    elsif value >= 1e9 then
        v_scaled := value / 1e9; v_suffix := 'B';
    elsif value >= 1e6 then
        v_scaled := value / 1e6; v_suffix := 'M';
    elsif value >= 1e3 then
        v_scaled := value / 1e3; v_suffix := 'K';
    else
        return '$' || to_char(round(value), 'FM999999990');
    end if;

    return '$' || to_char(
        round(v_scaled, case when v_scaled >= 100 then 0 when v_scaled >= 10 then 1 else 2 end),
        case when v_scaled >= 100 then 'FM990' when v_scaled >= 10 then 'FM990.0' else 'FM990.00' end
    ) || v_suffix;
end;
$$;

create or replace function public.format_usd_price(value numeric)
returns text
language sql
immutable
as $$
    select '$' || case
        when value is null then '0'
        when value >= 1000 then to_char(value, 'FM999999999990.00')
        when value >= 1 then rtrim(rtrim(to_char(value, 'FM9990.0000'), '0'), '.')
        else rtrim(rtrim(to_char(value, 'FM0.000000'), '0'), '.')
    end;
$$;

-- Shared by the trigger and the backfill, so both always agree.
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
        then 'Güven puanı ' || v_confidence || '/100 · 24s hacim '
             || public.format_usd_compact(v_volume) || ' · ' || public.format_usd_price(v_price)
        else 'Confidence ' || v_confidence || '/100 · 24h volume '
             || public.format_usd_compact(v_volume) || ' · ' || public.format_usd_price(v_price)
    end;
    return next;
end;
$$;

create or replace function public.format_breakout_notification()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_text record;
begin
    if new.notification_type is distinct from 'breakout_signal'
       or new.breakout_signal_id is null then
        return new;
    end if;

    select * into v_text
      from public.breakout_notification_text(new.breakout_signal_id, new.user_id, new.signal_status);

    -- Nothing to describe: keep whatever the caller wrote rather than blanking it.
    if v_text.title is null then
        return new;
    end if;

    new.title := v_text.title;
    new.body := v_text.body;
    return new;
end;
$$;

drop trigger if exists format_breakout_notification on public.notifications;
create trigger format_breakout_notification
    before insert on public.notifications
    for each row
    execute function public.format_breakout_notification();

-- Rewrite alerts already in the table so the in-app list stops showing the old
-- wording. Pushes already delivered cannot be changed.
-- The lateral has to sit inside its own subquery: an UPDATE cannot reference its
-- own target table from the FROM clause.
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
