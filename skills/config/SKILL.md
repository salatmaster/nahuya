---
name: config
description: Set up nahuya's settings interactively, for all your repos, one project or one repo.
disable-model-invocation: true
allowed-tools: Bash(nahuya config *), AskUserQuestion
---

# nahuya config

Current settings, each with where its value comes from:

!`sh "${CLAUDE_PLUGIN_ROOT}/bin/nahuya" config`

Walk the user through changing them with AskUserQuestion. The user typed this
command to change settings, so ask instead of explaining, and keep your own
text to a line between questions.

1. **Scope and topics.** Ask both in one call.
   - **Where should the changes apply?** (skip it outside a git repository and
     use all repos)
     - **All my repos:** the global git config.
     - **This project, for everyone:** the front matter of `.nahuya.md` at the
       repo root, which they commit to share it with the team.
     - **This repo, just me:** this clone's git config. It overrides the
       project file.
   - **What do you want to change?** (multiSelect)
     - **Push gate:** on or off, and how many unreviewed lines make it block.
     - **Reviewer:** the model it runs on and how deep it looks.
     - **Fixes:** a new commit, an amend, or left uncommitted.
     - **Cleanup effort:** rounds per review and passes per cleanup.

   For all repos, the gate switch and the review depth live in
   `/plugin configure`, which the global git config would silently override.
   Leave those two out of the questions and say where they are.
2. **Values.** One question per setting in the chosen topics, at most four per
   call. Mark the current value `(current)` and the default `(default)`, and
   put the current value first. Each option's description says what that value
   does in practice.
   - `gate`: on, off (default).
   - `threshold`: 300, 500 (default), 1000, 2000 unreviewed added lines,
     counted across pushes since the last review.
   - `reviewer-model`: inherit (default, the session's model), fable, opus,
     sonnet. Haiku is cheapest and misses the most; the user can type it.
   - `depth`: auto (default: deep for repo and folder cleanups, normal before a
     push), normal, deep.
   - `fix-mode`: commit (default, a new commit on top), amend (folded into the
     last commit while it isn't pushed), uncommitted (left in the working tree,
     nothing is pushed).
   - `max-rounds`: 2, 3 (default), 5. Each round after the first checks the
     previous round's fixes.
   - `passes`: 1 (default), 2, 3. Each pass reviews the whole cleaned-up result
     again from scratch and costs about as much as the first.
3. **Apply.** For each answer that differs from the current value, run
   `nahuya config <key> <value>` with `--global` for all repos, `--project` for
   the project, and no flag for this repo. If the user typed `default`, pass
   `--unset` instead of a value. If a value is rejected, ask that one question
   again with the error's list of valid values.
4. **Confirm.** Say in a line or two what changed and where. For the project,
   remind them to commit `.nahuya.md`. If a value still comes from a source
   that overrides the one you wrote (an environment variable, or this repo's
   git config over the project file), say which one, as `nahuya config` shows
   it.
