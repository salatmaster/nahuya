---
name: review
description: Report-only over-engineering review of a range, branch, path or the whole repo. Use when the user asks whether code is over-engineered, bloated or more complex than needed.
argument-hint: "[all | folder | base..tip]  default: your unpushed changes"
allowed-tools: Bash(nahuya *)
---

The target is: $ARGUMENTS (empty means the unreviewed commits plus uncommitted
changes).

**Range, branch or empty:** run `nahuya diff --target <target>`, which prints a
diff path. Launch one fresh `nahuya:reviewer` with `mode: review`, `round: 1`,
the diff path, `ledger: none`, and `requested` if the user said what the code is
for.

**`all` (the whole repo) or a folder:** run `nahuya shards --defaults 'shard_lines=${user_config.shard_lines} max_agents=${user_config.max_agents}' <all|folder>` plus any
flags from the arguments (`--top N`, `--skip K`, `--fit N`, `--max-lines N`). It
splits the code into shards ranked by over-engineering signals and prints them
with `shards_total`, `max_agents` and `est_tokens`.

Check the budget before launching any reviewer: it is `max_agents`. If the
selected shards fit, or the arguments already include `--top`, `--skip`,
`--fit` or `--max-lines`, go ahead. Otherwise don't start: run the same command
with `--fit <budget>` to learn the shard size that would fit, then ask the user
to choose, with the numbers:
- **Most suspicious first:** `--top <budget>`. The rest can follow later with
  `--skip <budget>`.
- **Bigger shards:** `--fit <budget>`, at the size you just learned. Above
  roughly 6000 lines per shard, attention per file drops.
- **Everything:** all `shards_total` shards, about `est_tokens` tokens. Say
  plainly that this is expensive.
- **A narrower folder.**

Then run the command with their choice.

Launch a fresh `nahuya:reviewer` per selected shard with `mode: review`,
`round: 1`, `files: <shard path>` and `ledger: none`, up to four at a time. If
shards remain, end by saying how to review the next batch
(`/nahuya:review <target> --skip N`).

Present the findings to the user in plain language, grouped by file, most
valuable first, keeping locations and evidence. Say that nothing was changed and
that these are unverified proposals. Apply one only if the user asks, and verify
it first; for many, suggest `/nahuya:polish <same target>`.
