#!/bin/zsh
# test_trust_gate.zsh — integration tests for __rollcage_check_trust
#
# Exercises the end-to-end wiring: summary + colorize filters + bold prompt +
# stdin approval + trust ledger updates. Runs on any platform with zsh
# (no sandbox-exec required).
#
# Usage: zsh test_trust_gate.zsh

SCRIPT_DIR="${0:A:h}"
source "${SCRIPT_DIR}/rollcage.lib.zsh"

# ── Framework ────────────────────────────────────────────────
__pass=0
__fail=0
__name=""

t() { __name="$1"; }

assert_eq() {
  local expected="$1" actual="$2"
  if [[ "$expected" == "$actual" ]]; then
    __pass=$((__pass + 1))
  else
    __fail=$((__fail + 1))
    echo "FAIL: ${__name}" >&2
    echo "  expected: ${(V)expected}" >&2
    echo "  actual:   ${(V)actual}" >&2
  fi
}

assert_contains() {
  local needle="$1" haystack="$2"
  if [[ "$haystack" == *"$needle"* ]]; then
    __pass=$((__pass + 1))
  else
    __fail=$((__fail + 1))
    echo "FAIL: ${__name}" >&2
    echo "  expected to contain: ${(V)needle}" >&2
  fi
}

assert_not_contains() {
  local needle="$1" haystack="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    __pass=$((__pass + 1))
  else
    __fail=$((__fail + 1))
    echo "FAIL: ${__name}" >&2
    echo "  expected NOT to contain: ${(V)needle}" >&2
  fi
}

# ── Isolated trust env ──────────────────────────────────────
TMP="$(mktemp -d)"
trap "rm -rf '$TMP'" EXIT

__rollcage_name="rollcage"
__rollcage_dir="${SCRIPT_DIR}"
__rollcage_base_profile="${SCRIPT_DIR}/base-claude.sb"
__rollcage_base_profiles=("${SCRIPT_DIR}/base-common.sb" "${SCRIPT_DIR}/base-claude.sb")
__rollcage_config_name=".rollcage"
__rollcage_user_config="${TMP}/no-user-config"
__rollcage_trust_dir="${TMP}/trust"
__rollcage_trusted_file="${__rollcage_trust_dir}/trusted"
__rollcage_trusted_copies="${__rollcage_trust_dir}/trusted.d"
__rollcage_packs_dir="${TMP}/packs"
mkdir -p "$__rollcage_packs_dir"

# Run check_trust directly (not via command substitution, which would swallow
# __rc in a subshell). Sets __rc and __out in the caller's scope.
run_trust() {
  local file="$1" reply="$2" color="${3:-always}"
  ROLLCAGE_COLOR="$color" __rollcage_check_trust "$file" \
    2>"${TMP}/stderr" >/dev/null <<< "$reply"
  __rc=$?
  __out="$(< "${TMP}/stderr")"
}

reset_ledger() { rm -rf "${__rollcage_trust_dir}"; }

# ── Tests ───────────────────────────────────────────────────
echo "=== Trust gate integration ==="

t "non-existent file: returns 0, no output"
nonexistent="${TMP}/nothing-here"
out=$(__rollcage_check_trust "$nonexistent" 2>&1 >/dev/null </dev/null)
rc=$?
assert_eq "0" "$rc"
assert_eq "" "$out"

t "already-trusted file: short-circuits, no output"
cfg="${TMP}/already.rollcage"
echo "tool node" > "$cfg"
__rollcage_trust "$cfg"
out=$(ROLLCAGE_COLOR=always __rollcage_check_trust "$cfg" 2>&1 >/dev/null </dev/null)
rc=$?
assert_eq "0" "$rc"
assert_eq "" "$out"
reset_ledger

t "new config + 'y': summary line shown before body"
cfg="${TMP}/new.rollcage"
cat > "$cfg" <<EOF
# demo
tool node
allow-write ~/data
allow-exec ~/.local/bin/foo
EOF
run_trust "$cfg" "y"
assert_contains "new config: ${cfg}" "$__out"
# Summary should name each verb present
assert_contains "exec"  "$__out"
assert_contains "write" "$__out"
assert_contains "tool"  "$__out"
# The log line "new config:" must come before the verb-body rendering of 'tool'
log_pos=$(echo "$__out"  | awk 'BEGIN{p=-1} /new config:/{p=NR; exit} END{print p}')
tool_pos=$(echo "$__out" | awk 'BEGIN{p=-1} /\x1b\[36m\x1b\[1mtool\x1b\[0m node/{p=NR; exit} END{print p}')
if (( log_pos > 0 && tool_pos > log_pos )); then
  __pass=$((__pass + 1))
else
  __fail=$((__fail + 1))
  echo "FAIL: ${__name} — log_pos=$log_pos tool_pos=$tool_pos" >&2
fi

t "new config + 'y': body renders with severity-colored verbs"
assert_contains $'\e[35m\e[1mallow-exec\e[0m'  "$__out"  # magenta
assert_contains $'\e[33m\e[1mallow-write\e[0m' "$__out"  # yellow
assert_contains $'\e[36m\e[1mtool\e[0m'        "$__out"  # cyan

t "new config + 'y': approval prompt is bold"
assert_contains $'\e[1mrollcage: allow this config? [y/N]\e[0m' "$__out"

t "new config + 'y': ledger gets entry, exit 0"
assert_eq "0" "$__rc"
# Non-git path: ledger entry uses 'path:<resolved>' scope form.
__cfg_resolved="$(readlink -f "$cfg")"
if [[ -f "$__rollcage_trusted_file" ]] && grep -qF "# path:${__cfg_resolved}" "$__rollcage_trusted_file"; then
  __pass=$((__pass + 1))
else
  __fail=$((__fail + 1))
  echo "FAIL: ${__name} — ledger not updated" >&2
fi
reset_ledger

t "new config + 'n': exit 1, ledger untouched, 'denied' logged"
cfg="${TMP}/rejected.rollcage"
echo "tool node" > "$cfg"
run_trust "$cfg" "n"
assert_eq "1" "$__rc"
assert_contains "denied" "$__out"
if [[ ! -f "$__rollcage_trusted_file" ]]; then
  __pass=$((__pass + 1))
elif ! grep -q "# ${cfg}$" "$__rollcage_trusted_file"; then
  __pass=$((__pass + 1))
else
  __fail=$((__fail + 1))
  echo "FAIL: ${__name} — ledger unexpectedly updated" >&2
fi
reset_ledger

t "new config + empty reply: default is deny (exit 1)"
cfg="${TMP}/empty-reply.rollcage"
echo "tool node" > "$cfg"
run_trust "$cfg" ""
assert_eq "1" "$__rc"
assert_contains "denied" "$__out"
reset_ledger

t "changed config + 'y': diff is rendered with file headers"
cfg="${TMP}/changing.rollcage"
echo "tool node" > "$cfg"
__rollcage_trust "$cfg"
cat > "$cfg" <<EOF
tool node
allow-exec ~/.local/bin/foo
EOF
run_trust "$cfg" "y"
assert_contains "config changed: ${cfg}" "$__out"
assert_contains "--- trusted" "$__out"
assert_contains "+++ current" "$__out"

t "changed config + 'y': summary reflects +1 exec delta"
assert_contains "+1" "$__out"
assert_contains "exec" "$__out"
# No additions should be reported for verbs that didn't change
assert_not_contains "+1 write" "$__out"
assert_not_contains "+1 read"  "$__out"

t "changed config + 'y': added exec line has magenta verb overlay on green polarity"
assert_contains $'\e[32m+\e[0m\e[35m\e[1mallow-exec\e[0m\e[32m ~/.local/bin/foo\e[0m' "$__out"
assert_eq "0" "$__rc"
reset_ledger

t "ROLLCAGE_COLOR=never: plain body, no ANSI"
cfg="${TMP}/plain.rollcage"
echo "tool node" > "$cfg"
run_trust "$cfg" "y" "never"
assert_not_contains $'\e[' "$__out"
assert_contains "tool node" "$__out"
assert_contains "allow this config? [y/N]" "$__out"
reset_ledger

# ── Pack trust gate ─────────────────────────────────────────
echo ""
echo "=== Pack trust gate ==="

# Helper: run check_pack_trust, capture stderr + rc (same shape as run_trust).
run_pack_trust() {
  local pack_file="$1" project_config="$2" reply="$3" color="${4:-always}"
  ROLLCAGE_COLOR="$color" __rollcage_check_pack_trust "$pack_file" "$project_config" \
    2>"${TMP}/stderr" >/dev/null <<< "$reply"
  __rc=$?
  __out="$(< "${TMP}/stderr")"
}

# Helper: run check_pack_trusts (orchestrator over a whole project config).
run_pack_trusts() {
  local project_config="$1" replies="$2" color="${3:-always}"
  ROLLCAGE_COLOR="$color" __rollcage_check_pack_trusts "$project_config" \
    2>"${TMP}/stderr" >/dev/null <<< "$replies"
  __rc=$?
  __out="$(< "${TMP}/stderr")"
}

reset_ledger  # start fresh

t "new pack for project + 'y': prompt shown, ledger gets compound entry"
pack="${__rollcage_packs_dir}/dev"
proj="${TMP}/projA/.rollcage"
mkdir -p "${TMP}/projA"
cat > "$pack" <<EOF
# shared dev pack
allow-read ~/.config/shared
allow-write ~/data/dev
EOF
echo "pack dev" > "$proj"
run_pack_trust "$pack" "$proj" "y"
assert_eq "0" "$__rc"
assert_contains "new pack: dev" "$__out"
assert_contains "allow pack dev for this project? [y/N]" "$__out"
# Ledger entry uses path:<resolved> scope form for non-git project
__proj_resolved="$(readlink -f "$proj")"
if grep -qF "# path:${__proj_resolved} pack dev" "$__rollcage_trusted_file"; then
  __pass=$((__pass + 1))
else
  __fail=$((__fail + 1))
  echo "FAIL: ${__name} — ledger missing scope-format pack entry for dev" >&2
fi

t "trusted pack (same project, same hash): reminder only, no prompt"
run_pack_trust "$pack" "$proj" ""
assert_eq "0" "$__rc"
assert_contains "using pack dev (trusted)" "$__out"
# Prompt string must NOT appear
assert_not_contains "allow pack dev for this project?" "$__out"

t "same pack, different project: prompts again (no cross-project trust)"
projB="${TMP}/projB/.rollcage"
mkdir -p "${TMP}/projB"
echo "pack dev" > "$projB"
run_pack_trust "$pack" "$projB" "y"
assert_eq "0" "$__rc"
assert_contains "new pack: dev" "$__out"
assert_contains "allow pack dev for this project?" "$__out"
# Both projects' entries coexist in the ledger (each at its own path: scope)
__proj_resolved="$(readlink -f "$proj")"
__projB_resolved="$(readlink -f "$projB")"
if grep -qF "# path:${__proj_resolved} pack dev" "$__rollcage_trusted_file" \
  && grep -qF "# path:${__projB_resolved} pack dev" "$__rollcage_trusted_file"; then
  __pass=$((__pass + 1))
else
  __fail=$((__fail + 1))
  echo "FAIL: ${__name} — ledger should have both project entries" >&2
fi

t "changed pack (same project): diff prompt, summary shows delta"
cat > "$pack" <<EOF
# shared dev pack
allow-read ~/.config/shared
allow-write ~/data/dev
allow-exec ~/.local/bin/dev-tool
EOF
run_pack_trust "$pack" "$proj" "y"
assert_eq "0" "$__rc"
assert_contains "pack changed: dev" "$__out"
assert_contains "--- trusted" "$__out"
assert_contains "+++ current" "$__out"
assert_contains "+1" "$__out"
assert_contains "exec" "$__out"
# Ledger entry updated to new hash, only one entry per (proj_scope, pack name)
__proj_resolved="$(readlink -f "$proj")"
count=$(grep -cF "# path:${__proj_resolved} pack dev" "$__rollcage_trusted_file")
assert_eq "1" "$count"

t "pack denial: rc=1, ledger entry not added"
pack2="${__rollcage_packs_dir}/rejected"
echo "allow-read ~/.config/x" > "$pack2"
projC="${TMP}/projC/.rollcage"
mkdir -p "${TMP}/projC"
echo "pack rejected" > "$projC"
run_pack_trust "$pack2" "$projC" "n"
assert_eq "1" "$__rc"
assert_contains "pack rejected denied" "$__out"
if ! grep -q "# ${projC} pack rejected\$" "$__rollcage_trusted_file" 2>/dev/null; then
  __pass=$((__pass + 1))
else
  __fail=$((__fail + 1))
  echo "FAIL: ${__name} — denied pack should not be in ledger" >&2
fi

reset_ledger

t "check_pack_trusts: all new packs — prompts each, all approved → rc=0"
pack_a="${__rollcage_packs_dir}/alpha"
pack_b="${__rollcage_packs_dir}/beta"
echo "allow-read ~/.config/alpha" > "$pack_a"
echo "allow-read ~/.config/beta" > "$pack_b"
proj2="${TMP}/proj2/.rollcage"
mkdir -p "${TMP}/proj2"
cat > "$proj2" <<EOF
pack alpha
pack beta
allow-read ~/.config/direct
EOF
run_pack_trusts "$proj2" $'y\ny'
assert_eq "0" "$__rc"
assert_contains "new pack: alpha" "$__out"
assert_contains "new pack: beta" "$__out"

t "check_pack_trusts: denying one pack aborts, remaining not prompted"
reset_ledger
run_pack_trusts "$proj2" $'n'
assert_eq "1" "$__rc"
assert_contains "new pack: alpha" "$__out"
# beta should NOT have been prompted — ordering stops on first denial
assert_not_contains "new pack: beta" "$__out"

t "check_pack_trusts: no pack directives → rc=0, no output"
proj3="${TMP}/proj3/.rollcage"
mkdir -p "${TMP}/proj3"
cat > "$proj3" <<EOF
tool node
allow-read ~/.config/nopack
EOF
run_pack_trusts "$proj3" ""
assert_eq "0" "$__rc"
assert_eq "" "$__out"

# ── Reject-on-denial behavior (assembler) ───────────────────
echo ""
echo "=== Reject-on-denial ==="

reset_ledger

t "__rollcage_assemble: denied project config → rc=1 (no fallback)"
proj_dir="${TMP}/reject-proj"
mkdir -p "$proj_dir"
echo "tool node" > "${proj_dir}/.rollcage"
__rollcage_assemble "$proj_dir" >/dev/null 2>"${TMP}/stderr" <<< "n"
rc=$?
assert_eq "1" "$rc"

t "__rollcage_assemble: denied project no longer writes a base-only profile"
# Regression test: old behavior returned 0 with base-only SBPL when the
# user rejected the project config. New behavior must return 1.
out="$(__rollcage_assemble "$proj_dir" 2>/dev/null <<< "n" || echo __FAILED__)"
assert_contains "__FAILED__" "$out"

t "__rollcage_assemble: approved project + denied pack → rc=1"
reset_ledger
pack3="${__rollcage_packs_dir}/gamma"
echo "allow-read ~/.config/gamma" > "$pack3"
proj_dir2="${TMP}/reject-pack-proj"
mkdir -p "$proj_dir2"
echo "pack gamma" > "${proj_dir2}/.rollcage"
# Reply "y" to approve project, "n" to deny pack
__rollcage_assemble "$proj_dir2" >/dev/null 2>"${TMP}/stderr" <<< $'y\nn'
rc=$?
assert_eq "1" "$rc"

t "__rollcage_assemble: approved project + approved pack → rc=0, pack body emitted"
reset_ledger
out="$(__rollcage_assemble "$proj_dir2" 2>/dev/null <<< $'y\ny')"
rc=$?
assert_eq "0" "$rc"
assert_contains "pack: gamma" "$out"
assert_contains "/.config/gamma" "$out"

# ── Ledger collision regression ─────────────────────────────
echo ""
echo "=== Ledger collision ==="

reset_ledger

t "pack + project with identical content: project still prompts"
# Regression: old grep patterns matched ^<hash> anywhere, so an approved
# pack entry with the same content-hash as an unrelated project config
# would silently treat the project as trusted. After the rewrite, trust
# lookups are line-exact and must not collide.
identical='allow-read ~/.config/shared'
pack_id="${__rollcage_packs_dir}/ident"
proj_id_dir="${TMP}/ident-proj"
mkdir -p "$proj_id_dir"
printf '%s\n' "$identical" > "$pack_id"
printf '%s\n' "$identical" > "${proj_id_dir}/.rollcage"
# Pre-trust the pack for a completely different project
other_proj="${TMP}/other-proj/.rollcage"
mkdir -p "${TMP}/other-proj"
printf '%s\n' "$identical" > "$other_proj"
__rollcage_trust_pack_for_project "$pack_id" "$other_proj"
# Now check: is_trusted for a project whose hash matches the pack's hash
# must return false (we never trusted THAT project config).
if __rollcage_is_trusted "${proj_id_dir}/.rollcage"; then
  __fail=$((__fail + 1))
  echo "FAIL: ${__name} — is_trusted matched a pack entry by hash alone" >&2
else
  __pass=$((__pass + 1))
fi
reset_ledger

t "project path with regex metacharacters: no over-match"
# Paths routinely contain '.', which in regex matches any char. If the
# old grep pattern were still in play, 'proj.x/.rollcage' would match
# 'projXx/.rollcage' in is_trusted. Line-exact comparison must not.
reset_ledger
proj_dot_dir="${TMP}/proj.x"
proj_alt_dir="${TMP}/projXx"
mkdir -p "$proj_dot_dir" "$proj_alt_dir"
printf 'tool node\n' > "${proj_dot_dir}/.rollcage"
printf 'tool node\n' > "${proj_alt_dir}/.rollcage"  # same content → same hash
__rollcage_trust "${proj_dot_dir}/.rollcage"
if __rollcage_is_trusted "${proj_alt_dir}/.rollcage"; then
  __fail=$((__fail + 1))
  echo "FAIL: ${__name} — '.' in path over-matched as regex" >&2
else
  __pass=$((__pass + 1))
fi
reset_ledger

t "pack ledger entry does not satisfy project is_trusted (compound format)"
# Ensure the compound pack ledger entry ('<hash> # <proj> pack <name>')
# is not picked up by is_trusted when looking for a plain project entry.
reset_ledger
pack_plain="${__rollcage_packs_dir}/plain"
printf 'allow-read ~/.config/x\n' > "$pack_plain"
proj_plain="${TMP}/plain-proj/.rollcage"
mkdir -p "${TMP}/plain-proj"
printf 'pack plain\n' > "$proj_plain"
__rollcage_trust_pack_for_project "$pack_plain" "$proj_plain"
# The ledger now has ONE entry: '<hash> # /.../plain-proj/.rollcage pack plain'.
# is_trusted for the project file must not fire on it.
if __rollcage_is_trusted "$proj_plain"; then
  __fail=$((__fail + 1))
  echo "FAIL: ${__name} — project is_trusted matched compound pack entry" >&2
else
  __pass=$((__pass + 1))
fi
reset_ledger

t "trust_pack: removing old pack entry does not touch project entries"
# Regression: rewriting the ledger to update a pack entry must preserve
# all project config entries, even when they share a prefix (same proj path).
reset_ledger
pack_upd="${__rollcage_packs_dir}/upd"
printf 'allow-read ~/.config/v1\n' > "$pack_upd"
proj_upd="${TMP}/upd-proj/.rollcage"
mkdir -p "${TMP}/upd-proj"
printf 'pack upd\n' > "$proj_upd"
__rollcage_trust "$proj_upd"
__rollcage_trust_pack_for_project "$pack_upd" "$proj_upd"
# Mutate the pack and re-trust
printf 'allow-read ~/.config/v2\n' > "$pack_upd"
__rollcage_trust_pack_for_project "$pack_upd" "$proj_upd"
# Project must still be trusted after pack re-trust
if __rollcage_is_trusted "$proj_upd"; then
  __pass=$((__pass + 1))
else
  __fail=$((__fail + 1))
  echo "FAIL: ${__name} — pack re-trust wiped the project entry" >&2
fi
# And pack must be trusted at its new hash
if __rollcage_is_pack_trusted_for_project "$pack_upd" "$proj_upd"; then
  __pass=$((__pass + 1))
else
  __fail=$((__fail + 1))
  echo "FAIL: ${__name} — pack not trusted at new hash" >&2
fi
reset_ledger

# ── Trust scope (repo-aware identity) ──────────────────────
echo ""
echo "=== Trust scope ==="

reset_ledger

# Helper: build a fixture git repo with one initial commit + a worktree.
# Sets fixture_repo, fixture_worktree, fixture_repo_id (the absolute,
# symlink-resolved git-common-dir that should be shared by both).
make_repo_fixture() {
  local base="$1"
  rm -rf "$base"
  mkdir -p "$base"
  git -C "$base" init -q -b main
  git -C "$base" config user.email "t@example.com"
  git -C "$base" config user.name "T"
  echo "tool node" > "${base}/.rollcage"
  git -C "$base" add .rollcage
  git -C "$base" -c commit.gpgsign=false commit -q -m init
  fixture_repo="$base"
  fixture_worktree="${base}/.claude/worktrees/feature"
  git -C "$base" worktree add -q "$fixture_worktree" -b feature 2>/dev/null
  fixture_repo_id="$(readlink -f "${base}/.git")"
}

t "trust_scope: file in regular git repo returns repo:<common-dir>"
make_repo_fixture "${TMP}/repo-scope-a"
scope=$(__rollcage_trust_scope "${fixture_repo}/.rollcage")
assert_eq "repo:${fixture_repo_id}" "$scope"

t "trust_scope: worktree resolves to main repo's common-dir"
scope=$(__rollcage_trust_scope "${fixture_worktree}/.rollcage")
assert_eq "repo:${fixture_repo_id}" "$scope"

t "trust_scope: file outside any git repo returns path:<resolved>"
non_git_dir="${TMP}/scope-non-git"
mkdir -p "$non_git_dir"
non_git_file="${non_git_dir}/.rollcage"
echo "tool node" > "$non_git_file"
expected_resolved="$(readlink -f "$non_git_file")"
scope=$(__rollcage_trust_scope "$non_git_file")
assert_eq "path:${expected_resolved}" "$scope"

t "trust_scope: nonexistent file in git repo still resolves via parent dir"
# The .rollcage file may not exist yet (first run after creating the project).
# Scope must still resolve based on the containing dir's git context.
ghost_file="${fixture_repo}/.rollcage.does-not-exist"
scope=$(__rollcage_trust_scope "$ghost_file")
assert_eq "repo:${fixture_repo_id}" "$scope"

# ── Scope-aware ledger (worktree trust sharing) ────────────
echo ""
echo "=== Scope-aware ledger ==="

reset_ledger

t "trust in main repo covers worktree at same commit (identical content)"
make_repo_fixture "${TMP}/share-trust"
__rollcage_trust "${fixture_repo}/.rollcage"
# Worktree's .rollcage was created by `git worktree add` checking out the same
# branch that committed .rollcage. Content is byte-identical.
if __rollcage_is_trusted "${fixture_worktree}/.rollcage"; then
  __pass=$((__pass + 1))
else
  __fail=$((__fail + 1))
  echo "FAIL: ${__name} — worktree should inherit trust from main repo" >&2
fi
reset_ledger

t "diverged worktree (different content) is NOT trusted"
make_repo_fixture "${TMP}/diverged-trust"
__rollcage_trust "${fixture_repo}/.rollcage"
# Modify the worktree's .rollcage to diverge
echo "tool python" > "${fixture_worktree}/.rollcage"
if __rollcage_is_trusted "${fixture_worktree}/.rollcage"; then
  __fail=$((__fail + 1))
  echo "FAIL: ${__name} — diverged content must re-prompt" >&2
else
  __pass=$((__pass + 1))
fi
reset_ledger

t "separate clone with same content is NOT trusted (different repo_id)"
make_repo_fixture "${TMP}/orig-clone"
__rollcage_trust "${fixture_repo}/.rollcage"
# Independent repo with the exact same .rollcage content
mkdir -p "${TMP}/separate-clone"
git -C "${TMP}/separate-clone" init -q -b main
echo "tool node" > "${TMP}/separate-clone/.rollcage"
if __rollcage_is_trusted "${TMP}/separate-clone/.rollcage"; then
  __fail=$((__fail + 1))
  echo "FAIL: ${__name} — separate repo must re-prompt even at same content" >&2
else
  __pass=$((__pass + 1))
fi
reset_ledger

t "trust() writes new repo-scoped format for in-repo file"
make_repo_fixture "${TMP}/new-format"
__rollcage_trust "${fixture_repo}/.rollcage"
hash="$(__rollcage_file_hash "${fixture_repo}/.rollcage")"
expected_line="${hash} # repo:${fixture_repo_id} @ ${fixture_repo}/.rollcage"
if grep -qxF "$expected_line" "$__rollcage_trusted_file"; then
  __pass=$((__pass + 1))
else
  __fail=$((__fail + 1))
  echo "FAIL: ${__name} — expected line not found:" >&2
  echo "  expected: $expected_line" >&2
  echo "  ledger contents:" >&2
  cat "$__rollcage_trusted_file" >&2
fi
reset_ledger

t "trust() writes path-scoped format for non-git file"
non_git_dir="${TMP}/non-git-trust"
mkdir -p "$non_git_dir"
non_git_file="${non_git_dir}/.rollcage"
echo "tool node" > "$non_git_file"
__rollcage_trust "$non_git_file"
hash="$(__rollcage_file_hash "$non_git_file")"
resolved_path="$(readlink -f "$non_git_file")"
# path: form does not need the redundant @ tail
expected_line="${hash} # path:${resolved_path}"
if grep -qxF "$expected_line" "$__rollcage_trusted_file"; then
  __pass=$((__pass + 1))
else
  __fail=$((__fail + 1))
  echo "FAIL: ${__name} — expected line not found:" >&2
  echo "  expected: $expected_line" >&2
  cat "$__rollcage_trusted_file" >&2
fi
reset_ledger

t "was_previously_trusted: matches scope (any hash) for in-repo file"
make_repo_fixture "${TMP}/was-prev"
__rollcage_trust "${fixture_repo}/.rollcage"
# Change file content → different hash → no longer is_trusted, but
# was_previously_trusted should still return 0.
echo "tool python" > "${fixture_repo}/.rollcage"
if __rollcage_was_previously_trusted "${fixture_repo}/.rollcage"; then
  __pass=$((__pass + 1))
else
  __fail=$((__fail + 1))
  echo "FAIL: ${__name} — was_previously_trusted should match scope" >&2
fi
reset_ledger

t "was_previously_trusted: matches via worktree scope when only main was trusted"
make_repo_fixture "${TMP}/was-prev-wt"
__rollcage_trust "${fixture_repo}/.rollcage"
# Diverge worktree
echo "tool python" > "${fixture_worktree}/.rollcage"
if __rollcage_was_previously_trusted "${fixture_worktree}/.rollcage"; then
  __pass=$((__pass + 1))
else
  __fail=$((__fail + 1))
  echo "FAIL: ${__name} — worktree should match prev-trusted via shared scope" >&2
fi
reset_ledger

# ── Scope-aware pack ledger ────────────────────────────────
echo ""
echo "=== Scope-aware pack ledger ==="

reset_ledger

t "pack trusted in main covers worktree at same project content"
make_repo_fixture "${TMP}/pack-share"
pack_file="${__rollcage_packs_dir}/devp"
echo "allow-read ~/.config/devp" > "$pack_file"
__rollcage_trust_pack_for_project "$pack_file" "${fixture_repo}/.rollcage"
# Worktree's project config has same content — same scope → same pack trust
if __rollcage_is_pack_trusted_for_project "$pack_file" "${fixture_worktree}/.rollcage"; then
  __pass=$((__pass + 1))
else
  __fail=$((__fail + 1))
  echo "FAIL: ${__name} — worktree pack trust should follow project scope" >&2
fi
reset_ledger

t "trust_pack writes new repo-scoped pack format"
make_repo_fixture "${TMP}/pack-format"
pack_file="${__rollcage_packs_dir}/alphap"
echo "allow-read ~/.config/alphap" > "$pack_file"
__rollcage_trust_pack_for_project "$pack_file" "${fixture_repo}/.rollcage"
hash="$(__rollcage_file_hash "$pack_file")"
expected_line="${hash} # repo:${fixture_repo_id} pack alphap @ ${fixture_repo}/.rollcage"
if grep -qxF "$expected_line" "$__rollcage_trusted_file"; then
  __pass=$((__pass + 1))
else
  __fail=$((__fail + 1))
  echo "FAIL: ${__name} — expected line not found:" >&2
  echo "  expected: $expected_line" >&2
  cat "$__rollcage_trusted_file" >&2
fi
reset_ledger

t "trust_pack writes path-scoped format for non-git project"
non_git_proj_dir="${TMP}/non-git-pack-proj"
mkdir -p "$non_git_proj_dir"
non_git_proj="${non_git_proj_dir}/.rollcage"
echo "pack betap" > "$non_git_proj"
pack_file="${__rollcage_packs_dir}/betap"
echo "allow-read ~/.config/betap" > "$pack_file"
__rollcage_trust_pack_for_project "$pack_file" "$non_git_proj"
hash="$(__rollcage_file_hash "$pack_file")"
resolved_proj="$(readlink -f "$non_git_proj")"
expected_line="${hash} # path:${resolved_proj} pack betap"
if grep -qxF "$expected_line" "$__rollcage_trusted_file"; then
  __pass=$((__pass + 1))
else
  __fail=$((__fail + 1))
  echo "FAIL: ${__name} — expected line not found:" >&2
  echo "  expected: $expected_line" >&2
  cat "$__rollcage_trusted_file" >&2
fi
reset_ledger

t "check_trust on worktree silently approves after trusting main"
make_repo_fixture "${TMP}/check-trust-wt"
__rollcage_trust "${fixture_repo}/.rollcage"
# An empty stdin would deny if a prompt fired — silence proves no prompt.
out="$(__rollcage_check_trust "${fixture_worktree}/.rollcage" 2>&1 </dev/null)"
rc=$?
assert_eq "0" "$rc"
assert_eq "" "$out"
reset_ledger

t "check_trust on diverged worktree shows 'config changed' diff"
make_repo_fixture "${TMP}/check-trust-diverge"
__rollcage_trust "${fixture_repo}/.rollcage"
echo "tool python" > "${fixture_worktree}/.rollcage"
# 'y' to approve the divergence
__rollcage_check_trust "${fixture_worktree}/.rollcage" 2>"${TMP}/stderr" >/dev/null <<< "y"
rc=$?
out="$(< "${TMP}/stderr")"
assert_eq "0" "$rc"
assert_contains "config changed" "$out"
assert_contains "--- trusted" "$out"
reset_ledger

t "__rollcage_assemble: worktree project shares trust with main"
make_repo_fixture "${TMP}/assemble-wt"
# Trust main first
__rollcage_assemble "$fixture_repo" >/dev/null 2>"${TMP}/stderr" <<< "y"
rc1=$?
assert_eq "0" "$rc1"
# Now assemble from the worktree — should be silent (no prompt)
out="$(__rollcage_assemble "$fixture_worktree" 2>&1 </dev/null)"
rc2=$?
assert_eq "0" "$rc2"
# Output should NOT contain a trust prompt
if [[ "$out" == *"allow this config?"* ]]; then
  __fail=$((__fail + 1))
  echo "FAIL: ${__name} — assemble re-prompted on worktree" >&2
else
  __pass=$((__pass + 1))
fi
reset_ledger

t "assemble in linked worktree adds read grant for main checkout"
make_repo_fixture "${TMP}/wt-read-grant"
# Trust main first so worktree assemble runs silently (and inherits trust).
__rollcage_trust "${fixture_repo}/.rollcage"
out="$(__rollcage_assemble "$fixture_worktree" 2>/dev/null </dev/null)"
__main_resolved="$(readlink -f "$fixture_repo")"
expected_rule="(allow file-read-data (subpath \"${__main_resolved}\"))"
assert_contains "$expected_rule" "$out"
reset_ledger

t "assemble in linked worktree adds write grant for main's .git"
make_repo_fixture "${TMP}/wt-git-write"
__rollcage_trust "${fixture_repo}/.rollcage"
out="$(__rollcage_assemble "$fixture_worktree" 2>/dev/null </dev/null)"
__main_resolved="$(readlink -f "$fixture_repo")"
expected_allow="(allow file-write* (subpath \"${__main_resolved}/.git\"))"
expected_deny_hooks="(deny file-write* (subpath \"${__main_resolved}/.git/hooks\"))"
expected_deny_config="(deny file-write* (literal \"${__main_resolved}/.git/config\"))"
assert_contains "$expected_allow" "$out"
assert_contains "$expected_deny_hooks" "$out"
assert_contains "$expected_deny_config" "$out"
reset_ledger

t "assemble in linked worktree: deny rules come AFTER allow (last-match-wins)"
make_repo_fixture "${TMP}/wt-git-order"
__rollcage_trust "${fixture_repo}/.rollcage"
out="$(__rollcage_assemble "$fixture_worktree" 2>/dev/null </dev/null)"
__main_resolved="$(readlink -f "$fixture_repo")"
allow_pos=$(echo "$out" | awk -v p="(allow file-write* (subpath \"${__main_resolved}/.git\"))" '{ if (index($0, p)) { print NR; exit } }')
deny_hooks_pos=$(echo "$out" | awk -v p="(deny file-write* (subpath \"${__main_resolved}/.git/hooks\"))" '{ if (index($0, p)) { print NR; exit } }')
deny_config_pos=$(echo "$out" | awk -v p="(deny file-write* (literal \"${__main_resolved}/.git/config\"))" '{ if (index($0, p)) { print NR; exit } }')
if [[ -n "$allow_pos" && -n "$deny_hooks_pos" && -n "$deny_config_pos" \
     && "$deny_hooks_pos" -gt "$allow_pos" \
     && "$deny_config_pos" -gt "$allow_pos" ]]; then
  __pass=$((__pass + 1))
else
  __fail=$((__fail + 1))
  echo "FAIL: ${__name} — allow=$allow_pos deny_hooks=$deny_hooks_pos deny_config=$deny_config_pos" >&2
fi
reset_ledger

t "assemble in main checkout does NOT add .git write grant"
make_repo_fixture "${TMP}/wt-no-git-main"
__rollcage_trust "${fixture_repo}/.rollcage"
out="$(__rollcage_assemble "$fixture_repo" 2>/dev/null </dev/null)"
__main_resolved="$(readlink -f "$fixture_repo")"
unwanted_rule="(allow file-write* (subpath \"${__main_resolved}/.git\"))"
if [[ "$out" == *"$unwanted_rule"* ]]; then
  __fail=$((__fail + 1))
  echo "FAIL: ${__name} — main checkout should not get worktree .git write grant" >&2
else
  __pass=$((__pass + 1))
fi
reset_ledger

t "assemble in main checkout does NOT add main-worktree read grant"
make_repo_fixture "${TMP}/wt-no-grant-main"
__rollcage_trust "${fixture_repo}/.rollcage"
out="$(__rollcage_assemble "$fixture_repo" 2>/dev/null </dev/null)"
__main_resolved="$(readlink -f "$fixture_repo")"
unwanted_rule="(allow file-read-data (subpath \"${__main_resolved}\"))"
if [[ "$out" == *"$unwanted_rule"* ]]; then
  __fail=$((__fail + 1))
  echo "FAIL: ${__name} — main checkout should not auto-grant itself" >&2
else
  __pass=$((__pass + 1))
fi
reset_ledger

t "assemble outside git repo does NOT add main-worktree read grant"
non_git_dir="${TMP}/wt-non-git"
mkdir -p "$non_git_dir"
out="$(__rollcage_assemble "$non_git_dir" 2>/dev/null </dev/null)"
if [[ "$out" == *"Linked worktree"* ]]; then
  __fail=$((__fail + 1))
  echo "FAIL: ${__name} — non-git project should not get worktree section" >&2
else
  __pass=$((__pass + 1))
fi

t "different repo same pack: prompts independently (no cross-repo trust)"
make_repo_fixture "${TMP}/pack-isolation-a"
proj_a="${fixture_repo}/.rollcage"
pack_file="${__rollcage_packs_dir}/isop"
echo "allow-read ~/.config/isop" > "$pack_file"
__rollcage_trust_pack_for_project "$pack_file" "$proj_a"
# Save first repo's id
first_repo_id="$fixture_repo_id"
# Make a totally separate repo
make_repo_fixture "${TMP}/pack-isolation-b"
proj_b="${fixture_repo}/.rollcage"
if __rollcage_is_pack_trusted_for_project "$pack_file" "$proj_b"; then
  __fail=$((__fail + 1))
  echo "FAIL: ${__name} — pack trust must not cross repos" >&2
else
  __pass=$((__pass + 1))
fi
reset_ledger

# ── Shared user config across real launcher wrappers ────────
echo "=== Shared user config ==="

__shared_config_root="${TMP}/shared-config"
__shared_config_home="${__shared_config_root}/home"
mkdir -p "${__shared_config_home}/.config/rollcage" "${__shared_config_root}/project"
# Initialize each CLI in a child with an isolated home so the test never
# reads or changes the real user's rules or trust ledger.
cat > "${__shared_config_root}/assemble.zsh" <<'EOF'
set -euo pipefail
repo="$1"
launcher="$2"
project="$3"
source "${repo}/rollcage.lib.zsh"
__rollcage_init "$launcher" "$repo"
__rollcage_assemble "$project"
EOF

assemble_shared_config() {
  /usr/bin/env HOME="$__shared_config_home" zsh -f "${__shared_config_root}/assemble.zsh" \
    "$SCRIPT_DIR" "$1" "${__shared_config_root}/project"
}

cat > "${__shared_config_home}/.config/rollcage/config" <<'EOF'
# A stowed Git config and a toolchain must work for every agent.
allow-read ~/shared-dotfiles/.gitconfig
tool gh
EOF
for launcher in claude codex pi omp opencode; do
  t "${launcher}: shared user rules and toolchains are assembled"
  out="$(assemble_shared_config "$launcher" </dev/null)"
  assert_eq "0" "$?"
  assert_contains 'User config: ~/.config/rollcage/config' "$out"
  assert_contains '(allow file-read-data (subpath (string-append (param "HOME") "/shared-dotfiles/.gitconfig")))' "$out"
  assert_contains 'toolchain: gh' "$out"
done

echo 'allow-write /System/forbidden' > "${__shared_config_home}/.config/rollcage/config"
for launcher in claude codex pi omp opencode; do
  t "${launcher}: invalid shared user rules abort assembly"
  out="$(assemble_shared_config "$launcher" 2>/dev/null </dev/null)"
  assert_eq "1" "$?"
  assert_eq "" "$out"
done

rm "${__shared_config_home}/.config/rollcage/config"
for launcher in claude codex pi omp opencode; do
  t "${launcher}: shared user config is optional"
  out="$(assemble_shared_config "$launcher" </dev/null)"
  assert_eq "0" "$?"
  assert_contains '(deny default)' "$out"
  assert_not_contains 'User config:' "$out"
done

# CLI approvals are deliberately separate even for byte-identical rules.
echo "=== CLI trust isolation ==="
cat > "${__shared_config_root}/trust.zsh" <<'EOF'
source "$1/rollcage.lib.zsh"
__rollcage_init "$2" "$1"
case "$3" in
  trust) __rollcage_trust "$4" ;;
  check) __rollcage_is_trusted "$4" ;;
  trust-pack) __rollcage_trust_pack_for_project "$5" "$4" ;;
  check-pack) __rollcage_is_pack_trusted_for_project "$5" "$4" ;;
esac
EOF
__isolated_config="${__shared_config_root}/project/.rollcage"
__isolated_pack="${__shared_config_home}/.config/rollcage/packs/dev"
mkdir -p "${__isolated_pack:h}"
printf 'pack dev\n' > "$__isolated_config"
printf 'tool node\n' > "$__isolated_pack"
cli_trust() {
  /usr/bin/env HOME="$__shared_config_home" zsh -f "${__shared_config_root}/trust.zsh" \
    "$SCRIPT_DIR" "$1" "$2" "$__isolated_config" "$__isolated_pack"
}
cli_trust claude trust
cli_trust claude trust-pack
for cli in codex pi omp opencode; do
  t "$cli: Claude approvals cannot authorize project rules or packs"
  cli_trust "$cli" check
  assert_eq 1 "$?"
  cli_trust "$cli" check-pack
  assert_eq 1 "$?"
  cli_trust "$cli" trust
  cli_trust "$cli" trust-pack
  cli_trust "$cli" check
  assert_eq 0 "$?"
  cli_trust "$cli" check-pack
  assert_eq 0 "$?"
done

echo "=== DSL tool boundary and literal path data ==="
__tool_probe_dir="${TMP}/tool-probe"
mkdir -p "$__tool_probe_dir/install/toolchains"
printf ';; fixture\n(allow default)\n' > "$__tool_probe_dir/outside.sb"
t "tool traversal cannot load an existing SBPL file outside toolchains"
out="$(
  __rollcage_dir="$__tool_probe_dir/install"
  printf '%s\n' 'tool ../../outside' | __rollcage_validate project
)"
assert_eq 1 "$?"
assert_eq "" "$out"

t "backslash paths survive parser, validator, and generator"
printf '%s\n' 'allow-write ./data\nfile' > "$__tool_probe_dir/rules"
out="$(__rollcage_parse "$__tool_probe_dir/rules" | __rollcage_validate project | __rollcage_generate)"
assert_contains '(param "PROJECT_DIR") "/data\\nfile"' "$out"

# ── Results ────────────────────────────────────────────────
echo ""
echo "=== Results ==="
total=$((__pass + __fail))
echo "${__pass}/${total} passed"
if (( __fail > 0 )); then
  exit 1
fi
