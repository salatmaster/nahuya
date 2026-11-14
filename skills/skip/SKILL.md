---
name: skip
description: Let the next push of the current HEAD through the nahuya gate without review.
disable-model-invocation: true
---

!`sh "${CLAUDE_PLUGIN_ROOT}/bin/nahuya" skip`

Tell the user in one line what the output above says. If a push was blocked
earlier in this session, run it again.
