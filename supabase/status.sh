#!/usr/bin/env bash
#
# Reports what is actually deployed, using only the publishable key — the same
# key that already ships inside the app. Nothing here is a secret, so this can be
# run by anyone, at any time, including from a chat session.
#
#   ./supabase/status.sh
#
# It answers "did that migration actually land" without anyone having to open the
# dashboard and paste a query.

set -uo pipefail

URL="https://desdaealmbjnbokmvnsn.supabase.co/rest/v1"
KEY="sb_publishable_yTZk4Y6lY44v8KP3noCN7g_FfUkZpEX"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

table_exists() {
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$URL/$1?select=*&limit=1" -H "apikey: $KEY")
    [[ "$code" == "200" ]]
}

column_exists() {
    ! curl -s "$URL/$1?select=$2&limit=1" -H "apikey: $KEY" | grep -q "does not exist\|Could not find"
}

head_ "Tables"
for t in candles journey_state signal_journey_events breakout_signals notifications notification_queue; do
    table_exists "$t" && ok "$t" || bad "$t is missing"
done

head_ "Columns added by migrations"
column_exists signal_journey_events notifiable \
    && ok "signal_journey_events.notifiable" \
    || bad "signal_journey_events.notifiable — 20260726_journey_state.sql has not run"

head_ "Notification wording functions"
# Called with their real signatures: a mismatched call 404s even when the
# function exists, which has caused a false alarm here before.
compact=$(curl -s -X POST "$URL/rpc/format_usd_compact" -H "apikey: $KEY" \
    -H "Content-Type: application/json" -d '{"value": 1234567890}')
if [[ "$compact" == '"$1.23B"' ]]; then
    ok "format_usd_compact -> $compact"
else
    bad "format_usd_compact -> $compact (20260725_format_breakout_notifications.sql has not run)"
fi

price=$(curl -s -X POST "$URL/rpc/format_usd_price" -H "apikey: $KEY" \
    -H "Content-Type: application/json" -d '{"value": 167.42}')
[[ "$price" == '"$167.42"' ]] && ok "format_usd_price -> $price" || bad "format_usd_price -> $price"

head_ "Analysis models"
curl -s "$URL/analysis_models?select=slug,display_name,is_active&order=sort_order.asc" -H "apikey: $KEY" \
  | python3 -c "
import json, sys
try:
    rows = json.load(sys.stdin)
except Exception:
    print('  could not read analysis_models'); sys.exit()
for r in rows:
    mark = '\033[32m✓\033[0m' if r.get('is_active') else '\033[31m✗\033[0m'
    print(f\"  {mark} {r['slug']:<20} {r['display_name']}\")
expected = {'gpt-5-6-sol-v1', 'double-bottom-v1', 'double-top-v1'}
missing = expected - {r['slug'] for r in rows}
if missing:
    print('  \033[31mmissing:\033[0m', ', '.join(sorted(missing)))
"

cat <<'NOTE'

Row counts for candles and journey_state are not readable with this key — their
row-level security allows signed-in users only. Their presence above means the
migrations ran; to see how full they are, run in the SQL Editor:

  select timeframe, count(distinct symbol_id) symbols, count(*) candles,
         max(close_time) newest
    from public.candles group by timeframe order by timeframe;

  select am.slug, js.timeframe, js.status, count(*)
    from public.journey_state js
    join public.analysis_models am on am.id = js.analysis_model_id
   group by 1,2,3 order by 1,2,3;
NOTE
