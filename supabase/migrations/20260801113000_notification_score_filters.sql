begin;

alter table public.profiles
  add column if not exists minimum_regime_score smallint not null default 0,
  add column if not exists minimum_readiness_score smallint not null default 0,
  add column if not exists minimum_breakout_quality_score smallint not null default 70,
  add column if not exists minimum_confirmation_score smallint not null default 0;

update public.profiles
   set minimum_breakout_quality_score = minimum_breakout_score;

alter table public.profiles
  add constraint profiles_minimum_regime_score_range
    check (minimum_regime_score between 0 and 100),
  add constraint profiles_minimum_readiness_score_range
    check (minimum_readiness_score between 0 and 100),
  add constraint profiles_minimum_breakout_quality_score_range
    check (minimum_breakout_quality_score between 0 and 100),
  add constraint profiles_minimum_confirmation_score_range
    check (minimum_confirmation_score between 0 and 100);

-- One localized source of truth for both queued pushes and any later requeue.
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
  v_regime integer;
  v_readiness integer;
  v_quality integer;
  v_confirmation integer;
  v_status text;
  v_language text;
  v_bearish boolean;
  v_phase text;
begin
  select s.base_asset,
         coalesce(bs.regime_score, 0),
         coalesce(bs.readiness_score, 0),
         coalesce(bs.breakout_quality_score, bs.breakout_confidence_score, 0),
         coalesce(bs.confirmation_score, 0),
         coalesce(p_signal_status, bs.status),
         coalesce(bs.direction = 'down' or am.slug = 'double-top-v1', false)
    into v_base_asset, v_regime, v_readiness, v_quality,
         v_confirmation, v_status, v_bearish
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

  title := v_base_asset || ' · ' || v_phase;
  body := case when v_language = 'tr'
    then 'Rejim ' || v_regime || ' · Hazırlık ' || v_readiness
      || ' · Kalite ' || v_quality || ' · Teyit ' || v_confirmation
    else 'Regime ' || v_regime || ' · Ready ' || v_readiness
      || ' · Quality ' || v_quality || ' · Confirm ' || v_confirmation
  end;
  return next;
end;
$$;

-- Every enabled threshold must pass. A zero default keeps later-stage scores
-- from suppressing early alerts unless the user explicitly raises them.
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
    select p.id as user_id
    from public.profiles p
    where p.notifications_enabled
      and p.preferred_analysis_model_id = new.analysis_model_id
      and exists (
        select 1 from public.subscription_entitlements e
        where e.user_id = p.id
          and e.status in ('active', 'grace_period')
          and e.expires_at > now()
      )
      and p.preferred_timeframe = new.timeframe
      and coalesce(new.regime_score, 0) >= p.minimum_regime_score
      and coalesce(new.readiness_score, 0) >= p.minimum_readiness_score
      and coalesce(new.breakout_quality_score, new.breakout_confidence_score, 0)
            >= p.minimum_breakout_quality_score
      and coalesce(new.confirmation_score, 0) >= p.minimum_confirmation_score
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
