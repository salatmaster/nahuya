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

**`all` (the whole repo) or a folder:** run `nahuya shards <all|folder>`, which splits
the code into shards and prints their paths. If there are more than 8, tell the
user the count and ask whether to go ahead or narrow the path, unless they
already said to go ahead. Launch a fresh `nahuya:reviewer` per shard with
`mode: review`, `round: 1`, `files: <shard path>` and `ledger: none`, up to four
at a time.

Present the findings to the user in plain language, grouped by file, most
valuable first, keeping locations and evidence. Say that nothing was changed and
that these are unverified proposals. Apply one only if the user asks, and verify
it first; for many, suggest `/nahuya:polish <same target>`.
