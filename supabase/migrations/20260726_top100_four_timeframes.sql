-- Applied 2026-07-26 (already run against the live project).
--
-- The product now analyzes only the 100 highest-volume USDT pairs on four
-- timeframes (15m, 1h, 4h, 1d), at every candle close. Candles are no longer
-- stored server-side: scan-market fetches them from Binance per run and the
-- app draws charts straight from Binance, so the candle store and its sync
-- pipeline are gone.

-- 1) Reset all derived analysis and notification data.
truncate table
  signal_score_components,
  signal_journey_events,
  signal_outcome_snapshots,
  signal_predictions,
  indicator_snapshots,
  journey_state,
  notification_deliveries,
  notification_queue,
  notifications,
  breakout_signals,
  scan_job_errors,
  scan_jobs
  cascade;

-- 2) The candle store is retired (the sync-candles function is deleted too).
drop table if exists public.candles cascade;

-- 3) Retire the candle-sync crons and every removed-timeframe scan cron.
select cron.unschedule(jobname) from cron.job where jobname in (
  'candles-15m','candles-30m','candles-1h','candles-2h','candles-4h-6h','candles-1d',
  'scan-market-30m','scan-market-2h','scan-market-6h',
  'sweep-15m','sweep-30m','sweep-1h','sweep-2h','sweep-4h','sweep-6h','sweep-1d',
  'scan-market-15m','scan-market-1h','scan-market-4h','scan-market-1d'
);

-- 4) One cron per timeframe, firing right after each candle close. Each run
-- posts all four batch slots in parallel, so the whole 100-coin universe is
-- scanned within the same minute (100 coins x 4 timeframes x 3 models).
-- Minutes are staggered per timeframe: more than ~8 concurrent pg_net posts
-- in the same minute starve its worker into DNS timeouts.
do $do$
declare
  tf record;
  cmd text;
  slot int;
begin
  for tf in
    select * from (values
      ('15m', '1,16,31,46 * * * *'),
      ('1h',  '2 * * * *'),
      ('4h',  '3 */4 * * *'),
      ('1d',  '5 0 * * *')
    ) as t(timeframe, schedule)
  loop
    cmd := '';
    for slot in 0..3 loop
      cmd := cmd || format(
        $$select net.http_post(url := 'https://desdaealmbjnbokmvnsn.supabase.co/functions/v1/scan-market', headers := jsonb_build_object('Content-Type','application/json','x-cron-secret',(select decrypted_secret from vault.decrypted_secrets where name='pulse15_cron_secret')), body := '{"timeframe":"%s","batchSlot":%s}'::jsonb, timeout_milliseconds := 55000); $$,
        tf.timeframe, slot
      );
    end loop;
    perform cron.schedule('scan-market-' || tf.timeframe, tf.schedule, cmd);
  end loop;
end
$do$;
