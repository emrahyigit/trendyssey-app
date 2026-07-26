# Trendyssey backend

## Where this is going

The app derives journeys from candles; the server records "what changed since I
last looked". A missed run loses a transition permanently, the app still shows it,
and the two disagree — that is the PEPE case, and it is a data-model problem, not
a bug in either side.

The target is one input, one algorithm, one truth: the server stores candles,
re-derives whole windows idempotently, and the app reads the result instead of
computing its own.

| Phase | What | Status |
| --- | --- | --- |
| 0 | Idempotency key, `notifiable` flag, self-healing reconciliation | applied |
| 1 | `candles` table + `sync-candles` job | applied + scheduled (2026-07-26) |
| 2 | `journey_state`, one row per symbol/model/timeframe | applied |
| 3 | WebSocket ingest | not planned |

Applied in order, phases 0–2 are what stop the app and the server from diverging.

**Candle store live since 2026-07-26.** `sync-candles` requires the cron
secret (`x-cron-secret`, deployed with `--no-verify-jwt`) and runs on pg_cron
(`candles-15m` … `candles-1d`), sweeping the top-200 USDT pairs; `scan-market`
also upserts the tail of every candle series it analyzes, so the store can
never lag behind a signal it produced. The iOS `CandleService` reads closed
candles from this store (Binance is used only for the still-forming candle and
as a fallback for unswept coins), which makes the store the single input behind
charts, on-device journeys, scenarios and server-side signals alike.
`derive-journeys` remains unscheduled: scan-market itself writes each pattern
model's full journey history (`notifiable = false`) on every scan.

# Double Bottom / Double Top alerts

**Applied 2026-07-26.** All three models are now interpreted server-side by
`scan-market` (source in `functions/scan-market/`): `gpt-5-6-sol-v1` keeps the
EMA engine (`_shared/indicators.ts` + `_shared/signal_lifecycle.ts`), while
`double-bottom-v1` / `double-top-v1` run `_shared/double-pattern.ts` — the
line-for-line port of the on-device analyzer. Each model writes its own
`breakout_signals` row per symbol/timeframe (patterns use `direction = 'down'`
for Double Top), and the existing triggers turn status transitions into journey
events, outcome snapshots and push notifications. Before this split every
active model row was fed through the EMA engine, which produced identical,
EMA-derived "double pattern" signals; those rows were purged when the split
shipped.

The sections below describe the earlier plan (`detect-double-patterns`,
`derive-journeys` + the candle store). They are kept as the future
single-input architecture; `sync-candles` and `derive-journeys` are deployed
but unscheduled, and the `candles` table is empty.

## What is here

| File | Purpose |
| --- | --- |
| `migrations/20260725_add_double_pattern_models.sql` | Registers `double-bottom-v1` and `double-top-v1` in `analysis_models`. Safe to re-run. |
| `functions/_shared/double-pattern.ts` | Detection and journey state machine, ported line for line from the iOS app. |
| `functions/_shared/double-pattern.test.ts` | Parity fixtures; expected values come from the Swift implementation. |
| `functions/detect-double-patterns/index.ts` | The job: scans symbols, runs both models, records transitions. Dry run by default. |
| `functions/_shared/notification-text.ts` | Composes `notifications.title` / `.body`: confidence score and dollar volume, no risk. |
| `functions/_shared/notification-text.test.ts` | Locks that contract. |
| `migrations/20260726_journey_state.sql` | Phase 0 + 2: idempotency key, `notifiable`, `journey_state` + trigger. |
| `migrations/20260726_candles.sql` | Phase 1: the candle store the server derives from. |
| `functions/sync-candles/index.ts` | Fills the candle store from Binance. Closed candles only. |
| `functions/derive-journeys/index.ts` | Reconciles journeys from stored candles. Replaces `detect-double-patterns`. |
| `diagnose-late-pushes.sql` | Separates detection lag from queue lag when a push arrives late. |

## Bringing the pipeline up

```bash
supabase functions deploy sync-candles
supabase functions deploy derive-journeys
```

**1. Seed the candle store.** The default sweep only appends recent candles, so
ask for a deep one the first time, per timeframe:

```bash
curl -X POST ".../functions/v1/sync-candles" -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" -d '{"timeframes":["1h"],"limit":500}'
```

Check it landed:

```sql
select timeframe, count(distinct symbol_id) as symbols, count(*) as candles,
       max(close_time) as newest
  from public.candles group by timeframe order by timeframe;
```

**2. Dry-run the reconciler.** It writes nothing until asked:

```bash
curl -X POST ".../functions/v1/derive-journeys" -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" -d '{"timeframes":["1h"]}'
```

`seriesWithoutCandles` should be near zero. If it is not, the store is not filled
yet — go back to step 1. Then run it for real with `{"dryRun": false}`.

**3. Schedule both** with pg_cron, `derive-journeys` a few minutes behind
`sync-candles` for the same timeframe.

**4. Filter notifications on `notifiable`.** Whatever creates notification rows
must add `and notifiable` to its query. Without it, a reconciliation pass that
rebuilds history will send an alert for every transition it recovers.

## Pushes arriving late

A push describes a move that already happened hours ago when one of four stages
lags. `diagnose-late-pushes.sql` separates them — run it in the SQL Editor and
read the three lag columns:

| Gap | Meaning |
| --- | --- |
| `detection_lag_min` | the scan found the transition late |
| `schedule_lag_min` | the queue row was made due late |
| `worker_lag_min` | the worker calling `claim_notification_jobs()` is behind |

Whichever is large is the stage at fault. The last query also shows whether a
backlog of pending jobs exists: every overdue job, when it finally fires, is an
alert about a move the user has already missed.

`detect-double-patterns` is not a candidate for this. It only records transitions
from the last two candles of the timeframe it is scanning (`REPLAY_CANDLES`), so
it cannot reach back into old history and raise an alert for it. Its dry run
reports `staleSkipped` — how many older transitions it deliberately ignored.

## Notification wording — apply this one

`migrations/20260725_format_breakout_notifications.sql` is the fix that does not
depend on finding the job. It adds a BEFORE INSERT trigger on `notifications`,
so whatever writes a breakout alert, the text is composed in the database:

```
SOL · Kırılım başladı
Güven puanı 78/100 · 24s hacim $1.23B · $167.42
```

Confidence score, dollar volume, dollar price. No risk, no "3.2x". Language follows
`profiles.preferred_language`; Double Top reads as a breakdown. The migration
also rewrites alerts already in the table, so the in-app list stops showing the
old wording — pushes already delivered on a device cannot be changed.

Verified against a local Postgres 16 rebuilt from the real column names (probed
through PostgREST): the backfill rewrites `Güç 78 · Risk 22 · Hacim 3.2x` into
the wording above, new inserts are composed regardless of what the caller passed,
sub-cent prices keep their precision (`$0.000042`), notifications that are not
breakout alerts are left untouched, and running it twice changes nothing.

### The TypeScript equivalent

`functions/_shared/notification-text.ts` produces the same strings for callers
that would rather compose in the job than rely on the trigger. Use one or the
other; the trigger wins if both run, since it rewrites on insert.

```ts
import { composeNotification } from "../_shared/notification-text.ts";

const { title, body } = composeNotification({
  baseAsset: symbol.base_asset,
  status: event.status,
  confidence: event.confidence,
  quoteVolume24h: symbol.quote_volume_24h,
  price: event.price,
  direction: model.slug === "double-top-v1" ? "bearish" : "bullish",
  language: user.preferred_language === "tr" ? "tr" : "en",
});
```

It produces, for example:

```
SOL · Kırılım başladı
Güven puanı 78/100 · 24s hacim $1.23B · $167.42
```

Volume is the 24-hour figure in dollars, not a ratio against the previous
candle: a multiple says nothing about whether a coin is liquid enough to trade,
while `$1.23B` does. False-breakout risk is deliberately absent, and the tests
fail if either slips back in.

Verified locally: `deno check` passes on all three, and the five parity tests
pass.

## Step 1 — add the model rows

Two ways. The dashboard needs no tooling at all:

**Dashboard (no CLI):** open the project's SQL Editor, paste the contents of
`migrations/20260725_add_double_pattern_models.sql`, run it.

**CLI:**

```bash
supabase login            # opens a browser; no key is typed anywhere
supabase link --project-ref desdaealmbjnbokmvnsn
supabase db push
```

Read the migration first: it reuses the EMA model's `scoring_configuration_id`
so the column stays non-null. If scoring is model-specific in your pipeline,
create dedicated configurations and reference those instead.

Check it worked — all three models should come back:

```sql
select slug, display_name, is_active, sort_order
  from public.analysis_models order by sort_order;
```

### Why `scoring_configuration_id` needs care

That column is both **NOT NULL** and **UNIQUE**
(`analysis_models_scoring_configuration_id_key`). So every model needs a
configuration row of its own: two models cannot share one, and none can go
without. Two earlier versions of this migration got that wrong — one pointed both
new models at the EMA configuration (duplicate key), the next left the column
unset (not-null violation).

The migration now copies the EMA model's configuration once per new model. The
copy never names a column of `scoring_configurations`, because that table is not
readable from outside the database and its shape is unknown here: the row goes
through `to_jsonb` / `jsonb_populate_record`, and any UNIQUE text column is given
a per-copy value so the second insert cannot collide.

The copied weights are only there to satisfy the constraint. These two models
score themselves — on the device, and in `detect-double-patterns`, which writes
`confidence` straight onto each journey event — so nothing reads those copies
today. Tune them if you later route these models through the scoring pipeline.

**Verified before shipping.** The migration was run against a local Postgres 16
rebuilt from your `pg_indexes` output and the column order in the 23502 error,
across four possible shapes of `scoring_configurations` (a UNIQUE `name`, no text
columns at all, two UNIQUE text columns, and a UNIQUE `varchar`). All four end
with three models and three configurations, and running it twice changes nothing.
The single-default partial index stays satisfied.

To see the real state, run this in the SQL Editor — it executes as the owner and
is not filtered by row-level security, unlike the key the app uses:

```sql
select am.slug, am.display_name, am.is_active, am.sort_order, sc.id as config
  from public.analysis_models am
  join public.scoring_configurations sc on sc.id = am.scoring_configuration_id
 order by am.sort_order;
```

## Step 2 — deploy the job

```bash
supabase functions deploy detect-double-patterns
```

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected into deployed
functions automatically. No key belongs in these files.

## Step 3 — dry run first

The function writes nothing unless you ask it to. Run it once and read the
output:

```bash
curl -X POST "https://desdaealmbjnbokmvnsn.supabase.co/functions/v1/detect-double-patterns" \
  -H "Authorization: Bearer $YOUR_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" -d '{}'
```

You get back `wouldInsert`, plus a `sample` of the rows it intends to write.
**Compare that sample against your `signal_journey_events` table before going
further.** This matters: the function was written against the columns the iOS
app reads, which is a partial view of the schema. NOT NULL columns the app never
selects, column defaults, and the `journey_id` lifecycle could not be inspected
from outside, so the insert shape is an informed guess until you confirm it.

Likely adjustments in `insertEvents()`:

- `journey_id` — the EMA pipeline groups events into journeys. If that column is
  NOT NULL, decide whether a new journey starts at each `breakout_detected` and
  populate it.
- `false_breakout_risk` — currently reported as `100 - confidence` rather than
  invented. Replace it if your scoring configuration defines risk separately.
- Any column with no default that the app never reads.

## Step 4 — enable writes, then schedule

```bash
curl -X POST ".../functions/v1/detect-double-patterns" \
  -H "Authorization: Bearer $YOUR_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" -d '{"dryRun": false}'
```

Re-runs are idempotent: existing transitions are filtered out before inserting.
Once a real run looks right, schedule it next to the EMA detection job (pg_cron
every 5 minutes is a reasonable start).

From there the existing notification pipeline does the rest — it already filters
by the user's `analysisModelSlug`, timeframe and selected stages, so alerts start
flowing as soon as the events exist. The app already sends the selected model's
slug, so no client change is needed.

## Two things that will bite if missed

- **Closed candles only.** The job filters unclosed candles already. Passing one
  lets a phase flip back and forth inside the same bar, which would send an alert
  and then contradict it.
- **Double Top is bearish.** Its breakout completes *downward*. Anything that
  assumes a rising move — target prices, "held above breakout" flags, return and
  outcome calculations in `signal_outcome_snapshots` — has to be mirrored for it,
  or the model is scored as wrong every time it is right.

## Keeping the two implementations in step

The app scores these models on the device; the backend scores them for alerts. If
the rules drift, a user gets a push that disagrees with the app when they open it.
`double-pattern.test.ts` locks the shared behaviour and the same fixtures exist on
the Swift side — change one, run both.

The slugs in the migration must match `JourneyModel.serverSlug` in
`Trendyssey/Domain/Models/JourneyAnalysis.swift`. If they do not, the app quietly
falls back to the EMA model.

The port leaves out the higher-timeframe confluence factor, worth up to 10 of the
app's 100 points: it needs a second candle series. Add it where the backend
already fetches those, or expect server scores a few points below the app's.
