---
name: skip
description: Skip nahuya review of the commits up to the current HEAD, so the push gate stops counting them.
disable-model-invocation: true
---

!`sh "${CLAUDE_PLUGIN_ROOT}/bin/nahuya" skip`

Tell the user in one line what the output above says. If a push was blocked
earlier in this session, run it again.
