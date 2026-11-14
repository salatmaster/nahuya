---
name: polish
description: Review-and-fix loop that removes over-engineering and bloat from unpushed commits, or from existing code under a path. Use when the nahuya push gate blocks a push or the user asks to de-bloat a branch or a codebase.
argument-hint: "[tests] [all | folder | base..tip]  default: commits waiting to be pushed"
allowed-tools: Bash(nahuya *)
---

# nahuya polish

Run review rounds. In each round a fresh reviewer subagent proposes findings,
and you verify each one against the code, then apply or reject it. Two mistakes
are equally easy here. You can reject a sound finding because the code is yours,
or apply an unsound one because that is less work than arguing. Either decision
needs your own evidence.

If the argument is `all` (the whole repo) or a folder rather than a range,
follow **Existing code** at the end instead of Setup and Rounds.

**Tests only.** If the first argument is `tests` (`tests`, `tests all`,
`tests src/`, `tests main..HEAD`), drop it and run the same flow on test code
only:
- add `--only-tests` to every `nahuya diff`, `inventory`, `shards` and `clones`
  command;
- give every reviewer `only_tests: yes`;
- ask only whether to clean duplicates (`--tests`) or also remove worthless
  tests (`--prune-tests`), unless the arguments already say;
- with no further argument, cover the tests in the commits waiting to be
  pushed. Skip the "nothing to polish" stop in Setup step 2; stop only if
  round 1's diff has no files;
- finish with `nahuya mark --keep-anchor`, since production code wasn't
  reviewed, and push only if the user asked.

## Setup

1. If the gate blocked a command, make sure what that command was going to commit
   is committed.
2. Run `nahuya status $ARGUMENTS`. It prints the range, the unreviewed line
   count, the effective settings, `head_pushed`, the check command, the ledger
   path, and any files with uncommitted changes (`uncommitted=`). Findings in
   those files go to the report and are not applied.

   If there is no argument and `unreviewed_added_lines` is 0, there is nothing
   to polish. Tell the user, suggest `/nahuya:polish all` or a folder for
   existing code, and stop.
3. Write `requested`: the user's own words for this work from the conversation,
   quoted without commentary. If several requests apply, quote each one.
4. Run the check once (the `check` command, or the project's usual tests or build
   for the touched code), and note the result as the baseline.

The reviewer's `depth` is the `depth` setting; `auto` means `normal` here.

## Rounds

For k = 1 … max_rounds:

1. Run `nahuya diff --round k` (for round 1, append $ARGUMENTS). It writes this
   round's diff and prints its path. Add `--full` if the previous round hit the
   findings cap.
2. Launch a fresh `nahuya:reviewer`. Never resume an earlier one. Pass `model`
   unless reviewer_model is `inherit`. Give it `mode: review`, `round: k`,
   `depth`, the diff path, the ledger path, and `requested`, and nothing else. It
   is useful because it hasn't seen your reasoning.
3. A `lost-behavior` finding means an earlier fix of this run dropped
   something. If it holds, restore the behavior, by reverting that edit if
   needed, before anything else. For every other finding, read the code and
   repeat the decisive search yourself. Then decide:
   - **apply** it if your own search confirms it. Keep behavior identical, and
     update the callers, tests and docs that reference what changed. Code you
     merge or move keeps its error handling and validation, and the result must
     read at a glance. If shortening it makes it cryptic, keep it longer.
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
- **behavior changed**: every applied change that intentionally doesn't keep
  behavior identical, for example a merge of drifted copies where one version
  won. Say what behaves differently now.
- **rejected**: `location — reason`
- **overturned by judge**: any findings the judge reversed
- **needs-context**: what needs the user's decision, and what would settle it
- the number of rounds run, and whether max_rounds cut the loop short

## Existing code

The user asked for a cleanup of code that already ships. The reviewer's `depth`
is `deep` unless the `depth` setting is `normal`.

1. **Map.** Run `nahuya inventory <all|folder>` plus `--tests`, `--no-tests` or
   `--with-nonprod` from the arguments. It shows directories with files, lines,
   tests, over-engineering signals and build manifests, the folders it skipped
   as non-production, and where to write the plan. If the total fits in
   `shard-lines`, skip planning: run `nahuya shards <target>` and go to step 3.
2. **Plan logical components.** Skim the README and the entry points (main,
   routes, handlers, jobs, CLI commands) to see the real flows. Then group the
   code by what it does: a feature, a service, a layer, a package. Code that does similar jobs belongs together even
   when it lives in different directories, because that is where duplication
   hides. Aim for about `shard-lines` per component and at most twice that; look
   inside big areas with `nahuya inventory <target> --files <dir>` and split them.
   Put the components most likely to be over-engineered or bloated first. Put
   code you'd leave out (one-off research, examples or generated code the filters
   missed) under a `## skip — <reason>` component. Write the plan to the path
   `inventory` printed:

       ## liquidation — both liquidators share one skeleton
       src/liq/
       src/firm/liquidator.rs
       ## web api
       src/web/
       ## skip — one-off research scripts
       research/

   A path claims everything under it, and the longest matching path wins. Run
   `nahuya shards <target> --plan <plan> <flags>` and fix the plan until it
   reports no `unassigned` lines.
3. **Ask once, only what is open.** Put the open questions in one message:
   - **Tests:** unless the arguments say `--no-tests`, `--tests` or
     `--prune-tests`, and the inventory shows tests, ask how to treat them:
     - **leave them alone** (`--no-tests`);
     - **clean duplicates and copy-pasted setup** (`--tests`);
     - **also remove worthless tests** (`--prune-tests`). These are tests that
       pass no matter how the code breaks: no real assertion, checking a mock,
       restating the type system, or disabled for good. Regression, money,
       security and data tests, and the last test of a behavior, always stay.
   - **Budget:** count the reviewers: one per component, one for the duplicates pass in `deep`, and two kept for round 2 and a possible judge. If that exceeds
     `max_agents` and the arguments have no `--top` or `--skip`, offer:
     - **most suspicious first:** `--top <budget>`, the rest later with
       `--skip`;
     - **fewer, bigger components:** merge components in the plan. Above
       roughly 6000 lines each, attention per file drops;
     - **everything:** about `est_tokens` tokens plus verification. Say plainly that this
       is expensive;
     - **a narrower folder.**
   - **Left out:** list the skipped folders (`--with-nonprod` includes them) and
     your `## skip` components with their reasons.

   Then run the final `nahuya shards` command with the choices and `--loop`; that starts the ledger.
4. **Settings.** Run `nahuya status` with no argument for the settings and check
   command, use the ledger path that `shards` printed, and do Setup steps 3–4.
   `requested` is the user's words for this run. Note the current HEAD as the
   run's start.
5. **Shards.** Go shard by shard. For each, launch a fresh `nahuya:reviewer`
   with `mode: review`, `round: 1`, `depth`, `tests` (`prune` if `shards`
   printed `test_mode=prune`, otherwise `dedupe`), `files: <shard path>`, the
   ledger path and `requested`. You may launch the next shard's reviewer while you
   verify the current one. Verify, apply, log and run the judge exactly as in
   Rounds steps 3–5. Log with round `1`. After each shard, run the check and,
   with fix_mode `commit`, commit that shard's edits. A change that spans
   several files gets its own commit.
6. **Duplicates (deep).** Run `nahuya clones <same target and test flag>`. If
   `pairs` is above 0, launch one more fresh reviewer with `clones: <path>`
   instead of `files`, and handle its findings the same way.
7. **Later rounds** work as in Rounds, using `nahuya diff --round k`, which
   covers the fixes made so far.
8. **Finish** as above, with these differences:
   - run `nahuya mark --keep-anchor` instead of `nahuya mark`;
   - push only if the user asked you to.

   Add to the report:
   - the lines reviewed (`selected_lines`, and how many were tests);
   - the net lines removed and their share of the lines reviewed, from
     `git diff --shortstat <start>..HEAD`;
   - what was not reviewed: remaining components with the command for the
     next batch, skipped folders, `## skip` components, and the tests if they
     were left out.
