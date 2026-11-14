---
name: polish
description: Review-and-fix loop that removes over-engineering from unpushed commits, or from existing code under a path. Use when the nahuya push gate blocks a push or the user asks to de-bloat a branch or a codebase.
argument-hint: "[all | folder | base..tip]  default: commits waiting to be pushed"
allowed-tools: Bash(nahuya *)
---

# nahuya polish

Run review rounds over unreviewed commits. In each round a fresh reviewer
subagent proposes findings, and you verify each one against the code, then apply
or reject it. Two mistakes are equally easy here. You can reject a sound finding
because the code is yours, or apply an unsound one because that is less work than
arguing. Either decision needs your own evidence.

If the argument is `all` (the whole repo) or a folder rather than a range,
follow **Existing code** at the end instead of Setup and Rounds.

## Setup

1. If the gate blocked a command, make sure what that command was going to commit
   is committed.
2. Run:

       nahuya status --defaults 'threshold=${user_config.threshold} max_rounds=${user_config.max_rounds} reviewer_model=${user_config.reviewer_model} fix_mode=${user_config.fix_mode} shard_lines=${user_config.shard_lines} max_agents=${user_config.max_agents}' $ARGUMENTS

   It prints the range, the effective settings, `head_pushed`, the check command,
   the ledger path, and any files with uncommitted changes (`uncommitted=`).
   Findings in those files go to the report and are not applied.
3. Write `requested`: the user's own words for this work from the conversation,
   quoted without commentary. If several requests apply, quote each one.
4. Run the check once (the `check` command, or the project's usual tests or build
   for the touched code), and note the result as the baseline.

## Rounds

For k = 1 … max_rounds:

1. Run `nahuya diff --round k` (for round 1, append $ARGUMENTS). It writes this
   round's diff and prints its path. Add `--full` if the previous round returned
   10 findings.
2. Launch a fresh `nahuya:reviewer`. Never resume an earlier one. Pass `model`
   unless reviewer_model is `inherit`. Give it `mode: review`, `round: k`, the diff
   path, the ledger path, and `requested`, and nothing else. It is useful because
   it hasn't seen your reasoning.
3. For each finding, read the code and repeat the decisive search yourself. Then
   decide:
   - **apply** it if your own search confirms it. Keep behavior identical, and
     update the callers, tests and docs that reference what changed.
   - **reject** it if it doesn't hold. Back the rejection with evidence: a
     file:line that uses the code, a test that needs it, or the quoted request it
     serves. "Might be useful later" isn't evidence.
   - mark it **needs-context** if you can neither confirm nor refute it, or if the
     reviewer marked it that way. Leave the code as it is.

   Record each decision with
   `nahuya log <k> <applied|rejected|needs-context> <category> "<id>" "<change or reason>"`.
4. Check whether you rejected any `confidence: high` finding on evidence other than
   a user request. If so, write each one verbatim, with your rejection and
   evidence, to `disputes-r<k>.md` next to the ledger. Then launch one fresh
   reviewer with `mode: judge`, the disputes path and `requested`. Act on its
   verdicts and log them:
   - `apply`: apply the finding.
   - `keep-code`: the finding stays rejected.
   - `needs-context`: put it in the report.
5. Run the check. A failure that wasn't in the baseline came from this round's
   edits. Revert the edit responsible and log it as rejected with
   `broke check: <what failed>`.
6. Stop early if this round applied nothing, if an edit would undo an earlier
   round's edit, or if the remaining findings only re-argue earlier fixes.

## Finish

If no round returned a findings block, report that the review failed and leave
the push blocked.

Otherwise, persist the edits according to fix_mode:
- `commit`: commit only the files you edited, with a message that describes the
  simplification. Leave nahuya out of the message so it reads like any other
  cleanup commit.
- `amend`: if `head_pushed` is no, run `git commit --amend --no-edit -- <files>`.
  Otherwise commit instead, and say why.
- `uncommitted`: leave the edits in the working tree, and don't push.

Then run `nahuya mark` as a command of its own. If a blocked push started this
loop and fix_mode isn't `uncommitted`, run the push again as a separate command:
just the push, not the whole original command. The gate checks a whole command
line before any part of it runs, so `nahuya mark && git push` is still blocked.

Report briefly, using these sections:
- **applied**: `location — what changed`
- **rejected**: `location — reason`
- **overturned by judge**: any findings the judge reversed
- **needs-context**: what needs the user's decision, and what would settle it
- the number of rounds run, and whether max_rounds cut the loop short

## Existing code

1. Run `nahuya shards --defaults 'shard_lines=${user_config.shard_lines} max_agents=${user_config.max_agents}' <all|folder>`
   plus any flags from the arguments (`--top N`, `--skip K`, `--fit N`,
   `--max-lines N`). It splits the code into shards of whole files, ranked by
   over-engineering signals, and prints them with `shards_total`, `max_agents`
   and `est_tokens`.

   Check the budget before launching any reviewer. The budget is `max_agents`
   minus 2, which leaves room for round 2 and a possible judge. If the selected
   shards fit, or the arguments already include `--top`, `--skip`, `--fit` or
   `--max-lines`, go ahead. Otherwise don't start: run the same command with
   `--fit <budget>` to learn the shard size that would fit, then ask the user to
   choose, with the numbers:
   - **Most suspicious first:** `--top <budget>`. The rest can follow later with
     `--skip <budget>`.
   - **Bigger shards:** `--fit <budget>`, at the size you just learned. Above
     roughly 6000 lines per shard, attention per file drops.
   - **Everything:** all `shards_total` shards, about `est_tokens` tokens plus
     verification. Say plainly that this is expensive.
   - **A narrower folder.**

   Once settled, run the command with their choice and `--loop`; that starts the
   ledger for this run.
2. Run the `nahuya status --defaults '...'` command from Setup step 2 without
   the trailing argument, for the settings and check command. Use the ledger
   path that `shards` printed. Then do Setup steps 3–4. `requested` is the user's words for
   this run.
3. Round 1 goes shard by shard. For each shard, launch a fresh `nahuya:reviewer`
   with `mode: review`, `round: 1`, `files: <shard path>`, the ledger path and
   `requested`. You may launch the next shard's reviewer while you verify the
   current one. Verify, apply, log and run the judge exactly as in Rounds steps
   3–5, finishing each shard before moving to the next, so edits never overlap.
   Log with round `1`.
4. Rounds 2 and later work as in Rounds, using `nahuya diff --round k`, which
   covers the fixes made so far.
5. Finish as above, except: never push, and run `nahuya mark --keep-anchor`
   instead of `nahuya mark`, because this reviewed existing code rather than the
   commits waiting to be pushed.
