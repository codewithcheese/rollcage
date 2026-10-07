# Add a permissive "gui" profile variant for Electron+libghostty dev

Status: unimplemented design notes. The proposed profile selector must be handled
by the dispatcher before selecting the Claude adapter; existing CLI arguments
remain pass-through. Final `base-protections.sb` denies still apply.

## Context

Today `rollcage claude` launches `claude --dangerously-skip-permissions` (bypass mode) with the
Seatbelt sandbox as the *only* safety boundary (`adapters/claude.zsh`). The user is using Claude to
develop an **Electron app that embeds libghostty**. That means Claude — running inside the
sandbox — must be able to run the dev server and **launch the Electron GUI** (Chromium +
Metal via libghostty) from within the sandbox.

Two changes are needed:

1. The sandbox must be permissive enough for a GUI dev app. `base-common.sb` already opens
   `network*`, `mach*`, `iokit*`, `ipc-posix*`, `dynamic-code-generation` (V8 JIT), and
   exec of anything under `PROJECT_DIR` (so `node_modules/.../Electron` already runs). The
   real gap is **filesystem writes under `~/Library`** that Electron/Chromium/libghostty need
   for userData, caches, GPU/shader caches, and window state.
2. Because the profile is more permissive, Claude should run in **`auto` permission mode**
   (`--permission-mode auto`, confirmed a valid flag), not bypass — Claude's own classifier
   becomes the second safety layer. Electron runs with `--no-sandbox` (user-side launch
   detail; nested Chromium sandboxing is intentionally not attempted).

Delivery (per user): a **more permissive base-profile variant** selected from the existing
`rollcage` launcher via an env var. Keep `rollcage` generic — no app-specific bundle IDs baked in.

## Approach

Selection knob: `ROLLCAGE_PROFILE` env var. Unset/`default` → current behavior. `gui` →
append `base-gui.sb` to the base fragments **and** swap the permission flag to
`--permission-mode auto`. Unknown values error out (no silent misconfig).

### 1. New file: `base-gui.sb` (additive fragment)

Concatenated after `base-common.sb` + `base-claude.sb` (the assembler just `cat`s the array —
`__rollcage_read_base_profile`). Each rule gets a comment (repo convention). Grants **read+write**
(write does not imply read in SBPL, so both verbs) on the GUI-runtime subpaths Electron/
Chromium/libghostty use:

- `~/Library/Application Support` — Electron `userData`, libghostty config/state, Chromium GPUCache/ShaderCache
- `~/Library/Caches` — Chromium HTTP/code cache
- `~/Library/Saved Application State` — Cocoa window restoration
- `~/Library/HTTPStorages` — Chromium network state
- `~/Library/WebKit` — webview storage
- `~/Library/Preferences` — Cocoa/Chromium `NSUserDefaults` plists

Plus **read-only**:
- `~/.config/ghostty` — libghostty config / themes
- `~/Library/Fonts` — user fonts for text rendering

Security scoping (deny-after-allow, last-match-wins):
- `(deny file-write* (subpath "~/Library/Application Support/com.apple.TCC"))` — block tampering with the privacy/permissions DB.
- Note in comments: `~/Library/LaunchAgents` is deliberately **not** granted (sits outside the allowed subpaths) so this variant can't install a login persistence item.
- Header comment states the trade-off explicitly: this variant widens writes across other apps' `~/Library` data; that is the accepted cost of running a GUI dev app, and is why Claude runs in `auto` (not bypass) mode under it.

No new `process-exec`, `mach`, `iokit`, or `network` rules are required — base already covers them.

### 2. Launcher wiring

**`rollcage.lib.zsh`** (`__rollcage_init`, around line 14): conditionally append the fragment.
```zsh
__rollcage_base_profiles=("${__rollcage_dir}/base-common.sb" "${__rollcage_dir}/base-${cli}.sb")
if [[ "$cli" == "claude" && "${ROLLCAGE_PROFILE:-default}" == "gui" ]]; then
  __rollcage_base_profiles+=("${__rollcage_dir}/base-gui.sb")
fi
```

**`adapters/claude.zsh`** (`__rollcage_launch_claude`): select permission flag via an array, and validate the env var
near the top of `main()` (error on unknown value). Replace the hardcoded
`claude --dangerously-skip-permissions ...` with:
```zsh
local -a perm_args=(--dangerously-skip-permissions)
[[ "${ROLLCAGE_PROFILE:-default}" == "gui" ]] && perm_args=(--permission-mode auto)
# ...
-- claude "${perm_args[@]}" --plugin-dir "${__rollcage_dir}" "${claude_args[@]}"
```
The reload-on-denial loop, plugin dir, and denial-log hook are unchanged.

### 3. Tests

- New integration test `test_rollcage_gui_sandbox.zsh` (mirrors `test_codex_sandbox.zsh` /
  `test_pi_sandbox.zsh` precedent). Assemble with `ROLLCAGE_PROFILE=gui` and assert:
  - write **allowed** to `~/Library/Application Support/<tmp>` and `~/Library/Caches/<tmp>`
  - write **denied** to `~/Library/Application Support/com.apple.TCC/<tmp>`
  - write **denied** to `~/Library/LaunchAgents/<tmp>` (not granted)
  - `~/.ssh` read still **denied** (base isolation intact)
  - clean up all fixtures.
- No DSL change → `test_rollcage.bash` and `toolchains/*` untouched.

### 4. Docs

- `README.md`: document the `ROLLCAGE_PROFILE=gui` variant — what it adds and that it runs
  Claude in `auto` mode.
- `CLAUDE.md` (repo): add `base-gui.sb` to the architecture file list and an "Profile
  variants" note under the SBPL section; record the `auto`-mode + `--no-sandbox` decisions.
- `plugin/skills/debug-sandbox/SKILL.md`: note the gui variant and what it already covers, so
  denial diagnosis accounts for it.

## Verification

1. `bash test_rollcage.bash` — DSL pipeline unaffected (sanity).
2. `zsh test_rollcage_gui_sandbox.zsh` — new gui-profile assertions pass.
3. `zsh test_sandbox.zsh --toolchain none` — base profile unchanged/green.
4. Manual smoke: `ROLLCAGE_PROFILE=gui rollcage` in the Electron+libghostty project, confirm
   Claude starts in `auto` mode and that `npm run dev` + launching the Electron app
   (`electron . --no-sandbox`) renders a window with the embedded terminal. If a denial
   appears, the denial-log hook surfaces the path to fold into `base-gui.sb` or project `.rollcage`.

## Open trade-off (flagged, not blocking)

`base-gui.sb` grants broad `~/Library/{Application Support,Caches,...}` read+write rather
than scoping to the app's bundle name, because the custom app's product name isn't known
here. If you'd prefer tighter scoping, give me the app's `userData` dir / product name and
I'll narrow the subpaths and move the rest to project `.rollcage`.
