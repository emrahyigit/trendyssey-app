-- Phase 0 + 2: make journey records self-healing, and give the app one row to read.
--
-- Two problems this closes:
--
--   1. The detection job records "what changed since I last looked". A missed run
--      loses that transition permanently and invisibly — the app derives the same
--      transition from candles and shows it, the server never has it, and screens
--      that read the server silently disagree with screens that compute.
--
--      The fix is an idempotency key. Once a job can re-derive a whole window and
--      upsert without creating duplicates, a missed run costs nothing: the next
--      run rebuilds the same truth.
--
--   2. Lists in the app had to analyse dozens of coins on the device to know the
--      current phase. `journey_state` holds exactly one row per
--      (symbol, model, timeframe), maintained by a trigger, so any producer —
--      the existing EMA job or the pattern job — keeps it current for free.
--
-- Safe to run more than once.

begin;

-- ---------------------------------------------------------------------------
-- 1. Idempotency key on the event log
-- ---------------------------------------------------------------------------

-- A unique index cannot be created while duplicates exist. Collapse them first,
-- keeping the row that was recorded first so created_at stays meaningful.
do $$
declare
    v_removed integer;
begin
    with ranked as (
        select id,
               row_number() over (
                   partition by symbol_id, analysis_model_id, timeframe, status, candle_close_time
                   order by created_at, id
               ) as position
          from public.signal_journey_events
    )
    delete from public.signal_journey_events e
     using ranked
     where e.id = ranked.id and ranked.position > 1;
    get diagnostics v_removed = row_count;
    if v_removed > 0 then
        raise notice 'signal_journey_events: removed % duplicate row(s) before adding the unique key', v_removed;
    end if;
end $$;

create unique index if not exists signal_journey_events_identity_key
    on public.signal_journey_events
    (symbol_id, analysis_model_id, timeframe, status, candle_close_time);

-- ---------------------------------------------------------------------------
-- 2. Recording an event must not force a push
-- ---------------------------------------------------------------------------

-- A reconciling job re-derives whole windows, so it writes transitions that
-- closed hours ago. Those belong in the record but must never reach a device:
-- an alert about a move the user already missed is worse than no alert.
-- Producers set this to false for anything that is not fresh, and whatever
-- creates notification rows filters on it.
alter table public.signal_journey_events
    add column if not exists notifiable boolean not null default true;

comment on column public.signal_journey_events.notifiable is
    'False for transitions recorded after the fact (backfill or a wide reconciliation window). Notification producers must skip these.';

-- ---------------------------------------------------------------------------
-- 3. Current state, one row per symbol/model/timeframe
-- ---------------------------------------------------------------------------

create table if not exists public.journey_state (
    symbol_id uuid not null references public.symbols (id) on delete cascade,
    analysis_model_id uuid not null references public.analysis_models (id) on delete cascade,
    timeframe text not null,
    status text not null,
    confidence integer not null default 0,
    false_breakout_risk integer,
    volume_ratio numeric,
    price numeric,
    candle_close_time timestamptz not null,
    updated_at timestamptz not null default now(),
    primary key (symbol_id, analysis_model_id, timeframe)
);

create index if not exists journey_state_lookup_idx
    on public.journey_state (analysis_model_id, timeframe, status);

alter table public.journey_state enable row level security;

-- Same read rule the app already relies on elsewhere: signed-in users may read.
drop policy if exists journey_state_read on public.journey_state;
create policy journey_state_read on public.journey_state
    for select to authenticated using (true);

-- Maintained by trigger rather than by each producer, so the existing EMA job
-- keeps it current without being modified.
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
        candle_close_time, updated_at
    )
    values (
        new.symbol_id, new.analysis_model_id, new.timeframe, new.status,
        coalesce(new.confidence, 0), new.false_breakout_risk, new.volume_ratio, new.price,
        new.candle_close_time, now()
    )
    on conflict (symbol_id, analysis_model_id, timeframe) do update
    set status = excluded.status,
        confidence = excluded.confidence,
        false_breakout_risk = excluded.false_breakout_risk,
        volume_ratio = excluded.volume_ratio,
        price = excluded.price,
        candle_close_time = excluded.candle_close_time,
        updated_at = now()
    -- Backfill writes old transitions after newer ones. Without this guard a
    -- reconciliation pass would drag the current phase backwards in time.
    where public.journey_state.candle_close_time <= excluded.candle_close_time;
    return new;
end;
$$;

drop trigger if exists sync_journey_state on public.signal_journey_events;
create trigger sync_journey_state
    after insert on public.signal_journey_events
    for each row
    execute function public.sync_journey_state();

-- Seed from what is already recorded: the newest transition per combination.
insert into public.journey_state (
    symbol_id, analysis_model_id, timeframe, status,
    confidence, false_breakout_risk, volume_ratio, price, candle_close_time
)
select distinct on (symbol_id, analysis_model_id, timeframe)
       symbol_id, analysis_model_id, timeframe, status,
       coalesce(confidence, 0), false_breakout_risk, volume_ratio, price, candle_close_time
  from public.signal_journey_events
 order by symbol_id, analysis_model_id, timeframe, candle_close_time desc, created_at desc
on conflict (symbol_id, analysis_model_id, timeframe) do update
set status = excluded.status,
    confidence = excluded.confidence,
    false_breakout_risk = excluded.false_breakout_risk,
    volume_ratio = excluded.volume_ratio,
    price = excluded.price,
    candle_close_time = excluded.candle_close_time,
    updated_at = now()
where public.journey_state.candle_close_time <= excluded.candle_close_time;

commit;

-- Verify:
-- select am.slug, js.timeframe, js.status, count(*)
--   from public.journey_state js
--   join public.analysis_models am on am.id = js.analysis_model_id
--  group by 1, 2, 3 order by 1, 2, 3;
