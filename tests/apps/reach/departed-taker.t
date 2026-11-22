#!/usr/bin/env bash
# A card whose agent has gone is taken by the next agent that asks.
#
# take_winner writes takers/<sha256(message-id)> once and never removes it, so
# without a lease the first taker holds the card for the life of the mailbox.
# With an engine reachable the hold expires and the work moves on by itself.
set -Eeuo pipefail
# shellcheck source=test-lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/test-lib.sh"
export SNO_REACH_ROOT="$STATE" PATH="$APP/vendor/bin:$PATH"
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

# Its hold lapses, and the card is taken by whoever asks next.
sleep "${REACH_LEASE_WAIT_SECS:-7}"
invoke reply --as "$OTHER" --card "$spare" --state accepted <<<accepted
expect_rc 0
pass 'a departed taker releases the card'
