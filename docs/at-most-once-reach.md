# Ownership in reach, and what this lease covers

Written against `539db2cd` while building the `take_winner` lease in this PR.
Every claim below is a line you can open. Where a mechanism could not be found
in source it says so rather than guessing.

The shape of all of it: reach is careful about **doing** work and has less to say
about **who owns** a piece of work and for how long.

## 1. A taker file is permanent, so a dead agent keeps its card

`take_winner` (`apps/reach/lib/reach-main:2973`) creates
`takers/<sha256(message-id)>` with an `O_EXCL` create. Nothing in either tree
removes it. The first taker therefore holds the card for the life of the
mailbox, including after its process is gone.

`packages/memory/config/agent-state.ts` already works this out and then stops:

```ts
650  const exited = !registered && rows.every(row => row.process === "exited");
651  if (!exited && (age === "unknown" || age <= 900)) continue;
653  view.stuck.push({ card: "unknown", holder, reason: exited ? "agent process exited" : "silent", ... });
```

The consumers of `view.stuck` are a text view (`:843`) and the
`N stuck: sno squad` status line (`:953`). Searching that file for `reclaim`,
`takeover`, `steal` or `reassign` returns nothing. The resolution is a person
deleting the file.

**What this PR does about it.** The hold becomes a lease, so it lapses when
nobody renews it and the next agent to ask gets the card. `agent-state` and
`read_taker` are untouched.

## 2. The send path has no ownership at all

The only `flock` on the path guards the rate-limit counter, not the send.
`preflight_send_rate_limit` (`:1413`) acquires at `:1456` and releases at
`:1532`, which is the last thing it does before returning. The send happens
after that, through:

```
queue_and_attempt_message      :2025
  ├─ stage_message_in_outbox   :1957   writes the outbox entry
  └─ attempt_outbox_entry      :2013
        └─ process_outbox_entry :1817  no flock in its body
              └─ reach-deliver         no flock anywhere in the file
```

Two runs both pass the quota, both release, and both deliver.

Worth separating, because it is the more interesting half: `stage_message_in_outbox`
writes a durable entry *before* the attempt, so the intent survives a crash.
What the outbox has no notion of is **identity**. Each run stages its own entry,
so two runs are two entries and two deliveries. The durability half is built.
The deduplication half is not.

## 3. There is no key two runs would both derive

Even a dedupe on `Message-ID` would not catch it. `send` validates the id rather
than minting it (`:1514`, "could not read validated Message-ID for send rate
limit"), so identity comes from whatever builds the card. The one place reach
mints an id, `apps/reach/lib/reach-call:174`, uses `date -u '+%s%N'`:

```bash
message_id="<agent-window-...-${state}-$(date -u '+%s%N')@localhost>"
```

Two runs building the same logical message produce two different ids, so they
derive two different keys and every guard sees two unrelated operations.

## 4. Ownership is hand-rolled three times, on three surfaces

| where | mechanism |
| :--- | :--- |
| `apps/reach/lib/reach-pickup` | `flock` at `:37`, claim at `:80` |
| `apps/reach/lib/reach-main` | one taker in `take_winner`, commit `cbf6eea` |
| `apps/heartbeat/bin/heartbeat` | `owner_id():132`, `pid_is_heartbeat():155`, `reap_dead_claims():181` |

Each is correct for its own surface. Sends are the fourth surface and have none.

A note on something **not** included here: the `wake-attempts` records carrying
`state_owner` and `bound_seconds` look like a fourth mechanism, but those fields
appear only in test files in this checkout. Whatever writes them lives
elsewhere, so this document makes no claim about them.

## 5. Liveness and ownership are split between two mechanisms

`apps/heartbeat/bin/heartbeat:22` states the consequence in its own header:

> MANY AGENTS, NO LOCK. [...] Two agents may both run `card-B` and never see
> each other; one agent may not run `card-B` twice.

So heartbeat gives liveness without ownership, and `take_winner` gives ownership
without liveness. Each is deliberate and each is right on its own. The cases
that hurt are the ones needing both at once: a holder that is alive and should
keep its claim, and a holder that is gone and should lose it. Telling those two
apart is what a lease is, which is why this PR makes the taker one.

## Scheduled runs

`heartbeat` already derives a stable identity for a task:

```bash
383  due_lock() { printf '%s/due/%s.lock' "$STATE_ROOT" "$(registry_key "$1"$'\n'"$2")"; }
     registry_key() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }
```

`sha256(record + "\n" + action)`, taken non-blocking at `:598` and held by the
detached runner at `:629` until the agent exits. It is an `flock`, so it is
released when the process dies and records nothing afterwards: mutual exclusion
while the run is alive, no memory of whether the work happened.

A run started outside `--due-tick` never takes it.
