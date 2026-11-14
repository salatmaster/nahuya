---
name: review
description: Report-only review for over-engineering and bloat of a change, a range, a folder or the whole repo. Use when the user asks whether code is over-engineered, bloated or more complex than needed.
argument-hint: "[tests] [all | folder | base..tip]  default: your unpushed changes"
allowed-tools: Bash(nahuya *)
---

The target is: $ARGUMENTS (empty means the unreviewed commits plus uncommitted
changes).

**Tests only.** If the first argument is `tests` (`tests`, `tests all`,
`tests src/`, `tests main..HEAD`), drop it and review test code only:
- add `--only-tests` to every `nahuya diff`, `inventory`, `shards` and `clones`
  command;
- give every reviewer `only_tests: yes`;
- ask only whether to look for duplicates (`--tests`) or also for worthless
  tests (`--prune-tests`), unless the arguments already say.

**Range, branch or empty:** run `nahuya diff --target <target>`, which prints a
diff path. If it prints `note=`, pass the note on to the user. Launch one fresh
`nahuya:reviewer` with `mode: review`, `round: 1`, `depth: normal` (or `deep` if
the `depth` setting is `deep`), the diff path, `ledger: none`, and `requested` if
the user said what the code is for.

**`all` (the whole repo) or a folder:** this is a cleanup review, so `depth` is
`deep` unless the `depth` setting is `normal`.
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
   - **Budget:** count the reviewers: one per component plus one for the duplicates pass. If that exceeds
     `max_agents` and the arguments have no `--top` or `--skip`, offer:
     - **most suspicious first:** `--top <budget>`, the rest later with
       `--skip`;
     - **fewer, bigger components:** merge components in the plan. Above
       roughly 6000 lines each, attention per file drops;
     - **everything:** about `est_tokens` tokens. Say plainly that this
       is expensive;
     - **a narrower folder.**
   - **Left out:** list the skipped folders (`--with-nonprod` includes them) and
     your `## skip` components with their reasons.

   Then run the final `nahuya shards` command with the choices.
4. Launch a fresh `nahuya:reviewer` per selected shard with `mode: review`,
   `round: 1`, `depth`, `tests` (`prune` if `shards` printed `test_mode=prune`,
   otherwise `dedupe`), `files: <shard path>` and `ledger: none`, up to four at
   a time.
5. In `deep`, also run `nahuya clones <same target and test flag>`. If `pairs`
   is above 0, launch one more reviewer with `clones: <path>`.

Present the findings to the user in plain language, grouped by file, biggest
saving first, keeping locations and evidence. Number them across all groups so
the user can say "apply 2 and 5". Then add:
- the total: `-N lines, -M dependencies possible`;
- the lines reviewed;
- what wasn't reviewed (remaining components with the next-batch command,
  skipped folders, `## skip` components, excluded tests).

Say that nothing was changed and that these are unverified proposals. Apply
findings only when the user asks ("apply 2 and 5"), and verify each one first. For many findings, suggest
`/nahuya:polish <same target>`.
