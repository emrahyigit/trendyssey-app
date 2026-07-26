-- Why a push arrives long after the move it describes.
--
-- Run this in the SQL Editor. It runs as the owner, so it sees the queue rows
-- that row-level security hides from the app's key.
--
-- A breakout alert has four timestamps, and the gap between any two of them is a
-- different bug:
--
--   candle_close_time  the market moved
--   notifications.created_at   the row was written  → gap here means the DETECTION job is late
--   notification_queue.available_at  the push became due → gap here means it was SCHEDULED late
--   notification_queue.claimed_at    the worker picked it up → gap here means the WORKER is behind
--
-- Read the last three columns: whichever one is large is the stage at fault.

select
    s.base_asset,
    am.slug                                as model,
    bs.timeframe,
    n.signal_status,
    bs.signal_time                         as moved_at,
    n.created_at                           as recorded_at,
    q.available_at,
    q.claimed_at,
    q.status                               as queue_status,
    round(extract(epoch from (n.created_at - bs.signal_time)) / 60)   as detection_lag_min,
    round(extract(epoch from (q.available_at - n.created_at)) / 60)   as schedule_lag_min,
    round(extract(epoch from (q.claimed_at - q.available_at)) / 60)   as worker_lag_min
  from public.notifications n
  join public.breakout_signals bs on bs.id = n.breakout_signal_id
  join public.symbols s on s.id = bs.symbol_id
  left join public.analysis_models am on am.id = bs.analysis_model_id
  left join public.notification_queue q on q.notification_id = n.id
 where n.notification_type = 'breakout_signal'
   and n.created_at > now() - interval '2 days'
 order by n.created_at desc
 limit 50;


-- How stale were the alerts sent in the last day, per model? A healthy detection
-- job keeps p50 under one candle of the timeframe it scans.
select
    am.slug as model,
    bs.timeframe,
    count(*) as alerts,
    round(percentile_cont(0.5) within group (
        order by extract(epoch from (n.created_at - bs.signal_time)) / 60
    )) as median_lag_min,
    round(max(extract(epoch from (n.created_at - bs.signal_time)) / 60)) as worst_lag_min
  from public.notifications n
  join public.breakout_signals bs on bs.id = n.breakout_signal_id
  left join public.analysis_models am on am.id = bs.analysis_model_id
 where n.notification_type = 'breakout_signal'
   and n.created_at > now() - interval '1 day'
 group by am.slug, bs.timeframe
 order by median_lag_min desc nulls last;


-- Is there a backlog? Anything pending and long overdue means the worker that
-- calls claim_notification_jobs() is not keeping up — and every one of those,
-- when it finally fires, is a push about a move that already happened.
select
    status,
    count(*) as jobs,
    min(available_at) as oldest_due,
    round(extract(epoch from (now() - min(available_at))) / 60) as oldest_overdue_min
  from public.notification_queue
 group by status
 order by jobs desc;


-- The exact wording currently stored, to confirm whether the formatting
-- migration has been applied. If these still read "Risk" or "3.2x", then
-- 20260725_format_breakout_notifications.sql has not run.
select title, body, created_at
  from public.notifications
 where notification_type = 'breakout_signal'
 order by created_at desc
 limit 5;
