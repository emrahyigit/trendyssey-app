-- A push fires only when a signal actually changes phase.
--
-- The matcher trigger used to fire on any update touching status, scores,
-- volume or candle_close_time. Since the scanner rewrites the row every visit
-- with a fresh candle_close_time — and the dedup key includes that timestamp —
-- a coin sitting in breakout_detected re-notified on every new candle:
-- "Breakout started" arrived again long after the move began.
--
-- Split the trigger: INSERT still notifies (a brand-new signal row), UPDATE
-- notifies only when the status is genuinely different from before.

begin;

drop trigger if exists breakout_signal_notification_matcher on public.breakout_signals;

create trigger breakout_signal_notification_matcher_insert
    after insert on public.breakout_signals
    for each row
    execute function public.enqueue_matching_signal_notifications();

create trigger breakout_signal_notification_matcher_update
    after update on public.breakout_signals
    for each row
    when (old.status is distinct from new.status)
    execute function public.enqueue_matching_signal_notifications();

commit;
