---
name: config
description: Show or change nahuya settings (gate, threshold, max-rounds, model, fix-mode, layer).
argument-hint: "[key value] [--global]"
disable-model-invocation: true
---

!`sh "${CLAUDE_PLUGIN_ROOT}/bin/nahuya" config --defaults 'gate=${user_config.gate} threshold=${user_config.threshold} max_rounds=${user_config.max_rounds} reviewer_model=${user_config.reviewer_model} fix_mode=${user_config.fix_mode} layer=${user_config.layer}' $ARGUMENTS`

Show the output above to the user as is.
