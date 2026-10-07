# Draft: relaxed profile with a deny-default baseline and broader filesystem grants

Status: design notes only; this variant is not implemented. The historical
experiments and usage counts below were recorded during earlier investigation;
their scripts and raw results are not included here and must be reproduced before
they are relied on for implementation. The proposed profile selector must be added to the dispatcher; it is not an
existing Rollcage option.

## Context

`rollcage claude` today runs `claude --dangerously-skip-permissions` in `__rollcage_launch_claude` under a
**deny-default allowlist** sandbox (`base-common.sb:2` is `(deny default)`): access is limited
to the project, temporary directories, explicit base grants, and configured rules.
That is the right posture for untrusted work, but it is too restrictive for everyday tasks — the user reports avoiding
`rollcage` for that reason and running `claude` bare instead, i.e. with **no** sandbox at all.

The goal of this variant is a **low-friction profile usable in the majority of cases**, opt-in,
that gives *some* protection against common attack vectors — especially the developer
supply-chain malware class (malicious npm/pip install scripts) — without the strictness of the
allowlist. It is explicitly **not** full containment; it trades the strict profile's narrower
read access for usability while leaving network traffic unrestricted, on the theory
that *a sandbox the user actually runs beats a strict one they bypass.*

### Previously recorded interface decisions

- **Selection:** `ROLLCAGE_PROFILE=relaxed` env var, plus an `rollcage --relaxed claude` flag as sugar
  for it. Unset/`default` → today's behavior. Unknown value → hard error (no silent misconfig).
- **Permission mode:** run Claude in **`--permission-mode auto`**, not bypass. The sandbox is a
  weaker boundary here, so Claude's own classifier stays on as a second layer.
- **Rollout:** opt-in only. Do **not** make `relaxed` the default yet. Revisit flipping the
  default (with `ROLLCAGE_PROFILE=strict` to opt back) only after it is battle-tested, as a
  deliberate, announced change.

## Threat model

Grounded in a survey of 2023–2026 dev supply-chain incidents (Shai-Hulud npm worm, s1ngularity/Nx,
gemini-ai-checker, LLMjacking, PondRAT, ua-parser-js/coa/rc, node-ipc, etc.). Host-level payload
behavior sorts into four classes; only two are filesystem problems this profile can address:

| Behavior | Example | Addressed here? |
|---|---|---|
| Read home-dir secrets (`~/.npmrc`, `~/.aws`, `~/.ssh`, AI-tool creds, wallets) | Shai-Hulud, s1ngularity | **Yes** — read-deny list |
| Write persistence (LaunchAgents, `~/.zshrc`, PATH hijack, agent hooks, login items) | s1ngularity (`sudo shutdown` into `.zshrc`) | **Partly** — deny listed paths; other write/delegation paths need testing |
| Network exfil (POST to C2, push to attacker GitHub repo) | every harvesting incident | **No** — this profile leaves network access open |
| Spawn/download second-stage; abuse other AI CLIs (`gemini --yolo`) | Shai-Hulud (TruffleHog), s1ngularity | **Partly** — see Exec |

Out of scope by threat model (state plainly so the profile doesn't over-claim): browser-runtime
crypto-clippers (chalk/debug, Solana web3.js, Ledger connect-kit — execute in *end users'*
browsers, never touch this machine) and build-time backdoors (xz/liblzma — weaponizes *server*
binaries at distro build time). Neither is reachable by a dev-workstation sandbox.

## Historical experiment notes to reproduce

Earlier notes report experiments with `sandbox-exec` on Darwin 24.6, using
`(allow default)` and scoped `(deny default)` profiles. Treat the following as
reported observations and design assumptions, rather than current verification:

1. **Deny-default + scoped allow-list fails closed, and deny-after-allow (last-match-wins) works.**
   A write outside the write allow-list is refused with **no deny rule** (fail-closed by absence);
   a deny placed after a broad read-allow carves a hole in it. Both confirmed; the profile uses
   `(deny default)` with a write/exec allow-list and a read deny-list — see The model.
2. **Policy is inherited across `fork` *and* `exec`, at any depth.** A write-deny is enforced on
   tested descendant binary — `touch`, `cp`, `sh`→`cp` reportedly hit the same deny.
   This supports protection of the listed file paths against direct writes;
   it does not establish that every persistence or delegated-write path is blocked.
3. **A descendant cannot loosen or re-apply the sandbox.** A nested `sandbox-exec` to
   `(allow default)` fails with `sandbox_apply: Operation not permitted`; there is no API to
   remove a sandbox.
4. **Seatbelt resolves symlinks before matching.** Reading a denied target via a symlink placed
   in an allowed dir is blocked — the deny-list can't be symlink-evaded.
5. **MAC overrides DAC.** A file the user owns and can normally read is still blocked by a deny;
   enforcement is independent of file ownership/permissions — and by the same kernel mechanism,
   independent of uid (root is bound too; not separately tested).
6. **Preference-domain writes (`defaults`/cfprefsd) need a *dual* deny.** `defaults write` has two
   paths: the cfprefsd XPC path and a direct-file fallback. A lone `file-write*` deny on
   `~/Library/Preferences` is **bypassed** (the unsandboxed `cfprefsd` daemon performs the write).
   But `file-write*` deny **combined with** `user-preference-write` deny (blanket *or*
   `preference-domain`-scoped) **blocks it** — confirmed for login-relevant domains. The SBPL
   reference documents `user-preference-write` with a `(preference-domain "com.apple.loginwindow")`
   example, consistent with this.
7. **File-drop persistence holds.** Dropping a LaunchAgent via `touch`, via `defaults write <path>`,
   or via `launchctl submit` are all **blocked** under a `~/Library/LaunchAgents` write-deny.
8. **Network can only be filtered by IP/port, never by hostname** (confirmed against multiple
   sources + the SBPL reference). General-purpose hostname allowlisting is not achievable in
   Seatbelt — so a dev profile that needs npm/registry/CDN access leaves network open.

## The model

**Keep `(deny default)`, and treat the three filesystem axes asymmetrically.** Reads and writes
carry different risk, so they get different shapes (mirroring Claude Code's own native sandbox:
reads = deny-list, writes = allow-list + carve-outs):

| Axis | Shape | Why |
|---|---|---|
| **Read** | allow `/`, **deny-list** secrets | Broad reads reduce friction but expose files omitted from the deny-list. With network access open, readable data can be exfiltrated. |
| **Write** | **allow-list** (`$HOME` + tmp + project), deny carve-outs within | Writes cause the damage (persistence/destruction/tamper). Must fail **closed**: everything outside the allow-list is unwritable *by absence* — no enumeration of system roots needed. |
| **Exec** | **allow-list** (system bins + `$HOME` + project) | Blocks direct execution of native binaries in scratch directories outside these roots. Allowed interpreters can still run readable scripts there. |

```scheme
(deny default)                          ; fail-closed baseline — identical to the strict profile
;; ── carry over base-common's reviewed non-FS allows verbatim ──
;;   network*, mach*, iokit*, sysctl*, system*, ipc-posix*, signal, process-info*,
;;   process-codesigning-status*, user-preference-read, dynamic-code-generation, process-fork

;; ── READ: broad, with a deny-list (low harm, broad need) ──
(allow file-read* (subpath "/"))        ; read anywhere; secrets carved out by the deny-list below

;; ── WRITE: allow-LIST (fail closed; nothing outside these paths is writable) ──
(allow file-write*
  (subpath (param "HOME"))              ; the user's home — the friction relief vs strict
  (subpath (param "PROJECT_DIR"))       ; workspace
  (subpath "/private/tmp")
  (subpath (param "TMPDIR"))
  (subpath (param "CACHE_DIR"))
  (subpath (param "VOLATILE_DIR")))     ; code-signing clones at launch

;; ── EXEC: allow-LIST (system bins + home + project; NOT /tmp scratch) ──
(allow process-exec
  (subpath "/bin") (subpath "/sbin") (subpath "/usr") (subpath "/opt")
  (subpath (param "HOME"))              ; tools in ~/.bun, ~/.cargo, ~/.local/bin, nvm, …
  (subpath (param "PROJECT_DIR")))

;; ── then the secret / persistence / guardrail deny-list (after the allows, last-match-wins),
;;    only needed for carve-outs INSIDE the allowed write area ──
```

Verified: `(deny default)` + scoped allow-list enforces fail-closed outside the allow-list **with
no deny rule** (a write to a path outside the allow-list is refused), while broad reads still work.
Beyond Seatbelt, macOS enforces the rest independently: TCC (keylogging/screen capture), SIP
(system integrity), keychain ACLs + securityd (keychain items), hardened runtime (app-memory).

### Why not `(allow default)`

1. **Fail-closed vs fail-open.** Anything forgotten — or any operation class a future macOS adds —
   is *denied* under `(deny default)`, *allowed* under `(allow default)`. The baseline should fail
   closed; relax only the axes we intend to.
2. **Reuses the proven non-FS posture.** base-common's non-FS allows already run Claude + every
   toolchain. The friction is purely filesystem, so only the file/exec allowlists need widening.
   `(allow default)` would additionally grant `authorization-right-obtain`, `nvram*`,
   `user-preference-write`, etc. — none needed for dev work.
3. **Auditable + documentable.** Per repo rule, every SBPL statement needs a justifying comment.
   `(allow default)` is one line granting thousands of operations; explicit allows are
   self-documenting and the profile is readable as "exactly this is permitted."
4. **Smaller diff from strict.** `base-relaxed-common.sb` = base-common with file allowlists
   widened to `/` + exec opened + deny-list appended — easy to review and keep in sync.

Cost: an exotic non-FS operation a tool needs could be denied. base-common already covers the
realistic set (the strict profile proves it), and the denial-log hook surfaces any gap to add.

## The deny-list

### Reads to deny (broad read grant otherwise)

The running agent's *own* credentials are the deliberate exception — Claude needs
`~/.claude/.credentials.json` and the keychain to authenticate, so we protect *other* tools, not
self. Each rule carries a comment naming the incident driver (repo convention).

| Target | Driver |
|---|---|
| `~/.ssh`, `~/.gnupg` | SSH/GPG private keys (s1ngularity, Shai-Hulud) |
| `~/.aws`, `~/.config/gcloud`, `~/.config/gh`, `~/.npmrc`, `~/.netrc` | cloud/registry tokens (Shai-Hulud, s1ngularity, LLMjacking) |
| `~/.gemini`, `~/.cursor`, `~/.continue`, `~/.codeium`, Cline/Windsurf globalStorage | *other* AI agents' creds (s1ngularity, gemini-ai-checker) |
| `~/.ethereum`, `~/.electrum`, `~/Library/Application Support/{Exodus,Electrum,…}` | crypto wallets (s1ngularity, GlassWorm) |
| `~/Library/Application Support/Google/Chrome`, Firefox, `~/Library/Safari`, `~/Library/Cookies` | browser cred/cookie stores (JarkaStealer, PureLogs) |
| `~/Library/Group Containers/2BUA8C4S2C.com.1password` | belt-and-suspenders (encrypted at rest anyway) |

### Writes to deny (carve-outs *inside* the write allow-list)

Because writes are an allow-list, system roots (`/usr`, `/etc`, `/Library`, `/opt`, …),
`/Library/LaunchAgents`, and `/private/var/at` need **no** deny rule — they're outside `$HOME`/tmp/
project, hence unwritable by absence. The deny-list only carves out persistence/secret locations
*within* the allowed area. All are direct file writes, confirmed blocked tree-wide (finding #2, #7).

**Earlier notes report a usage survey** (see Survey below): most listed paths had
few observed writes across 302 sessions and 15,897 Bash commands. These aggregate
counts suggest low friction in that corpus, but do not establish future compatibility.

| Target | Vector | Writes in history |
|---|---|---|
| `~/.zshrc`, `.zprofile`, `.zshenv`, `.bashrc`, `.bash_profile`, `.profile`, `~/.config/fish/config.fish`, `~/.oh-my-zsh` | shell-init persistence (s1ngularity) | ~few (mostly read false-positives) |
| `~/.ssh`, `~/.gnupg` | `config` exec directives / `authorized_keys` backdoor / keys (also read-denied) | 1 / 0 |
| `~/Library/LaunchAgents` | login persistence (the in-`$HOME` launch dir) | ~2 |
| `~/.local/bin` | PATH hijack + protects the `claude` binary symlink | 0 |
| `~/.gitconfig`, `~/.config/git` | `core.hooksPath`/aliases/filters/`credential.helper` → exec on git ops | 0 |
| `~/.claude/{settings.json,settings.local.json,hooks,plugins,commands,CLAUDE.md}` | tamper with own guardrails / prompt-inject future sessions | 4 / 5 (rest 0) |
| `~/.config/rollcage`, `(param ROLLCAGE_DIR)` | rewrite trust ledger / `base-claude.sb` → disable sandbox next launch | 6 (dev-on-rollcage only) |
| `<project>/.git/hooks`, `<project>/.rollcage` | code-on-git-action / sandbox config escalation | (already in strict base) |

Notes:
- `~/.cargo/config.toml`, `~/.npmrc`, and similar tool-config exec hooks are **0 writes** too, but
  belong in their toolchains (see Tier 2 below), not the base.
- `~/.claude/CLAUDE.md` is the softest entry (prompt-injection risk only, ~5 historical edits) — but
  it's stowed from a repo, so denying the literal path doesn't block real editing. Drop if desired.
- **Kept writable despite being exec-vectors**, because the survey shows they're active workflows:
  `~/.task/hooks` (7 writes), and the pnpm/uv/node stores under `~/Library`, `~/.cache`,
  `~/.local/share`, `~/.config/pnpm`.
- `/Library/Application Support/ClaudeCode` managed settings are outside `$HOME` → already
  unwritable; deny only if a future macOS relocates them under `$HOME`.

### Preference-domain persistence (the dual-deny — finding #6)

A `file-write*` deny on `~/Library/Preferences` alone is insufficient. For each persistence-
relevant preference domain, deny **both** paths:

```scheme
;; Block the direct-file fallback that `defaults`/plutil could use to drop a pref plist.
;; cfprefsd-mediated writes for OTHER (innocuous) domains still work — cfprefsd is unsandboxed —
;; so this is low-friction; it only stops a sandboxed process writing pref plists directly.
(deny file-write*
  (subpath (string-append (param "HOME") "/Library/Preferences")))

;; Block the cfprefsd XPC path for login/persistence domains. Scoped by domain so ordinary
;; preference writes (the common case) are unaffected. Verified: file-deny + this = blocked.
(deny user-preference-write
  (preference-domain "com.apple.loginitems")
  (preference-domain "com.apple.loginwindow")
  (preference-domain "com.apple.SystemLoginItems")
  (preference-domain "com.apple.backgroundtaskmanagement"))
```

Caveat: the persistence-relevant domain set is enumerable (whack-a-mole), but the high-value ones
are few. Treat this list as best-effort and expand if new vectors surface.

### Exec — allow-list (`$HOME` granularity, not open)

The write allow-list and deny carve-outs target direct writes to listed persistence paths;
they do not guarantee prevention of every persistence mechanism. Exec scope reduces
the directly executable surface. The friction
reason for opening exec was avoiding enumeration of `~/.bun`, `~/.cargo`, `~/.local/bin`, nvm, etc.
— but a single `(subpath (param "HOME"))` covers all of them at once. So make exec an **allow-list**
(system bins + `$HOME` + project), which:

- covers every real dev tool with no enumeration;
- **blocks direct native execution from scratch directories outside the exec roots**;
- still permits an allowed interpreter to run a readable script in `/tmp`;
- permits binaries written under `$HOME` to execute, and does not prove they cannot
  establish persistence through an omitted path or an unsandboxed service.

This is tighter than open exec at the same near-zero friction, consistent with the fail-closed
write/exec posture.

### Network — open (finding #8)

Left open: Seatbelt cannot allowlist by hostname, and a dev profile needs npm/registry/CDN/GitHub
access. Even the worst incidents (Shai-Hulud, s1ngularity) exfiltrated over `api.github.com` via
stolen tokens, so an IP/port allowlist wouldn't have stopped them anyway. The chosen strategy is
**starve and confine** (deny reading the credentials worth stealing) rather than chase egress.

## Survey: validating the deny-list against real usage

The deny-list was checked against the user's actual Claude Code history rather than guessed. Method
(token-efficient, aggregate-only — stream every JSONL, emit counts):

- Corpus: `~/.claude/projects/**/*.jsonl` — 302 main sessions + 353 subagents, 551 MB.
- **Structured writes:** for every `Write`/`Edit`/`NotebookEdit` `tool_use`, take `file_path`,
  classify against the record's `cwd` (in-project vs out), bucket out-of-project home writes by
  `~/c1/c2`. Result: 9,525 writes — 89% in-project, 10% other code projects, **only 35 (0.37%) to
  home infra** (dotfiles/config/Library). Top home-infra targets: `~/.claude/plans` (15, keep),
  `~/.claude/CLAUDE.md` (5), `~/.task/hooks` (5, keep), `~/.claude/settings.json` (4).
- **Bash side-effect writes:** scan 15,897 `Bash` commands for each deny-target path with a
  write-verb heuristic, then disambiguate global `~/.claude` from project `.claude` and eyeball
  examples to drop read/backup false-positives. Result: deny-targets are written 0–5× each; the
  scary-looking counts (`~/.claude/settings` "56 write-ish") were reads/backups-to-`/tmp`/mentions.

The reported counts suggest low friction in the surveyed workflows, and informed the list
(keep `~/.task/hooks` and the pnpm/uv stores writable; `~/.gitconfig`/`~/.local/bin`/`~/.cargo`
denies are free; `/tmp` must stay writable).

## Architecture / wiring

The relaxed model widens base-common's filesystem allowlists rather than flipping the default, so
it **replaces** the base fragments (different allow scopes + a deny-list) but keeps the same
`(deny default)` baseline. Unlike the committed `gui-profile-variant.md` plan it does not append to
the strict base — the file allowlists differ — but it is a small, reviewable diff from it.

### New fragments

- `base-relaxed-common.sb` — `(deny default)` + base-common's non-FS allows carried over verbatim +
  the broad read allow (`(subpath "/")`) + the write/exec allow-lists (`$HOME` + tmp + project) +
  the read/write deny carve-outs + the dual-deny preference block.
- `base-relaxed.sb` — Claude-specific runtime grants. Reads of `~/.claude` stay
  allowed (covered by the broad read allow; not in the read-deny list) so the agent can auth.
- `base-relaxed-tail.sb` — mandatory guardrail write-denies, appended after all
  user/project rules and toolchains; covers agent settings/hooks, sandbox control
  state, the installation directory, and project sandbox config.

### Selection (`rollcage.lib.zsh`, `__rollcage_init`)

```zsh
# Only the Claude selection would accept this draft variant.
case "${ROLLCAGE_PROFILE:-default}" in
  default) __rollcage_base_profiles=("${__rollcage_dir}/base-common.sb" "${__rollcage_dir}/base-${cli}.sb") ;;
  relaxed) __rollcage_base_profiles=("${__rollcage_dir}/base-relaxed-common.sb" "${__rollcage_dir}/base-relaxed.sb") ;;
  *) __rollcage_log "unknown ROLLCAGE_PROFILE: ${ROLLCAGE_PROFILE}"; return 1 ;;
esac
```

### Launcher (`rollcage` dispatcher and `adapters/claude.zsh`)

- Parse `--relaxed` in the dispatcher before the CLI selector → set `ROLLCAGE_PROFILE=relaxed` (flag is sugar for the env var);
  validate `ROLLCAGE_PROFILE` near the top and error on unknown values.
- Replace the hardcoded permission flag in `__rollcage_launch_claude` with an array, mirroring the gui plan:

```zsh
local -a perm_args=(--dangerously-skip-permissions)
[[ "${ROLLCAGE_PROFILE:-default}" == "relaxed" ]] && perm_args=(--permission-mode auto)
# … -- claude "${perm_args[@]}" --plugin-dir "${__rollcage_dir}" "${claude_args[@]}"
```

The reload-on-denial loop, plugin dir, denial-log hook, packs, DSL, and trust gate are unchanged.

### Re-grant ordering (required protection)

The assembler (`__rollcage_assemble`) concatenates base → user rules → project
rules, with toolchains and packs expanded in place. A later allow can override an
earlier deny. The base-only policy permitted a later parent-directory write grant to override
the literal `.rollcage` deny. Rollcage now appends `base-protections.sb` and
resolved control-file denies after all grants; retain that ordering in variants.

For the **non-negotiable guardrail set** (`~/.claude` settings/hooks, `~/.config/rollcage`,
the other launchers' trust stores, `ROLLCAGE_DIR`, project `.rollcage`), append
the existing `base-protections.sb` and additional relaxed guardrails in
`base-relaxed-tail.sb` **last** so generated rules cannot override them. This is a
required boundary, not optional hardening. Test parent grants, creation, replacement,
deletion, and resolved symlink paths. Whether other secret/persistence denies may
be deliberately re-granted remains a separate design decision.

## Residuals (documented, not fixed)

- **Network exfil** is not contained (finding #8). The read-deny list starves it of high-value
  material; it does not stop it. Same gap exists in the strict profile.
- **In-session damage** — a payload can read the *project's own* `.env` (necessarily readable) and
  POST it during install. Listed write-denies do not stop this exfiltration.
- **The agent's own token is readable in-session** — `~/.claude/.credentials.json` and the keychain
  must stay readable for Claude to auth, so in-session code (incl. a payload that nests
  `claude -p …`) can read them. Unavoidable; also true of the strict profile.
- **Broad `mach`/XPC delegation** for operations macOS does *not* gate at the operation level. The
  cfprefsd case turned out closable via `user-preference-write` (macOS does gate that on the
  caller), but other unsandboxed-daemon delegations may not have an equivalent operation gate.
  Tightening `mach*` wholesale is fragile/high-friction; left open (as in the strict profile).
- **Supply-chain prompt injection** (`.cursorrules`/`CLAUDE.md` with hidden instructions) lives in
  the project tree — an agent-design concern, not a sandbox one.
- **Interpreter execution** — native exec restrictions on `/tmp` do not stop
  allowed shells or runtimes reading and executing scripts there.

## Tests

New `test_rollcage_relaxed_sandbox.zsh` (mirrors `test_codex_sandbox.zsh` / `test_pi_sandbox.zsh`),
assembled with `ROLLCAGE_PROFILE=relaxed`:

- **Allow-list works:** write to `~/<random>` and read an arbitrary home file → allowed.
- **Write fails closed by absence:** write to a path *outside* `$HOME`/tmp/project (e.g.
  `/opt/relaxed-test`, `/usr/local/relaxed-test`) → denied with no deny rule present.
- **Write carve-outs hold:** `~/Library/LaunchAgents`, `~/.zshrc`, `~/.local/bin`, `~/.gitconfig`,
  `~/.claude/settings.json`, `~/.config/rollcage`, `~/.ssh`, project `.rollcage` → denied.
- **Final protections hold:** later parent-directory grants cannot permit writing,
  replacing, creating, or deleting protected config and trust state.
- **Read-denies hold:** `~/.ssh`, `~/.aws`, `~/.gemini` → denied; `~/.claude` → **allowed** (agent creds).
- **Symlink evasion blocked:** symlink in project → `~/.ssh`, read denied.
- **Preference dual-deny:** `defaults write com.apple.loginitems …` → blocked; an innocuous
  domain → still writes (selectivity). Assert the file-deny-only case is *not* relied upon.
- **Exec allow-list:** a binary under `~` runs; a binary in `$TMPDIR`/`/private/tmp` does **not**
  (blocked by absence). Separately document that allowed interpreters can run scripts there.
- **Agent starts:** Claude launches under the profile (as the rollcage codex/rollcage pi tests verify their agents).

DSL pipeline is unchanged → `test_rollcage.bash` and `toolchains/*` untouched.

## Docs to update

- `README.md` — document `ROLLCAGE_PROFILE=relaxed` / `rollcage --relaxed claude`: what it adds, that it
  runs Claude in `auto` mode, and the explicit residuals (network not contained).
- `CLAUDE.md` (repo) — add the `base-relaxed*.sb` files to the architecture list and a "Profile
  variants" note under the SBPL section; record the deny-default model, final protections,
  and the dual-deny finding once reproduced.
- `plugin/skills/debug-sandbox/SKILL.md` — note the relaxed variant so denial diagnosis accounts
  for it (and that under it most denials mean a guardrail/secret deny fired, not a missing allow).
- `.github/workflows/test.yml` — add a CI job running `zsh test_rollcage_relaxed_sandbox.zsh`.

## Verification

1. `bash test_rollcage.bash` — DSL pipeline unaffected (sanity).
2. `zsh test_rollcage_relaxed_sandbox.zsh` — new relaxed assertions pass.
3. `zsh test_sandbox.zsh --toolchain none` — strict base profile unchanged/green.
4. Manual smoke: `rollcage --relaxed claude` in a normal project; confirm Claude starts in `auto` mode,
   ordinary home-dir reads/writes work, and `npm install` of a known package succeeds while a
   write to `~/Library/LaunchAgents` is refused.

## Open trade-offs (flagged, not blocking)

- **Credential-CLI reads** (`~/.aws`, `~/.config/gcloud`, `~/.config/gh`, `~/.npmrc`): denied here
  because real malware targets exactly these paths, but that breaks `aws`/`gh`/`npm publish`
  *inside* agent sessions. The DSL is the re-grant path — a project that needs one adds
  `allow-read ~/.config/gh` to its `.rollcage` (trust-gated). If the user routinely uses these CLIs
  in sessions, reconsider leaving them readable.
- **`~/.claude/settings.json` write-deny** may interfere with in-session settings changes
  (`/config`). Claude Code's native sandbox denies it and CC still works (settings edits are rare /
  doable outside); following that precedent, but easy to carve out if it bites.
- **Re-grants outside the guardrail set** — decide which secret/persistence denies
  may be overridden by trusted rules. Final guardrail protections are mandatory.
