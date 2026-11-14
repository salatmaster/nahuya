#!/bin/sh
# nahuya persistent layer: prints layer.md at session start, after /clear and
# after compaction. SessionStart stdout is added to Claude's context.

NH_ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 0
. "$NH_ROOT/lib/nahuya.sh" || exit 0
cat > /dev/null
[ "$(nh_cfg layer)" = on ] || exit 0
cat "$NH_ROOT/layer.md"
