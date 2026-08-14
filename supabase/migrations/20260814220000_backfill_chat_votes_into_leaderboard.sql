-- Chat votes now score on the same leaderboard as the daily game, so the calls
-- already cast in the chat need their daily_predictions row.
--
-- Entry price is the first closed 15m price at or after the vote — the same
-- price the scorer uses to resolve a call, so a backfilled row is scored on
-- exactly the terms it would have had. A coin outside the scanned universe has
-- no such close; it falls back to the symbol's current price, and a vote with
-- neither is left out rather than scored against an invented number.
--
-- Every breakout signal is direction 'up': "holds" means the coin rises.

begin;

insert into public.daily_predictions (
  user_id, symbol_id, prediction_day, direction, entry_price,
  predicted_at, evaluation_ends_at
)
select p.user_id,
       s.id,
       p.prediction_day,
       case when p.prediction = 'holds' then 'up' else 'down' end,
       coalesce(
         (select h.close_price
            from public.market_state_history h
           where h.symbol_id = s.id
             and h.timeframe = '15m'
             and h.candle_close_time >= p.predicted_at
             and h.close_price > 0
           order by h.candle_close_time asc
           limit 1),
         nullif(s.current_price, 0)
       ),
       p.predicted_at,
       p.predicted_at + interval '24 hours'
from public.signal_predictions p
join public.symbols s on s.symbol = p.symbol
join public.profiles pr on pr.id = p.user_id
-- Only the current UTC day. 15m history does not reach further back, so an
-- older vote would be stamped with today's price as its entry — a call dated
-- last week priced this morning. Those stay in the chat's own accuracy view.
where p.prediction_day = (timezone('UTC', now()))::date
  and coalesce(
        (select h.close_price
           from public.market_state_history h
          where h.symbol_id = s.id
            and h.timeframe = '15m'
            and h.candle_close_time >= p.predicted_at
            and h.close_price > 0
          order by h.candle_close_time asc
          limit 1),
        nullif(s.current_price, 0)
      ) > 0
on conflict (user_id, symbol_id, prediction_day) do nothing;

commit;
