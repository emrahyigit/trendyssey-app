-- Separates breakout detection from scoring and registers the first six active
-- breakout variants. EMA remains available in code as a shared regime/trend
-- feature, but is retired as a user-selectable breakout engine.

begin;

alter table public.analysis_models
  add column if not exists engine_kind text;

update public.analysis_models
   set engine_kind = case slug
     when 'gpt-5-6-sol-v1' then 'ema_cross'
     when 'double-bottom-v1' then 'double_pattern'
     when 'double-top-v1' then 'double_pattern'
     else engine_kind
   end
 where engine_kind is null;

do $$
begin
  if exists (select 1 from public.analysis_models where engine_kind is null) then
    raise exception 'Every analysis model needs an explicit engine_kind before this migration can continue';
  end if;
end $$;

alter table public.analysis_models alter column engine_kind set not null;

alter table public.analysis_models
  drop constraint if exists analysis_models_engine_kind_check;
alter table public.analysis_models
  add constraint analysis_models_engine_kind_check check (
    engine_kind in ('ema_cross', 'donchian', 'horizontal_level', 'consolidation', 'double_pattern')
  );

comment on column public.analysis_models.engine_kind is
  'Explicit scanner implementation. Unknown values fail closed; they never fall back to EMA.';

-- Four scores answer four separate questions. breakout_confidence_score stays
-- during the client transition and mirrors breakout_quality_score.
alter table public.breakout_signals
  add column if not exists regime_score integer not null default 0,
  add column if not exists readiness_score integer not null default 0,
  add column if not exists breakout_quality_score integer not null default 0,
  add column if not exists confirmation_score integer not null default 0,
  add column if not exists breakout_triggered boolean not null default false,
  add column if not exists scoring_version text not null default 'breakout-scores-v1';

alter table public.breakout_signals
  drop constraint if exists breakout_signals_four_scores_check;
alter table public.breakout_signals
  add constraint breakout_signals_four_scores_check check (
    regime_score between 0 and 100 and
    readiness_score between 0 and 100 and
    breakout_quality_score between 0 and 100 and
    confirmation_score between 0 and 100
  );

alter table public.signal_journey_events
  add column if not exists regime_score integer,
  add column if not exists readiness_score integer,
  add column if not exists breakout_quality_score integer,
  add column if not exists confirmation_score integer,
  add column if not exists breakout_triggered boolean,
  add column if not exists scoring_version text;

alter table public.journey_state
  add column if not exists regime_score integer not null default 0,
  add column if not exists readiness_score integer not null default 0,
  add column if not exists breakout_quality_score integer not null default 0,
  add column if not exists confirmation_score integer not null default 0,
  add column if not exists breakout_triggered boolean not null default false,
  add column if not exists scoring_version text not null default 'breakout-scores-v1';

-- Existing rows keep their legacy meaning until the next scan. This makes the
-- migration immediately readable by both old and new clients.
update public.breakout_signals
   set breakout_quality_score = breakout_confidence_score,
       readiness_score = coalesce(nullif(explanation_facts ->> 'setupScore', '')::integer, 0),
       confirmation_score = case status
         when 'confirmed' then breakout_confidence_score
         when 'retest' then least(100, breakout_confidence_score / 2)
         else 0
       end,
       breakout_triggered = status in ('breakout_detected', 'retest', 'confirmed')
 where breakout_quality_score = 0
   and breakout_confidence_score > 0;

-- This is the identity used by the full-window pattern reconciler. The older
-- symbol/model/timeframe identity remains useful, but cannot serve this upsert.
with ranked as (
  select id,
         row_number() over (
           partition by breakout_signal_id, journey_id, status, candle_close_time
           order by created_at, id
         ) as position
    from public.signal_journey_events
)
delete from public.signal_journey_events event
 using ranked
 where event.id = ranked.id and ranked.position > 1;

create unique index if not exists signal_journey_events_journey_identity_key
  on public.signal_journey_events
  (breakout_signal_id, journey_id, status, candle_close_time);

-- Carry event-time scores into the current-state projection. Historical rows
-- that predate this migration fall back to their legacy confidence value.
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
    coalesce(new.breakout_triggered, new.status in ('breakout_detected', 'retest', 'confirmed')),
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

-- Clone a scoring configuration for each new model. analysis_models currently
-- enforces a one-to-one configuration relationship, so variants cannot share
-- the source row even when most defaults are the same.
do $$
declare
  source_config uuid;
  source_row jsonb;
  unique_text_columns text[];
  target record;
  new_config uuid;
  patch jsonb;
  column_name text;
  config_json jsonb;
begin
  select scoring_configuration_id into source_config
    from public.analysis_models where slug = 'gpt-5-6-sol-v1';
  if source_config is null then
    raise exception 'gpt-5-6-sol-v1 needs a scoring configuration before breakout variants can be registered';
  end if;

  select to_jsonb(sc) into source_row
    from public.scoring_configurations sc where sc.id = source_config;

  select coalesce(array_agg(distinct a.attname::text), '{}')
    into unique_text_columns
    from pg_index i
    join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey)
   where i.indrelid = 'public.scoring_configurations'::regclass
     and i.indisunique
     and a.attname <> 'id'
     and a.atttypid in ('text'::regtype, 'varchar'::regtype);

  for target in
    select * from (values
      ('donchian-20-v1', '57000000-0000-4000-8000-000000000001'::uuid, 'Donchian 20',
       'donchian', 20, 10, 'Son 20 tamamlanmış mumun fiyat kanalını kapanışla kıran hareketleri izler.'),
      ('donchian-50-v1', '57000000-0000-4000-8000-000000000002'::uuid, 'Donchian 50',
       'donchian', 50, 20, 'Son 50 tamamlanmış mumun fiyat kanalını kapanışla kıran daha seçici hareketleri izler.'),
      ('horizontal-level-v1', '57000000-0000-4000-8000-000000000003'::uuid, 'Yatay Seviye',
       'horizontal_level', 20, 30, 'ATR toleransıyla kümelenen doğrulanmış pivot tepelerinin üzerindeki kapanışları izler.'),
      ('consolidation-v1', '57000000-0000-4000-8000-000000000004'::uuid, 'Konsolidasyon',
       'consolidation', 20, 40, 'Daralan yirmi mumluk işlem aralığının üst sınırındaki volatilite genişlemesini izler.')
    ) as values_table(slug, model_id, display_name, engine_kind, period, sort_order, description)
  loop
    config_json := coalesce(source_row -> 'configuration', '{}'::jsonb) ||
      jsonb_build_object(
        'model', target.slug,
        'donchianPeriod', target.period,
        'engineKind', target.engine_kind,
        'scoringVersion', 'breakout-scores-v1'
      );

    if exists (select 1 from public.analysis_models where slug = target.slug) then
      update public.analysis_models
         set display_name = target.display_name,
             description = target.description,
             provider = 'Trendyssey',
             authoring_model = 'trendyssey-level-breakout',
             engine_kind = target.engine_kind,
             required_tier = 'pro',
             is_active = true,
             sort_order = target.sort_order,
             updated_at = now()
       where slug = target.slug;

      update public.scoring_configurations sc
         set configuration = config_json
       where sc.id = (select scoring_configuration_id from public.analysis_models where slug = target.slug);
      continue;
    end if;

    new_config := gen_random_uuid();
    patch := jsonb_build_object('id', new_config, 'configuration', config_json);
    foreach column_name in array unique_text_columns loop
      patch := patch || jsonb_build_object(
        column_name,
        coalesce(source_row ->> column_name, 'config') || '-' || target.slug
      );
    end loop;

    insert into public.scoring_configurations
    select (jsonb_populate_record(null::public.scoring_configurations, source_row || patch)).*;

    insert into public.analysis_models (
      id, slug, display_name, provider, authoring_model, version,
      description, required_tier, scoring_configuration_id,
      engine_kind, is_active, is_default, sort_order
    ) values (
      target.model_id, target.slug, target.display_name, 'Trendyssey',
      'trendyssey-level-breakout', 1, target.description, 'pro', new_config,
      target.engine_kind, true, false, target.sort_order
    );
  end loop;
end $$;

-- Six active breakout variants: four level engines plus the two neckline
-- patterns. EMA is retained as implementation and historical data only.
update public.analysis_models
   set is_active = false, is_default = false, updated_at = now()
 where slug = 'gpt-5-6-sol-v1';

update public.analysis_models
   set engine_kind = 'double_pattern',
       sort_order = case slug when 'double-bottom-v1' then 50 else 60 end,
       is_active = true,
       updated_at = now()
 where slug in ('double-bottom-v1', 'double-top-v1');

update public.analysis_models set is_default = false where is_default;
update public.analysis_models
   set is_default = true
 where slug = 'donchian-20-v1';

-- Pushes keep the legacy score column for compatibility, but label its new
-- meaning correctly and prefer the explicit quality column.
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
  v_quality integer;
  v_slug text;
  v_status text;
  v_language text;
  v_bearish boolean;
  v_phase text;
begin
  select s.base_asset,
         coalesce(s.quote_volume_24h, 0),
         coalesce(bs.signal_price, s.current_price, 0),
         coalesce(bs.breakout_quality_score, bs.breakout_confidence_score, 0),
         am.slug,
         coalesce(p_signal_status, bs.status)
    into v_base_asset, v_volume, v_price, v_quality, v_slug, v_status
    from public.breakout_signals bs
    join public.symbols s on s.id = bs.symbol_id
    left join public.analysis_models am on am.id = bs.analysis_model_id
   where bs.id = p_breakout_signal_id;

  if v_base_asset is null then return; end if;

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
    when 'retest' then case when v_language = 'tr' then 'Seviye test ediliyor' else 'Level being tested' end
    when 'failed' then case when v_language = 'tr' then 'Sinyal geçersiz oldu' else 'Signal invalidated' end
    when 'expired' then case when v_language = 'tr' then 'Takip tamamlandı' else 'Tracking complete' end
    else coalesce(v_status, '')
  end;

  title := v_base_asset || ' · ' || v_phase;
  body := case when v_language = 'tr'
    then 'Kırılım kalitesi ' || v_quality || '/100 · 24s hacim '
      || public.format_usd_compact(v_volume) || ' · ' || public.format_usd_price(v_price)
    else 'Breakout quality ' || v_quality || '/100 · 24h volume '
      || public.format_usd_compact(v_volume) || ' · ' || public.format_usd_price(v_price)
  end;
  return next;
end;
$$;

commit;

-- Verify:
-- select slug, engine_kind, is_active, is_default, scoring_configuration_id
-- from public.analysis_models order by sort_order;
