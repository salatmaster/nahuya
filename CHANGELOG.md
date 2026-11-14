# Changelog

All notable changes to nahuya are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.6.4] - 2026-11-14

### Changed

- When the gate blocks on code that doesn't ship, Claude stops and suggests an `exclude:` entry
  in `.nahuya.md` instead of reviewing it. Claude leaves the file for you to edit.

### Fixed

- The push gate counted code in non-production folders such as `research/`, `examples/` and
  `benchmarks/`, which whole-repo runs already skip, so committing one-off research scripts
  could block a push. Those folders no longer count.

## [0.6.3] - 2026-11-14

### Changed

- The push gate counts only code. Markdown, text, JSON, YAML, TOML, XML, config files, HTML/CSS
  and SVG no longer push a change over the threshold.

### Fixed

- After a feature branch was rebased onto a newer main, the gate counted main's new commits as
  yours, and the review diff included them. Now only your own commits count.
- A rebase or amend no longer throws away the last review: commits already reviewed stay
  reviewed, and only new or changed ones count.
- On main, commits by other people that you pulled no longer count toward your threshold.

## [0.6.2] - 2026-11-14

### Fixed

- The push gate missed a push made in the same command as the commit (`git commit … && git push`),
  the way Claude usually pushes. The hook runs before the command, when that commit doesn't exist
  yet, so the new lines weren't counted. When a command commits before it pushes, the gate now
  counts the work it is about to commit.
- `nahuya status` no longer fails on `--prune-tests` and the other test flags the skills pass along.

## [0.6.1] - 2026-11-14

### Changed

- `/nahuya:skip` now skips review of everything up to the current commit, the way a finished
  review would. Before, it let one push of that commit through, and the next commit brought the
  same lines back into the count and blocked again.

## [0.6.0] - 2026-11-14

### Added

- Tests in Rust are found by syntax. Modules declared under `#[cfg(test)]`, and their submodules,
  count as test files. In other sources only the lines inside `#[cfg(test)]` and `#[test]` items
  count as tests, so a file with a small test module at the end no longer counts as a test file
  in full.
- When Claude plans a whole-repo run, it can tag a component `[tests]` (test helpers and
  harnesses with ordinary names) or `[not tests]`. A component that the test filter empties is
  reported instead of silently dropping out of the run.

### Changed

- With `--prune-tests`, tests that repeat a neighbor on the same class of input go too, as do
  tests that compute the expected value with the code under test. Touching money no longer
  protects a test by itself: what stays is the only test that catches a money, security or data
  bug, regression tests, and the last test of a behavior.
- Tests-only runs keep their shards apart from regular runs, and a new run no longer replaces the
  shards of a polish run that is still going.
- The push gate leaves out Rust test modules.

### Fixed

- Data such as JSON, YAML or OpenAPI specs under `spec/` or `tests/` no longer counts as test
  code.
- In tests-only runs on a range, the choice between cleaning duplicates and pruning now reaches
  the reviewer.
- The `reviewer-model` setting now applies to every reviewer, including whole-repo shards, the
  duplicates pass and the judge.
- With `fix-mode` `amend`, a whole-repo cleanup is committed per shard instead of being folded
  into your last commit.
- The `/nah-*` aliases had invalid frontmatter.

## [0.5.0] - 2026-11-14

### Added

- `tests` as the first argument of `/nahuya:review` or `/nahuya:polish` works on test code only,
  with any target.
- Claude asks how to treat tests in a cleanup: leave them alone, clean duplicates and copied
  setup, or also remove tests that can't fail. Each removal comes with a mutation-style argument.
- `/nahuya:aliases` installs the short commands `/nah-review`, `/nah-polish`, `/nah-skip` and
  `/nah-stats`.

### Changed

- The duplicates pass looks at the files of the planned run and leaves data and markup out.

### Removed

- `/nahuya:config`. Settings live in `/plugin configure`, with per-repo overrides in
  `git config nahuya.*`.

## [0.4.0] - 2026-11-14

### Added

- Whole-repo and folder runs are planned by logical component from a cheap map of the code, so
  related code from different folders goes to the same reviewer.
- The `depth` setting. Cleanups run `deep`: small real findings count, and behavior-preserving
  changes may span files.
- A clone detector for a duplicates pass across files.
- New finding categories: duplication, boilerplate, needless conversion, derivable state, wasted
  work, special cases, comment bloat and redundant tests.
- Later rounds check that the fixes kept every guard, validation and error path. Anything lost is
  restored first.

### Fixed

- Plugin settings such as `max-rounds` were ignored by the skills.

## [0.3.0] - 2026-11-14

### Added

- A budget for whole-repo and folder reviews: about 3000 lines per reviewer (`shard-lines`) and at
  most 10 reviewers per run (`max-agents`). Above that, Claude asks before spending anything.

## [0.2.0] - 2026-11-14

First public release: the push gate, the review-and-fix loop, the report-only reviewer and the
disclosure layer.

[unreleased]: https://github.com/salatmaster/nahuya/compare/v0.6.4...HEAD
[0.6.4]: https://github.com/salatmaster/nahuya/compare/v0.6.3...v0.6.4
[0.6.3]: https://github.com/salatmaster/nahuya/compare/v0.6.2...v0.6.3
[0.6.2]: https://github.com/salatmaster/nahuya/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/salatmaster/nahuya/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/salatmaster/nahuya/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/salatmaster/nahuya/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/salatmaster/nahuya/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/salatmaster/nahuya/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/salatmaster/nahuya/releases/tag/v0.2.0
