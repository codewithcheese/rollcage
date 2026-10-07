# rollcage

## Sandbox profile (base-claude.sb)

- Every SBPL statement must have a comment explaining why it exists.

## Working principles

- **Research before guessing.** When unsure about sandbox behavior, SBPL semantics, or macOS internals, use agents or GitHub issues to verify. Don't assume.
- **Test inside the sandbox.** Don't assume rules work — write explicit test commands using `sandbox-exec` with the assembled profile.
- **Security implications first.** Think through what a permission change exposes before suggesting it. Scope as narrowly as possible.
- **Prefer alternatives to widening permissions.** Local installs over global, project-local paths over home paths. Only widen if no alternative exists.
- **Keep rollcage generic.** No tool-specific code in rollcage itself. Tool-specific paths belong in toolchains or project `.rollcage` files.
- **Infrastructure vs project config.** System-level paths (TMPDIR, CACHE_DIR, VOLATILE_DIR) and always-on tools (cmux) belong in base-common.sb or `~/.config/rollcage/config`, not project `.rollcage`.
- **Separate toolchains for separate trade-offs.** e.g. `playwright` (shared cache) vs `playwright-chromium` (macOS integration paths). Don't bundle unrelated concerns.

## Plugin

Plugin source lives in `plugin/`. Manifest at `.claude-plugin/plugin.json` (repo root).

```
.claude-plugin/plugin.json    # manifest, explicitly references plugin/hooks/hooks.json
plugin/
  hooks/hooks.json             # hook config (referenced from manifest)
  hooks/sandbox-denial-hook.sh # PostToolUseFailure hook
  skills/debug-sandbox/        # sandbox debugging skill
```

- The **hook** provides enough context for the model to decide whether to invoke the skill. Detailed instructions belong in the skill, not the hook.
- The **skill** must check `~/.config/rollcage/config` (user-level) before suggesting project rules. Don't duplicate what's already active.
- Update the skill's toolchain table and "base profile already covers" section when adding toolchains or base-claude.sb parameters.

# Development Guide

## Architecture

```
rollcage                  # Unified CLI dispatcher
rollcage.lib.zsh          # Shared initialization, DSL, assembler, trust gate
adapters/<cli>.zsh       # Claude, Codex, Pi, OMP, and OpenCode launch behavior
base-common.sb           # Shared deny-default policy
base-<cli>.sb            # CLI-specific runtime policy
base-protections.sb      # Final write denies after generated grants
toolchains/
  <name>.sb              # Vetted toolchain fragment
  <name>.test.zsh        # Toolchain sandbox tests
  test_helpers.zsh       # Shared test helpers
.claude-plugin/plugin.json # Claude plugin manifest
plugin/                  # Claude hooks and skills
test_rollcage.bash       # Portable DSL tests
test_trust_gate.zsh      # Portable trust tests
test_dispatch.zsh        # Portable dispatcher tests
test_sandbox.zsh         # Claude base and toolchain integration
test_<cli>_sandbox.zsh   # Other CLI base integration
test_protections_sandbox.zsh # Final write denies and read isolation
```

The DSL (`.rollcage` files) is the safety boundary between user/project config and the kernel sandbox. Bundled SBPL is in `base-*.sb` and `toolchains/*.sb` — both are bundled and vetted.

## SBPL parameters

All parameters are passed to `sandbox-exec` via `-D KEY=value` flags in `rollcage`.

| Parameter | Resolves to |
|---|---|
| `HOME` | `/Users/<you>` |
| `PROJECT_DIR` | Absolute path of the project (via `readlink -f`) |
| `TMPDIR` | `/private/var/folders/.../T/` |
| `CACHE_DIR` | `/private/var/folders/.../C/` (sibling of TMPDIR) |
| `VOLATILE_DIR` | `/private/var/folders/.../X/` (sibling of TMPDIR, code-signing clones) |
| `ROLLCAGE_DIR` | Resolved Rollcage installation directory |

Use `(param "NAME")` in SBPL — never hardcode paths.

## Environment variables

rollcage sets these env vars for processes inside the sandbox:

| Variable | Value | Stability |
|---|---|---|
| `ROLLCAGE_ACTIVE` | `1` | **Stable** — shared sandbox detection marker |
| `ROLLCAGE_CLI` | Selected CLI name | **Stable** — `claude`, `codex`, `pi`, `omp`, or `opencode` |
| `ROLLCAGE_COLOR` | `auto`, `always`, or `never` | Optional trust-prompt color preference |
| `ROLLCAGE_DENIAL_LOG` | Path to denial log file | Internal; Claude only |
| `ROLLCAGE_RELOAD_SENTINEL` | Path to reload sentinel | Internal; Claude only |

Check any Rollcage sandbox: `[[ "${ROLLCAGE_ACTIVE:-}" == "1" ]]`.
Check the selected CLI: `[[ "${ROLLCAGE_CLI:-}" == "codex" ]]`.

## Codex support

`rollcage codex` uses the same shared DSL, trust gate, packs, and assembler as `rollcage`, with shared user-level config and a Codex-specific base profile:

- Project config: `.rollcage` (shared by all CLI selections)
- User config: `~/.config/rollcage/config`
- Packs referenced by `.rollcage`: `~/.config/rollcage/packs/<name>`
- Trust ledger: `~/.config/rollcage/trust/codex/trusted`
- Base fragments: `base-common.sb` + `base-codex.sb`

`rollcage codex` resolves the `codex` executable before entering Seatbelt and launches it with `--dangerously-bypass-approvals-and-sandbox`; the outer `sandbox-exec` profile is the sandbox boundary. Keep Codex plugin/hook behavior out of scope until there is a deliberate design for it.

Current Codex install layouts covered by `base-codex.sb`:

- Direct release binary renamed to `~/.local/bin/codex`
- npm install under NVM, including the vendored native binary under `@openai/codex`
- bun global install under `~/.bun`
- Homebrew cask/global npm under `/opt/homebrew` or `/usr/local`

## Pi support

`rollcage pi` uses the same shared DSL, trust gate, packs, and assembler as `rollcage`, with shared user-level config and a Pi-specific base profile:

- Project config: `.rollcage` (shared by all CLI selections)
- User config: `~/.config/rollcage/config`
- Packs referenced by `.rollcage`: `~/.config/rollcage/packs/<name>`
- Trust ledger: `~/.config/rollcage/trust/pi/trusted`
- Base fragments: `base-common.sb` + `base-pi.sb`

`rollcage pi` resolves the `pi` executable before entering Seatbelt and launches it directly — Pi has no built-in approval/sandbox layer to disable, so the binary just runs under the outer `sandbox-exec` profile. Keep Pi plugin/hook behavior out of scope until there is a deliberate design for it.

Current Pi install layouts covered by `base-pi.sb` (only the methods documented at pi.dev/docs):

- npm install -g under NVM, including the vendored native binary under `@earendil-works/pi-coding-agent`
- `curl pi.dev/install.sh` fallback layout: `~/.local/bin/pi` plus the optional vendored node runtime under `~/.local/share/pi-node`
- Intel Homebrew global npm under `/usr/local`

Apple Silicon Homebrew installs are covered by the shared `/opt/homebrew` read+exec rules.

Pi installs runtime packages and TypeScript extensions under `~/.pi/agent/{npm,git,extensions}`. The whole `~/.pi` tree is read+write, but `process-exec` is scoped narrowly to those three subdirs — sessions, `auth.json`, settings, themes, prompts, and other state under `~/.pi` cannot be executed even if a write lands there.

## SBPL rules to know

- `(deny default)` is in `base-common.sb`. Final write denies are appended after all generated grants in `base-protections.sb`; the assembler also protects resolved control-file targets and freezes their ancestor directory entries against replacement.
- **Last-match-wins**: a `(deny)` placed AFTER an `(allow)` overrides it. This is how we protect files inside writable directories.
- Use `(literal)` for exact file paths, `(subpath)` for directories.
- `(path)` allows CANNOT override `(subpath)` denies. But `(literal)` denies CAN override `(subpath)` allows (when the deny comes after).
- Seatbelt resolves symlinks before matching. All paths passed to `sandbox-exec` must be resolved with `readlink -f`.
- Use `(param "HOME")`, `(param "PROJECT_DIR")`, etc. — never hardcode user paths.

## Adding a toolchain

Create two files:

### 1. `toolchains/<name>.sb`

SBPL fragment granting read, write, and exec access for the tool. Use `(param "HOME")` for home-relative paths.

**Every rule MUST have a comment explaining its intent** — why this path is needed and what operation requires it. The `.sb` file should start with a header comment describing what the toolchain provides and how the tool's filesystem layout works.

```scheme
;; Example toolchain
;;
;; tool installs to ~/.tool/bin/ and caches data at ~/.tool/cache/.
;; Config at ~/.tool/config (read-only).

;; Exec — tool binaries
(allow process-exec
  (subpath (string-append (param "HOME") "/.tool/bin")))

;; Read — binaries, cache, and config
(allow file-read-data
  (subpath (string-append (param "HOME") "/.tool")))

(allow file-write*
  (subpath (string-append (param "HOME") "/.tool/cache")))
```

Principle of least privilege: only allow writes to cache/state directories, not the entire tool directory. Keep exec to `bin/` directories.

### 2. `toolchains/<name>.test.zsh`

Sandbox tests using the shared helpers. Follow this pattern:

```zsh
# <Tool name> toolchain sandbox tests
tc_setup <name>

# Create fixture directories and files
tc_fixture_dir "${HOME}/.tool/bin"
tc_fixture_dir "${HOME}/.tool/cache"
tc_fixture_file "${HOME}/.tool/config"

# Test read access
t "<name>: read ~/.tool"
expect_success "allowed" tc_sandboxed cat "${HOME}/.tool/config"

# Test write access
t "<name>: write ~/.tool/cache"
expect_success "allowed" tc_sandboxed touch "${HOME}/.tool/cache/test-write"
rm -f "${HOME}/.tool/cache/test-write"

# Test write is blocked where it should be
t "<name>: ~/.tool/bin not writable"
expect_fail "blocked" tc_sandboxed touch "${HOME}/.tool/bin/test-write"

# Test usability — use full binary paths, not bare names
# (sandbox-exec doesn't search PATH)
__tool_bin="${HOME}/.tool/bin/tool"
[[ -x "$__tool_bin" ]] || __tool_bin="$(command -v tool 2>/dev/null || echo "")"

t "<name>: tool --version"
expect_success "runs" tc_sandboxed "$__tool_bin" --version

# Test real operations, not just --version
t "<name>: tool init project"
expect_success "init" tc_sandboxed "$__tool_bin" init "${PROJECT_DIR}/test-proj"

# Test isolation
t "<name>: ~/.ssh blocked"
expect_fail "blocked" tc_sandboxed cat "${HOME}/.ssh/known_hosts"

tc_cleanup
```

The test runner auto-discovers `toolchains/*.test.zsh` — no registration needed.

**Important CI practices:**
- Use full binary paths (`"$__tool_bin"`) — `sandbox-exec` doesn't search PATH
- `tc_sandboxed` automatically `cd`s to PROJECT_DIR — tools need a readable CWD
- For `/bin/sh -c` wrappers, include `cd '${PROJECT_DIR}' &&` at the start
- Test real operations (install, build, run) not just `--version`
- When a test fails, stderr and sandbox denial logs are shown automatically

### 3. Update README.md

Add the toolchain to the "Available toolchains" table.

### 4. Update `plugin/skills/debug-sandbox/SKILL.md`

Add the toolchain to the skill's toolchain table so the debug-sandbox skill knows about it when diagnosing denials. Update the "base profile already covers" section if relevant.

### 5. Add a CI job

Each toolchain gets its own parallel CI job in `.github/workflows/test.yml`. The job installs the tool at its canonical path and runs `zsh test_sandbox.zsh --toolchain <name>`.

## Adding a pack

Packs are **user data**, not repo assets. They live at `~/.config/rollcage/packs/<pack-name>` and are written in the same DSL as `.rollcage` (minus `pack` itself — no nesting). There is no template to check in, no test harness to wire up: a pack is just a file the user drops in their own config directory.

When working on pack-related code:

- Parser, validator, and generator all go through `rollcage.lib.zsh`. The validator takes a source argument (`user`, `project`, `pack`) — `pack` is only legal with `source=project`, and `pack` with `source=pack` is an error.
- Generator expansion is recursive: a `pack` directive re-runs `__rollcage_parse | __rollcage_validate pack | __rollcage_generate` on the pack file. Keep pipefail enabled in any new pipeline so inner failures abort assembly.
- Trust is per-(project, pack name, pack hash). Ledger entries use `<hash> # <scope> pack <pack_name>` (plus a diagnostic path for repo scope); snapshots are keyed by sha256 of `<scope>|pack|<pack_name>`. Stores are separate under `~/.config/rollcage/trust/<cli>/`.
- `__rollcage_check_pack_trusts` uses fd 3 for its parse feed so the interactive `read` inside `__rollcage_check_pack_trust` still sees user stdin. Don't "simplify" that to a normal while-loop redirect.

## Modifying the base policy (base-claude.sb)

### Adding read access

```scheme
(allow file-read-data
  (subpath (string-append (param "HOME") "/.new-config")))
```

### Adding write access

```scheme
(allow file-write*
  (subpath (string-append (param "HOME") "/.new-state")))
```

### Protecting a file inside a writable directory

Use deny-after-allow (last-match-wins). Put the deny in `base-protections.sb`, which is appended after all base, user, toolchain, pack, and project grants:

```scheme
(deny file-write*
  (literal (string-append (param "PROJECT_DIR") "/.secret-file")))
```

Use `(literal)` for files, `(subpath)` for directories. Add a corresponding sandbox test in `test_sandbox.zsh` under "Blocked writes" and a structural check in `test_rollcage.bash` under "Write protection".

## Running tests

```bash
# DSL pipeline (any platform, fast)
bash test_rollcage.bash

# Sandbox integration — all tests (macOS only)
zsh test_sandbox.zsh

# Base profile only (no toolchains)
zsh test_sandbox.zsh --toolchain none

# Specific toolchain(s)
zsh test_sandbox.zsh --toolchain node
zsh test_sandbox.zsh --toolchain node,uv

# With a custom project config
zsh test_sandbox.zsh --with-config path/to/.rollcage

# Codex base-profile integration
zsh test_codex_sandbox.zsh

# Pi base-profile integration
zsh test_pi_sandbox.zsh

# Dispatcher and final control-file protections
zsh test_dispatch.zsh
zsh test_protections_sandbox.zsh
```

### Test structure

- `test_rollcage.bash` — tests the DSL pipeline in pure bash. Duplicates the parser/validator/generator functions from `rollcage.lib.zsh` since they use zsh syntax. If you change the DSL logic in `rollcage.lib.zsh`, update the corresponding functions in `test_rollcage.bash` too.
- `test_sandbox.zsh` — tests real `sandbox-exec` enforcement for the Claude base profile. Runs base profile tests (reads, writes, exec, escape vectors), then auto-discovers and runs `toolchains/*.test.zsh`.
- `test_codex_sandbox.zsh` — tests real `sandbox-exec` enforcement for the Codex base profile and verifies current Codex can start when installed.
- `test_pi_sandbox.zsh` — tests real `sandbox-exec` enforcement for the Pi base profile and verifies current Pi can start when installed. Also checks the scoped-exec rule under `~/.pi/agent`.
- `toolchains/*.test.zsh` — each file sources `test_helpers.zsh` and tests one toolchain. Creates fixture dirs, verifies access, checks tool usability if installed.

### Test helpers reference

| Helper | Purpose |
|---|---|
| `tc_setup <name>` | Assemble a profile with this toolchain enabled |
| `tc_sandboxed <cmd...>` | Run a command inside the toolchain's sandbox |
| `tc_fixture_dir <path>` | Create a directory (auto-cleaned) |
| `tc_fixture_file <path> [content]` | Create a file (auto-cleaned) |
| `tc_has_cmd <cmd>` | Check if a command exists on the host |
| `tc_cleanup` | Remove profile and fixtures (call at end of test) |
| `t <name>` | Set the current test name |
| `expect_success <desc> <cmd...>` | Assert command succeeds |
| `expect_fail <desc> <cmd...>` | Assert command fails (sandbox blocks it) |

## DSL safety rules

The validator in `rollcage.lib.zsh` enforces:

- Directives: `tool`, `pack` (project only), `allow-read`, `allow-write`, `allow-exec`
- Paths must start with `~/`, `./`, or `/`
- No bare `~` (too broad)
- System-path handling is verb-specific:
  - `allow-read` on `/System`, `/Library`, `/usr`, `/bin`, `/sbin`, `/opt/homebrew` — rejected, base already reads these
  - `allow-write` on those same roots — rejected outright (system paths must not be writable from config)
  - `allow-exec` — only `/bin/*`, `/usr/bin/*`, `/opt/homebrew/*` are rejected as redundant; `/Library/*`, `/usr/libexec/*`, `/usr/local/*`, `/sbin/*`, `/System/*` are allowed so tools like Temurin JDK can be granted exec
- Paths targeting `.rollcage` as basename rejected (config is protected)
- Tool names must be safe basenames (`[A-Za-z0-9_][A-Za-z0-9_-]*`) matching a file in `toolchains/`; paths and traversal are rejected.

If you add a new validation rule, add it to both `rollcage.lib.zsh` and the duplicate in `test_rollcage.bash`.
