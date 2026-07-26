-- Phase 1: give the server the same input the app has.
--
-- Today the detection job fetches candles from Binance at the moment it runs, so
-- what it knows is limited to what it happened to see. The app fetches the last
-- 500 candles and derives the whole journey from them, which is why the two
-- disagree. Storing candles removes the asymmetry: both sides read the same
-- history, so the same algorithm has to produce the same answer.
--
-- It also cuts the traffic. Re-fetching 200 candles for 470 symbols across 7
-- timeframes is roughly 90 MB per sweep; appending only the candles that closed
-- since the last sweep is closer to 2 MB.
--
-- Safe to run more than once.

begin;

create table if not exists public.candles (
    symbol_id uuid not null references public.symbols (id) on delete cascade,
    timeframe text not null,
    open_time timestamptz not null,
    close_time timestamptz not null,
    open numeric not null,
    high numeric not null,
    low numeric not null,
    close numeric not null,
    volume numeric not null,
    quote_volume numeric not null,
    primary key (symbol_id, timeframe, open_time)
);

comment on table public.candles is
    'Closed candles only. An open candle would let a phase flip back and forth inside one bar, so writers must exclude it.';

-- The analyzers walk a window forward in time, so this is the access pattern.
create index if not exists candles_series_idx
    on public.candles (symbol_id, timeframe, close_time desc);

alter table public.candles enable row level security;

drop policy if exists candles_read on public.candles;
create policy candles_read on public.candles
    for select to authenticated using (true);

-- How far back each timeframe is kept. The longest analyzer window needs about
-- 130 candles (EMA 99 plus warm-up) and the backtest screens ask for up to 1000,
-- so 1500 leaves room without letting the table grow without bound.
create or replace function public.prune_candles(keep_per_series integer default 1500)
returns integer
language plpgsql
as $$
declare
    v_removed integer;
begin
    with ranked as (
        select symbol_id, timeframe, open_time,
               row_number() over (
                   partition by symbol_id, timeframe order by open_time desc
               ) as position
          from public.candles
    )
    delete from public.candles c
     using ranked r
     where c.symbol_id = r.symbol_id
       and c.timeframe = r.timeframe
       and c.open_time = r.open_time
       and r.position > keep_per_series;
    get diagnostics v_removed = row_count;
    return v_removed;
end;
$$;

commit;

-- Verify after the first sweep:
-- select timeframe, count(distinct symbol_id) as symbols, count(*) as candles,
--        min(close_time) as oldest, max(close_time) as newest
--   from public.candles group by timeframe order by timeframe;
