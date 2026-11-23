#!/usr/bin/env bash
# A card whose agent has gone is taken by the next agent that asks.
#
# take_winner writes takers/<sha256(message-id)> once and never removes it, so
# without a lease the first taker holds the card for the life of the mailbox.
# With an engine reachable the hold expires and the work moves on by itself.
#
# Both outcomes are asserted. An engine is optional, so a checkout with none
# must still behave exactly as it did before, and that is the arm this runs in
# CI. Which arm ran is printed.
set -Eeuo pipefail
# shellcheck source=test-lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/test-lib.sh"
export SNO_REACH_ROOT="$STATE" PATH="$APP/vendor/bin:$PATH"

# Short enough that the test can wait the hold out. Nothing renews a hold yet,
# so the default is sized for a card being worked, not for a test.
export REACH_LEASE_TTL_MS=4000
lease_wait=6

# 69 is reach-lease saying it found no SDK and no engine. Any other answer,
# won or refused, means one answered.
engine=no
if [[ -x "$APP/lib/reach-lease" ]]; then
    probe_rc=0
    "$APP/lib/reach-lease" "departed-taker-probe-$$" probe >/dev/null 2>&1 || probe_rc=$?
    [[ "$probe_rc" == 69 ]] || engine=yes
fi
printf 'engine reachable: %s\n' "$engine"

participants
report="keeper.reports@$HOST"
initialize "$report" Reports
register "$report"

id="departed-taker@$HOST"
card "$id" "$SENDER" "$RECEIVER" decision departed "Reply-To: Reports <$report>" |
    sed "s/^To:.*/To: Worker <$RECEIVER>, Observer <$OTHER>/" >"$WORK/card"
reach send --as "$SENDER" --no-ring <"$WORK/card"
held="$(message_path "$RECEIVER" "$id")"
spare="$(message_path "$OTHER" "$id")"

printf '%s\n' 'accepted' |
    reach reply --as "$RECEIVER" --card "$held" --state accepted >/dev/null
pass 'the worker took the card'

# The worker goes. Nothing it was holding will ever be released by it.
reach unregister --as "$RECEIVER" >"$WORK/gone" 2>&1 || true
[[ ! -f "$STATE/$RECEIVER/reachable.json" ]] ||
    fail 'the worker is still registered; this test cannot say it departed'
pass 'the worker departed'

sleep "${REACH_LEASE_WAIT_SECS:-$lease_wait}"
invoke reply --as "$OTHER" --card "$spare" --state accepted <<<accepted
if [[ "$engine" == yes ]]; then
    expect_rc 0
    pass 'a departed taker releases the card'
else
    expect_rc 75
    has "$WORK/err" "taken by $RECEIVER"
    pass 'without an engine the card stays held, as it does today'
fi
