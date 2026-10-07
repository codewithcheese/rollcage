# xclaude

A macOS Seatbelt sandbox for agent CLIs — [Claude Code](https://claude.com/claude-code) via `xclaude`, Codex CLI via `xcodex`, the [Pi coding agent](https://pi.dev) via `xpi`, [Oh My Pi](https://github.com/can1357/oh-my-pi) via `xomp`, and [OpenCode](https://opencode.ai) via `xopencode`. Each wrapper runs the underlying agent in `sandbox-exec` with a strict, layered SBPL profile so the agent can only read and write files you've explicitly allowed.

> **Naming note:** This project should be renamed `quicksand` to better align
> with its multi-agent support.

## Why

By default Claude Code can read and write anywhere your shell can — including `~/.ssh`, `~/.aws`, browser profiles, shell history, and any document on disk. Anthropic ships a built-in sandbox option (`sandbox.enabled` in settings) but it has [known issues](https://github.com/anthropics/claude-code/issues/31473) on macOS: `denyRead` is ineffective, `allowRead` doesn't exist in the schema, and the generated SBPL profiles can crash the process silently.

xclaude replaces it with a hand-tuned Seatbelt profile that **defaults to strict deny**, lets you opt in to extra access via a tiny safe DSL, and ships with a Claude Code plugin so the agent helps you fix denials instead of working around them.

For Codex CLI, `xcodex` uses the same outer Seatbelt boundary and starts Codex with `--dangerously-bypass-approvals-and-sandbox`. That disables Codex's own approval/sandbox layer because the OS sandbox assembled by xcodex is the enforcement boundary.

For the Pi coding agent, `xpi` uses the same outer Seatbelt boundary. Pi has no built-in approval/sandbox layer to disable, so the binary runs with whatever arguments you pass through — the OS sandbox is the only enforcement layer.

For Oh My Pi, `xomp` passes `--auto-approve` to bypass OMP's application-level permission prompts while applying the same outer Seatbelt boundary. OMP's DeepSeek API keys and OpenAI Codex OAuth credentials stay in its own SQLite store under `~/.omp`; `xomp` does not expose Codex CLI's auth file or the macOS Keychain.

For OpenCode, `xopencode` passes `--auto` to bypass OpenCode's application-level permission prompts while applying the outer Seatbelt boundary. OpenCode's credentials and session database remain in its app-specific data directory; unrelated agent credentials and the macOS Keychain stay blocked.

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
| `.xclaude` | Sandbox config — prevents privilege escalation on next launch |
| `.env`, `.env.local`, `.env.development`, `.env.staging`, `.env.test`, `.env.production` | Common locations for secrets and API keys |
| `.git/hooks/` | Prevents injection of code that runs on git operations |

### Verified escape vectors

These attack patterns are all blocked by Seatbelt's kernel-level enforcement and covered by the test suite: symlink traversal, hardlinks, `/tmp` script execution, child process inheritance (python, node, bash), file descriptor redirects, and `curl` exfiltration of locally blocked files.

## Quick start

1. Clone the repo and add it to your PATH:

   ```bash
   git clone https://github.com/codewithcheese/xclaude.git
   export PATH="$PWD/xclaude:$PATH"   # add to your shell rc
   ```

2. Run it from any project directory, using the wrapper for your agent:

   ```bash
   cd /path/to/your/project
   xclaude    # Claude Code
   xcodex     # Codex CLI
   xpi        # Pi coding agent
   xomp       # Oh My Pi coding agent
   xopencode  # OpenCode
   ```

That's it. xclaude assembles a profile from `base.sb` (plus any user/project config), launches Claude Code under `sandbox-exec`, and bypasses Claude's internal permission prompts (`--dangerously-skip-permissions`) — the OS sandbox is the actual boundary.

If your project needs additional access (a runtime, a custom binary, a config file outside the project), add a `.xclaude` file. The bundled `/debug-sandbox` skill will draft it for you the first time something gets blocked.

## How it works

```
base.sb                       # core profile (always applied)
+ ~/.config/xclaude/config    # personal rules for all projects (optional)
+ ./.xclaude                  # project-specific rules (optional, trust-gated)
     └─ each `pack <name>` expands ~/.config/xclaude/packs/<name>
        (trust-gated per project, per hash)
        │
        ▼
sandbox-exec -f <assembled>   --   claude --dangerously-skip-permissions --plugin-dir <xclaude>
```

For Codex the same flow uses `base-common.sb + base-codex.sb`, `~/.config/xclaude/config`, and the same project-level `./.xclaude` file, then launches:

```sh
sandbox-exec -f <assembled> -- codex --dangerously-bypass-approvals-and-sandbox
```

For Pi the same flow uses `base-common.sb + base-pi.sb`, `~/.config/xclaude/config`, and the same project-level `./.xclaude` file, then launches:

```sh
sandbox-exec -f <assembled> -- pi <your args>
```

For Oh My Pi the flow uses `base-common.sb + base-omp.sb`, `~/.config/xclaude/config`, and the same project-level `./.xclaude` file, then launches:

```sh
sandbox-exec -f <assembled> -- omp --auto-approve <your args>
```

For OpenCode the flow uses `base-common.sb + base-opencode.sb`, `~/.config/xclaude/config`, and the same project-level `./.xclaude` file, then launches:

```sh
OPENCODE_DISABLE_AUTOUPDATE=1 sandbox-exec -f <assembled> -- opencode --auto <your args>
```

All layers are **additive**. The base profile starts with `(deny default)` and the DSL has no `deny` verb, so config files can only widen access — never narrow what the base profile already grants.

The wrapper resolves all paths through `readlink -f` before passing them to `sandbox-exec` because Seatbelt resolves symlinks before matching rules.

### Trust gate

`.xclaude` files are security-sensitive — they control what the sandbox allows. xclaude treats them like direnv: explicit approval is required.

When a project has a `.xclaude` config, xclaude computes its sha256 hash and checks `~/.config/xclaude/trusted`. If the file is **new**, xclaude prints its full contents and prompts for approval. If it has **changed** since it was last approved, xclaude prints a unified diff against the stored copy and prompts again. This prevents a malicious commit from silently widening sandbox access when you `cd` into a cloned repo.

Approved hashes live in `~/.config/xclaude/trusted`; copies of approved configs in `~/.config/xclaude/trusted.d/` (used to render diffs).

Trust is keyed on the repository's git common directory when the config lives inside a git working tree, otherwise on the resolved file path. This means **all worktrees of the same repository share trust**: approving `.xclaude` in the main checkout silently covers any worktree at the same content hash. A worktree on a branch with a diverged `.xclaude` re-prompts (different hash → different decision); an unrelated clone with identical content also re-prompts (different repo). Legacy path-keyed ledger entries continue to be honored until they are next re-trusted.

When xclaude runs from a **linked git worktree**, it auto-grants `file-read-data` on the main checkout. This makes `git -C <main>`, cross-branch diffs, and reading sibling files work without per-worktree config. The working tree of main stays read-only — only the shared `.git/` directory gets `file-write*` (so `git add`/`commit`/`checkout` from inside the worktree can update per-worktree state under `.git/worktrees/<name>/` and the shared `objects/` / `refs/` / `logs/` stores). Within `.git/`, writes to `hooks/` and `config` are denied (last-match-wins) — those are privilege-escalation paths. (A future per-worktree config knob could opt out of these grants for stricter isolation; not currently exposed.)

The user-level config (`~/.config/xclaude/config`) is **not** trust-gated — you own that file and edits take effect on the next launch.

Rejection is fatal: denying a config (or any pack it references — see [Packs](#packs)) exits xclaude without launching Claude. There is no base-only fallback — reject means edit and retry, not run with less.

### xcodex

`xcodex` follows the same DSL and trust model, but uses Codex-specific defaults:

- Project config: `.xclaude` (shared with `xclaude`)
- User config: `~/.config/xclaude/config`
- Packs referenced by `.xclaude`: `~/.config/xclaude/packs/<name>`
- Trust ledger: `~/.config/xcodex/trusted`
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
server, `xcodex` starts it with `--disable-sandbox`. This disables only the
REPL's incompatible attempt to nest another Seatbelt sandbox: the MCP server
and its Node kernel still inherit xcodex's outer profile. The Codex base grants
read access to the bundled packages and execution only for `node_repl` and its
`node` kernel; adjacent `npm`, `npx`, `corepack`, and setup scripts remain
non-executable.

The project config name is currently still `.xclaude` for both agents. The name may become more generic later, but the DSL rules are project/tool requirements and normally do not need to differ between Claude and Codex.

Codex install layouts covered by the base profile:

| Install layout | Covered paths |
|---|---|
| Direct release binary | `~/.local/bin/codex` |
| npm under NVM | `~/.nvm/.../bin/codex` plus vendored native binary under `~/.nvm/.../lib/node_modules/@openai/codex` |
| bun global install | `~/.bun/bin` and `~/.bun/install/global` |
| Homebrew cask / Intel global npm | `/usr/local/bin/codex`, `/usr/local/Caskroom/codex`, `/usr/local/bin/node`, `/usr/local/lib/node_modules/@openai/codex` |

Apple Silicon Homebrew installs are covered by the shared `/opt/homebrew` read+exec rules. Plugin and hook support for Codex is intentionally not implemented yet.

### xpi

`xpi` follows the same DSL and trust model, but uses Pi-specific defaults:

- Project config: `.xclaude` (shared with `xclaude` and `xcodex`)
- User config: `~/.config/xclaude/config`
- Packs referenced by `.xclaude`: `~/.config/xclaude/packs/<name>`
- Trust ledger: `~/.config/xpi/trusted`
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

### xomp

`xomp` follows the shared DSL and trust model with OMP-specific defaults:

- Project config: `.xclaude` (shared with the other launchers)
- User config: `~/.config/xclaude/config`
- Packs referenced by `.xclaude`: `~/.config/xclaude/packs/<name>`
- Trust ledger: `~/.config/xomp/trusted`
- Base fragments: `base-common.sb` + `base-omp.sb`

OMP keeps settings, profiles, sessions, extracted native addons, plugins, worktrees, and logs under `~/.omp`. Provider API keys and OAuth access/refresh material—including OMP's independent OpenAI Codex OAuth flow—live in `~/.omp/agent/agent.db`. The whole OMP tree is readable and writable, but execution is limited to OMP code-bearing directories (`agent/{extensions,hooks,tools}`, `plugins`, the managed `python-env`, and downloaded browsers under `puppeteer`) so writable sessions, databases, settings, and logs are not executable. `xomp` always passes `--auto-approve` because Seatbelt is the permission boundary.

OMP install layouts covered by the base profile:

| Install layout | Covered paths |
|---|---|
| Official binary installer | `~/.local/bin/omp` |
| Bun global install | `~/.bun/bin` and `~/.bun/install/global` |
| mise GitHub backend | `~/.local/share/mise/{shims/omp,installs/omp}` plus `~/.local/bin/mise` |
| Intel Homebrew | `/usr/local/bin/omp` and `/usr/local/Cellar/omp` |

Apple Silicon Homebrew is covered by the shared `/opt/homebrew` rules. The base also supports OMP's managed Python REPL environment, python.org framework interpreters, PTYs, JavaScript dynamic code generation, Apple LLDB under Xcode or Command Line Tools, and OMP's downloaded Chrome-for-Testing fallback under `~/.omp/puppeteer`. System Google Chrome remains blocked unless `tool chrome` is enabled; this makes OMP fall back to its isolated download by default instead of exposing the installed browser. Browser-profile and desktop-control access remain opt-in because those features expose substantially broader user data. Other language servers and debuggers use the existing project/system paths or an explicit toolchain.

### xopencode

`xopencode` follows the shared DSL and trust model with OpenCode-specific defaults:

- Project config: `.xclaude` (shared with the other launchers)
- User config: `~/.config/xclaude/config`
- Packs referenced by `.xclaude`: `~/.config/xclaude/packs/<name>`
- Trust ledger: `~/.config/xopencode/trusted`
- Base fragments: `base-common.sb` + `base-opencode.sb`

The launcher resolves the exact `opencode` executable before entering Seatbelt, so the official installer, Homebrew, npm/bun/pnpm/yarn, mise, and custom release-binary locations work without granting execution across an entire package-manager tree.

OpenCode's app-specific roots are writable because normal operation persists credentials, sessions, logs, model selection, prompt history, plugin dependencies, and downloaded tooling:

| Purpose | Default path | Access |
|---|---|---|
| Global config, agents, skills, plugins | `~/.config/opencode` | read+write |
| Credentials, SQLite sessions, logs, snapshots | `~/.local/share/opencode` | read+write |
| Model selection, prompt history, locks | `~/.local/state/opencode` | read+write |
| Plugin cache and downloaded tools/LSPs | `~/.cache/opencode` | read+write; exec only under `bin/` |

OpenCode also receives read-only access to `~/.claude/skills` and `~/.agents/skills`, which it auto-discovers. It does not receive `~/.codex`, the macOS Keychain, or unrelated home directories. `xopencode` always passes `--auto` because Seatbelt is the permission boundary, matching `xclaude`'s prompt-bypass model. It also sets `OPENCODE_DISABLE_AUTOUPDATE=1` because the selected installation is read-only; run `opencode upgrade` outside the sandbox.

Nonstandard `XDG_*` or `OPENCODE_CONFIG*` paths are not converted into implicit grants because environment variables are not trust-gated. Paths under the project already work; external paths require explicit trusted `allow-read`/`allow-write` directives.

## Project configuration

Create a `.xclaude` file in your project root to declare toolchains and extra paths.

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
- **No targeting `.xclaude`** — the sandbox config file is protected from being widened to writable or executable

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

All five launchers (`xclaude`, `xcodex`, `xpi`, `xomp`, and `xopencode`) read `~/.config/xclaude/config`. For personal paths that apply to all projects (e.g., shell config symlink targets, always-on tools), use the same DSL:

```sh
# Personal tools available in all projects
tool cmux
allow-read  ~/Documents/GitHub/codewithcheese/macos-setup
allow-read  ~/.config/auto-chat
allow-write ~/.config/auto-chat
```

This layer is applied before the project config, is not trust-gated, and edits take effect on the next launch. `pack` is **not** allowed here; packs exist to share DSL across your own projects, not to define global defaults.

If you previously used a launcher-specific `config` file under `~/.config/xcodex`, `~/.config/xpi`, `~/.config/xomp`, or `~/.config/xopencode`, move the rules you want to share into `~/.config/xclaude/config`; those old config files are no longer loaded. Each launcher keeps its own trust ledger and snapshots.

### Packs

Packs are reusable DSL fragments you keep under `~/.config/xclaude/packs/`. Each pack is a plain file using the same four allow-verbs plus `tool`:

```sh
# ~/.config/xclaude/packs/web-dev
tool node
allow-read ~/.config/shared-dotfiles
allow-write ~/cache/projects-shared
```

A project opts in with `pack <name>`:

```sh
# my-project/.xclaude
pack web-dev
allow-read ./vendor
```

**Rules:**

- `pack` is only legal in project configs (`.xclaude`), never in user config or inside another pack.
- Packs cannot contain `pack` (no nesting, no cycles).
- Packs can contain `tool <bundled>` and the usual `allow-read`/`allow-write`/`allow-exec`.
- Packs share the DSL's safety constraints — no raw SBPL, no system paths, no targeting `.xclaude`.
- Pack names must match `[A-Za-z0-9_][A-Za-z0-9_-]*` (no `..`, no slashes).

**Trust model.** Pack approval is per-project, per-hash:

| Situation | What you see |
|---|---|
| First time this project references `pack X` | Prompt — full pack contents shown |
| Pack unchanged since you approved it for this project | One-line reminder (`using pack X (trusted)`) + verb summary |
| Pack file changed | Diff prompt — accept/reject the delta |
| A different project references the same pack (same hash) | Prompt — each project trusts independently |

Approving a pack in project A does **not** carry over to project B: each project audits every pack it pulls in. Denial of any pack exits xclaude — there is no base-only fallback.

## Bundled plugin

xclaude ships with a Claude Code plugin that's loaded automatically — `xclaude` always launches `claude` with `--plugin-dir <xclaude-install-dir>`. You don't install or enable it separately.

It provides three things:

### Denial hook

`plugin/hooks/sandbox-denial-hook.sh` is registered as a `PostToolUseFailure` hook. When a tool inside the sandbox fails with "Operation not permitted" or "Permission denied", the hook:

1. Tails the sandbox denial log that `xclaude` streams from `/usr/bin/log` (kept outside the sandbox because `log` refuses to run inside one).
2. Filters denials from the last 5 seconds matching `file-read-data`, `file-write`, `process-exec`, or `forbidden-exec`.
3. Injects an `additionalContext` system reminder back to Claude with the specific denials and instructions to invoke `/debug-sandbox` rather than try to bypass the sandbox.

The hook is gated on `XCLAUDE_ACTIVE=1`, so it's a no-op when running plain `claude`.

### `/debug-sandbox` skill

A configuration assistant that drafts `.xclaude` changes. It:

- Considers alternatives to widening permissions first (local installs over global, project-local paths over `~/`)
- Reads `~/.config/xclaude/config` so it doesn't suggest rules you already have
- Identifies your tech stack and matches it to a bundled toolchain when possible
- Picks the narrowest path and the minimum operation (`allow-read` over `allow-write` whenever the tool only needs to read)
- Refuses to suggest workarounds that bypass the sandbox

You can invoke it manually with `/debug-sandbox`, but typically the denial hook will direct Claude to invoke it automatically when something gets blocked.

### `/reload-sandbox` skill — hot reload

`.xclaude` is write-protected inside the sandbox (deny-after-allow), so configuration changes have to happen on disk before the sandbox restarts. The reload skill bridges this gap:

1. The skill `touch`es a sentinel file (`$XCLAUDE_RELOAD_SENTINEL`) and tells you to `/exit`.
2. `xclaude` runs in a `while true` loop. When `claude` exits, it checks for the sentinel.
3. If the sentinel exists, xclaude re-runs the assembler, regenerates the profile, and starts a new `claude --continue` so your conversation resumes seamlessly.
4. If the new `.xclaude` differs from the previously trusted version, the trust gate shows a diff and re-prompts before activating it.

In practice the workflow is: a tool fails → hook injects denial context → Claude invokes `/debug-sandbox` → you approve the proposed `.xclaude` → Claude invokes `/reload-sandbox` → you `/exit` → sandbox restarts with the new rules → conversation continues.

## Detecting the sandbox

xclaude sets `XCLAUDE_ACTIVE=1` for every process inside the sandbox. CLI tools that should only run within the sandbox can check for it:

```bash
# Shell
if [[ "${XCLAUDE_ACTIVE:-}" != "1" ]]; then
  echo "error: must run inside xclaude sandbox" >&2
  exit 1
fi
```

```python
# Python
import os, sys
if os.environ.get("XCLAUDE_ACTIVE") != "1":
    print("error: must run inside xclaude sandbox", file=sys.stderr)
    sys.exit(1)
```

```javascript
// Node.js
if (process.env.XCLAUDE_ACTIVE !== "1") {
  console.error("error: must run inside xclaude sandbox");
  process.exit(1);
}
```

`XCLAUDE_ACTIVE` is the **stable, public** API for sandbox detection — it's inherited by all child processes and won't change. `xclaude`, `xcodex`, `xpi`, `xomp`, and `xopencode` all set it so sandbox-aware tools work under any launcher. Other `XCLAUDE_*` environment variables (`XCLAUDE_DENIAL_LOG`, `XCLAUDE_RELOAD_SENTINEL`) are internal and may change without notice.

The agent-specific wrappers also set `XCODEX_ACTIVE=1`, `XPI_ACTIVE=1`, `XOMP_ACTIVE=1`, or `XOPENCODE_ACTIVE=1` respectively. None has denial-hook or reload sentinel variables today.

## Reference

### SBPL parameters

`xclaude` passes these to `sandbox-exec` via `-D KEY=value`. Use `(param "NAME")` in SBPL — never hardcode paths.

| Parameter | Resolves to |
|---|---|
| `HOME` | `/Users/<you>` |
| `PROJECT_DIR` | Absolute path of the project (resolved with `readlink -f`) |
| `TMPDIR` | `/private/var/folders/<...>/T/` |
| `CACHE_DIR` | `/private/var/folders/<...>/C/` (sibling of TMPDIR — Spotlight/mds, keychain, direct Metal cache writes) |
| `VOLATILE_DIR` | `/private/var/folders/<...>/X/` (sibling of TMPDIR — code-signing clones) |
| `XCLAUDE_DIR` | Absolute path of the xclaude installation (used to allow the bundled plugin) |
| `XOMP_DIR` | Absolute path of the xomp installation |
| `XOPENCODE_DIR` | Absolute path of the xopencode installation |
| `OPENCODE_BIN` | Resolved OpenCode executable selected before entering Seatbelt |

### Environment variables

| Variable | Value | Stability |
|---|---|---|
| `XCLAUDE_ACTIVE` | `1` | **Stable** — shared public API for sandbox detection, set by both launchers |
| `XCLAUDE_DENIAL_LOG` | Path to streaming denial log | Internal — do not rely on |
| `XCLAUDE_RELOAD_SENTINEL` | Path to reload sentinel file | Internal — do not rely on |
| `XCODEX_ACTIVE` | `1` | **Stable** — public API for Codex sandbox detection |
| `XPI_ACTIVE` | `1` | **Stable** — public API for Pi sandbox detection |
| `XOMP_ACTIVE` | `1` | **Stable** — public API for Oh My Pi sandbox detection |
| `XOPENCODE_ACTIVE` | `1` | **Stable** — public API for OpenCode sandbox detection |

### Files

| File | Purpose |
|---|---|
| `xclaude` | Executable entry point — sources library, runs sandboxed Claude (reload loop) |
| `xcodex` | Executable entry point — sources library, runs sandboxed Codex CLI |
| `xpi` | Executable entry point — sources library, runs sandboxed Pi coding agent |
| `xomp` | Executable entry point — sources library, runs sandboxed Oh My Pi |
| `xopencode` | Executable entry point — sources library, runs sandboxed OpenCode |
| `xsandbox.lib.zsh` | Shared DSL parser, validator, SBPL generator, assembler, trust gate |
| `xclaude.lib.zsh` | Claude-specific wrapper over the shared library |
| `xcodex.lib.zsh` | Codex-specific wrapper over the shared library |
| `xpi.lib.zsh` | Pi-specific wrapper over the shared library |
| `xomp.lib.zsh` | Oh My Pi-specific wrapper over the shared library |
| `xopencode.lib.zsh` | OpenCode-specific wrapper over the shared library |
| `base-common.sb` | Shared SBPL base (`deny default` + common rules) |
| `base.sb` | Claude-specific SBPL fragment layered on top of `base-common.sb` |
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
| `test_xclaude.bash` | DSL pipeline unit tests (any platform, bash 4+) |
| `test_sandbox.zsh` | Sandbox integration test runner (macOS only) |
| `test_xcodex_sandbox.zsh` | Codex base-profile sandbox integration tests (macOS only) |
| `test_xpi_sandbox.zsh` | Pi base-profile sandbox integration tests (macOS only) |
| `test_xomp_sandbox.zsh` | Oh My Pi base-profile sandbox integration tests (macOS only) |
| `test_xopencode_sandbox.zsh` | OpenCode base-profile sandbox integration tests (macOS only) |
| [`CLAUDE.md`](CLAUDE.md) | Development guide — architecture, adding toolchains, base profile changes |
| [`DEBUGGING.md`](DEBUGGING.md) | Diagnosing sandbox issues, SBPL gotchas, denial categories |

## Testing

**DSL pipeline tests** (any platform, bash 4+):

```bash
bash test_xclaude.bash
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
zsh test_sandbox.zsh --with-config path/to/.xclaude

# Codex base profile
zsh test_xcodex_sandbox.zsh

# Oh My Pi base profile
zsh test_xomp_sandbox.zsh

# OpenCode base profile
zsh test_xopencode_sandbox.zsh
```

GitHub Actions workflows are temporarily disabled and preserved in
[`.github/workflows-disabled`](.github/workflows-disabled/README.md).
Run the commands above locally. The preserved workflows define separate
toolchain jobs with tools installed at their canonical paths. Tests verify:

- Read/write/exec access to declared paths
- Real tool operations (`npm install`, `cargo build`, `uv pip install`, etc.) — not just `--version`
- Isolation (sensitive paths like `~/.ssh` remain blocked)
- Write protection (`.xclaude`, `.env*`, `.git/hooks`)
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
