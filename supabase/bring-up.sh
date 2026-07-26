#!/usr/bin/env bash
#
# Brings the whole server pipeline up in one command.
#
# Everything here runs through the Supabase CLI's browser session: no
# service-role key and no access token is typed or stored. It does not push
# migrations — that step needs the database password, and every migration here
# has already been applied through the SQL Editor.
#
#   bash supabase/bring-up.sh            # deploy, seed candles, dry-run only
#   bash supabase/bring-up.sh --write    # ...and then write for real
#   bash supabase/bring-up.sh --check    # verify prerequisites, change nothing
#
# Run it with `bash <path>` from the repository root. Typing just the filename
# gives "command not found" — the shell only searches PATH for bare names.
#
# Safe to run again: migrations, candle upserts and journey upserts are all
# idempotent, so a second run changes nothing that a first run already did.

set -euo pipefail

PROJECT_REF="desdaealmbjnbokmvnsn"
TIMEFRAMES="15m,30m,1h,2h,4h,6h,1d"
SEED_LIMIT=500
WRITE=0
CHECK_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --write) WRITE=1; shift ;;
        --check) CHECK_ONLY=1; shift ;;
        --timeframes) TIMEFRAMES="$2"; shift 2 ;;
        --seed-limit) SEED_LIMIT="$2"; shift 2 ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")/.."

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

to_json_array() {
    printf '%s' "$1" | awk -F, '{
        printf "["
        for (i = 1; i <= NF; i++) printf "%s\"%s\"", (i > 1 ? "," : ""), $i
        printf "]"
    }'
}

TF_JSON="$(to_json_array "$TIMEFRAMES")"

# ---------------------------------------------------------------------------

step "Checking the CLI"
# Homebrew's bin is missing from some non-login shells (Xcode's terminal, cron),
# which is the usual reason this reads "command not found".
SUPABASE_BIN=""
for candidate in supabase /opt/homebrew/bin/supabase /usr/local/bin/supabase "$HOME/.local/bin/supabase"; do
    if command -v "$candidate" >/dev/null 2>&1; then SUPABASE_BIN="$candidate"; break; fi
done
[[ -n "$SUPABASE_BIN" ]] || fail \
    "supabase CLI not found. Install it with: brew install supabase/tap/supabase"
supabase() { command "$SUPABASE_BIN" "$@"; }
echo "using $SUPABASE_BIN ($(supabase --version 2>/dev/null || echo '?'))"

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    if supabase projects list >/dev/null 2>&1; then
        echo "signed in: yes"
    else
        echo "signed in: no — the real run will open a browser to sign you in"
    fi
    echo "timeframes: $TIMEFRAMES"
    echo
    echo "Prerequisites look fine. Nothing was changed."
    exit 0
fi

if ! supabase projects list >/dev/null 2>&1; then
    echo "Not signed in. A browser window will open — no key is typed anywhere."
    supabase login
fi

if [[ ! -f supabase/.temp/project-ref ]] && ! supabase status >/dev/null 2>&1; then
    step "Linking the project"
    supabase link --project-ref "$PROJECT_REF"
fi

# Migrations are deliberately NOT pushed here.
#
# `supabase db push` opens a direct Postgres connection and asks for the database
# password, which contradicts the promise at the top of this file — and it is not
# needed anyway: every migration in this repository has already been applied
# through the SQL Editor. Run ./supabase/status.sh to confirm that, or push them
# yourself if you prefer the CLI:
#
#   supabase db push        # will prompt for the database password
#
step "Skipping migrations (already applied — see status.sh)"

step "Deploying functions"
supabase functions deploy sync-candles
supabase functions deploy derive-journeys

step "Seeding the candle store (timeframes: $TIMEFRAMES, $SEED_LIMIT candles each)"
# The deep sweep only matters the first time; later runs append what is missing.
supabase functions invoke sync-candles \
    --body "{\"timeframes\": $TF_JSON, \"limit\": $SEED_LIMIT}"

step "Reconciling journeys — DRY RUN, nothing is written"
supabase functions invoke derive-journeys --body "{\"timeframes\": $TF_JSON}"

cat <<'NOTE'

Read the dry run above before going further:

  seriesWithoutCandlesCount   should be near zero. If it is high, the candle
                              store did not fill — re-run the seed step and
                              check the sync-candles output for failures.
  ofWhichNotifiable           how many transitions are fresh enough to alert on.
                              Everything else is recorded silently.
NOTE

if [[ "$WRITE" -eq 0 ]]; then
    cat <<'NOTE'

Nothing was written. When the numbers above look right, run again with --write.
NOTE
    exit 0
fi

step "Reconciling journeys — WRITING"
supabase functions invoke derive-journeys \
    --body "{\"timeframes\": $TF_JSON, \"dryRun\": false}"

step "Done"
cat <<'NOTE'
Two things are still manual, and both are one-time:

  1. Schedule sync-candles and derive-journeys with pg_cron. See the schedules
     in supabase/functions/sync-candles/index.ts.

  2. Add `and notifiable` to whatever query creates notification rows. Without
     it, the first reconciliation pass will alert on every transition it
     recovers from history.
NOTE
