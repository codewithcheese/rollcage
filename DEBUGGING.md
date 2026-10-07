# Debugging the Seatbelt Sandbox

## Quick test

```bash
# Does the base profile load without crashing?
sandbox-exec -D PROJECT_DIR=$(readlink -f $PWD) -D TMPDIR=$(readlink -f $TMPDIR) \
  -D CACHE_DIR=$(readlink -f $TMPDIR | sed 's|/T.*|/C|') -D HOME=$HOME \
  -f base-claude.sb -- /bin/echo "profile ok"

# Does Claude run in print mode?
sandbox-exec -D PROJECT_DIR=$(readlink -f $PWD) -D TMPDIR=$(readlink -f $TMPDIR) \
  -D CACHE_DIR=$(readlink -f $TMPDIR | sed 's|/T.*|/C|') -D HOME=$HOME \
  -f base-claude.sb -- claude --print "Say: hello" < /dev/null

# Does the TUI render? (uses `script` to allocate a real TTY)
timeout 5 script -q /dev/null sandbox-exec -D PROJECT_DIR=$(readlink -f $PWD) \
  -D TMPDIR=$(readlink -f $TMPDIR) \
  -D CACHE_DIR=$(readlink -f $TMPDIR | sed 's|/T.*|/C|') -D HOME=$HOME \
  -f base-claude.sb -- claude < /dev/null 2>&1 | cat -v | head -10
# Look for ANSI escape codes like "Claude Code" — that means the TUI rendered.
```

Note: all paths are resolved with `readlink -f` because Seatbelt resolves symlinks before matching (e.g., `/var` → `/private/var`).

## Viewing sandbox denials

Use `/usr/bin/log` (not `log` — zsh has a built-in that conflicts):

```bash
# Stream all sandbox denials in real time
/usr/bin/log stream --predicate 'eventMessage CONTAINS "Sandbox" AND eventMessage CONTAINS "deny"' --style compact

# Filter for Claude specifically (process name is the version number)
/usr/bin/log stream --predicate 'eventMessage CONTAINS "deny" AND eventMessage CONTAINS "2.1.87"' --style compact

# Show recent denials (last 60 seconds)
/usr/bin/log show --last 60s --predicate 'eventMessage CONTAINS "Sandbox" AND eventMessage CONTAINS "deny"' --style compact
```

### Force denial logging

**Warning**: `(debug deny)` may crash `sandbox-exec` on macOS 14+ (exit code 134). Test before using.

If it works on your macOS version, add `(debug deny)` after `(version 1)` to ensure all denials are logged. Otherwise, rely on `/usr/bin/log show` filtering — sandbox denials are logged by default on most macOS versions.

### Common denial patterns

| Log message | Meaning | Fix |
|---|---|---|
| `deny(1) file-read-data /path/...` | Missing read path | Add `(allow file-read-data (subpath "/path"))` |
| `deny(1) file-write-create /path/...` | Missing write path | Add `(allow file-write* (subpath "/path"))` |
| `deny(1) forbidden-exec-sugid` | Setuid binary execution | Usually harmless (bash), can ignore |
| `deny(1) process-codesigning-status*` | Bun codesigning check | Add `(allow process-codesigning-status*)` |
| `deny(1) user-preference-read` | Preferences API | Add `(allow user-preference-read)` if needed |

## SBPL gotchas

### Exit code 134 (SIGABRT)

The profile has a syntax error or the process can't start. Common causes:

- **Missing `(path "/")`**: `(subpath "/bin")` does NOT include the root directory entry itself. You need `(allow file-read-data (path "/"))` separately.
- **Using `file-read*` for allowlists**: This crashes. Use `file-read-data` for your allowlist and keep `file-read-metadata`, `file-read-xattr`, and `file-map-executable` globally allowed.
- **Invalid operation names**: e.g., `ioctl*` doesn't exist, use `iokit*`.

### Rule precedence: allow vs deny with `path`/`literal`/`subpath`

SBPL rule evaluation is **asymmetric** — allows and denies interact differently:

**Allow `(path)` CANNOT override deny `(subpath)`:**

```scheme
(deny file-read-data (subpath "/Users/tom"))
(allow file-read-data (path "/Users/tom/.zshrc"))  ;; DOES NOT WORK
(allow file-read-data (subpath "/Users/tom/project"))  ;; WORKS (subpath-in-subpath)
```

Individual file allows (`path`/`literal`) cannot punch a hole in a parent `subpath` deny. Only a more specific `subpath` allow can.

**Deny `(literal)` CAN override allow `(subpath)` — last-match-wins:**

```scheme
(allow file-write* (subpath "/Users/tom/project"))
(deny file-write* (literal "/Users/tom/project/.rollcage"))  ;; WORKS — deny after allow
```

When a deny comes **after** a matching allow, the deny wins. This is how you protect specific files inside an otherwise writable directory. Use `(literal)` for exact path matching.

### Symlink resolution

Seatbelt resolves symlinks before applying rules. If `~/.zshrc` -> `~/Documents/GitHub/.../file`, you must allow the resolved target path. Denying `~/Documents` will block `~/.zshrc` even though the symlink is in `~/`.

Check for symlinks: `readlink -f ~/.zshrc`

### `sandbox-exec` cannot nest

```
sandbox-exec: sandbox_apply: Operation not permitted
```

A process already inside a sandbox cannot apply another sandbox. If Claude Code's internal sandbox is enabled, its bash commands will fail. Fix: set `sandbox.enabled: false` in `.claude/settings.local.json`, or use `--setting-sources local`.

### TUI blank screen

If Claude starts but shows nothing, check in order:

1. **`process-codesigning-status*`** — Bun requires this. Without it, the TUI silently fails.
2. **Missing write paths** — Claude writes to `~/.claude.json`, `~/.claude.json.lock`, `~/.claude.json.tmp.*`, and `~/.local/state/claude/locks/`. All must be writable.
3. **Missing temp read** — Claude writes bash output to `/tmp/claude-501/` and reads it back. Both `/private/tmp` and `TMPDIR` need read AND write access.

## Bisection technique

When something breaks, bisect between `(allow default)` and the strict profile:

```scheme
;; Start: everything allowed
(version 1)
(allow default)

;; Step 1: add write restrictions only
(deny file-write*)
(allow file-write* (subpath "/"))  ;; does it still work?

;; Step 2: narrow writes
(deny file-write*)
(allow file-write* (subpath "/specific/paths"))

;; Step 3: add read restrictions
;; ... and so on
```

Use `script -q /dev/null sandbox-exec ... -- claude < /dev/null` with `cat -v` to check TUI output without needing a real terminal.

## Reference: operation categories

Operations that `(deny default)` blocks and you may need to re-allow:

| Category | Purpose |
|---|---|
| `network*` | All network access |
| `mach*` | Mach IPC (system services) |
| `ipc-posix*` | POSIX IPC (semaphores, shared memory) |
| `sysctl*` | System information queries |
| `signal` | Signal delivery |
| `iokit*` | IOKit device access |
| `process-info*` | Process information queries |
| `process-fork` | Fork child processes |
| `process-exec` | Execute binaries |
| `process-codesigning-status*` | Codesigning status checks (Bun needs this) |
| `system*` | Miscellaneous system operations |
| `user-preference-read` | CFPreferences API reads |
| `file-read-metadata` | stat, lstat, realpath |
| `file-read-xattr` | Extended attribute reads |
| `file-read-data` | Actual file content reads |
| `file-map-executable` | mmap executable pages (dyld) |
| `file-write*` | All file write operations |
| `file-ioctl` | ioctl on file descriptors |
