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
    depth) echo auto ;;
    max_rounds) echo 3 ;;
    passes) echo 1 ;;
    reviewer_model) echo inherit ;;
    fix_mode) echo commit ;;
    *) return 1 ;;
  esac
}

NH_KEYS="gate threshold max_rounds passes reviewer_model fix_mode layer shard_lines max_agents depth"

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
    threshold|max_rounds|passes|shard_lines|max_agents)
      case $_v in ''|*[!0-9]*) return 1 ;; esac
      [ "$_v" -ge 1 ] 2>/dev/null || return 1
      echo "$_v" ;;
    reviewer_model)
      case $_v in inherit|opus|fable|sonnet|haiku) echo "$_v" ;; *) return 1 ;; esac ;;
    fix_mode)
      case $_v in commit|amend|uncommitted) echo "$_v" ;; *) return 1 ;; esac ;;
    depth)
      case $_v in auto|normal|deep) echo "$_v" ;; *) return 1 ;; esac ;;
    *) return 1 ;;
  esac
}

# Reads a variable by name. Callers only pass names built from validated keys.
nh_getenv() { eval "printf '%s' \"\${$1-}\""; }

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
  [ -n "$_v" ] || _v=$(nh_plugin_option "$1")
  if [ -n "$_v" ] && _n=$(nh_norm "$1" "$_v"); then printf '%s\tplugin config\n' "$_n"; return; fi
  printf '%s\tdefault\n' "$(nh_default "$1")"
}

nh_cfg() { nh_cfg_src "$1" | cut -f1; }

# Flatten JSON on stdin into "path<TAB>scalar" lines (object keys joined by "/").
nh_json_flatten() {
  LC_ALL=C awk '
    function ws() { while (P <= N && index(" \t\r\n", substr(S, P, 1))) P++ }
    function str(   o, c, e) {
      o = ""; P++
      while (P <= N) {
        c = substr(S, P, 1)
        if (c == "\\") { e = substr(S, P + 1, 1); P += 2
          if (e == "n") o = o " "; else if (e == "t") o = o " "; else if (e == "u") { o = o "?"; P += 4 } else o = o e
          continue }
        if (c == "\"") { P++; return o }
        o = o c; P++
      }
      return o
    }
    function val(path,   c, k, v, i) {
      ws(); c = substr(S, P, 1)
      if (c == "{") {
        P++; ws(); if (substr(S, P, 1) == "}") { P++; return }
        while (P <= N) {
          ws(); k = str(); ws(); P++
          val(path == "" ? k : path "/" k)
          ws(); c = substr(S, P, 1); P++
          if (c != ",") return
        }
        return
      }
      if (c == "[") {
        P++; ws(); i = 0; if (substr(S, P, 1) == "]") { P++; return }
        while (P <= N) { val(path "/" i++); ws(); c = substr(S, P, 1); P++; if (c != ",") return }
        return
      }
      if (c == "\"") { print path "\t" str(); return }
      v = ""; while (P <= N && substr(S, P, 1) !~ /[,}\] \t\r\n]/) { v = v substr(S, P, 1); P++ }
      print path "\t" v
    }
    { S = S (NR > 1 ? "\n" : "") $0 }
    END { N = length(S); P = 1; val("") }'
}

# Plugin settings saved by /plugin configure (pluginConfigs in settings.json).
# Skills can't rely on ${user_config.*} substitution, so read them directly.
nh_plugin_option() {
  for _sf in "${NH_TOP:+$NH_TOP/.claude/settings.local.json}" "${NH_TOP:+$NH_TOP/.claude/settings.json}" \
             "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"; do
    [ -n "$_sf" ] && [ -f "$_sf" ] || continue
    _pv=$(nh_json_flatten < "$_sf" 2>/dev/null | awk -F'\t' -v k="$1" '
      index($1, "pluginConfigs/nahuya@") == 1 && $1 ~ ("/options/" k "$") { print $2; exit }')
    if [ -n "$_pv" ]; then printf '%s' "$_pv"; return 0; fi
  done
}

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
    # History was rewritten (rebase, amend, reset): carry the anchor over.
    if [ -n "$_a" ] && _a=$(nh_rewritten_anchor "$_a" "$1"); then
      printf '%s\n' "$_a" > "$_f"; echo "$_a"; return 0
    fi
  fi
  _a=$(nh_fallback_base "$1" "$2") || return 1
  mkdir -p "$NH_STATE/anchors" && printf '%s\n' "$_a" > "$_f"
  echo "$_a"
}

# Where an anchor ($1) that is no longer in tip's ($2) history ended up. Start
# after the history both share, or after the default branch if tip was rebased
# onto it, then step over the commits that are copies of reviewed ones (same
# patch). Amended or squashed commits have a new patch and count again.
nh_rewritten_anchor() {
  git rev-parse -q --verify "$1^{commit}" >/dev/null 2>&1 || return 1
  _lim=$(git merge-base "$1" "$2" 2>/dev/null)
  [ -n "$_lim" ] || return 1
  if _d=$(nh_default_ref) && _md=$(git merge-base "$_d" "$2" 2>/dev/null) && [ -n "$_md" ] &&
     git merge-base --is-ancestor "$_lim" "$_md" 2>/dev/null; then
    _lim=$_md
  fi
  _r=$(git cherry "$1" "$2" "$_lim" 2>/dev/null | awk '$1 != "-" { exit } { last = $2 } END { print last }')
  echo "${_r:-$_lim}"
}

nh_has_merges() { git rev-list --merges -n 1 "$1..$2" 2>/dev/null | grep -q .; }

# Base for the review diff. Off the default branch, start where the branch left it
# (after a merge of it or a rebase onto it) so other people's code isn't reviewed as ours.
nh_review_base() {
  if ! nh_is_trunk "$3" && _d=$(nh_default_ref); then
    _mb=$(git merge-base "$_d" "$2" 2>/dev/null)
    if [ -n "$_mb" ] && git merge-base --is-ancestor "$1" "$_mb" 2>/dev/null; then
      echo "$_mb"; return
    fi
  fi
  echo "$1"
}

# Commits in $1..$2 (branch $3) that aren't our work: off the default branch, the
# ones it already has (local or remote); on it, pulled commits by other authors.
nh_theirs() {
  _d=$(nh_default_ref) || return 0
  if nh_is_trunk "$3"; then
    _me=$(git var GIT_AUTHOR_IDENT 2>/dev/null | sed -n 's/.*<\(.*\)>.*/\1/p')
    [ -n "$_me" ] || return 0
    _own=$(git rev-list --no-merges "$1..$2" --not "$_d" 2>/dev/null)
    git log --no-merges --format='%H %ae' "$1..$2" 2>/dev/null | NH_OWN=$_own NH_ME=$_me awk '
      BEGIN { n = split(ENVIRON["NH_OWN"], a, "\n"); for (i = 1; i <= n; i++) own[a[i]] = 1; me = tolower(ENVIRON["NH_ME"]) }
      !($1 in own) && tolower($2) != me { print $1 }'
  else
    _lb=${_d#*/}
    git show-ref --verify -q "refs/heads/$_lb" && _lb=refs/heads/$_lb || _lb=
    _own=$(git rev-list --no-merges "$1..$2" --not "$_d" $_lb 2>/dev/null)
    git rev-list --no-merges "$1..$2" 2>/dev/null | NH_OWN=$_own awk '
      BEGIN { n = split(ENVIRON["NH_OWN"], a, "\n"); for (i = 1; i <= n; i++) own[a[i]] = 1 }
      !($0 in own)'
  fi
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

# Data and markup. Never test code, even under tests/ or spec/.
nh_is_data() {
  case $1 in
    *.json|*.jsonc|*.json5|*.yaml|*.yml|*.xml|*.csv|*.tsv|*.toml|*.ini|*.cfg|*.conf|*.properties|*.txt|*.lock|*.snap|\
    *.html|*.htm|*.css|*.scss|*.svg|*.md|*.mdx|*.rst|\
    *.JSON|*.YAML|*.YML|*.XML|*.CSV|*.HTML|*.MD)
      return 0 ;;
  esac
  return 1
}

# Test code in Rust sources, where the compiler marks it rather than the path.
# cwd: anywhere in the repo. Prints "path<TAB>all" for whole test files (modules
# declared under #[cfg(test)], and their submodules) and "path<TAB>N" for files
# whose #[cfg(test)] / #[test] items span N lines. Paths are repo-relative.
nh_rust_tests() {
  (
    cd "${NH_TOP:-.}" || exit 0
    _rs=$(git -c core.quotePath=false ls-files -- '*.rs' 2>/dev/null)
    [ -n "$_rs" ] || exit 0
    git -c core.quotePath=false grep -l -I -E '#\[(cfg\((all\()?test[,)]|test\])' -- '*.rs' 2>/dev/null |
      while IFS= read -r _f; do printf '\001FILE %s\n' "$_f"; cat "$_f"; printf '\n'; done |
      NH_RS=$_rs LC_ALL=C awk '
        function endfile() { if (item) enditem() }
        function enditem() { cnt[file] += ln - start + 1; item = 0 }
        # Scan one line of an open test item: track strings, comments and brackets.
        function scan(s,   i, n, c, rest) {
          n = length(s); i = 1
          while (i <= n) {
            c = substr(s, i, 1)
            if (st == 1) { if (c == "\\") { i += 2; continue } if (c == "\"") st = 0; i++; continue }
            if (st == 2) {
              if (c == "\"" && substr(s, i + 1, rh) == hashes) { st = 0; i += rh + 1; continue }
              i++; continue
            }
            if (st == 3) {
              if (c == "/" && substr(s, i + 1, 1) == "*") { nest++; i += 2; continue }
              if (c == "*" && substr(s, i + 1, 1) == "/") { if (--nest == 0) st = 0; i += 2; continue }
              i++; continue
            }
            if (c == "/" && substr(s, i + 1, 1) == "/") return
            if (c == "/" && substr(s, i + 1, 1) == "*") { st = 3; nest = 1; i += 2; continue }
            if (c == "\"") { st = 1; i++; continue }
            if (c == "r" && (i == 1 || substr(s, i - 1, 1) !~ /[A-Za-z0-9_]/) && match(substr(s, i + 1), /^#*"/)) {
              rh = RLENGTH - 1; hashes = substr(s, i + 1, rh); st = 2; i += RLENGTH + 1; continue
            }
            if (c == "\047") {
              rest = substr(s, i)
              if (match(rest, /^\047(\\[^\047]*|[^\047\\])\047/)) { i += RLENGTH; continue }
              i++; continue
            }
            if (c == "(" || c == "[") par++
            else if (c == ")" || c == "]") par--
            else if (c == "{") { depth++; opened = 1 }
            else if (c == "}") { depth--; if (depth < 0 || (opened && depth == 0)) { enditem(); return } }
            else if ((c == ";" || c == ",") && depth == 0 && par == 0 && !opened) {
              if (c == ";" && match(decl, /(^|[^A-Za-z0-9_])mod[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*$/)) {
                m = substr(decl, RSTART, RLENGTH); sub(/^.*mod[ \t]+/, "", m); sub(/[ \t]+$/, "", m)
                nd++; dpar[nd] = file; dname[nd] = m; dpath[nd] = pathattr
              }
              enditem(); return
            }
            if (depth == 0 && !opened) decl = decl c
            i++
          }
          decl = decl " "
        }
        /^\001FILE / { endfile(); file = substr($0, 7); ln = 0; next }
        {
          ln++
          if (!item) {
            if ($0 !~ /^[ \t]*#\[(cfg\((all\()?test[,)]|test\])/) next
            item = 1; start = ln; depth = 0; par = 0; opened = 0; st = 0; decl = ""; pathattr = ""
          }
          if (match($0, /#\[path[ \t]*=[ \t]*"[^"]*"/)) { pathattr = substr($0, RSTART, RLENGTH); sub(/^[^"]*"/, "", pathattr); sub(/"$/, "", pathattr) }
          scan($0)
        }
        function dirof(p) { if (!sub(/\/[^\/]*$/, "", p)) p = ""; return p }
        function under(d, f) { return d == "" ? f : d "/" f }
        END {
          endfile()
          n = split(ENVIRON["NH_RS"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") rs[a[i]] = 1
          # #[cfg(test)] mod NAME; -> NAME.rs or NAME/mod.rs (a crate root looks in its
          # own directory, any other file in a directory named after it)
          for (j = 1; j <= nd; j++) {
            p = dpar[j]; d = dirof(p); b = p; sub(/.*\//, "", b)
            if (dpath[j] != "") { c = under(d, dpath[j]); while (sub(/(^|\/)\.\//, "/", c)) ; sub(/^\//, "", c); if (c in rs) whole[c] = 1; continue }
            s = b; sub(/\.rs$/, "", s)
            own = (b == "main.rs" || b == "lib.rs" || b == "mod.rs") ? d : under(d, s)
            split(own SUBSEP d, cand, SUBSEP)
            for (k = 1; k <= 2; k++) {
              m = under(cand[k], dname[j])
              if ((m ".rs") in rs) { whole[m ".rs"] = 1; tdir[m "/"] = 1; break }
              if ((m "/mod.rs") in rs) { whole[m "/mod.rs"] = 1; tdir[m "/"] = 1; break }
            }
          }
          for (f in rs) for (t in tdir) if (index(f, t) == 1) { whole[f] = 1; break }
          for (f in whole) print f "\tall"
          for (f in cnt) if (!(f in whole) && cnt[f] > 0) print f "\t" cnt[f]
        }'
  )
}

# Prose and repo metadata: skipped when reviewing a whole directory of existing code.
nh_is_doc() {
  case $1 in
    *.md|*.mdx|*.markdown|*.rst|*.adoc|*.txt|*.svg|\
    README|*/README|LICENSE*|*/LICENSE*|COPYING*|*/COPYING*|NOTICE*|*/NOTICE*|CHANGELOG*|*/CHANGELOG*|\
    .gitignore|*/.gitignore|.gitattributes|*/.gitattributes|.editorconfig|*/.editorconfig|CODEOWNERS|*/CODEOWNERS)
      return 0 ;;
  esac
  return 1
}

# Directories that usually hold non-production code. Whole-repo runs skip them
# by default and report what they skipped.
NH_NONPROD_RE='(^|/)(research|experiments|examples|example|samples|demo|demos|notebooks|bench|benches|benchmarks|fixtures|testdata|test-data|scratch|playground|sandbox|tmp)/'

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
  # The gate counts code that ships: the folders whole-repo runs skip don't count.
  [ "$1" != count ] || _paths=$(printf '%s\n' "$_paths" | grep -v -E "$NH_NONPROD_RE")
  [ -n "$_paths" ] || return 0
  _ex=$(nh_user_excludes)
  _attr=$(printf '%s\n' "$_paths" | git check-attr --stdin linguist-generated linguist-vendored 2>/dev/null |
    awk -F': ' '$3 == "set" || $3 == "true" { print $1 }')
  # Rust test modules: whole test files ("all") and files with inline tests
  _rust=
  if [ "$1" = count ] || [ -n "${NH_ONLY_TESTS-}" ]; then
    case $_paths in *.rs|*.rs"$NH_NL"*) _rust=$(nh_rust_tests) ;; esac
  fi
  printf '%s\n' "$_paths" | while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    nh_builtin_excluded "$_p" && continue
    nh_match_any "$_p" "$_ex" && continue
    if [ "$1" = count ]; then
      nh_is_test "$_p" && continue
      nh_is_doc "$_p" && continue
      nh_is_data "$_p" && continue
      printf '%s\n' "$_rust" | grep -Fxq -- "$_p${NH_TAB}all" && continue
    elif [ -n "${NH_ONLY_TESTS-}" ]; then
      nh_is_data "$_p" && continue
      if ! nh_is_test "$_p"; then
        printf '%s\n' "$_rust" | cut -f1 | grep -Fxq -- "$_p" || continue
      fi
    fi
    printf '%s\n' "$_p"
  done | NH_ATTR=$_attr awk 'BEGIN { n = split(ENVIRON["NH_ATTR"], a, "\n"); for (i = 1; i <= n; i++) skip[a[i]] = 1 } !($0 in skip)'
}

# Added lines of our own code between $1 and $2 (branch $3): no tests, docs, data,
# generated or vendored files, and no commits that came from someone else.
nh_count_added() {
  _s=$(nh_review_base "$1" "$2" "$3")
  _th=$(nh_theirs "$_s" "$2" "$3")
  if [ -z "$_th" ] && ! nh_has_merges "$_s" "$2"; then
    git -c core.quotePath=false diff --numstat --no-renames "$_s" "$2" 2>/dev/null
  else
    # Sum per commit over our own commits, leaving out merges.
    _ours=$(git rev-list --no-merges "$_s..$2" 2>/dev/null | NH_TH=$_th awk '
      BEGIN { n = split(ENVIRON["NH_TH"], a, "\n"); for (i = 1; i <= n; i++) skip[a[i]] = 1 }
      !($0 in skip)')
    [ -z "$_ours" ] || printf '%s\n' "$_ours" |
      git -c core.quotePath=false log --no-walk=unsorted --stdin --numstat --no-renames --format= 2>/dev/null
  fi | nh_sum_kept
}

# stdin: numstat. Sums the added lines of the files the gate counts.
nh_sum_kept() {
  _ns=$(cat)
  _kept=$(printf '%s\n' "$_ns" | awk -F'\t' 'NF >= 3 && $1 != "-" { print $3 }' | sort -u | nh_keep count)
  printf '%s\n' "$_ns" | NH_KEPT=$_kept awk -F'\t' '
    BEGIN { n = split(ENVIRON["NH_KEPT"], k, "\n"); for (i = 1; i <= n; i++) ok[k[i]] = 1 }
    NF >= 3 && $1 != "-" && ($3 in ok) { s += $1 }
    END { print s + 0 }'
}

# Added lines of our own code in uncommitted work (tracked and untracked,
# minus ignored), compared with HEAD.
nh_count_uncommitted() {
  _tree=$(nh_snapshot) || { echo 0; return; }
  git -c core.quotePath=false diff --numstat --no-renames HEAD "$_tree" 2>/dev/null | nh_sum_kept
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
    # Heredoc bodies are data. But an unquoted delimiter lets $( and ` in the body run, and
    # a missing delimiter is more likely a misparse (1 << 2), so those bodies are tokenized.
    function bodies(s, i, n,   k, b, e, line, done) {
      for (k = 1; k <= NH; k++) {
        b = i; done = 0
        while (i <= n && !done) {
          e = index(substr(s, i), "\n"); if (!e) e = n - i + 2
          line = substr(s, i, e - 1); i += e
          if (HX[k]) sub(/^\t+/, "", line)
          done = line == HD[k]
        }
        if (!done || !HQ[k] && (index(substr(s, b, i - b), "$(") || index(substr(s, b, i - b), "`"))) { i = b; break }
      }
      NH = 0; return i
    }
    function tokenize(s,   i, n, c, q, d, j, op, w) {
      split("", T); N = 0; NH = 0; tok = ""; intok = 0; q = ""; n = length(s); i = 1
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
          j = i
          while (i <= n && index("<>&|", substr(s, i, 1))) {
            if (substr(s, i, 1) == "&" && substr(s, i + 1, 1) ~ /[0-9-]/) { i += 2; while (substr(s, i, 1) ~ /[0-9]/) i++; d = 1; break }
            i++
          }
          if (d) { d = 0; continue }
          op = substr(s, j, i - j)
          if (op == "<<" && substr(s, i, 1) == "-") { op = "<<-"; i++ }
          while (substr(s, i, 1) == " " || substr(s, i, 1) == "\t") i++
          j = i
          while (i <= n && substr(s, i, 1) !~ /[ \t\n;&|()<>`]/) i++
          w = substr(s, j, i - j)
          if (op ~ /^<<-?$/ && w != "") {
            HX[++NH] = op == "<<-"; HQ[NH] = w ~ /[\047"\\]/
            gsub(/[\047"\\]/, "", w); HD[NH] = w
          }
          continue
        }
        if (c == "\n" && NH) { sep(); i = bodies(s, i + 1, n); continue }
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

# ---------------------------------------------------------------- clones

# Near-duplicate code across files. stdin: file list (repo-relative), cwd = repo
# top. Lines are whitespace-normalized; blank, brace-only, comment and import
# lines are ignored. Prints "len<TAB>fileA<TAB>startA<TAB>endA<TAB>fileB<TAB>startB<TAB>endB",
# longest first. $1 = minimum normalized lines.
nh_clones() {
  _min=${1:-6}
  while IFS= read -r _f; do
    [ -f "$_f" ] || continue
    printf '\001FILE %s\n' "$_f"; cat "$_f"; printf '\n'
  done | LC_ALL=C awk -v W="$_min" '
    /^\001FILE / { file = substr($0, 7); ln = 0; nn = 0; next }
    {
      ln++; t = $0; gsub(/^[ \t]+|[ \t]+$/, "", t); gsub(/[ \t]+/, " ", t)
      if (t == "" || t ~ /^[][{}();,]+$/ || t ~ /^(\/\/|#|\/\*|\*|--|<!--)/) next
      if (t ~ /^(import|use|from|package|require|#include|using|extern crate|mod) /) next
      nn++; at[file, nn] = ln; txt[nn] = t
      if (nn < W) next
      k = txt[nn - W + 1]; for (j = nn - W + 2; j <= nn; j++) k = k "\n" txt[j]
      if (k in first) {
        split(first[k], a, SUBSEP)
        if (a[1] != file || nn - a[2] >= W)
          printf "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n", a[1], file, nn - a[2], a[2], at[a[1], a[2] - W + 1], at[a[1], a[2]], at[file, nn - W + 1], at[file, nn]
      } else first[k] = file SUBSEP nn
    }' | sort -t "$NH_TAB" -k1,1 -k2,2 -k3,3n -k4,4n | awk -F'\t' -v W="$_min" '
    function flush() { if (have) printf "%d\t%s\t%d\t%d\t%s\t%d\t%d\n", W + last - beg, fa, sa, ea, fb, sb, eb }
    {
      if (have && $1 == fa && $2 == fb && $3 == dg && $4 == last + 1) { last = $4; ea = $6; eb = $8; next }
      flush(); have = 1; fa = $1; fb = $2; dg = $3; beg = $4; last = $4; sa = $5; ea = $6; sb = $7; eb = $8
    }
    END { flush() }' | sort -t "$NH_TAB" -k1,1nr
}
