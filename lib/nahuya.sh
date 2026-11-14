# shellcheck shell=sh
# Shared functions for the nahuya hooks and the `nahuya` CLI.
# POSIX sh + git + awk only, so it runs under macOS /bin/sh, Linux and Git Bash.

NH_TAB=$(printf '\t')
NH_NL='
'

nh_die() { printf 'nahuya: %s\n' "$*" >&2; exit 1; }

nh_tmp() { mktemp "${TMPDIR:-/tmp}/nahuya.XXXXXX"; }

# ---------------------------------------------------------------- config

nh_default() {
  case $1 in
    gate|layer) echo on ;;
    threshold) echo 500 ;;
    shard_lines) echo 3000 ;;
    max_agents) echo 10 ;;
    max_rounds) echo 3 ;;
    reviewer_model) echo inherit ;;
    fix_mode) echo commit ;;
    *) return 1 ;;
  esac
}

NH_KEYS="gate threshold max_rounds reviewer_model fix_mode layer shard_lines max_agents"

# Canonical key from what a user types: max-rounds, MAX_ROUNDS, model, fix-mode.
nh_key() {
  _k=$(printf '%s' "$1" | tr 'A-Z-' 'a-z_')
  [ "$_k" = model ] && _k=reviewer_model
  nh_default "$_k" >/dev/null 2>&1 || return 1
  printf '%s\n' "$_k"
}

# Validate and normalize a value; prints it, or returns 1 if invalid.
nh_norm() {
  _v=$(printf '%s' "$2" | tr 'A-Z' 'a-z')
  case $1 in
    gate|layer)
      case $_v in on|true|yes|1) echo on ;; off|false|no|0) echo off ;; *) return 1 ;; esac ;;
    threshold|max_rounds|shard_lines|max_agents)
      case $_v in ''|*[!0-9]*) return 1 ;; esac
      [ "$_v" -ge 1 ] 2>/dev/null || return 1
      echo "$_v" ;;
    reviewer_model)
      case $_v in inherit|opus|fable|sonnet|haiku) echo "$_v" ;; *) return 1 ;; esac ;;
    fix_mode)
      case $_v in commit|amend|uncommitted) echo "$_v" ;; *) return 1 ;; esac ;;
    *) return 1 ;;
  esac
}

# Reads a variable by name. Callers only pass names built from validated keys.
nh_getenv() { eval "printf '%s' \"\${$1-}\""; }

# Plugin-config defaults handed over by a skill: --defaults 'k=v k=v'.
NH_USER_DEFAULTS=${NH_USER_DEFAULTS-}
nh_userdefault() {
  set -f
  for _kv in $NH_USER_DEFAULTS; do
    case $_kv in "$1="*) set +f; printf '%s' "${_kv#*=}"; return 0 ;; esac
  done
  set +f
}

# nh_cfg_src KEY -> "value<TAB>source". Precedence:
# env NAHUYA_* > git config nahuya.* (repo, then global) > plugin userConfig > default.
# Invalid values at one level fall through to the next.
nh_cfg_src() {
  _K=$(printf '%s' "$1" | tr 'a-z' 'A-Z')
  _v=$(nh_getenv "NAHUYA_$_K")
  if [ -n "$_v" ] && _n=$(nh_norm "$1" "$_v"); then printf '%s\tenv NAHUYA_%s\n' "$_n" "$_K"; return; fi
  _gk=nahuya.$(printf '%s' "$1" | tr _ -)
  _v=$(git config --get "$_gk" 2>/dev/null)
  if [ -n "$_v" ] && _n=$(nh_norm "$1" "$_v"); then
    _scope=$(git config --show-scope --get "$_gk" 2>/dev/null | cut -f1)
    printf '%s\tgit config (%s)\n' "$_n" "${_scope:-git}"; return
  fi
  _v=$(nh_getenv "CLAUDE_PLUGIN_OPTION_$_K")
  [ -n "$_v" ] || _v=$(nh_userdefault "$1")
  if [ -n "$_v" ] && _n=$(nh_norm "$1" "$_v"); then printf '%s\tplugin config\n' "$_n"; return; fi
  printf '%s\tdefault\n' "$(nh_default "$1")"
}

nh_cfg() { nh_cfg_src "$1" | cut -f1; }

# ---------------------------------------------------------------- repo

# Enter the repo containing $1 (or cwd). Sets NH_TOP and NH_STATE.
nh_enter_repo() {
  if [ -n "${1-}" ]; then cd "$1" 2>/dev/null || return 1; fi
  NH_TOP=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$NH_TOP" ] || return 1
  _gd=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
  NH_STATE=$(cd "$_gd" && pwd)/nahuya || return 1
}

nh_short() { git rev-parse --short "$1" 2>/dev/null || printf '%.7s' "$1"; }

nh_branch_key() {
  _b=${1:-detached}
  printf '%s' "$_b" | tr -c 'A-Za-z0-9._-' '_'
}

# Resolve what is being pushed. Sets NH_TIP (sha) and NH_BRANCH (may be empty).
nh_resolve_tip() {
  _spec=${1:-HEAD}
  case $_spec in refs/heads/*) _spec=${_spec#refs/heads/} ;; esac
  NH_TIP=$(git rev-parse -q --verify "$_spec^{commit}" 2>/dev/null) || return 1
  case $_spec in
    HEAD|@) NH_BRANCH=$(git symbolic-ref -q --short HEAD 2>/dev/null) ;;
    *) if git show-ref --verify -q "refs/heads/$_spec"; then NH_BRANCH=$_spec; else NH_BRANCH=; fi ;;
  esac
}

# The remote default branch, e.g. origin/main.
nh_default_ref() {
  _r=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)
  if [ -n "$_r" ]; then echo "$_r"; return 0; fi
  for _r in origin/main origin/master; do
    if git rev-parse -q --verify "refs/remotes/$_r" >/dev/null 2>&1; then echo "$_r"; return 0; fi
  done
  return 1
}

nh_is_trunk() {
  [ -n "$1" ] || return 1
  _d=$(nh_default_ref) || return 1
  [ "$1" = "${_d#*/}" ]
}

# Where unreviewed code starts when nothing is recorded yet:
# the branch upstream, else the merge-base with the remote default branch.
nh_fallback_base() {
  if [ -n "$2" ] && _u=$(git rev-parse -q --verify "$2@{upstream}^{commit}" 2>/dev/null); then
    git merge-base "$_u" "$1" 2>/dev/null && return 0
  fi
  _d=$(nh_default_ref) || return 1
  git merge-base "$_d" "$1" 2>/dev/null
}

# The anchor: first unreviewed point on this branch. Persisted per branch so that
# small pushes accumulate instead of each slipping under the threshold.
nh_anchor() {
  _f=$NH_STATE/anchors/$(nh_branch_key "$2")
  if [ -f "$_f" ]; then
    _a=$(cat "$_f")
    if [ -n "$_a" ] && git merge-base --is-ancestor "$_a" "$1" 2>/dev/null; then
      echo "$_a"; return 0
    fi
  fi
  _a=$(nh_fallback_base "$1" "$2") || return 1
  [ -n "$_a" ] || return 1
  mkdir -p "$NH_STATE/anchors" && printf '%s\n' "$_a" > "$_f"
  echo "$_a"
}

nh_has_merges() { git rev-list --merges -n 1 "$1..$2" 2>/dev/null | grep -q .; }

# Base for the review diff. If the default branch was merged in after the anchor,
# diff from the merge-base so other people's merged code isn't reviewed as ours.
nh_review_base() {
  if nh_has_merges "$1" "$2" && ! nh_is_trunk "$3" && _d=$(nh_default_ref); then
    _mb=$(git merge-base "$_d" "$2" 2>/dev/null)
    if [ -n "$_mb" ] && git merge-base --is-ancestor "$1" "$_mb" 2>/dev/null; then
      echo "$_mb"; return
    fi
  fi
  echo "$1"
}

# ---------------------------------------------------------------- file filters

nh_builtin_excluded() {
  case $1 in
    *package-lock.json|*npm-shrinkwrap.json|*yarn.lock|*pnpm-lock.yaml|*bun.lock|*bun.lockb|\
    *Cargo.lock|*poetry.lock|*Pipfile.lock|*uv.lock|*pdm.lock|*composer.lock|*Gemfile.lock|\
    *go.sum|*flake.lock|*mix.lock|*pubspec.lock|*Podfile.lock|*packages.lock.json|*gradle.lockfile|\
    vendor/*|*/vendor/*|node_modules/*|*/node_modules/*|third_party/*|*/third_party/*|\
    dist/*|*/dist/*|build/*|*/build/*|\
    *.min.js|*.min.css|*.min.mjs|*.js.map|*.css.map|*.snap|\
    *.pb.go|*.pb.cc|*.pb.h|*_pb2.py|*_pb2.pyi|*_pb2_grpc.py|\
    *_generated.*|*.generated.*|*.g.dart|*.freezed.dart|*.designer.cs|*.Designer.cs)
      return 0 ;;
  esac
  return 1
}

nh_is_test() {
  case $1 in
    test/*|*/test/*|tests/*|*/tests/*|__tests__/*|*/__tests__/*|spec/*|*/spec/*|\
    *_test.*|*.test.*|*.spec.*|*_spec.rb|test_*.py|*/test_*.py|\
    *Test.java|*Tests.java|*Test.kt|*Tests.kt|*Tests.cs|*Test.cs|*Tests.swift)
      return 0 ;;
  esac
  return 1
}

# Prose and repo metadata: skipped when reviewing a whole directory of existing code.
nh_is_doc() {
  case $1 in
    *.md|*.mdx|*.markdown|*.rst|*.adoc|*.txt|*.svg|\
    LICENSE*|*/LICENSE*|COPYING*|*/COPYING*|NOTICE*|*/NOTICE*|CHANGELOG*|*/CHANGELOG*|\
    .gitignore|*/.gitignore|.gitattributes|*/.gitattributes|.editorconfig|*/.editorconfig|CODEOWNERS|*/CODEOWNERS)
      return 0 ;;
  esac
  return 1
}

# .nahuya.md front matter (between the first two --- lines).
nh_md_front() {
  [ -f "$NH_TOP/.nahuya.md" ] || return 0
  tr -d '\r' < "$NH_TOP/.nahuya.md" | awk 'NR == 1 && $0 != "---" { exit } NR == 1 { next } $0 == "---" { exit } { print }'
}

nh_md_scalar() {
  nh_md_front | awk -v k="$1" '
    index($0, k ":") == 1 {
      v = substr($0, length(k) + 2); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
      print v; exit
    }'
}

nh_md_list() {
  nh_md_front | awk -v k="$1" '
    function emit(v) { sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
      if (v != "") print v }
    inlist && /^[ \t]+-[ \t]/ { sub(/^[ \t]+-[ \t]+/, ""); emit($0); next }
    inlist && /^[^ \t]/ { inlist = 0 }
    index($0, k ":") == 1 {
      v = substr($0, length(k) + 2); sub(/^[ \t]+/, "", v)
      if (v == "") { inlist = 1; next }
      gsub(/^\[|\]$/, "", v); n = split(v, parts, ",")
      for (i = 1; i <= n; i++) emit(parts[i])
    }'
}

# User exclude globs from .nahuya.md, turned into case patterns ('*' matches '/').
nh_user_excludes() {
  nh_md_list exclude | while IFS= read -r _g; do
    _any=
    case $_g in '**/'*) _g=${_g#'**/'}; _any=1 ;; esac
    _g=$(printf '%s' "$_g" | sed 's#\*\*#*#g')
    case $_g in
      /*) _g=${_g#/}; case $_g in */) echo "${_g}*" ;; *) echo "$_g"; echo "$_g/*" ;; esac ;;
      */) echo "${_g}*"; echo "*/${_g}*" ;;
      */*) echo "$_g"; echo "$_g/*"; [ -z "$_any" ] || { echo "*/$_g"; echo "*/$_g/*"; } ;;
      *) echo "$_g"; echo "*/$_g"; echo "$_g/*"; echo "*/$_g/*" ;;
    esac
  done
}

nh_match_any() {
  [ -n "$2" ] || return 1
  _old_ifs=$IFS; IFS=$NH_NL; set -f
  for _pat in $2; do
    case $1 in $_pat) IFS=$_old_ifs; set +f; return 0 ;; esac
  done
  IFS=$_old_ifs; set +f
  return 1
}

# stdin: paths. stdout: paths kept. $1 = count (also drops tests) | review.
nh_keep() {
  _paths=$(cat)
  [ -n "$_paths" ] || return 0
  _ex=$(nh_user_excludes)
  _attr=$(printf '%s\n' "$_paths" | git check-attr --stdin linguist-generated linguist-vendored 2>/dev/null |
    awk -F': ' '$3 == "set" || $3 == "true" { print $1 }')
  printf '%s\n' "$_paths" | while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    nh_builtin_excluded "$_p" && continue
    if [ "$1" = count ] && nh_is_test "$_p"; then continue; fi
    nh_match_any "$_p" "$_ex" && continue
    printf '%s\n' "$_p"
  done | NH_ATTR=$_attr awk 'BEGIN { n = split(ENVIRON["NH_ATTR"], a, "\n"); for (i = 1; i <= n; i++) skip[a[i]] = 1 } !($0 in skip)'
}

# Added lines of kept, non-test files between $1 and $2 (branch $3).
nh_count_added() {
  _ns=$(nh_tmp)
  if nh_has_merges "$1" "$2"; then
    # Sum per commit, leaving out merges and commits that came from the default branch.
    if ! nh_is_trunk "$3" && _d=$(nh_default_ref); then
      git -c core.quotePath=false log --no-merges --numstat --no-renames --format= "$1..$2" --not "$_d" > "$_ns" 2>/dev/null
    else
      git -c core.quotePath=false log --no-merges --numstat --no-renames --format= "$1..$2" > "$_ns" 2>/dev/null
    fi
  else
    git -c core.quotePath=false diff --numstat --no-renames "$1" "$2" > "$_ns" 2>/dev/null
  fi
  _kept=$(awk -F'\t' 'NF >= 3 && $1 != "-" { print $3 }' "$_ns" | sort -u | nh_keep count)
  NH_KEPT=$_kept awk -F'\t' '
    BEGIN { n = split(ENVIRON["NH_KEPT"], k, "\n"); for (i = 1; i <= n; i++) ok[k[i]] = 1 }
    NF >= 3 && $1 != "-" && ($3 in ok) { s += $1 }
    END { print s + 0 }' "$_ns"
  rm -f "$_ns"
}

# ---------------------------------------------------------------- diffs

# Snapshot of the working tree (tracked + untracked, minus ignored) as a tree id.
nh_snapshot() {
  _idx=$(nh_tmp); rm -f "$_idx"
  cp "$(git rev-parse --git-path index)" "$_idx" 2>/dev/null
  GIT_INDEX_FILE=$_idx git add -A -- ":/" >/dev/null 2>&1
  GIT_INDEX_FILE=$_idx git write-tree
  rm -f "$_idx"
}

# Write a reviewable diff from $1 to $2 (commits or trees) into $3, without
# generated, vendored, lock or user-excluded files. Prints the kept file count.
nh_write_diff() {
  _from=$1; _to=$2; _out=$3
  _keep=$(git -c core.quotePath=false diff --numstat --no-renames "$_from" "$_to" 2>/dev/null |
    awk -F'\t' 'NF >= 3 { print $3 }' | nh_keep review)
  _n=$(printf '%s' "$_keep" | grep -c . || true)
  {
    printf '# nahuya diff %s..%s (%s files; generated, vendored and lock files left out)\n' \
      "$(printf '%.12s' "$_from")" "$(printf '%.12s' "$_to")" "$_n"
    if [ -n "$_keep" ]; then
      set --
      while IFS= read -r _p; do set -- "$@" ":(top,literal)$_p"; done <<EOF
$_keep
EOF
      git -c core.quotePath=false diff --no-color "$_from" "$_to" -- "$@"
    fi
  } > "$_out"
  echo "$_n"
}

# ---------------------------------------------------------------- ledger

nh_ledger_path() {
  printf '%s/ledger/%.12s-%s.tsv\n' "$NH_STATE" "$1" "$(nh_branch_key "$2")"
}

# Last decision per id in a ledger: prints "decision<TAB>category<TAB>id".
nh_ledger_final() {
  awk -F'\t' '!/^#/ && NF >= 4 { d[$4] = $2; c[$4] = $3; if (!($4 in seen)) { seen[$4] = 1; order[++n] = $4 } }
    END { for (i = 1; i <= n; i++) print d[order[i]] "\t" c[order[i]] "\t" order[i] }' "$@" 2>/dev/null
}

# ---------------------------------------------------------------- hook input

# Extract a JSON string value by key from stdin (first match, any depth).
nh_json_str() {
  NH_KEY=$1 LC_ALL=C awk '
    function hexval(h,   i, v, c) { v = 0; h = tolower(h)
      for (i = 1; i <= 4; i++) { c = index("0123456789abcdef", substr(h, i, 1)) - 1; if (c < 0) return 63; v = v * 16 + c }
      return v }
    function u8(cp) {
      if (cp < 1) return ""
      if (cp < 128) return sprintf("%c", cp)
      if (cp < 2048) return sprintf("%c%c", 192 + int(cp / 64), 128 + cp % 64)
      return sprintf("%c%c%c", 224 + int(cp / 4096), 128 + int(cp / 64) % 64, 128 + cp % 64) }
    { s = s (NR > 1 ? "\n" : "") $0 }
    END {
      key = ENVIRON["NH_KEY"]; n = length(s); i = 1; want = 0
      while (i <= n) {
        c = substr(s, i, 1)
        if (c != "\"") { i++; continue }
        str = ""; i++
        while (i <= n) {
          c = substr(s, i, 1)
          if (c == "\\") {
            e = substr(s, i + 1, 1); i += 2
            if (e == "n") str = str "\n"; else if (e == "t") str = str "\t"; else if (e == "r") str = str "\r"
            else if (e == "b") str = str "\b"; else if (e == "f") str = str "\f"
            else if (e == "u") { str = str u8(hexval(substr(s, i, 4))); i += 4 }
            else str = str e
            continue
          }
          if (c == "\"") { i++; break }
          str = str c; i++
        }
        if (want) { printf "%s", str; exit }
        if (str != key) continue
        j = i; while (substr(s, j, 1) ~ /[ \t\r\n]/) j++
        if (substr(s, j, 1) != ":") continue
        j++; while (substr(s, j, 1) ~ /[ \t\r\n]/) j++
        if (substr(s, j, 1) == "\"") { want = 1; i = j }
      }
    }'
}

# Find pushes in a shell command. $1 = command, $2 = space-separated git aliases
# that expand to a push. Prints "dir<TAB>tip" per push (dir relative to the hook
# cwd, or absolute; empty = cwd). Quote-aware; handles chains, subshells,
# `bash -c`, env/sudo wrappers, `cd`, `git -C`, aliases and `gh pr create`.
nh_detect_pushes() {
  NH_CMD=$1 NH_ALIASES=" $2 " awk '
    function addtok() { if (intok) { T[++N] = tok; tok = ""; intok = 0 } }
    function sep() { addtok(); if (N > 0 && T[N] != SEP) T[++N] = SEP }
    function tokenize(s,   i, n, c, q, d) {
      split("", T); N = 0; tok = ""; intok = 0; q = ""; n = length(s); i = 1
      while (i <= n) {
        c = substr(s, i, 1)
        if (q == "\047") { if (c == "\047") q = ""; else tok = tok c; i++; continue }
        if (q == "\"") {
          if (c == "\\" && i < n && index("\"\\$`", substr(s, i + 1, 1))) { tok = tok substr(s, i + 1, 1); i += 2; continue }
          if (c == "\"") q = ""; else tok = tok c
          i++; continue
        }
        if (c == "\\") { if (substr(s, i + 1, 1) != "\n") { tok = tok substr(s, i + 1, 1); intok = 1 } i += 2; continue }
        if (c == "\047" || c == "\"") { q = c; intok = 1; i++; continue }
        if (c == " " || c == "\t") { addtok(); i++; continue }
        if (c == "#" && !intok) { while (i <= n && substr(s, i, 1) != "\n") i++; continue }
        if (c == ">" || c == "<") {
          if (intok && tok ~ /^[0-9]+$/) { tok = ""; intok = 0 } else addtok()
          while (i <= n && index("<>&|", substr(s, i, 1))) {
            if (substr(s, i, 1) == "&" && substr(s, i + 1, 1) ~ /[0-9-]/) { i += 2; while (substr(s, i, 1) ~ /[0-9]/) i++; d = 1; break }
            i++
          }
          if (d) { d = 0; continue }
          while (substr(s, i, 1) == " " || substr(s, i, 1) == "\t") i++
          while (i <= n && substr(s, i, 1) !~ /[ \t\n;&|()<>`]/) i++
          continue
        }
        if (index(";&|()`\n", c)) { sep(); i++; continue }
        if (c == "$" && substr(s, i + 1, 1) == "(") { sep(); i += 2; continue }
        tok = tok c; intok = 1; i++
      }
      addtok()
    }
    function join(base, d) {
      if (d ~ /^\// || d ~ /^[A-Za-z]:/) return d
      if (d == "~" || d ~ /^~\//) return ENVIRON["HOME"] substr(d, 2)
      return base == "" ? d : base "/" d
    }
    function emit(dir, tip,   k) { k = dir "\t" tip; if (!(k in out)) { out[k] = 1; print k } }
    function basename(p) { sub(/.*[\/\\]/, "", p); sub(/\.exe$/, "", p); return p }
    function push_args(i, e, dir,   t, del, dry, tags, np, P, r, src, k) {
      del = dry = tags = np = 0
      for (; i <= e; i++) {
        t = T[i]
        if (t == "--") { for (i++; i <= e; i++) P[++np] = T[i]; break }
        if (t ~ /^-/) {
          if (t == "-d" || t == "--delete") del = 1
          else if (t == "-n" || t == "--dry-run") dry = 1
          else if (t == "--tags") tags = 1
          else if (t == "-o" || t == "--push-option" || t == "--repo" || t == "--receive-pack" || t == "--exec") i++
          else if (t ~ /^-[A-Za-z][A-Za-z]+$/) { if (index(t, "n")) dry = 1; if (index(t, "d")) del = 1 }
          continue
        }
        P[++np] = t
      }
      if (del || dry) return
      if (np <= 1) { if (!tags) emit(dir, "HEAD"); return }
      for (k = 2; k <= np; k++) {
        r = P[k]; sub(/^\+/, "", r)
        if (r ~ /^:/) continue
        src = r; sub(/:.*/, "", src)
        if (src != "") { emit(dir, src); return }
      }
    }
    function git_cmd(i, e, dir,   t) {
      for (; i <= e; i++) {
        t = T[i]
        if (t !~ /^-/) break
        if (t == "-C" && i + 1 <= e) { dir = join(dir, T[i + 1]); i++ }
        else if (t == "-c" || t == "--git-dir" || t == "--work-tree" || t == "--namespace" || t == "--config-env") i++
      }
      if (i > e) return
      if (T[i] == "push" || index(ENVIRON["NH_ALIASES"], " " T[i] " ")) push_args(i + 1, e, dir)
    }
    function segment(b, e,   i, t, c0) {
      i = b
      while (i <= e) {
        t = T[i]
        if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { i++; continue }
        if (t == "command" || t == "builtin" || t == "exec" || t == "nohup" || t == "time" || t == "noglob") { i++; continue }
        if (t == "env" || t == "sudo") { i++; while (i <= e && (T[i] ~ /^-/ || T[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/)) { if (T[i] == "-u" || T[i] == "-C") i++; i++ } continue }
        if (t == "timeout") { i++; while (i <= e && T[i] ~ /^-/) i++; i++; continue }
        break
      }
      if (i > e) return
      c0 = basename(T[i])
      if ((c0 == "cd" || c0 == "pushd") && i + 1 <= e && T[i + 1] !~ /^-/) { CUR = join(CUR, T[i + 1]); return }
      if ((c0 == "bash" || c0 == "sh" || c0 == "zsh" || c0 == "dash") && i + 2 <= e && T[i + 1] == "-c") { PENDING[++NP] = T[i + 2]; PDIR[NP] = CUR; return }
      if (c0 == "git") { git_cmd(i + 1, e, CUR); return }
      if (c0 == "gh" && i + 2 <= e && T[i + 1] == "pr" && T[i + 2] == "create") emit(CUR, "HEAD")
    }
    function run(s, dir,   b, i) {
      tokenize(s); CUR = dir; b = 1
      for (i = 1; i <= N + 1; i++) {
        if (i == N + 1 || T[i] == SEP) { if (i > b) segment(b, i - 1); b = i + 1 }
      }
    }
    BEGIN {
      SEP = "\001"
      NP = 1; PENDING[1] = ENVIRON["NH_CMD"]; PDIR[1] = ""
      for (p = 1; p <= NP && p <= 8; p++) run(PENDING[p], PDIR[p])
    }'
}
