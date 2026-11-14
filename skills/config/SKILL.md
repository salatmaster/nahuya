---
name: config
description: Show or change nahuya settings (gate, threshold, max-rounds, model, fix-mode, layer, shard-lines, max-agents).
argument-hint: "[key value] [--global]"
disable-model-invocation: true
---

!`sh "${CLAUDE_PLUGIN_ROOT}/bin/nahuya" config --defaults 'gate=${user_config.gate} threshold=${user_config.threshold} max_rounds=${user_config.max_rounds} reviewer_model=${user_config.reviewer_model} fix_mode=${user_config.fix_mode} layer=${user_config.layer} shard_lines=${user_config.shard_lines} max_agents=${user_config.max_agents}' $ARGUMENTS`

Show the output above to the user as is.
