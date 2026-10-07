# rollcage

A macOS Seatbelt sandbox for agent CLIs — [Claude Code](https://claude.com/claude-code) via `rollcage claude`, Codex CLI via `rollcage codex`, the [Pi coding agent](https://pi.dev) via `rollcage pi`, [Oh My Pi](https://github.com/can1357/oh-my-pi) via `rollcage omp`, and [OpenCode](https://opencode.ai) via `rollcage opencode`. Each adapter runs the underlying agent in `sandbox-exec` with a strict, layered SBPL profile so the agent can only read and write files you've explicitly allowed.

## Why

By default Claude Code can read and write anywhere your shell can — including `~/.ssh`, `~/.aws`, browser profiles, shell history, and any document on disk. Anthropic ships a built-in sandbox option (`sandbox.enabled` in settings) but it has [known issues](https://github.com/anthropics/claude-code/issues/31473) on macOS: `denyRead` is ineffective, `allowRead` doesn't exist in the schema, and the generated SBPL profiles can crash the process silently.

rollcage replaces it with a hand-tuned Seatbelt profile that **defaults to strict deny**, lets you opt in to extra access via a tiny safe DSL, and ships with a Claude Code plugin so the agent helps you fix denials instead of working around them.

For Codex CLI, `rollcage codex` uses the same outer Seatbelt boundary and starts Codex with `--dangerously-bypass-approvals-and-sandbox`. That disables Codex's own approval/sandbox layer because the OS sandbox assembled by rollcage codex is the enforcement boundary.

For the Pi coding agent, `rollcage pi` uses the same outer Seatbelt boundary. Pi has no built-in approval/sandbox layer to disable, so the binary runs with whatever arguments you pass through — the OS sandbox is the only enforcement layer.

For Oh My Pi, `rollcage omp` passes `--auto-approve` to bypass OMP's application-level permission prompts while applying the same outer Seatbelt boundary. OMP's DeepSeek API keys and OpenAI Codex OAuth credentials stay in its own SQLite store under `~/.omp`; `rollcage omp` does not expose Codex CLI's auth file or the macOS Keychain.

For OpenCode, `rollcage opencode` passes `--auto` to bypass OpenCode's application-level permission prompts while applying the outer Seatbelt boundary. OpenCode's credentials and session database remain in its app-specific data directory; unrelated agent credentials and the macOS Keychain stay blocked.

## What it protects

The sandbox primarily enforces **filesystem isolation**. Network, POSIX IPC, and Mach ports are open; System V IPC remains blocked unless an opt-in toolchain grants it — see [Known limitations](#known-limitations) for the trade-offs.

### Reads, writes, exec

| Operation | Default policy |
|---|---|
| `file-read-data` | Strict allowlist: system runtime, Claude config, project directory, declared toolchains |
| `file-write*` | Project directory, Claude state files, tmp directories, code-signing clones — nothing else without an explicit rule |
| `process-exec` | System binaries, Homebrew, Claude binary, project scripts, declared toolchains |
| `network*`, `mach*`, `ipc-posix*` | All allowed |

### Blocked by default

`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.docker`, `~/Desktop`, `~/Downloads`, `~/Documents`, `~/Library` (except `~/Library/Keychains` for OAuth), `~/.zsh_history`, and anything else not explicitly listed.

### Write-protected inside the project

The project directory is writable, but these paths are protected by deny-after-allow rules (SBPL last-match-wins) so the agent cannot tamper with them:

| Path | Why |
|---|---|
| `.rollcage` | Sandbox config — prevents privilege escalation on next launch |
| `.env`, `.env.local`, `.env.development`, `.env.staging`, `.env.test`, `.env.production` | Common locations for secrets and API keys |
| `.git/hooks/` | Prevents injection of code that runs on git operations |

### Verified escape vectors

These attack patterns are all blocked by Seatbelt's kernel-level enforcement and covered by the test suite: symlink traversal, hardlinks, `/tmp` script execution, child process inheritance (python, node, bash), file descriptor redirects, and `curl` exfiltration of locally blocked files.

## Quick start

1. Clone the repo and add it to your PATH:

   ```bash
   git clone https://github.com/codewithcheese/rollcage.git
   export PATH="$PWD/rollcage:$PATH"   # add to your shell rc
   ```

Rollcage requires macOS with `sandbox-exec`; it refuses to launch without Seatbelt.

2. Run it from any project directory, selecting your agent:

   ```bash
   cd /path/to/your/project
   rollcage claude    # Claude Code
   rollcage codex     # Codex CLI
   rollcage pi        # Pi coding agent
   rollcage omp       # Oh My Pi coding agent
   rollcage opencode  # OpenCode
   ```

For Claude, `rollcage claude` assembles `base-common.sb` and `base-claude.sb`, applies user/project rules and final protections, launches Claude Code under `sandbox-exec`, and bypasses Claude's internal permission prompts (`--dangerously-skip-permissions`) — the OS sandbox is the actual boundary.

If your project needs additional access (a runtime, a custom binary, a config file outside the project), add a `.rollcage` file. The bundled `/debug-sandbox` skill will draft it for you the first time something gets blocked.

## How it works

```
base-common.sb + base-<cli>.sb # shared policy plus selected CLI policy
+ ~/.config/rollcage/config    # personal rules for all projects (optional)
+ ./.rollcage                  # project-specific rules (optional, trust-gated)
     └─ each `pack <name>` expands ~/.config/rollcage/packs/<name>
        (trust-gated per CLI, project, and hash)
+ base-protections.sb          # final write denies; resolved control paths also protected
        │
        ▼
sandbox-exec -f <assembled>   --   claude --dangerously-skip-permissions --plugin-dir <rollcage>
```

For Codex the same flow uses `base-common.sb + base-codex.sb`, `~/.config/rollcage/config`, and the same project-level `./.rollcage` file, then launches:

```sh
sandbox-exec -f <assembled> -- codex --dangerously-bypass-approvals-and-sandbox
```

For Pi the same flow uses `base-common.sb + base-pi.sb`, `~/.config/rollcage/config`, and the same project-level `./.rollcage` file, then launches:

```sh
sandbox-exec -f <assembled> -- pi <your args>
```

For Oh My Pi the flow uses `base-common.sb + base-omp.sb`, `~/.config/rollcage/config`, and the same project-level `./.rollcage` file, then launches:

```sh
sandbox-exec -f <assembled> -- omp --auto-approve <your args>
```

For OpenCode the flow uses `base-common.sb + base-opencode.sb`, `~/.config/rollcage/config`, and the same project-level `./.rollcage` file, then launches:

```sh
OPENCODE_DISABLE_AUTOUPDATE=1 sandbox-exec -f <assembled> -- opencode --auto <your args>
```

The base profile starts with `(deny default)`. DSL grants are additive, but final write protections are applied after every generated rule. Project rules, user configuration, packs, and trust state stay write-protected even when a parent directory is granted write access. Resolved control-file targets are protected too, including symlinked configs and referenced packs. Their ancestor directory entries cannot be renamed or replaced, while ordinary child state remains writable.

The wrapper resolves all paths through `readlink -f` before passing them to `sandbox-exec` because Seatbelt resolves symlinks before matching rules.

### Trust gate

`.rollcage` files are security-sensitive — they control what the sandbox allows. rollcage treats them like direnv: explicit approval is required.

When a project has a `.rollcage` config, rollcage computes its sha256 hash and checks `~/.config/rollcage/trust/<cli>/trusted`. If the file is **new**, rollcage prints its full contents and prompts for approval. If it has **changed** since it was last approved, rollcage prints a unified diff against the stored copy and prompts again. This prevents a malicious commit from silently widening sandbox access when you `cd` into a cloned repo.

Approved hashes live in `~/.config/rollcage/trust/<cli>/trusted`; copies of approved configs in `~/.config/rollcage/trust/<cli>/trusted.d/` (used to render diffs).

Trust is keyed on the repository's git common directory when the config lives inside a git working tree, otherwise on the resolved file path. This means **all worktrees of the same repository share trust**: approving `.rollcage` in the main checkout silently covers any worktree at the same content hash. A worktree on a branch with a diverged `.rollcage` re-prompts (different hash → different decision); an unrelated clone with identical content also re-prompts (different repo).

When rollcage runs from a **linked git worktree**, it auto-grants `file-read-data` on the main checkout. This makes `git -C <main>`, cross-branch diffs, and reading sibling files work without per-worktree config. The working tree of main stays read-only — only the shared `.git/` directory gets `file-write*` (so `git add`/`commit`/`checkout` from inside the worktree can update per-worktree state under `.git/worktrees/<name>/` and the shared `objects/` / `refs/` / `logs/` stores). Within `.git/`, writes to `hooks/` and `config` are denied (last-match-wins) — those are privilege-escalation paths. (A future per-worktree config knob could opt out of these grants for stricter isolation; not currently exposed.)

The user-level config (`~/.config/rollcage/config`) is **not** trust-gated — you own that file and edits take effect on the next launch.

Trust is separate for each CLI: an approval for Claude does not authorize Codex, Pi, OMP, or OpenCode.

Rejection is fatal: denying a config (or any pack it references — see [Packs](#packs)) exits Rollcage without launching the selected CLI. There is no base-only fallback — reject means edit and retry, not run with less.

### rollcage codex

`rollcage codex` follows the same DSL and trust model, but uses Codex-specific defaults:

- Project config: `.rollcage` (shared by all CLI selections)
- User config: `~/.config/rollcage/config`
- Packs referenced by `.rollcage`: `~/.config/rollcage/packs/<name>`
- Trust ledger: `~/.config/rollcage/trust/codex/trusted`
- Base fragments: `base-common.sb` + `base-codex.sb`

Sandboxed launches pass `--config check_for_update_on_startup=false` to skip
Codex's startup update check and upgrade prompt, since its installation is
read-only. This also disables startup update notifications. Upgrade Codex
outside the sandbox; the override does not change your saved Codex config.

Its base profile grants Codex access to `~/.codex` state, read-only access to
the documented user skill location at `~/.agents/skills`, and its current CLI
install location under `~/.nvm`, instead of Claude-specific paths like
`~/.claude` and `~/.local/share/claude`.

When `~/.codex/config.toml` registers ChatGPT.app's bundled `node_repl` MCP
server, `rollcage codex` starts it with `--disable-sandbox`. This disables only the
REPL's incompatible attempt to nest another Seatbelt sandbox: the MCP server
and its Node kernel still inherit rollcage codex's outer profile. The Codex base grants
read access to the bundled packages and execution only for `node_repl` and its
`node` kernel; adjacent `npm`, `npx`, `corepack`, and setup scripts remain
non-executable.

All five CLIs use the same `.rollcage` project rules and shared user rules; the selected CLI determines the base profile and trust store.

Codex install layouts covered by the base profile:

| Install layout | Covered paths |
|---|---|
| Direct release binary | `~/.local/bin/codex` |
| npm under NVM | `~/.nvm/.../bin/codex` plus vendored native binary under `~/.nvm/.../lib/node_modules/@openai/codex` |
| bun global install | `~/.bun/bin` and `~/.bun/install/global` |
| Homebrew cask / Intel global npm | `/usr/local/bin/codex`, `/usr/local/Caskroom/codex`, `/usr/local/bin/node`, `/usr/local/lib/node_modules/@openai/codex` |

Apple Silicon Homebrew installs are covered by the shared `/opt/homebrew` read+exec rules. Plugin and hook support for Codex is intentionally not implemented yet.

### rollcage pi

`rollcage pi` follows the same DSL and trust model, but uses Pi-specific defaults:

- Project config: `.rollcage` (shared by all CLI selections)
- User config: `~/.config/rollcage/config`
- Packs referenced by `.rollcage`: `~/.config/rollcage/packs/<name>`
- Trust ledger: `~/.config/rollcage/trust/pi/trusted`
- Base fragments: `base-common.sb` + `base-pi.sb`

Its base profile grants Pi access to `~/.pi` state and its CLI install location, instead of Claude- or Codex-specific paths.

Pi install layouts covered by the base profile:

| Install layout | Covered paths |
|---|---|
| npm under NVM | `~/.nvm/.../bin/pi` plus vendored binaries under `~/.nvm/.../lib/node_modules/@earendil-works/pi-coding-agent` |
| `curl pi.dev/install.sh` | `~/.local/bin/pi`, plus the optional vendored node runtime at `~/.local/share/pi-node` |
| Intel Homebrew global npm | `/usr/local/bin/pi`, `/usr/local/bin/node`, `/usr/local/lib/node_modules/@earendil-works/pi-coding-agent` |

Apple Silicon Homebrew installs are covered by the shared `/opt/homebrew` read+exec rules.

Unlike Codex, Pi can install npm and git packages and TypeScript extensions at runtime under `~/.pi/agent/{npm,git,extensions}`. Pi state (`~/.pi`) is fully readable and writable, but `process-exec` is scoped narrowly to those three install subdirectories — sessions, `auth.json`, settings, themes, prompts, and other state under `~/.pi` cannot be executed even if a write lands there. Plugin and hook support for Pi is intentionally not implemented yet.

### rollcage omp

`rollcage omp` follows the shared DSL and trust model with OMP-specific defaults:

- Project config: `.rollcage` (shared with the other launchers)
- User config: `~/.config/rollcage/config`
- Packs referenced by `.rollcage`: `~/.config/rollcage/packs/<name>`
- Trust ledger: `~/.config/rollcage/trust/omp/trusted`
- Base fragments: `base-common.sb` + `base-omp.sb`

OMP keeps settings, profiles, sessions, extracted native addons, plugins, worktrees, and logs under `~/.omp`. Provider API keys and OAuth access/refresh material—including OMP's independent OpenAI Codex OAuth flow—live in `~/.omp/agent/agent.db`. The whole OMP tree is readable and writable, but execution is limited to OMP code-bearing directories (`agent/{extensions,hooks,tools}`, `plugins`, the managed `python-env`, and downloaded browsers under `puppeteer`) so writable sessions, databases, settings, and logs are not executable. `rollcage omp` always passes `--auto-approve` because Seatbelt is the permission boundary.

OMP install layouts covered by the base profile:

| Install layout | Covered paths |
|---|---|
| Official binary installer | `~/.local/bin/omp` |
| Bun global install | `~/.bun/bin` and `~/.bun/install/global` |
| mise GitHub backend | `~/.local/share/mise/{shims/omp,installs/omp}` plus `~/.local/bin/mise` |
| Intel Homebrew | `/usr/local/bin/omp` and `/usr/local/Cellar/omp` |

Apple Silicon Homebrew is covered by the shared `/opt/homebrew` rules. The base also supports OMP's managed Python REPL environment, python.org framework interpreters, PTYs, JavaScript dynamic code generation, Apple LLDB under Xcode or Command Line Tools, and OMP's downloaded Chrome-for-Testing fallback under `~/.omp/puppeteer`. System Google Chrome remains blocked unless `tool chrome` is enabled; this makes OMP fall back to its isolated download by default instead of exposing the installed browser. Browser-profile and desktop-control access remain opt-in because those features expose substantially broader user data. Other language servers and debuggers use the existing project/system paths or an explicit toolchain.

### rollcage opencode

`rollcage opencode` follows the shared DSL and trust model with OpenCode-specific defaults:

- Project config: `.rollcage` (shared with the other launchers)
- User config: `~/.config/rollcage/config`
- Packs referenced by `.rollcage`: `~/.config/rollcage/packs/<name>`
- Trust ledger: `~/.config/rollcage/trust/opencode/trusted`
- Base fragments: `base-common.sb` + `base-opencode.sb`

The launcher resolves the exact `opencode` executable before entering Seatbelt, so the official installer, Homebrew, npm/bun/pnpm/yarn, mise, and custom release-binary locations work without granting execution across an entire package-manager tree.

OpenCode's app-specific roots are writable because normal operation persists credentials, sessions, logs, model selection, prompt history, plugin dependencies, and downloaded tooling:

| Purpose | Default path | Access |
|---|---|---|
| Global config, agents, skills, plugins | `~/.config/opencode` | read+write |
| Credentials, SQLite sessions, logs, snapshots | `~/.local/share/opencode` | read+write |
| Model selection, prompt history, locks | `~/.local/state/opencode` | read+write |
| Plugin cache and downloaded tools/LSPs | `~/.cache/opencode` | read+write; exec only under `bin/` |

OpenCode also receives read-only access to `~/.claude/skills` and `~/.agents/skills`, which it auto-discovers. It does not receive `~/.codex`, the macOS Keychain, or unrelated home directories. `rollcage opencode` always passes `--auto` because Seatbelt is the permission boundary, matching the Claude adapter's prompt-bypass model. It also sets `OPENCODE_DISABLE_AUTOUPDATE=1` because the selected installation is read-only; run `opencode upgrade` outside the sandbox.

Nonstandard `XDG_*` or `OPENCODE_CONFIG*` paths are not converted into implicit grants because environment variables are not trust-gated. Paths under the project already work; external paths require explicit trusted `allow-read`/`allow-write` directives.

## Project configuration

Create a `.rollcage` file in your project root to declare toolchains and extra paths.

For a repository-audit workflow—including inspecting Codex session history,
resolving symlinked paths, selecting least-privilege rules, and testing the
assembled profile—see [Creating a `.rollcage` rule set for Codex](docs/creating-rollcage-rules-for-codex.md).

### DSL

```sh
# Toolchains — predefined sandbox profiles
tool node
tool uv

# Extra paths
allow-read  ~/.config/special      # read-only access
allow-write ./local/.share         # read + write access
allow-exec  ~/.local/bin/custom    # read + exec access
```

**Directives:**

| Directive | Effect | Use case |
|---|---|---|
| `tool <name>` | Activates a bundled toolchain | Language runtimes, package managers |
| `pack <name>` | Activates a user-defined pack (project config only) | Reuse of DSL across your own projects |
| `allow-read <path>` | Adds `file-read-data` (subpath) | Config files, shared libraries, datasets |
| `allow-write <path>` | Adds `file-read-data` + `file-write*` (subpath) | Build caches, data directories |
| `allow-exec <path>` | Adds `file-read-data` + `process-exec` (subpath) | Custom binaries, scripts |

**Path expansion:**

| Prefix | Expands to | Example |
|---|---|---|
| `~/` | `$HOME` | `~/.cargo` → `/Users/you/.cargo` |
| `./` | `$PROJECT_DIR` | `./local/.share` → `/path/to/project/local/.share` |
| `/` | absolute | `/opt/custom` → `/opt/custom` |

**Safety constraints** — the DSL is intentionally narrow:

- **No `deny`** — you can only widen access, never narrow it
- **No raw SBPL** — every rule comes from a validated directive
- **No system paths** — `/System`, `/usr`, `/bin`, `/sbin`, `/Library`, `/opt/homebrew` are already in the base profile and rejected by the validator
- **No bare `~`, `~/`, `.`, or `./`** — you must specify a subdirectory
- **No targeting `.rollcage`** — the sandbox config file is protected from being widened to writable or executable

### Available toolchains

| Name | What it grants |
|---|---|
| `node` | NVM, npm/npx, Corepack, and pnpm (including native pnpm 12); macOS dependency/engine stores under `~/Library/pnpm`, legacy/XDG stores, and read-only pnpm configuration. See [pnpm configuration and sandbox scope](docs/pnpm.md). |
| `bun` | Bun runtime and install cache (`~/.bun`) |
| `uv` | uv/uvx, cache (`~/Library/Caches/uv`, `~/.local/share/uv`). `~/.local/bin` is read+exec only — `uv tool install` symlinks are redirected to `~/.local/share/uv/bin/` via `UV_TOOL_BIN_DIR` to prevent binary overwrite attacks |
| `python` | pyenv (`~/.pyenv`) and python.org Framework interpreters (`/Library/Frameworks/Python.framework`, read/exec only) |
| `metal` | Let Metal issue a read-write sandbox extension limited to `CACHE_DIR/com.apple.metalfe` for its compiler service. Pair with `allow-exec /Applications/Xcode.app/Contents/Developer` when using `xcrun` with full Xcode. |
| `rust` | Cargo (`~/.cargo`), rustup (`~/.rustup` read+exec; distribution state writable for pinned toolchain installs, settings read-only), and the C linker (clang/ld via Xcode or Command Line Tools, read+exec) that `cargo build` invokes to link native binaries |
| `go` | Go toolchain (`/usr/local/go`, `~/go`), build cache (`~/.cache/go-build`) |
| `swift` | SwiftPM via Xcode or Command Line Tools, SwiftPM caches/config (`~/Library/{Caches/,}org.swift.swiftpm`, `~/.swiftpm`). Pass `--disable-sandbox` to swift commands — macOS forbids nested `sandbox-exec` |
| `deno` | Deno runtime and cache (`~/.deno`) |
| `postgres` | Local PostgreSQL servers: SysV shared memory and semaphores required on macOS, plus Intel Homebrew PostgreSQL/libpq execution. Keep data, logs, and sockets under the project or temp directory; Homebrew's persistent cluster remains read-only |
| `gh` | GitHub CLI auth tokens (`~/.config/gh`, read-only) |
| `huggingface` | Model cache, auth tokens, assets (`~/.cache/huggingface`) |
| `seshi` | Claude Code session indexer hook. Venv (`~/.local/share/uv/tools/seshi`), uv-managed cpython (`~/.local/share/uv/python`), and data dir (`~/.local/share/seshi`). Pair with `huggingface` for embedding model downloads. Does not grant `~/.local/bin` — use the uv-managed binary path directly |
| `cmux` | cmux app bundle (`/Applications/cmux.app`), runtime state (`~/Library/Application Support/cmux`), caches (`~/Library/Caches/cmux`) |
| `playwright` | Browser downloads and binaries (`~/Library/Caches/ms-playwright`) |
| `playwright-chromium` | Chromium-specific macOS integration: locale, input methods, spelling, crash reporter. Requires `tool playwright` |
| `chrome` | Google Chrome.app (read+exec), macOS integration paths, GoogleUpdater. Use with `--no-sandbox --user-data-dir=./profile` |
| `electron-ghostty` | Electron apps embedding libghostty: `pseudo-tty` for PTY allocation, Electron support/cache/log/saved-state dirs, IME/keyboard/spelling reads. App must spawn `$SHELL` directly (no sugid exec via `/usr/bin/login`); embedded use only, not standalone Ghostty.app |

Adding a new toolchain is a five-file change (SBPL fragment, sandbox test, README row, debug-sandbox skill row, CI job). See [`CLAUDE.md`](CLAUDE.md#adding-a-toolchain) for the full guide.

### User-level config

All five CLI selections (`rollcage claude`, `rollcage codex`, `rollcage pi`, `rollcage omp`, and `rollcage opencode`) read `~/.config/rollcage/config`. For personal paths that apply to all projects (e.g., shell config symlink targets, always-on tools), use the same DSL:

```sh
# Personal tools available in all projects
tool cmux
allow-read  ~/Documents/GitHub/codewithcheese/macos-setup
allow-read  ~/.config/auto-chat
allow-write ~/.config/auto-chat
```

This layer is applied before the project config, is not trust-gated, and edits take effect on the next launch. `pack` is **not** allowed here; packs exist to share DSL across your own projects, not to define global defaults.

Each CLI keeps its own trust ledger and snapshots under `~/.config/rollcage/trust/<cli>/`.

### Packs

Packs are reusable DSL fragments you keep under `~/.config/rollcage/packs/`. Each pack is a plain file using `tool`, `allow-read`, `allow-write`, and `allow-exec`:

```sh
# ~/.config/rollcage/packs/web-dev
tool node
allow-read ~/.config/shared-dotfiles
allow-write ~/cache/projects-shared
```

A project opts in with `pack <name>`:

```sh
# my-project/.rollcage
pack web-dev
allow-read ./vendor
```

**Rules:**

- `pack` is only legal in project configs (`.rollcage`), never in user config or inside another pack.
- Packs cannot contain `pack` (no nesting, no cycles).
- Packs can contain `tool <bundled>` and the usual `allow-read`/`allow-write`/`allow-exec`.
- Packs share the DSL's safety constraints — no raw SBPL, no system paths, no targeting `.rollcage`.
- Pack names must match `[A-Za-z0-9_][A-Za-z0-9_-]*` (no `..`, no slashes).

**Trust model.** Pack approval is per-project, per-hash:

| Situation | What you see |
|---|---|
| First time this project references `pack X` | Prompt — full pack contents shown |
| Pack unchanged since you approved it for this project | One-line reminder (`using pack X (trusted)`) + verb summary |
| Pack file changed | Diff prompt — accept/reject the delta |
| A different project references the same pack (same hash) | Prompt — each project trusts independently |

Approving a pack in project A does **not** carry over to project B: each project audits every pack it pulls in. Denial of any pack exits rollcage — there is no base-only fallback.

## Bundled plugin

Rollcage ships with a Claude Code plugin loaded automatically by `rollcage claude` through `--plugin-dir <rollcage-install-dir>`. You don't install or enable it separately.

It provides three things:

### Denial hook

`plugin/hooks/sandbox-denial-hook.sh` is registered as a `PostToolUseFailure` hook. When a tool inside the sandbox fails with "Operation not permitted" or "Permission denied", the hook:

1. Tails the sandbox denial log that `rollcage claude` streams from `/usr/bin/log` (kept outside the sandbox because `log` refuses to run inside one).
2. Filters denials from the last 5 seconds matching `file-read-data`, `file-write`, `process-exec`, or `forbidden-exec`.
3. Injects an `additionalContext` system reminder back to Claude with the specific denials and instructions to invoke `/debug-sandbox` rather than try to bypass the sandbox.

The hook is gated on `ROLLCAGE_ACTIVE=1` and `ROLLCAGE_CLI=claude`, so it's a no-op when running plain `claude`.

### `/debug-sandbox` skill

A configuration assistant that drafts `.rollcage` changes. It:

- Considers alternatives to widening permissions first (local installs over global, project-local paths over `~/`)
- Reads `~/.config/rollcage/config` so it doesn't suggest rules you already have
- Identifies your tech stack and matches it to a bundled toolchain when possible
- Picks the narrowest path and the minimum operation (`allow-read` over `allow-write` whenever the tool only needs to read)
- Refuses to suggest workarounds that bypass the sandbox

You can invoke it manually with `/debug-sandbox`, but typically the denial hook will direct Claude to invoke it automatically when something gets blocked.

### `/reload-sandbox` skill — hot reload

`.rollcage` is write-protected inside the sandbox (deny-after-allow), so configuration changes have to happen on disk before the sandbox restarts. The reload skill bridges this gap:

1. The skill `touch`es a sentinel file (`$ROLLCAGE_RELOAD_SENTINEL`) and tells you to `/exit`.
2. The Claude adapter runs in a `while true` loop. When `claude` exits, it checks for the sentinel.
3. If the sentinel exists, `rollcage claude` re-runs the assembler, regenerates the profile, and starts a new `claude --continue` so your conversation resumes seamlessly.
4. If the new `.rollcage` differs from the previously trusted version, the trust gate shows a diff and re-prompts before activating it.

In practice the workflow is: a tool fails → hook injects denial context → Claude invokes `/debug-sandbox` → you approve the proposed `.rollcage` → Claude invokes `/reload-sandbox` → you `/exit` → sandbox restarts with the new rules → conversation continues.

## Detecting the sandbox

rollcage sets `ROLLCAGE_ACTIVE=1` for every process inside the sandbox. CLI tools that should only run within the sandbox can check for it:

```bash
# Shell
if [[ "${ROLLCAGE_ACTIVE:-}" != "1" ]]; then
  echo "error: must run inside rollcage sandbox" >&2
  exit 1
fi
```

```python
# Python
import os, sys
if os.environ.get("ROLLCAGE_ACTIVE") != "1":
    print("error: must run inside rollcage sandbox", file=sys.stderr)
    sys.exit(1)
```

```javascript
// Node.js
if (process.env.ROLLCAGE_ACTIVE !== "1") {
  console.error("error: must run inside rollcage sandbox");
  process.exit(1);
}
```

`ROLLCAGE_ACTIVE` is the **stable, public** API for sandbox detection — it's inherited by all child processes and won't change. `rollcage claude`, `rollcage codex`, `rollcage pi`, `rollcage omp`, and `rollcage opencode` all set it so sandbox-aware tools work under any launcher. `ROLLCAGE_DENIAL_LOG` and `ROLLCAGE_RELOAD_SENTINEL` are internal and may change without notice.

`ROLLCAGE_CLI` identifies the selected CLI: `claude`, `codex`, `pi`, `omp`, or `opencode`. Denial-hook and reload-sentinel variables are currently used only by the Claude adapter.

## Reference

### SBPL parameters

`rollcage` passes these to `sandbox-exec` via `-D KEY=value`. Use `(param "NAME")` in SBPL — never hardcode paths.

| Parameter | Resolves to |
|---|---|
| `HOME` | `/Users/<you>` |
| `PROJECT_DIR` | Absolute path of the project (resolved with `readlink -f`) |
| `TMPDIR` | `/private/var/folders/<...>/T/` |
| `CACHE_DIR` | `/private/var/folders/<...>/C/` (sibling of TMPDIR — Spotlight/mds, keychain, direct Metal cache writes) |
| `VOLATILE_DIR` | `/private/var/folders/<...>/X/` (sibling of TMPDIR — code-signing clones) |
| `ROLLCAGE_DIR` | Resolved Rollcage installation directory |
| `OPENCODE_BIN` | Resolved OpenCode executable selected before entering Seatbelt |

### Environment variables

| Variable | Value | Stability |
|---|---|---|
| `ROLLCAGE_ACTIVE` | `1` | Public sandbox detection marker |
| `ROLLCAGE_CLI` | `claude`, `codex`, `pi`, `omp`, or `opencode` | Public CLI identifier |
| `ROLLCAGE_COLOR` | `auto`, `always`, or `never` | Optional trust-prompt color preference |
| `ROLLCAGE_DENIAL_LOG` | Path to streaming denial log | Internal; Claude only |
| `ROLLCAGE_RELOAD_SENTINEL` | Path to reload sentinel | Internal; Claude only |

### Files

| File | Purpose |
|---|---|
| `rollcage` | Dispatcher: selects a supported CLI and requires Seatbelt |
| `rollcage.lib.zsh` | Shared initialization, DSL, assembler, and trust gate |
| `adapters/<cli>.zsh` | CLI-specific launch behavior; Claude retains its reload loop |
| `base-protections.sb` | Final write protections after all generated grants |
| `base-common.sb` | Shared SBPL base (`deny default` + common rules) |
| `base-claude.sb` | Claude-specific SBPL fragment layered on top of `base-common.sb` |
| `base-codex.sb` | Codex-specific SBPL fragment layered on top of `base-common.sb` |
| `base-pi.sb` | Pi-specific SBPL fragment layered on top of `base-common.sb` |
| `base-omp.sb` | Oh My Pi-specific SBPL fragment layered on top of `base-common.sb` |
| `base-opencode.sb` | OpenCode-specific SBPL fragment layered on top of `base-common.sb` |
| `toolchains/<name>.sb` | Bundled toolchain SBPL fragments |
| `toolchains/<name>.test.zsh` | Sandbox tests for each toolchain |
| `toolchains/test_helpers.zsh` | Shared test helpers (`tc_setup`, `tc_sandboxed`, ...) |
| `.claude-plugin/plugin.json` | Plugin manifest (loaded via `--plugin-dir`) |
| `plugin/hooks/hooks.json` | Hook registration (`PostToolUseFailure`) |
| `plugin/hooks/sandbox-denial-hook.sh` | Denial detection + context injection |
| `plugin/skills/debug-sandbox/SKILL.md` | `/debug-sandbox` configuration assistant |
| `plugin/skills/reload-sandbox/SKILL.md` | `/reload-sandbox` hot reload trigger |
| `test_rollcage.bash` | DSL pipeline unit tests (any platform, bash 4+) |
| `test_sandbox.zsh` | Claude base and toolchain integration tests (macOS only) |
| `test_dispatch.zsh` | Dispatcher, argument forwarding, reload, and rejection tests |
| `test_trust_gate.zsh` | Trust scope, packs, shared config, and CLI isolation tests |
| `test_protections_sandbox.zsh` | Final write protection and trust-store read isolation (macOS only) |
| `test_codex_sandbox.zsh` | Codex base-profile sandbox integration tests (macOS only) |
| `test_pi_sandbox.zsh` | Pi base-profile sandbox integration tests (macOS only) |
| `test_omp_sandbox.zsh` | Oh My Pi base-profile sandbox integration tests (macOS only) |
| `test_opencode_sandbox.zsh` | OpenCode base-profile sandbox integration tests (macOS only) |
| [`AGENTS.md`](AGENTS.md) | Development instructions shared by agents; `CLAUDE.md` imports them |
| [`DEBUGGING.md`](DEBUGGING.md) | Diagnosing sandbox issues, SBPL gotchas, denial categories |

## Testing

**Portable tests** (bash 4+ and zsh):

```bash
bash test_rollcage.bash
zsh test_trust_gate.zsh
zsh test_dispatch.zsh
```

Tests parser, validator, generator, assembler, and trust gate — no macOS or sandbox required.

**Sandbox integration tests** (macOS only):

```bash
# All tests (base + every discovered toolchain)
zsh test_sandbox.zsh

# Base profile only (no toolchains)
zsh test_sandbox.zsh --toolchain none

# Specific toolchain(s)
zsh test_sandbox.zsh --toolchain node
zsh test_sandbox.zsh --toolchain node,uv

# With a custom project config
zsh test_sandbox.zsh --with-config path/to/.rollcage

# Codex base profile
zsh test_codex_sandbox.zsh

# Pi base profile
zsh test_pi_sandbox.zsh

# Oh My Pi base profile
zsh test_omp_sandbox.zsh

# OpenCode base profile
zsh test_opencode_sandbox.zsh

# Final control-file protection and trust-store read isolation
zsh test_protections_sandbox.zsh
```

GitHub Actions workflows are temporarily disabled and preserved in
[`.github/workflows-disabled`](.github/workflows-disabled/README.md).
Run the commands above locally. The preserved workflows define separate
toolchain jobs with tools installed at their canonical paths. Tests verify:

- Read/write/exec access to declared paths
- Real tool operations (`npm install`, `cargo build`, `uv pip install`, etc.) — not just `--version`
- Isolation (sensitive paths like `~/.ssh` remain blocked)
- Write protection (`.rollcage`, `.env*`, `.git/hooks`)
- Escape vectors (symlinks, path traversal, child processes, fd redirects)

When a test fails unexpectedly, stderr and the recent sandbox denial log are displayed automatically.

## Known limitations

The sandbox enforces filesystem isolation only. These are accepted trade-offs and known gaps in the base profile.

### No network isolation

All network access is allowed (`(allow network*)`). The sandboxed process can make arbitrary HTTP requests, which means data exfiltration of anything it *can* read (project files, history, etc.) is possible via `curl` or any network client. SBPL may support filtering by host/IP/port — this hasn't been explored yet.

### Clipboard readable

`pbpaste` (in `/usr/bin`) can read the system clipboard. If you've copied a password or secret, it's accessible inside the sandbox. There is no SBPL operation to block this — clipboard access goes through Mach IPC, which must be globally allowed for Claude Code to function.

### Keychain metadata exposed

`security dump-keychain` reveals service names and account names for all keychain entries (e.g. "Chrome Safe Storage", "Arc", "1Password"). Actual password extraction triggers a macOS authorization UI prompt, so secrets are protected by a second layer. Removing `~/Library/Keychains` from the read allowlist would fix this but break OAuth login.

### File metadata globally visible

`file-read-metadata` is globally allowed (required for path resolution). This means `stat` and `test -e` work on any path — file existence, size, timestamps, and permissions are visible even for denied files. File **contents** are still blocked.

### JIT / dynamic code generation allowed

`dynamic-code-generation` is permitted because Bun, V8, and WASM runtimes need it. This weakens in-process exploit hardening (an attacker can inject shellcode instead of needing ROP/JOP), but in our threat model — an AI agent that can already exec bash, node, and python — the marginal risk is low. JIT code is still subject to the syscall sandbox.

## Compatibility

- macOS 14+ (Apple Silicon and Intel)
- Claude Code 2.1.x+
- Works alongside the cmux wrapper (`tool cmux`)
- `sandbox-exec` is officially deprecated by Apple but remains functional and is used by Chromium with the same approach
