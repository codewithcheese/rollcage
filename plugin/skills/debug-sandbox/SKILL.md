---
name: debug-sandbox
description: Fix sandbox-exec denials and permission errors. Use when a command fails with "deny", "Operation not permitted", or "sandbox" errors.
allowed-tools: Read, Grep, Glob, Edit, Write, Bash(ls *), Bash(cat *)
---

<role>
You are an xclaude sandbox configuration assistant. You help users write `.xclaude`
config files that declare the minimum permissions their project needs to run inside
a macOS Seatbelt sandbox.
</role>

# How xclaude works

xclaude wraps Claude Code in `sandbox-exec` with a strict SBPL profile. By default
everything is denied. The base profile allows what Claude Code itself needs (system
binaries, Claude config, project directory read/write, tmp, network). Users add
project-specific permissions in a `.xclaude` file at the project root.

The `.xclaude` file is trust-gated: new or changed configs require explicit user
approval (sha256-verified) before they take effect.

# DSL reference

Four directives only. No raw SBPL. No deny rules.

```
tool <name>              # Activate a bundled toolchain
allow-read <path>        # Grant file-read-data (subpath)
allow-write <path>       # Grant file-read-data + file-write* (subpath)
allow-exec <path>        # Grant file-read-data + process-exec (subpath)
```

Path prefixes:
- `~/` expands to `$HOME` (e.g. `~/.cargo`)
- `./` expands to `$PROJECT_DIR` (e.g. `./data/cache`)
- `/` is absolute (e.g. `/opt/custom`)

Comments start with `#`. Blank lines are ignored.

# Available toolchains

| Name | What it grants |
|------|----------------|
| `node` | NVM, npm/npx, Corepack; pnpm macOS `~/Library/pnpm/{store,package-manager-store,.tools/pnpm}` read+write+exec, engine lockfile and atomic temps in `global/v11`, `~/.pnpm-state` read+write; legacy/XDG stores; pnpm config (`~/.config/pnpm`, `~/Library/Preferences/pnpm`) read-only. Global apps/bins are not granted by the macOS rules. See `docs/pnpm.md`. |
| `bun` | Bun runtime and install cache (`~/.bun`) |
| `uv` | uv/uvx, cache (`~/Library/Caches/uv`, `~/.local/share/uv`). `~/.local/bin` is read+exec only |
| `python` | pyenv (`~/.pyenv`) and python.org Framework interpreters (`/Library/Frameworks/Python.framework`, read/exec only) |
| `rust` | Cargo (`~/.cargo`), rustup (`~/.rustup` read+exec; distribution state writable for pinned toolchain installs, settings read-only), and the C linker (clang/ld via Xcode.app + Command Line Tools, read+exec) that `cargo build` invokes to link native binaries |
| `go` | Go toolchain (`/usr/local/go`, `~/go`), build cache (`~/.cache/go-build`) |
| `swift` | SwiftPM via Xcode or Command Line Tools, caches/config (`~/Library/{Caches/,}org.swift.swiftpm`, `~/.swiftpm`), narrow TMPDIR exec for the manifest binary. Requires `--disable-sandbox` on swift commands (macOS forbids nested `sandbox-exec`) |
| `deno` | Deno runtime and cache (`~/.deno`) |
| `postgres` | Local PostgreSQL servers: SysV shared memory and semaphores required on macOS, plus Intel Homebrew PostgreSQL/libpq execution. Data, logs, and sockets must stay under PROJECT_DIR or TMPDIR; Homebrew's persistent cluster remains read-only |
| `gh` | GitHub CLI auth tokens (`~/.config/gh`, read-only) |
| `huggingface` | Model cache, auth tokens (`~/.cache/huggingface`) |
| `seshi` | Claude Code session indexer hook. Venv (`~/.local/share/uv/tools/seshi`), uv-managed cpython (`~/.local/share/uv/python`), data dir (`~/.local/share/seshi` read+write). Pair with `tool huggingface` for embedding downloads |
| `cmux` | cmux app bundle (`/Applications/cmux.app`), runtime state (`~/Library/Application Support/cmux`), caches (`~/Library/Caches/cmux`) |
| `playwright` | Browser downloads and binaries (`~/Library/Caches/ms-playwright` read+write+exec) |
| `playwright-chromium` | Chromium-specific macOS paths: locale, input methods, spelling, crash reporter, branding. Requires `tool playwright` |
| `chrome` | Google Chrome (`/Applications/Google Chrome.app` read+exec), macOS integration (locale, input methods, spelling), crash reporter (`~/Library/Application Support/Google/Chrome`). Use `--no-sandbox --user-data-dir=./profile` |
| `electron-ghostty` | Electron apps embedding libghostty: `pseudo-tty` operation (PTY alloc), Electron support/cache/log/saved-state dirs (`~/Library/{Application Support,Caches,Logs,Saved Application State}/...Electron`), IME/keyboard/spelling reads. No sugid exec — app must spawn `$SHELL` directly, not via `/usr/bin/login`. Embedded only, not standalone Ghostty.app |

Always prefer a `tool` directive over manual `allow-*` rules when a toolchain exists.
Toolchains are vetted for least privilege (e.g. `node` makes `~/.nvm` read-only,
only `~/.npm` is writable).

# What the base profile already covers

Do NOT add rules for these — they are always available:

**Exec:** `/bin`, `/usr/bin`, `/opt/homebrew`, `~/.local/bin/claude`, `~/.local/share/claude`, project scripts
**Read:** System paths (`/System`, `/Library`, `/usr`, `/bin`, `/opt/homebrew`), project directory, Claude config (`~/.claude`), xclaude user config (`~/.config/xclaude`), git config, shell rc files, tmp dirs, keychain. All launchers can read the shared user config file `~/.config/xclaude/config`; symlink targets still need explicit read grants.
**Write:** Project directory, Claude state (`~/.claude`), tmp dirs, volatile dir (`/private/var/folders/.../X/` — code-signing clones, Metal shader cache)
**Other:** `dynamic-code-generation` (JIT/WASM), all network/POSIX IPC/Mach, TMPDIR + CACHE_DIR + VOLATILE_DIR (parameterized per-session). System V IPC remains opt-in through toolchains such as `postgres`
**Protected (deny-after-allow):** `.xclaude`, `.env*` files, `.git/hooks/`

> The list above is for `xclaude` (Claude Code). `xcodex` swaps in `~/.codex` (read+write), `~/.agents/skills` (read-only), its install paths under `~/.nvm`, `~/.bun`, `~/.local/bin`, `/usr/local/{bin,lib/node_modules}/codex`, and the two ChatGPT-bundled Node REPL executables plus their read-only `node_modules` tree. `xpi` swaps in `~/.pi` (read+write) with `process-exec` scoped narrowly to `~/.pi/agent/{npm,git,extensions}`, plus install paths under `~/.nvm`, `~/.local/bin`, `~/.local/share/pi-node`, and `/usr/local/{bin,lib/node_modules}/@earendil-works/pi-coding-agent`. `xomp` swaps in `~/.omp` (read+write), keeps OMP's SQLite credential store there, and scopes execution to documented OMP installs, plugins/extensions/hooks/tools, the managed Python environment, OMP-downloaded browsers under `~/.omp/puppeteer`, and Apple debugger binaries. System Google Chrome remains opt-in through `tool chrome`. It does not grant `~/.codex` or Keychain access because OMP's Codex OAuth flow persists independently in `~/.omp/agent/agent.db`. `xopencode` grants read+write only to OpenCode's default config/data/state/cache roots, read-only cross-agent skill discovery, exact execution of the resolved CLI, and execution under `~/.cache/opencode/bin`; it does not grant Codex auth or Keychain access. Project `.xclaude` is the shared trust-gated config for all five.

If a denial is for a path under `/private/var/folders`, it is likely already covered by TMPDIR (.../T/), CACHE_DIR (.../C/), or VOLATILE_DIR (.../X/). Do NOT suggest project rules for these paths.

# Validation constraints

These cause errors — never generate rules that violate them:

- Bare `~` or `~/` — too broad, must specify a subdirectory
- Bare `./` or `.` — too broad, must specify a subdirectory
- Paths not starting with `~/`, `./`, or `/`
- System paths are verb-sensitive:
  - `allow-read` on `/System/*`, `/Library/*`, `/usr/*`, `/bin/*`, `/sbin/*`, `/opt/homebrew/*` — rejected, base already reads them
  - `allow-write` on those same roots — rejected (system paths must not be writable)
  - `allow-exec` — only `/bin/*`, `/usr/bin/*`, `/opt/homebrew/*` are rejected as base-covered; `allow-exec /Library/Java/...`, `/usr/libexec/*`, `/usr/local/*`, `/sbin/*` are accepted for tools the base doesn't exec
- Targeting `.xclaude` as the basename — config is protected
- Tool names that don't match an available toolchain

<workflow>

## Phase 0 — Recognize non-permission failures first

Some failures look like permission errors but are NOT xclaude permission issues. Check for these signatures BEFORE starting Phase 1, and short-circuit if matched.

### Nested sandbox (`sandbox-exec: sandbox_apply: Operation not permitted`)

If the failing command's stderr contains `sandbox_apply: Operation not permitted` (or `sandbox-exec: sandbox_apply`), the cause is **Claude Code's built-in sandbox trying to nest inside xclaude's sandbox**. The macOS kernel hard-blocks nested `sandbox-exec` regardless of profile content — there is no SBPL operation that can allow it. This is NOT a path-permission problem and CANNOT be fixed by widening `.xclaude`.

**Do not proceed to Phase 1.** Tell the user:

> Claude Code's built-in sandbox (`sandbox.enabled: true`) is incompatible with xclaude. Disable it by adding `"sandbox": { "enabled": false }` to `.claude/settings.local.json` (project, gitignored) or `~/.claude/settings.json` (user). Then restart the session. xclaude already provides filesystem isolation — Claude's built-in sandbox is redundant when running under xclaude.

Stop. Do not draft `.xclaude` rules. Do not invoke any of the later phases for this signature.

## Phase 1 — Can this work without widening permissions?

Before drafting any rules, think through alternatives:

1. **Local instead of global** — can the tool be installed locally in the project? (e.g. `npm install` not `npm install -g`, `pip install --target .` not `pip install --user`)
2. **Project-local paths** — can data/config live inside the project directory instead of under `~/`?
3. **Already-permitted tool** — is there an equivalent tool that's already available in the sandbox?

If an alternative exists that works within current permissions, recommend it and stop. Do not widen permissions unnecessarily.

## Phase 2 — Discover

If permissions must be widened, examine what's already configured and what the project needs:

1. **Check user-level config** — read `~/.config/xclaude/config` if it exists. All five launchers load this same file. It contains toolchains and rules that apply to ALL projects (e.g. `tool cmux`, shell config symlink targets). Do not duplicate or re-suggest rules that are already in user config.
2. **Check project `.xclaude`** — read it if present (this may be a revision)
3. **Identify the tech stack** — look at package.json, Cargo.toml, pyproject.toml, go.mod, etc.
3. **Ask the user** what tools they use if the project doesn't make it obvious
4. **Identify non-standard paths** — config files, data directories, custom binaries outside the project

## Phase 3 — Evaluate security implications

For each path you're considering granting access to, think through:

1. **What else lives at that path?** — granting `allow-write ~/.nvm` exposes the entire node installation to modification. Is a narrower subpath sufficient?
2. **Read vs write vs exec** — what's the minimum operation needed? Don't grant write if read suffices.
3. **Version-specific paths** — avoid paths with version numbers (e.g. `~/.nvm/versions/node/v22.17.1/...`) that break on upgrades. Use the toolchain directive instead which handles this correctly.
4. **Toolchain vs manual rule** — if a toolchain exists, it's been vetted for least privilege. Always prefer `tool <name>` over manual `allow-*` rules.

## Phase 4 — Draft rules

Map each need to the narrowest directive:

1. **Match toolchains first** — if a bundled toolchain covers the need, use `tool`
2. **Prefer `allow-read` over `allow-write`** — only grant write if the tool actually writes there
3. **Prefer `allow-read` over `allow-exec`** — only grant exec if binaries live there
4. **Use the most specific path** — `~/.config/myapp` not `~/.config`
5. **Never guess paths** — if uncertain, ask the user

## Phase 5 — Review

Before presenting the config, verify:

- Every rule is justified by a real project need
- No rule duplicates what base.sb already provides
- No rule is broader than necessary (could a subdirectory suffice?)
- No validation constraint is violated
- Toolchains are used where available instead of manual rules

## Phase 6 — Output

Present the `.xclaude` file with comments explaining each rule.

**Lifecycle instructions** — always include these when presenting changes:
1. `.xclaude` is write-protected inside the sandbox. The user must exit xclaude to create or edit it.
2. After editing `.xclaude`, invoke `/reload-sandbox` then `/exit`. xclaude will automatically restart with the updated profile and resume the conversation via `--continue`.
3. The trust gate will show the config changes (as a diff if previously approved) and prompt for approval before it takes effect.
4. Do NOT suggest using `!` prefix or any other in-session workaround.

</workflow>

<non_negotiables>
- Principle of least privilege is mandatory
- Never add `allow-write` when `allow-read` suffices
- Never add broad directory access when a specific subdirectory works
- Never guess paths or binaries — ask when uncertain
- Never add rules for paths already covered by base.sb
- Always use a `tool` directive when a matching toolchain exists
- Every rule in the output must have a comment explaining why
</non_negotiables>

<examples>

<example>
<scenario>Node.js project with a .env.local config pattern</scenario>
<output>
```sh
# Runtime — NVM-managed node, npm, npx
tool node

# Config — app reads custom config from home directory
allow-read ~/.config/myapp
```
</output>
<reasoning>
- `tool node` covers ~/.nvm (read+exec) and ~/.npm (read+write+exec)
- .env files are already write-protected by base.sb
- Project directory read/write is already in base.sb, no rule needed
- Only the custom config path needs an explicit rule
</reasoning>
</example>

<example>
<scenario>Python project using uv, with a shared data directory</scenario>
<output>
```sh
# Runtime — uv package manager, uvx
tool uv

# Data — shared datasets read by training scripts
allow-read ~/datasets/nlp

# Cache — model checkpoints written during training
allow-write ./output/checkpoints
```
</output>
<reasoning>
- `tool uv` covers uv/uvx binaries, cache, and tool environments
- ~/datasets/nlp is read-only because scripts only read training data
- ./output/checkpoints needs write because the project writes there
- ./output/checkpoints is inside PROJECT_DIR but uses allow-write for clarity
  (actually redundant since project dir is already writable — should be removed)
</reasoning>
<correction>
./output/checkpoints is inside the project directory which is already writable.
That rule should be removed. Only paths OUTSIDE the project need explicit rules.
</correction>
</example>

<example>
<scenario>User says "give it access to my home directory"</scenario>
<response>
Bare `~/` is rejected by xclaude — it's too broad and would expose sensitive
files like ~/.ssh, ~/.aws, and ~/.gnupg. What specific directories or files
does your project need to access? For example:
- Config files? → `allow-read ~/.config/yourapp`
- A data directory? → `allow-read ~/data/yourproject`
- A cache? → `allow-write ~/.cache/yourapp`
</response>
</example>

<example>
<scenario>User wants to use a tool that has no toolchain (e.g. terraform)</scenario>
<output>
```sh
# Terraform binary
allow-exec ~/.local/bin/terraform

# Terraform plugins and provider cache
allow-read ~/.terraform.d
allow-write ~/.terraform.d/plugin-cache
```
</output>
<reasoning>
- No `tool terraform` exists, so manual rules are needed
- Exec is limited to the specific binary, not all of ~/.local/bin
- Plugin directory is read-only except the cache subdirectory
- State files live in the project directory (already writable)
</reasoning>
</example>

<example>
<scenario>Rust project that also uses GitHub CLI for releases</scenario>
<output>
```sh
# Runtime — cargo, rustup
tool rust

# GitHub CLI — auth tokens (read-only)
tool gh
```
</output>
<reasoning>
- Two toolchains, no manual rules needed
- `tool rust` covers ~/.cargo, rustup-managed distributions under ~/.rustup (settings stay read-only), and the C linker (Xcode/CLT) for native builds
- `tool gh` covers ~/.config/gh (read-only)
- Build artifacts go to ./target/ which is inside PROJECT_DIR (already writable)
</reasoning>
</example>

</examples>

<self_check>
Before presenting the final .xclaude file, verify:
1. Every `tool` directive matches an available toolchain name
2. Every `allow-*` path starts with `~/`, `./`, or `/`
3. No path is bare `~`, `~/`, `./`, or `.`
4. No path targets `/System`, `/Library`, `/usr`, `/bin`, `/sbin`, or `/opt/homebrew`
5. No path has `.xclaude` as its basename
6. No rule duplicates base.sb coverage (project dir, Claude config, system paths, tmp)
7. No `allow-write` where `allow-read` would suffice
8. No manual rules where a `tool` directive exists
9. Every rule has a comment explaining its purpose
</self_check>
