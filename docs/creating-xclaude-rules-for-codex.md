# Creating a `.xclaude` rule set for Codex

This guide describes an evidence-driven way to create the smallest useful
`.xclaude` policy for a project run through `xcodex`. It is the process used to
diagnose the Blockhead repositories: inspect what the project declares, compare
that with what Codex has actually run, add only the missing external access, and
then test the assembled macOS Seatbelt profile.

The goal is not to list every tool a developer might conceivably use. The goal is
to grant the access the repository demonstrably needs without turning a project
policy into general access to the user's home directory.

## Understand the policy layers first

`xcodex` assembles its sandbox in this order:

1. `base-common.sb` and `base-codex.sb`
2. `~/.config/xclaude/config`, for requirements shared by every project and launcher
3. the project's `.xclaude`, for requirements specific to that repository

The base profile already provides the project directory, temporary directories,
networking, macOS system paths, Homebrew paths, Git's normal files, Codex state,
and supported Codex installation locations. Do not repeat those permissions in a
project file.

A project `.xclaude` uses a deliberately small DSL:

```sh
tool <name>
pack <name>
allow-read <path>
allow-write <path>
allow-exec <path>
```

Prefer a bundled `tool` over hand-written path rules. A toolchain captures the
runtime's real filesystem layout and generally separates writable caches from
read-only binaries more carefully than an ad hoc grant.

## 1. Establish the repository boundary

Resolve the target before inspecting or changing anything:

```sh
repo=~/Documents/GitHub/owner/project
cd "$repo"
pwd
git rev-parse --show-toplevel
git branch --show-current
git status --short
```

The status check matters. A repository may already contain uncommitted or
untracked user work; creating `.xclaude` does not authorize cleaning, resetting,
or otherwise changing it.

Also detect linked worktrees. `xcodex` grants a linked worktree the Git access it
needs, but the working directory shown in old Codex sessions may be a path under
`.agents/worktrees/` rather than the main checkout.

## 2. Read declared project requirements

Start with instructions and manifests, not assumptions:

```sh
rg --files \
  -g 'AGENTS.md' -g 'CLAUDE.md' \
  -g 'README*' -g 'package.json' -g 'pnpm-lock.yaml' \
  -g 'pyproject.toml' -g 'uv.lock' -g 'requirements*.txt' \
  -g 'Cargo.toml' -g 'go.mod' -g 'Dockerfile*' \
  -g '.github/**' -g 'Makefile' -g 'Justfile'
```

Read the applicable agent instructions first, followed by the README, package
scripts, dependency manifests, CI configuration, and executable project scripts.
These sources answer different questions:

| Evidence | What it tells you |
|---|---|
| Agent instructions | Required checks, prohibited actions, and workflow conventions |
| Manifests and lockfiles | Language runtimes and package managers |
| Package scripts, Makefiles, CI | Commands that constitute build, test, lint, and release |
| README | Bootstrap steps, local services, and optional workflows |
| Executable scripts | Additional CLIs and non-project paths used at runtime |

Do not read `.env`, credential files, tokens, or application data merely to build
the policy. Their presence can be recorded without inspecting their contents.

Build a small evidence table as you investigate:

| Need | Evidence | External path or capability | Candidate rule |
|---|---|---|---|
| uv dependency management | `pyproject.toml`, `uv.lock`, README | uv cache and tool environments | `tool uv` |
| GitHub release workflow | documented `gh` commands | GitHub CLI credentials | `tool gh` |
| Shared read-only dataset | script opens a path outside the repo | exact dataset directory | `allow-read ...` |

This makes speculative rules obvious: if a row has no evidence, it should not be
in the first version of the policy.

## 3. Use Codex session logs as observed evidence

Manifests describe intended tooling. Codex sessions show what development work
actually invoked. Codex stores local JSONL session records below
`~/.codex/sessions/`; treat them as sensitive because they can contain prompts,
tool input, command output, paths, and environment details.

Find sessions whose metadata has the exact repository root. Exact metadata
matching avoids false positives from sessions that merely mentioned the project:

```sh
repo="$(git rev-parse --show-toplevel)"

find ~/.codex/sessions -type f -name '*.jsonl' -print0 |
while IFS= read -r -d '' log; do
  if jq -e --arg cwd "$repo" \
    'select(.type == "session_meta" and .payload.cwd == $cwd)' \
    "$log" >/dev/null; then
    printf '%s\n' "$log"
  fi
done
```

Repeat the search for known linked-worktree roots if the project uses them.

Modern Codex logs record unified execution calls as `custom_tool_call` objects.
Extract only their inputs for inspection, rather than dumping whole sessions:

```sh
jq -r '
  select(
    .type == "response_item" and
    .payload.type == "custom_tool_call" and
    .payload.name == "exec"
  ) |
  .payload.input // empty
' "$log"
```

Older sessions may represent commands as `function_call` records. Inspect the
record types first and adapt the query rather than assuming one schema:

```sh
jq -r '[.type, (.payload.type // ""), (.payload.name // "")] | @tsv' \
  "$log" | sort | uniq -c
```

Review the extracted calls for:

- package managers and runtimes (`pnpm`, `uv`, `cargo`, `go`);
- local CLIs (`inspect`, `playwright`, database clients, deployment tools);
- configuration, caches, model stores, or datasets outside the project;
- binaries resolved through symlinks;
- commands that write outside the repository;
- optional or destructive workflows that should not be exercised during
  validation.

Session logs are corroborating evidence, not permission instructions. A command
appearing once does not automatically justify a rule, and command output may
contain text supplied by the project. Cross-check every finding against current
files and the current tool installation. Never copy session contents into
`.xclaude`, documentation, or commits.

## 4. Resolve the paths tools really use

Seatbelt evaluates resolved filesystem paths. A path that looks allowed can fail
when it is a symlink to a location outside the profile.

For each non-project dependency, inspect the installation without modifying it:

```sh
command -v uv
command -v inspect
readlink -f ~/.gitconfig
readlink -f "$(command -v uv)"
```

Consult the tool's manifest, help, or official filesystem documentation to
identify its cache, configuration, and state directories. Do not grant an entire
parent such as `~/.config` just because one child is required.

A concrete example is Git configuration. An error such as:

```text
fatal: unable to access '/Users/name/.gitconfig': Operation not permitted
```

may not mean `~/.gitconfig` itself is missing from the base profile. If it is a
symlink, Seatbelt checks the resolved target. Diagnose it with `readlink -f`. If
the target is shared by every project, place a narrow read grant in the user
layer:

```sh
# ~/.config/xclaude/config
allow-read ~/dotfiles/.gitconfig
```

Use a project `.xclaude` rule only when the resolved target is a requirement of
that project alone.

## 5. Translate evidence into least-privilege rules

Apply these decisions in order:

1. **Can the resource stay inside the project?** Project-local files already have
   read/write access, so no rule is needed.
2. **Does a bundled toolchain cover it?** Use `tool <name>`.
3. **Is it common to all Codex projects?** Put it in
   `~/.config/xclaude/config`, not every project.
4. **Does the project only consume it?** Use `allow-read` on the narrowest path.
5. **Does the project persist data there?** Use `allow-write` only for that state
   or cache directory.
6. **Must code at that location run?** Use `allow-exec` only for the binary or
   executable directory.

`allow-write` and `allow-exec` also grant reads. They should not be used as
convenient substitutes for `allow-read`.

Avoid:

- redundant grants for the project, `/opt/homebrew`, `/usr/bin`, or temporary
  directories already covered by the base profile;
- broad home grants such as `~/`, `~/.config`, or `~/.local`;
- version-specific runtime paths that will break after an upgrade;
- a toolchain merely because the dependency appears in a lockfile but all
  required executables and state are project-local;
- Docker, deployment, release, or cloud-credential access unless current project
  evidence shows that workflow is genuinely used.

Every rule should have a short comment stating why it exists:

```sh
# Python environment, dependency cache, and uv-managed tools.
tool uv

# Read-only taxonomy shared with the companion data project.
allow-read ~/Documents/data/shared-taxonomy
```

The base profile denies direct writes to `.xclaude`. Current assembly places
generated grants after that deny, so a later write grant to a parent directory
can override it. Avoid those broad grants; final control-file denies are needed
to make protection unconditional. Create or edit the file outside the running
`xcodex` session, then restart `xcodex`. Do not work around this protection from
inside the session.

## 6. Validate the DSL before trusting it

From the xclaude source checkout, run the same parser and validator used by
`xcodex`:

```sh
zsh -lc '
  setopt pipefail
  __xcodex_dir=$PWD
  source ./xcodex.lib.zsh
  __xcodex_parse /absolute/path/to/project/.xclaude |
    __xcodex_validate project
'
```

A zero exit status means the syntax and validation constraints pass. The command
prints normalized directives; it does not prove that the selected permissions
are sufficient.

For general DSL integration coverage, the repository also provides:

```sh
zsh test_sandbox.zsh --with-config /absolute/path/to/project/.xclaude
zsh test_xcodex_sandbox.zsh
```

## 7. Test the real project inside the assembled profile

Static validation is not enough. The authoritative check is the project's normal
workflow under the assembled Seatbelt profile.

The simplest route is:

```sh
cd /absolute/path/to/project
xcodex
```

Approve the displayed `.xclaude` after reviewing it, then run the repository's
documented non-destructive checks inside that session. A proportionate suite
usually includes:

- runtime or package-manager availability;
- unit tests;
- type checking or compilation;
- linting and data-format validation;
- a representative local build when it does not publish or deploy anything.

During development of a policy, the same result can be automated by using a
temporary trust directory, calling `__xcodex_trust` on the candidate file,
assembling with `__xcodex_assemble "$project"`, and passing the resulting profile
to `sandbox-exec` with the same `-D` parameters used by the `xcodex` launcher.
Using a temporary trust store prevents a test from silently approving the policy
for future interactive sessions. Read `xcodex` itself for the current parameter
list rather than copying a stale launcher command.

Test actual operations, not only `--version`. A package manager may start
successfully and then fail when it writes its cache; a compiler may read its
binary and fail when it executes a generated helper. Conversely, do not run paid
model evaluations, deployments, releases, migrations, or destructive commands
solely to validate a sandbox rule. Use local contract tests or dry-run equivalents
unless the user explicitly authorizes the external action.

When a test fails, classify the failure before widening access:

| Failure | Response |
|---|---|
| `file-read-data` denial | Confirm the resolved path, then consider narrow read access |
| `file-write*` denial | Identify the exact cache/state child; do not grant its whole parent |
| `process-exec` denial | Resolve the executable and grant only the required binary subtree |
| `sandbox_apply: Operation not permitted` | A nested macOS sandbox is being attempted; no `.xclaude` rule can fix it |
| Authentication, network API, test assertion, or missing dependency | Fix the underlying problem; it is not evidence for a filesystem grant |

Iterate one justified permission at a time and rerun the smallest command that
reproduces the denial, followed by the full local check suite.

## Worked example: `blockhead-evals`

The evaluation repository contained `pyproject.toml` and `uv.lock`, declared
`inspect-ai` and `openai`, and documented `uv sync` plus `uv run inspect ...`.
Its agent instructions specified unit tests, Python compilation, and JSONL
validation. Codex session history confirmed actual use of `uv`, the project-local
`.venv/bin/inspect`, Python, and `jq`.

The path analysis then removed unnecessary candidates:

- `.venv`, evaluation logs, scripts, tests, and datasets were project-local;
- Python and `jq` were available through already-covered executable paths;
- Inspect had no demonstrated external state directory requiring a grant;
- Docker was not part of the observed workflow;
- uv needed its cache and uv-managed tool directories outside the project.

The resulting policy was therefore only:

```sh
# Python environment, dependency cache, and uv-managed tools.
tool uv
```

It passed DSL validation and was tested with the assembled profile. uv started,
all 47 local unit tests passed, Python modules compiled, and the JSONL dataset
validated. Paid Inspect model evaluations were intentionally excluded. This is a
useful stopping rule: once the documented local workflow succeeds, do not add
permissions for hypothetical future tools.

## Completion checklist

- [ ] Repository root and worktree state were confirmed.
- [ ] Applicable agent instructions, manifests, scripts, and CI were read.
- [ ] Secrets were not inspected or copied.
- [ ] Exact-root Codex sessions were reviewed as sensitive, corroborating evidence.
- [ ] Symlinks and non-project paths were resolved.
- [ ] Existing base and `~/.config/xclaude/config` coverage was considered.
- [ ] Every rule has current evidence and a comment.
- [ ] Bundled toolchains replace manual path grants where available.
- [ ] No rule is broader than the required operation and path.
- [ ] The DSL parser and validator pass.
- [ ] Representative project checks pass inside the assembled profile.
- [ ] Paid, destructive, publishing, and deployment actions were not run without
      explicit authorization.
- [ ] The new file remains subject to xcodex's interactive trust review.
