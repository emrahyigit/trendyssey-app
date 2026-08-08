begin;

-- Push filtering gains the coin's 30-day breakout track record: users can
-- silence coins whose breakouts mostly invalidate. Same fate rules as
-- get_symbol_journey_stats; coins with fewer than 4 recorded breakouts always
-- pass, matching the app's "missing data is not guilt" stance.

alter table public.profiles
  add column if not exists minimum_success_rate smallint not null default 0;

alter table public.profiles
  add constraint profiles_minimum_success_rate_range
    check (minimum_success_rate between 0 and 100) not valid;

create or replace function public.symbol_success_rate(
  p_model_id uuid,
  p_symbol_id uuid,
  p_timeframe text
) returns integer
language sql
stable
security definer
set search_path = public
as $$
with started as (
  select journey_id, min(candle_close_time) as started_at
  from public.signal_journey_events
  where analysis_model_id = p_model_id
    and symbol_id = p_symbol_id
    and timeframe = p_timeframe
    and status = 'breakout_detected'
    and candle_close_time >= now() - interval '30 days'
  group by journey_id
),
fates as (
  select s.journey_id,
         bool_or(e.status = 'failed') as ever_failed
  from started s
  left join public.signal_journey_events e
    on e.journey_id = s.journey_id
   and e.symbol_id = p_symbol_id
   and e.analysis_model_id = p_model_id
   and e.candle_close_time >= s.started_at
  group by s.journey_id
)
-- Null when the sample is too small to judge; callers treat null as "pass".
select case
  when count(*) < 4 then null
  else round(100.0 * count(*) filter (where not ever_failed) / count(*))::integer
end
from fates;
$$;

revoke all on function public.symbol_success_rate(uuid, uuid, text) from public;

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
  success_rate integer;
begin
  -- One computation per signal event, shared by every matched user.
  success_rate := public.symbol_success_rate(new.analysis_model_id, new.symbol_id, new.timeframe);

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
      and coalesce(new.relative_strength_score, 100) >= p.minimum_signal_strength
      and coalesce(success_rate, 100) >= p.minimum_success_rate
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
