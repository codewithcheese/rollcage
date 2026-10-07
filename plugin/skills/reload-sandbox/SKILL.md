---
name: reload-sandbox
description: Reload the rollcage sandbox profile after config changes (.rollcage, toolchains). Creates a reload sentinel and tells the user to exit so rollcage restarts with the updated profile.
---

!`touch "$ROLLCAGE_RELOAD_SENTINEL"`

Reload queued. Tell the user:

> Reload queued. Exit claude now (type `/exit` or press Ctrl+C twice) and `rollcage claude` will automatically restart with the updated sandbox profile. Your conversation will resume where you left off.

Do not do anything else. Do not read or modify the `.rollcage` file. Do not attempt to kill the process.
