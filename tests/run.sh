#!/bin/sh
# nahuya test suite. Usage: sh tests/run.sh   (no dependencies beyond sh, git, awk)

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/lib/nahuya.sh"
GATE="$ROOT/hooks/push-gate.sh"
NAHUYA="$ROOT/bin/nahuya"
PASS=0; FAIL=0

ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*"; }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$3], got [$2]"; fi; }

# Isolate from the user's git config and nahuya env.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/nahuya-test.XXXXXX")
trap '[ -n "$KEEP" ] || rm -rf "$WORK"' EXIT
export HOME="$WORK/home" GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME"
git config --global init.defaultBranch main
unset NAHUYA_GATE NAHUYA_THRESHOLD NAHUYA_LAYER NAHUYA_MAX_ROUNDS NAHUYA_FIX_MODE NAHUYA_REVIEWER_MODEL \
  CLAUDE_PLUGIN_OPTION_GATE CLAUDE_PLUGIN_OPTION_THRESHOLD CLAUDE_PLUGIN_OPTION_LAYER

# ------------------------------------------------------------------ detection
det() { nh_detect_pushes "$1" "${2-}" | tr '\t\n' '|;'; }
eq "plain push" "$(det 'git push')" "|HEAD;"
eq "chain" "$(det 'git add . && git commit -m "fix; then git push" && git push -u origin HEAD')" "|HEAD;"
eq "push inside heredoc commit msg" "$(det 'git commit -m "$(cat <<EOF
mention git push here
EOF
)"')" ""
eq "-C and refspec" "$(det 'git -C ../other push origin feature:main')" "../other|feature;"
eq "cd" "$(det 'cd sub && git push')" "sub|HEAD;"
eq "delete flag" "$(det 'git push --delete origin old')" ""
eq "delete refspec" "$(det 'git push origin :old')" ""
eq "tags only" "$(det 'git push --tags')" ""
eq "branch plus tags" "$(det 'git push origin main --tags')" "|main;"
eq "dry run" "$(det 'git push -n')" ""
eq "alias" "$(det 'git p' 'p')" "|HEAD;"
eq "non-push alias" "$(det 'git st' 'p')" ""
eq "env + redirect + pipe" "$(det 'GIT_TRACE=1 git push 2>&1 | tee log')" "|HEAD;"
eq "bash -c" "$(det 'bash -c "cd x && git push"')" "x|HEAD;"
eq "gh pr create" "$(det 'gh pr create --fill')" "|HEAD;"
eq "echo" "$(det 'echo git push')" ""
eq "git log grep" "$(det 'git log --grep push')" ""
eq "abs git + -c" "$(det '/usr/bin/git -c core.x=y push --force-with-lease')" "|HEAD;"
eq "force refspec" "$(det 'git push origin +HEAD:refs/for/main')" "|HEAD;"
eq "redirect target" "$(det 'git status; git push origin feat >/dev/null')" "|feat;"
eq "subshell" "$(det '(cd a && git push)')" "a|HEAD;"

# ------------------------------------------------------------------ json
js() { printf '%s' "$1" | nh_json_str "$2"; }
eq "json simple" "$(js '{"tool_input":{"command":"git push"},"cwd":"/x"}' command)" "git push"
eq "json escapes" "$(js '{"tool_input":{"command":"git commit -m \"a\\b\" && git push","description":"x"}}' command)" 'git commit -m "a\b" && git push'
eq "json key in value" "$(js '{"description":"the \"command\": \"no\"","tool_input":{"command":"ls"}}' command)" "ls"
eq "json unicode" "$(js '{"command":"echo é&"}' command)" "echo é&"
eq "json newline" "$(js '{"command":"a\nb"}' command)" "a
b"

# ------------------------------------------------------------------ gate
# hook CMD DIR -> prints exit code; stderr/stdout saved to $WORK/out
hook() {
  printf '{"session_id":"t","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s"}}' "$2" "$1" |
    sh "$GATE" > "$WORK/out" 2>&1
  echo $?
}
lines() { # file n [prefix]
  mkdir -p "$(dirname "$1")"
  awk -v n="$2" -v p="${3:-line}" 'BEGIN { for (i = 1; i <= n; i++) print p, i }' >> "$1"
}
commit() { git add -A >/dev/null && git commit -qm "$1"; }

git init -q --bare "$WORK/remote.git"
git clone -q "$WORK/remote.git" "$WORK/repo" 2>/dev/null
R=$WORK/repo
cd "$R" || exit 1
echo seed > README; commit seed; git push -q origin main 2>/dev/null
git remote set-head origin main >/dev/null 2>&1

eq "nothing unpushed passes" "$(hook 'git push' "$R")" 0

# commit and push in one command: the hook runs before the commit exists
lines src/wip.py 600
eq "commit-and-push counts what it commits" "$(hook 'git add -A && git commit -qm wip && git push' "$R")" 2
grep -q '600 of them not committed yet' "$WORK/out" && ok || bad "pending lines named: $(cat "$WORK/out")"
eq "plain push ignores uncommitted work" "$(hook 'git push' "$R")" 0
rm -f src/wip.py; rm -f .git/nahuya/blocks

lines src/app.py 600; commit big
eq "600 lines blocks" "$(hook 'git push' "$R")" 2
grep -q 'push blocked, nothing in this command ran. 600 unreviewed' "$WORK/out" && ok || bad "block message: $(cat "$WORK/out")"
grep -q 'add them to `exclude:` in .nahuya.md' "$WORK/out" && ok || bad "block message suggests exclude: $(cat "$WORK/out")"
eq "gate off via env" "$(NAHUYA_GATE=off hook 'git push' "$R")" 0
eq "plugin option threshold" "$(CLAUDE_PLUGIN_OPTION_THRESHOLD=1000 hook 'git push' "$R")" 0
git config nahuya.threshold 1000
eq "git config threshold" "$(hook 'git push' "$R")" 0
eq "env beats git config" "$(NAHUYA_THRESHOLD=100 hook 'git push' "$R")" 2
git config --unset nahuya.threshold
rm -f .git/nahuya/blocks
eq "invalid env falls through" "$(NAHUYA_THRESHOLD=abc hook 'git push' "$R")" 2

# loop guard: 3 blocks of the same commit, then a pass with a notice
rm -f .git/nahuya/blocks
hook 'git push' "$R" >/dev/null; hook 'git push' "$R" >/dev/null; hook 'git push' "$R" >/dev/null
eq "4th attempt passes" "$(hook 'git push' "$R")" 0
grep -q '"additionalContext"' "$WORK/out" && ok || bad "loop guard notice missing"

# skip moves the anchor: skipped lines aren't counted again
sh "$NAHUYA" skip | grep -q '^nahuya: skipped review of [0-9]* added lines' && ok || bad "skip message"
eq "skip passes" "$(hook 'git push' "$R")" 0
lines after_skip.py 100; commit afterskip
eq "gate counts only after the skip" "$(sh "$NAHUYA" status | sed -n 's/^unreviewed_added_lines=\([0-9]*\).*/\1/p')" 100

# mark ends it
sh "$NAHUYA" mark >/dev/null
eq "after mark passes" "$(hook 'git push' "$R")" 0
git push -q origin main 2>/dev/null

# exclusions: tests, lock files, generated attrs, .nahuya.md excludes
lines tests/test_app.py 800; lines package-lock.json 800; lines gen/api.ts 800
printf 'gen/** linguist-generated\n' > .gitattributes
lines vendor2/lib.js 800
printf -- '---\nexclude:\n  - vendor2/\ncheck: make test\n---\nNotes.\n' > .nahuya.md
commit excluded
eq "tests/lock/generated/excluded don't count" "$(hook 'git push' "$R")" 0
nh_enter_repo; eq "check parsed" "$(nh_md_scalar check)" "make test"
git push -q origin main 2>/dev/null

# accumulation across pushes
lines src/a.py 300; commit a
eq "300 passes" "$(hook 'git push' "$R")" 0
git push -q origin main 2>/dev/null
lines src/b.py 300; commit b
eq "300 + 300 accumulates and blocks" "$(hook 'git push' "$R")" 2
sh "$NAHUYA" mark >/dev/null; git push -q origin main 2>/dev/null

# feature branch with main merged in: main's code doesn't count
git checkout -q -b feat
lines src/f.py 200; commit f1
git checkout -q main; lines src/other.py 900; commit other; git push -q origin main 2>/dev/null
sh "$NAHUYA" mark >/dev/null  # main reviewed, so pushing it later must pass
git checkout -q feat; git merge -q --no-edit main >/dev/null 2>&1
eq "merged main code not counted" "$(hook 'git push -u origin feat' "$R")" 0
lines src/f2.py 400; commit f2
eq "own branch code counts" "$(hook 'git push -u origin feat' "$R")" 2
eq "-C from elsewhere" "$(hook "git -C $R push -u origin feat" "$WORK")" 2
eq "explicit other branch" "$(hook 'git push origin main' "$R")" 0

# only our own code counts: no docs or data, nothing from main after a rebase,
# reviewed commits stay reviewed when rebased, pulled commits by others don't count
unrev() { sh "$NAHUYA" status | sed -n 's/^unreviewed_added_lines=\([0-9]*\).*/\1/p'; }
git init -q --bare "$WORK/rb.git"; git clone -q "$WORK/rb.git" "$WORK/rb" 2>/dev/null
cd "$WORK/rb" || exit 1
echo seed > README; commit seed; git push -q origin main 2>/dev/null; git remote set-head origin main >/dev/null 2>&1
lines docs/guide.md 300; lines notes.txt 300; lines conf/app.yaml 300; lines data/items.json 300; lines app.cfg 300; lines README 300
commit docs
eq "docs and data don't count" "$(hook 'git push' "$WORK/rb")" 0
lines research/r-12/backtest.py 900; lines examples/demo.py 900; lines src/core.py 10; commit nonprod
eq "non-production folders don't count" "$(sh "$NAHUYA" status | sed -n 's/^unreviewed_added_lines=\([0-9]*\).*/\1/p')" 10
git push -q origin main 2>/dev/null
git checkout -q -b topic; lines src/t1.py 300; commit t1
eq "topic before the rebase" "$(unrev)" 300
git checkout -q main; lines src/m1.py 900; commit m1; git push -q origin main 2>/dev/null
git checkout -q topic; git rebase -q main >/dev/null 2>&1
eq "rebase onto main: main's code not counted" "$(unrev)" 300
grep -q 'src/m1.py' "$(sh "$NAHUYA" diff --target | sed -n 's/^diff=//p')" && bad "review diff includes main's code after a rebase" || ok
sh "$NAHUYA" mark >/dev/null
lines src/t2.py 100; commit t2
git checkout -q main; lines src/m2.py 900; commit m2; git push -q origin main 2>/dev/null
git checkout -q topic; git rebase -q main >/dev/null 2>&1
eq "reviewed commits stay reviewed after a rebase" "$(unrev)" 100
sh "$NAHUYA" mark >/dev/null
lines src/t2.py 5; git add -A; git commit -q --amend --no-edit
eq "amended commit counts again" "$(unrev)" 105
sh "$NAHUYA" mark >/dev/null
printf 'conflict\n' > src/m2.py; commit c1
git checkout -q main; printf 'theirs\n' > src/m2.py; commit c2; git push -q origin main 2>/dev/null
git checkout -q topic; git rebase main >/dev/null 2>&1
code=$(hook 'git push' "$WORK/rb")
[ "$code" = 0 ] && ! grep -q 'fatal\|error' "$WORK/out" && ok || bad "gate during a stopped rebase: $code $(cat "$WORK/out")"
git rebase --abort
git checkout -q main; sh "$NAHUYA" mark >/dev/null
git clone -q "$WORK/rb.git" "$WORK/rb2" 2>/dev/null
(cd "$WORK/rb2" && lines src/o.py 900 && git add -A && GIT_AUTHOR_EMAIL=o@o git commit -qm other && git push -q origin main 2>/dev/null)
git pull -q --rebase origin main 2>/dev/null
lines src/mine.py 50; commit mine
eq "pulled commits by others not counted on main" "$(unrev)" 50
cd "$R" || exit 1

# no remote: nothing to compare against
git init -q "$WORK/solo"; cd "$WORK/solo" && lines x.py 900 && commit x
eq "no remote passes" "$(hook 'git push' "$WORK/solo")" 0
cd "$R" || exit 1

# ------------------------------------------------------------------ CLI loop
git checkout -q feat
out=$(sh "$NAHUYA" diff --round 1)
d1=$(printf '%s\n' "$out" | sed -n 's/^diff=//p')
[ -s "$d1" ] && ok || bad "round 1 diff empty"
grep -q 'src/f2.py' "$d1" && ok || bad "round 1 diff misses own change"
grep -q 'src/other.py' "$d1" && bad "round 1 diff includes merged main code" || ok
[ -f "$(sh "$NAHUYA" status | sed -n 's/^ledger=//p' | sed 's/ (.*//')" ] && ok || bad "ledger created at round 1"
sh "$NAHUYA" log 1 applied dead-code "src/f2.py:thing" "removed it" >/dev/null || bad "log failed"
sh "$NAHUYA" log 1 rejected pass-through "src/f.py:x" "used by router: src/r.py:3" >/dev/null
sed -i.bak '1,50d' src/f2.py && rm -f src/f2.py.bak
out=$(sh "$NAHUYA" diff --round 2)
d2=$(printf '%s\n' "$out" | sed -n 's/^diff=//p')
grep -q '^-line 1$' "$d2" && ok || bad "round 2 delta missing fix"
grep -q 'src/f.py' "$d2" && bad "round 2 delta not limited to fixes" || ok
commit fixes
eq "status shows rounds" "$(NAHUYA_MAX_ROUNDS=5 sh "$NAHUYA" status | sed -n 's/^max_rounds=//p')" 5
sh "$NAHUYA" mark >/dev/null
sh "$NAHUYA" stats | grep -q 'applied rate: 50%' && ok || bad "stats: $(sh "$NAHUYA" stats)"
eq "run records size at loop start" "$(tail -1 .git/nahuya/runs.tsv | cut -f5)" 600
eq "after loop push passes" "$(hook 'git push -u origin feat' "$R")" 0
git push -q -u origin feat 2>/dev/null
sh "$NAHUYA" diff --target | grep -q '^note=nothing unreviewed' && ok || bad "review falls back to last commit"
lines src/f9.py 20; lines tests/test_f9.py 20; commit f9
d=$(sh "$NAHUYA" diff --target --only-tests HEAD~1..HEAD | sed -n 's/^diff=//p')
grep -q 'tests/test_f9.py' "$d" && ok || bad "test-only diff keeps tests"
grep -q 'src/f9.py' "$d" && bad "test-only diff kept production code" || ok

sh "$NAHUYA" diff --target src/a.py >/dev/null 2>&1 && bad "path accepted by diff --target" || ok
sh "$NAHUYA" diff --target tests HEAD~1..HEAD | grep -q '^diff=' && ok || bad "diff takes the tests keyword"
# the gate leaves out Rust modules declared under #[cfg(test)]
printf 'mod a;\n#[cfg(test)]\nmod scen;\nfn main() {}\n' > src/main.rs; lines src/a.rs 5; lines src/scen.rs 700; commit rustgate
eq "rust test module not counted" "$(sh "$NAHUYA" status | sed -n 's/^unreviewed_added_lines=\([0-9]*\).*/\1/p')" 29

# plugin settings saved by /plugin configure
mkdir -p "$HOME/.claude"
printf '{"pluginConfigs":{"nahuya@nahuya":{"options":{"threshold":1200,"gate":true}}}}' > "$HOME/.claude/settings.json"
sh "$NAHUYA" config | grep -q 'threshold *1200 *(plugin config)' && ok || bad "plugin settings: $(sh "$NAHUYA" config)"
NAHUYA_THRESHOLD=300 sh "$NAHUYA" config | grep -q 'threshold *300 *(env' && ok || bad "env beats plugin settings"
rm -f "$HOME/.claude/settings.json"
sh "$NAHUYA" config depth deep >/dev/null; eq "depth setting" "$(git config nahuya.depth)" deep
sh "$NAHUYA" config depth extreme >/dev/null 2>&1 && bad "bad depth accepted" || ok
git config --unset nahuya.depth

# config command
sh "$NAHUYA" config threshold 900 >/dev/null
eq "config writes git config" "$(git config nahuya.threshold)" 900
sh "$NAHUYA" config threshold --unset >/dev/null
eq "config unset" "$(git config nahuya.threshold)" ""
sh "$NAHUYA" config threshold lots >/dev/null 2>&1 && bad "invalid value accepted" || ok
sh "$NAHUYA" config bogus 1 >/dev/null 2>&1 && bad "unknown key accepted" || ok
sh "$NAHUYA" config 'model' fable >/dev/null
eq "model alias" "$(git config nahuya.reviewer-model)" fable

# ------------------------------------------------------------------ whole repo
cd "$WORK/solo" || exit 1
lines lib/a.py 400; lines lib/b.py 400; lines web/c.ts 400; printf 'x\n' > NOTES.md; lines vendor/v.js 500
commit spread
out=$(sh "$NAHUYA" shards . --max-lines 500)
eq "shard count" "$(printf '%s\n' "$out" | sed -n 's/^shards_total=//p')" 4
eq "shard lines" "$(printf '%s\n' "$out" | sed -n 's/^lines=//p')" 2100
printf '%s\n' "$out" | grep -q NOTES && bad "docs not skipped" || ok
grep -q 'vendor/' .git/nahuya/shards/*/*.txt && bad "vendor not skipped" || ok
grep -q '^lib/a.py (400 lines)$' .git/nahuya/shards/*/shard-*.txt && ok || bad "shard manifest"
eq "all keyword" "$(cd lib && sh "$NAHUYA" shards all --max-lines 500 | sed -n 's/^lines=//p')" 2100
out=$(sh "$NAHUYA" shards . --max-lines 500 --top 2)
eq "top limits selection" "$(printf '%s\n' "$out" | sed -n 's/^shards_selected=//p')" 2
printf '%s\n' "$out" | grep -q '^remaining=2 (next batch: --skip 2)$' && ok || bad "next batch hint: $out"
eq "skip takes the rest" "$(sh "$NAHUYA" shards . --max-lines 500 --skip 2 | sed -n 's/^shards_selected=//p')" 2
eq "fit packs into budget" "$(sh "$NAHUYA" shards . --fit 2 | sed -n 's/^shards_total=//p')" 2
eq "shard_lines from config" "$(NAHUYA_SHARD_LINES=900 sh "$NAHUYA" shards . | sed -n 's/^shard_lines=//p')" 900
eq "max_agents from env" "$(NAHUYA_MAX_AGENTS=4 sh "$NAHUYA" shards . | sed -n 's/^max_agents=//p')" 4
eq "explicit doc file" "$(sh "$NAHUYA" shards NOTES.md | sed -n 's/^files=//p')" 1
printf 'class FooFactory:\n    pass\nclass BarManager:\n    pass\n' > lib/zz_factory.py; commit sig
eq "suspicious shard ranks first" "$(sh "$NAHUYA" shards lib --max-lines 10 | head -1 | sed 's/.*signals=//')" 2
git rm -q lib/zz_factory.py; commit unsig
sh "$NAHUYA" status >/dev/null 2>&1 && ok || bad "status dies without a remote"
sh "$NAHUYA" shards lib --loop >/dev/null
sh "$NAHUYA" log 1 applied dead-code "lib/a.py:x" "removed" >/dev/null && ok || bad "log in whole mode"
sed -i.bak '1,10d' lib/a.py && rm -f lib/a.py.bak
d=$(sh "$NAHUYA" diff --round 2 | sed -n 's/^diff=//p')
grep -q '^-line 1$' "$d" && ok || bad "whole-mode round 2 delta"
before=$(cat .git/nahuya/anchors/main 2>/dev/null)
commit trim; sh "$NAHUYA" mark --keep-anchor >/dev/null
eq "keep-anchor leaves anchor" "$(cat .git/nahuya/anchors/main 2>/dev/null)" "$before"
eq "whole run recorded" "$(tail -1 .git/nahuya/runs.tsv | cut -f5)" 800
# per-target shard dirs, non-prod folders, tests, module packing, clones
sh "$NAHUYA" shards lib >/dev/null; sh "$NAHUYA" shards all >/dev/null
[ -d .git/nahuya/shards/lib ] && [ -d .git/nahuya/shards/all ] && ok || bad "per-target shard dirs"
lines research/r.py 300; commit research
out=$(sh "$NAHUYA" shards all)
printf '%s\n' "$out" | grep -q '^skipped_nonprod=research/ (300 lines' && ok || bad "nonprod skipped: $out"
grep -q 'research/' .git/nahuya/shards/all/*.txt && bad "research reviewed" || ok
sh "$NAHUYA" shards all --with-nonprod | grep -q '^lines=2390$' && ok || bad "with-nonprod"
lines examples/e.py 500; commit ex
eq "non-production folders biggest first" "$(sh "$NAHUYA" inventory all | sed -n 's/^skipped_nonprod=\([^ ]*\).*/\1/p' | tr '\n' ' ')" "examples/ research/ "
git rm -q -r examples; commit unex
lines tests/test_x.py 120; commit t
sh "$NAHUYA" shards all | grep -q '^test_lines=120 in 1 files' && ok || bad "test lines reported"
out=$(sh "$NAHUYA" shards all --no-tests)
printf '%s\n' "$out" | grep -q '^lines=2090$' && ok || bad "no-tests"
printf '%s\n' "$out" | grep -q '^test_mode=off$' && ok || bad "test mode off"
sh "$NAHUYA" shards all --prune-tests | grep -q '^test_mode=prune$' && ok || bad "test mode prune"
printf 'fn add(a: i32, b: i32) -> i32 { a + b }\n#[cfg(test)]\nmod tests {\n    #[test]\n    fn adds() { assert_eq!(super::add(1, 2), 3); }\n}\n' > lib/calc.rs; commit rust
out=$(sh "$NAHUYA" shards all --only-tests)
printf '%s\n' "$out" | grep -q '^scope=tests-only' && ok || bad "only-tests scope: $out"
TS=.git/nahuya/shards/tests-all
grep -q 'tests/test_x.py' $TS/*.txt && ok || bad "only-tests keeps test files"
grep -q '^lib/calc.rs (5 test lines of 6)$' $TS/*.txt && ok || bad "only-tests counts inline rust test lines: $(cat $TS/*.txt)"
grep -q 'lib/a.py' $TS/*.txt && bad "only-tests kept production code" || ok
sh "$NAHUYA" shards all --only-tests --no-tests >/dev/null 2>&1 && bad "contradictory test flags accepted" || ok
# Rust: modules declared under #[cfg(test)] are test files; strings and comments don't confuse the count
mkdir -p crate/src/kit
printf 'mod core;\n#[cfg(test)]\nmod scenarios;\n#[cfg(test)]\n#[path = "harness_impl.rs"]\nmod harness;\n#[cfg(test)]\nmod kit;\nfn main() {}\n' > crate/src/main.rs
printf 'pub fn f() -> &'"'"'static str { "}" }\n#[cfg(test)]\nmod tests {\n    // a } in a comment\n    #[test]\n    fn t() { assert_eq!(super::f(), "}"); let _c = '"'"'{'"'"'; }\n}\n' > crate/src/core.rs
lines crate/src/scenarios.rs 50; lines crate/src/harness_impl.rs 30; lines crate/src/kit/mod.rs 5; lines crate/src/kit/world.rs 40
commit rustmods
rt=$(cd crate && NH_TOP=$WORK/solo nh_rust_tests | sort | tr '\t\n' ':;')
eq "rust test modules" "$rt" "crate/src/core.rs:6;crate/src/harness_impl.rs:all;crate/src/kit/mod.rs:all;crate/src/kit/world.rs:all;crate/src/main.rs:7;crate/src/scenarios.rs:all;lib/calc.rs:5;"
sh "$NAHUYA" shards all --only-tests >/dev/null
grep -q '^crate/src/kit/world.rs (40 lines)$' $TS/*.txt && ok || bad "submodule of a test module"
sh "$NAHUYA" shards all --no-tests >/dev/null
grep -q 'crate/src/scenarios.rs' .git/nahuya/shards/all/*.txt && bad "--no-tests kept a rust test module" || ok
grep -q 'crate/src/core.rs' .git/nahuya/shards/all/*.txt && ok || bad "--no-tests dropped code with inline tests"
# data is never test code; inventory shows tests and data
mkdir -p spec; lines spec/api.json 200; lines spec/user_spec.rb 10; commit specdata
sh "$NAHUYA" shards all --only-tests >/dev/null
grep -q 'spec/api.json' $TS/*.txt && bad "data counted as tests" || ok
grep -q 'spec/user_spec.rb' $TS/*.txt && ok || bad "spec code kept"
out=$(sh "$NAHUYA" inventory all --only-tests)
printf '%s\n' "$out" | grep -q '^spec/  files=2 lines=210 tests=10 data=200' && ok || bad "inventory tests and data: $out"
printf '%s\n' "$out" | grep -q 'shards/tests-all/plan.md' && ok || bad "tests-only plan path"
sh "$NAHUYA" inventory all --files crate/src/ | grep -q '^    crate/src/core.rs  lines=7 tests=6' && ok || bad "inventory inline tests: $(sh "$NAHUYA" inventory all --files crate/src/)"
# plan tags correct the test split; a component that loses every file is reported
lines lib/fixtures_builder.py 60; commit fb
printf '## helpers [tests]\nlib/fixtures_builder.py\n## lib\nlib/\n## rust\ncrate/\n## web\nweb/\n## rest\nx.py\nspec/\ntests/\nCargo.toml\nplan.md\nplan2.md\ndata/\n' > plan3.md
out=$(sh "$NAHUYA" shards all --only-tests --plan plan3.md)
printf '%s\n' "$out" | grep -q 'component=helpers$' && ok || bad "[tests] tag: $out"
printf '%s\n' "$out" | grep -q '^empty=web (' && ok || bad "empty component reported: $out"
printf '%s\n' "$out" | grep -q '^unassigned=' && bad "filtered files reported as unassigned: $out" || ok
sed 's/^## rust$/## rust [not tests]/' plan3.md > plan4.md
sh "$NAHUYA" shards all --only-tests --plan plan4.md | grep -q '^empty=rust (' && ok || bad "[not tests] tag"
# a running polish keeps its shards
sh "$NAHUYA" shards all --only-tests --plan plan3.md --loop >/dev/null
sh "$NAHUYA" shards all --only-tests >/dev/null 2>&1 && bad "shards replaced under a running polish" || ok
sh "$NAHUYA" shards all >/dev/null 2>&1 && ok || bad "other run's shards blocked"
sh "$NAHUYA" status tests all | grep -q '^scope=tests-only' && ok || bad "status tests all: $(sh "$NAHUYA" status tests all 2>&1)"
sh "$NAHUYA" status --only-tests >/dev/null 2>&1 && ok || bad "status --only-tests"
sh "$NAHUYA" status tests all --prune-tests >/dev/null 2>&1 && ok || bad "status takes the test flags"
sh "$NAHUYA" mark --keep-anchor >/dev/null
sh "$NAHUYA" shards all --only-tests >/dev/null 2>&1 && ok || bad "shards after the run ended"
git rm -q -r crate spec lib/fixtures_builder.py; commit unrust
sh "$NAHUYA" shards all --no-tests --max-lines 850 >/dev/null
grep -l 'lib/a.py' .git/nahuya/shards/all/*.txt | xargs grep -q 'lib/b.py' && ok || bad "module kept together"
awk 'BEGIN { for (i = 1; i <= 12; i++) printf "total = total + value_%d * weight\n", i }' > lib/dup1.py
cp lib/dup1.py web/dup2.py; commit dup
rm -f .git/nahuya/shards/all/shard-*.txt
out=$(sh "$NAHUYA" clones all --no-tests)
[ "$(printf '%s\n' "$out" | sed -n 's/^pairs=//p')" -ge 1 ] && ok || bad "clone pairs: $out"
grep -q 'lib/dup1.py:1-12  <->  web/dup2.py:1-12' .git/nahuya/shards/all/clones.txt && ok || bad "clone ranges: $(cat .git/nahuya/shards/all/clones.txt)"
printf '## lib only\nlib/\n## skip: rest\nweb/\nx.py\nresearch/\ntests/\nCargo.toml\n' > plan2.md
sh "$NAHUYA" shards all --plan plan2.md >/dev/null
sh "$NAHUYA" clones all | grep -q '(from the last shards' && ok || bad "clones reuse shards"
grep -q 'web/dup2.py' .git/nahuya/shards/all/clones.txt && bad "clones ignored the plan" || ok
mkdir -p data; awk 'BEGIN { for (i = 1; i <= 12; i++) printf "{\"k%d\": %d},\n", i, i }' > data/a.json; cp data/a.json data/b.json; commit json
rm -f .git/nahuya/shards/all/shard-*.txt
sh "$NAHUYA" clones all >/dev/null; grep -q 'data/a.json' .git/nahuya/shards/all/clones.txt && bad "json in clones" || ok
# inventory and plans
out=$(sh "$NAHUYA" inventory all --no-tests)
printf '%s\n' "$out" | grep -q '^lib/  files=' && ok || bad "inventory dirs: $out"
printf '%s\n' "$out" | grep -q 'shards/all/plan.md' && ok || bad "inventory plan path"
sh "$NAHUYA" inventory all --files lib/ | grep -q '^  lib/a.py  lines=' && ok || bad "inventory --files"
printf 'x\n' > Cargo.toml; commit manifest
sh "$NAHUYA" inventory all | grep -q '^x.py  lines=' && ok || bad "root files listed"
sh "$NAHUYA" inventory all | grep -q '^\./  manifest=Cargo.toml$' && ok || bad "root manifest shown: $(sh "$NAHUYA" inventory all)"
printf '## core\nlib/\nweb/dup2.py\n## web\nweb/\n## skip: scratch\nx.py\n' > plan.md
out=$(sh "$NAHUYA" shards all --no-tests --plan plan.md)
printf '%s\n' "$out" | grep -q 'component=core$' && ok || bad "plan component: $out"
grep -q 'web/dup2.py' .git/nahuya/shards/all/shard-1.txt && ok || bad "longest match wins"
printf '%s\n' "$out" | grep -q '^planned_skip=skip: scratch (900 lines' && ok || bad "planned skip"
printf '%s\n' "$out" | grep -q '^unassigned=' && ok || bad "unassigned reported"
sh "$NAHUYA" shards all --plan plan.md --fit 2 >/dev/null 2>&1 && bad "fit with plan accepted" || ok
cd "$R" || exit 1

# aliases
T=$WORK/cfg; CLAUDE_CONFIG_DIR=$T sh "$NAHUYA" aliases >/dev/null
[ -f "$T/skills/nah-polish/SKILL.md" ] && grep -q 'nahuya:polish' "$T/skills/nah-polish/SKILL.md" && ok || bad "alias installed"
grep -q '^description: "Short for /nahuya:polish: ' "$T/skills/nah-polish/SKILL.md" && ok || bad "alias description quoted (it contains a colon)"
mkdir -p "$T/skills/nah-mine"; echo mine > "$T/skills/nah-mine/SKILL.md"
CLAUDE_CONFIG_DIR=$T sh "$NAHUYA" aliases remove >/dev/null
[ ! -d "$T/skills/nah-polish" ] && [ -f "$T/skills/nah-mine/SKILL.md" ] && ok || bad "alias remove touched only ours"

# the review and polish skills share the planning steps word for word
blk() { sed -n '/^1\. \*\*Map\.\*\*/,/^   Then run the final/p' "$1" | sed '$d'; }
[ -n "$(blk "$ROOT/skills/review/SKILL.md")" ] && ok || bad "planning block not found"
eq "shared planning steps" "$(blk "$ROOT/skills/review/SKILL.md")" "$(blk "$ROOT/skills/polish/SKILL.md")"

# release scripts: cut [Unreleased] into a version, notes from the changelog, version in plugin.json
RS=$ROOT/.github/scripts; C=$WORK/rel; mkdir -p "$C"
printf '# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- A thing.\n\n## [0.1.0] - 2026-01-01\n\nFirst.\n\n[unreleased]: https://x/compare/v0.1.0...HEAD\n[0.1.0]: https://x/releases/tag/v0.1.0\n' > "$C/CHANGELOG.md"
bash "$RS/cut-changelog.sh" 0.2.0 2026-02-02 "$C/CHANGELOG.md" >/dev/null 2>&1
grep -q '^## \[0.2.0\] - 2026-02-02$' "$C/CHANGELOG.md" && grep -q '^\[0.2.0\]: https://x/compare/v0.1.0...v0.2.0$' "$C/CHANGELOG.md" && ok || bad "cut changelog: $(cat "$C/CHANGELOG.md")"
bash "$RS/cut-changelog.sh" 0.3.0 2026-02-03 "$C/CHANGELOG.md" >/dev/null 2>&1 && bad "empty [Unreleased] released" || ok
eq "release notes" "$(bash "$RS/release-notes.sh" 0.2.0 "$C/CHANGELOG.md" | head -3 | tr '\n' '|')" "### Fixed||- A thing.|"
printf '{\n  "name": "x",\n  "version": "0.1.0",\n  "userConfig": { "a": { "version": "1" } }\n}\n' > "$C/plugin.json"
bash "$RS/set-plugin-version.sh" 0.2.0 "$C/plugin.json" >/dev/null
eq "plugin version set" "$(grep -c '"version": "0.2.0"' "$C/plugin.json")" 1
grep -q '"version": "1"' "$C/plugin.json" && ok || bad "set-plugin-version touched userConfig"
bash "$RS/release-notes.sh" "$(sed -n 's/^  "version": "\(.*\)",$/\1/p' "$ROOT/.claude-plugin/plugin.json")" "$ROOT/CHANGELOG.md" >/dev/null 2>&1 && ok || bad "CHANGELOG.md has no section for the current version"

# session start layer
eq "layer on" "$(echo '{}' | sh "$ROOT/hooks/session-start.sh" | head -c 8)" "(nahuya)"
eq "layer off" "$(echo '{}' | NAHUYA_LAYER=off sh "$ROOT/hooks/session-start.sh")" ""
[ "$(wc -c < "$ROOT/layer.md")" -le 800 ] && ok || bad "layer.md over 800 chars"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
