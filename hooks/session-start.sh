#!/bin/sh
# nahuya persistent layer: prints layer.md at session start, after /clear and
# after compaction. SessionStart stdout is added to Claude's context.

cat > /dev/null
cat "$(dirname "$0")/../layer.md"
