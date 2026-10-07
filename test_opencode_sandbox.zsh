#!/bin/zsh
# rollcage opencode sandbox integration tests
# Runs on macOS only. Exercises OpenCode config/auth/state/cache access,
# auto-approval, downloaded-tool execution, credential isolation, and installed
# CLI startup.
#
# Usage: zsh test_opencode_sandbox.zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
__rollcage_dir="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/rollcage.lib.zsh"
__rollcage_init opencode "$SCRIPT_DIR"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "SKIP: sandbox tests require macOS" >&2
  exit 0
fi

if ! command -v sandbox-exec &>/dev/null; then
  echo "SKIP: sandbox-exec not found" >&2
  exit 0
fi

__test_pass=0
__test_fail=0
__test_skip=0
__test_name=""

t() { __test_name="$1"; }

expect_success() {
  local desc="$1"; shift
  local __stderr_file="${TMPDIR_RESOLVED}/rollcage-opencode-test-stderr-$$.txt"
  if "$@" >/dev/null 2>"$__stderr_file"; then
    __test_pass=$((__test_pass + 1))
  else
    __test_fail=$((__test_fail + 1))
    echo "FAIL: ${__test_name} — ${desc}" >&2
    echo "  command: $*" >&2
    if [[ -s "$__stderr_file" ]]; then
      echo "  stderr:" >&2
      sed 's/^/    /' < "$__stderr_file" | tail -20 >&2
    fi
  fi
  rm -f "$__stderr_file"
}

expect_fail() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    __test_fail=$((__test_fail + 1))
    echo "FAIL: ${__test_name} — ${desc}" >&2
    echo "  expected sandbox to block: $*" >&2
  else
    __test_pass=$((__test_pass + 1))
  fi
}

skip() {
  __test_skip=$((__test_skip + 1))
  echo "SKIP: ${__test_name} — $1" >&2
}

PROJECT_DIR="$(readlink -f "$(mktemp -d)")"
TMPDIR_RESOLVED="$(readlink -f "${TMPDIR:-/private/tmp}")"
CACHE_DIR="${TMPDIR_RESOLVED%/T*}/C"
VOLATILE_DIR="${TMPDIR_RESOLVED%/T*}/X"
ROLLCAGE_DIR="$(readlink -f "${SCRIPT_DIR}")"
HOME_DIR="${HOME}"

__rollcage_trust_dir="$(mktemp -d)"
__rollcage_trusted_file="${__rollcage_trust_dir}/trusted"
__rollcage_trusted_copies="${__rollcage_trust_dir}/trusted.d"

__fixtures_created=()
__ensure_dir() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    /bin/mkdir -p "$dir"
    __fixtures_created+=("$dir")
  fi
}

__ensure_file() {
  local path="$1" content="${2:-rollcage-opencode-test-fixture}"
  __ensure_dir "${path:h}"
  if [[ ! -f "$path" ]]; then
    /bin/echo "$content" > "$path"
    __fixtures_created+=("$path")
  fi
}

__ensure_executable() {
  local path="$1"
  __ensure_file "$path" $'#!/bin/sh\necho rollcage-opencode-test\n'
  /bin/chmod +x "$path"
}

__fake_opencode="${HOME}/.opencode/bin/rollcage-opencode-test-$$"
__wrapper_fake_dir="${PROJECT_DIR}/wrapper-bin"
__wrapper_fake="${__wrapper_fake_dir}/opencode"
__cache_tool="${HOME}/.cache/opencode/bin/rollcage-opencode-tool-test-$$"
__data_executable="${HOME}/.local/share/opencode/rollcage-opencode-data-test-$$"
__ensure_executable "$__fake_opencode"
__ensure_file "$__wrapper_fake" $'#!/bin/sh\ntest "$1" = "--auto"\n'
/bin/chmod +x "$__wrapper_fake"
__ensure_executable "$__cache_tool"
__ensure_executable "$__data_executable"
__ensure_file "${HOME}/.config/opencode/rollcage-opencode-test-readable-$$"
__ensure_file "${HOME}/.local/share/opencode/rollcage-opencode-test-readable-$$"
__ensure_file "${HOME}/.local/state/opencode/rollcage-opencode-test-readable-$$"
__ensure_file "${HOME}/.cache/opencode/rollcage-opencode-test-readable-$$"
__ensure_file "${HOME}/.config/rollcage/trust/opencode/rollcage-opencode-test-readable-$$"
__ensure_file "${HOME}/.claude/skills/rollcage-opencode-test-$$/SKILL.md"
__ensure_file "${HOME}/.agents/skills/rollcage-opencode-test-$$/SKILL.md"
__ensure_file "${HOME}/.ssh/known_hosts"

/bin/echo "hello" > "${PROJECT_DIR}/testfile.txt"

cleanup() {
  rm -rf "$PROJECT_DIR" "$__rollcage_trust_dir"
  rm -f "${PROFILE_PATH:-}"
  local f i
  for (( i=${#__fixtures_created[@]}; i >= 1; i-- )); do
    f="${__fixtures_created[$i]}"
    if [[ -d "$f" ]]; then
      rmdir "$f" 2>/dev/null || true
    else
      rm -f "$f" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT

PROFILE="$(__rollcage_assemble "$PROJECT_DIR")"
PROFILE_PATH="${TMPDIR_RESOLVED}/rollcage-opencode-test-$$.sb"
printf '%s\n' "$PROFILE" > "$PROFILE_PATH"

sandboxed_with_bin() {
  local allowed_bin="$1"; shift
  cd "$PROJECT_DIR"
  ROLLCAGE_ACTIVE=1 ROLLCAGE_CLI=opencode OPENCODE_DISABLE_AUTOUPDATE=1 sandbox-exec \
    -D "PROJECT_DIR=${PROJECT_DIR}" \
    -D "TMPDIR=${TMPDIR_RESOLVED}" \
    -D "CACHE_DIR=${CACHE_DIR}" \
    -D "VOLATILE_DIR=${VOLATILE_DIR}" \
    -D "HOME=${HOME_DIR}" \
    -D "ROLLCAGE_DIR=${ROLLCAGE_DIR}" \
    -D "OPENCODE_BIN=${allowed_bin}" \
    -f "$PROFILE_PATH" \
    -- "$@"
}

sandboxed() {
  sandboxed_with_bin "$__fake_opencode" "$@"
}

echo "=== rollcage opencode profile ==="
echo "  base-common.sb + base-opencode.sb assembled to: ${PROFILE_PATH}"
echo "  project dir: ${PROJECT_DIR}"
echo ""

echo "=== Read and write access ==="

t "read project file"
expect_success "allowed" sandboxed cat "${PROJECT_DIR}/testfile.txt"

t "read OpenCode global config"
expect_success "allowed" sandboxed cat "${HOME}/.config/opencode/rollcage-opencode-test-readable-$$"

t "read OpenCode auth/session data"
expect_success "allowed" sandboxed cat "${HOME}/.local/share/opencode/rollcage-opencode-test-readable-$$"

t "read OpenCode UI state"
expect_success "allowed" sandboxed cat "${HOME}/.local/state/opencode/rollcage-opencode-test-readable-$$"

t "read OpenCode cache"
expect_success "allowed" sandboxed cat "${HOME}/.cache/opencode/rollcage-opencode-test-readable-$$"

t "read cross-agent skills"
expect_success "Claude skill allowed" sandboxed cat "${HOME}/.claude/skills/rollcage-opencode-test-$$/SKILL.md"
expect_success "shared skill allowed" sandboxed cat "${HOME}/.agents/skills/rollcage-opencode-test-$$/SKILL.md"

t "read ~/.ssh remains blocked"
expect_fail "blocked" sandboxed cat "${HOME}/.ssh/known_hosts"

t "write OpenCode config"
expect_success "allowed" sandboxed touch "${HOME}/.config/opencode/rollcage-opencode-test-write-$$"
rm -f "${HOME}/.config/opencode/rollcage-opencode-test-write-$$"

t "write OpenCode data"
expect_success "allowed" sandboxed touch "${HOME}/.local/share/opencode/rollcage-opencode-test-write-$$"
rm -f "${HOME}/.local/share/opencode/rollcage-opencode-test-write-$$"

t "write OpenCode state"
expect_success "allowed" sandboxed touch "${HOME}/.local/state/opencode/rollcage-opencode-test-write-$$"
rm -f "${HOME}/.local/state/opencode/rollcage-opencode-test-write-$$"

t "write OpenCode cache"
expect_success "allowed" sandboxed touch "${HOME}/.cache/opencode/rollcage-opencode-test-write-$$"
rm -f "${HOME}/.cache/opencode/rollcage-opencode-test-write-$$"

t "write rollcage opencode trust store remains blocked"
expect_fail "blocked" sandboxed touch "${HOME}/.config/rollcage/trust/opencode/rollcage-opencode-test-write-$$"

t "write home root remains blocked"
expect_fail "blocked" sandboxed touch "${HOME}/rollcage-opencode-test-should-not-exist"

t "write to existing .rollcage config is blocked"
/bin/echo "tool node" > "${PROJECT_DIR}/.rollcage"
expect_fail "blocked" sandboxed /bin/sh -c "echo 'allow-read ~/.ssh' >> '${PROJECT_DIR}/.rollcage'"

t "create .rollcage config is blocked"
rm -f "${PROJECT_DIR}/.rollcage"
expect_fail "blocked" sandboxed /bin/sh -c "echo 'allow-read ~/.ssh' > '${PROJECT_DIR}/.rollcage'"

echo "=== Exec access ==="

t "exec exact resolved OpenCode binary"
expect_success "allowed" sandboxed "$__fake_opencode"

t "exec downloaded OpenCode cache tool"
expect_success "allowed" sandboxed "$__cache_tool"

t "exec from OpenCode data remains blocked"
expect_fail "blocked" sandboxed "$__data_executable"

t "tmp script execution remains blocked"
sandboxed /bin/sh -c "printf '#!/bin/sh\necho bad\n' > /private/tmp/rollcage-opencode-exec-$$ && chmod +x /private/tmp/rollcage-opencode-exec-$$" 2>/dev/null || true
if [[ -f "/private/tmp/rollcage-opencode-exec-$$" ]]; then
  expect_fail "blocked" sandboxed "/private/tmp/rollcage-opencode-exec-$$"
  rm -f "/private/tmp/rollcage-opencode-exec-$$"
else
  __test_pass=$((__test_pass + 1))
fi

t "ROLLCAGE_CLI is visible"
expect_success "visible" sandboxed /bin/sh -c 'test "$ROLLCAGE_CLI" = opencode'

t "shared ROLLCAGE_ACTIVE is visible"
expect_success "visible" sandboxed /bin/sh -c 'test "$ROLLCAGE_ACTIVE" = 1'

t "OpenCode auto-update is disabled inside rollcage opencode"
expect_success "disabled" sandboxed /bin/sh -c 'test "$OPENCODE_DISABLE_AUTOUPDATE" = 1'

t "rollcage opencode auto-approves OpenCode permissions"
expect_success "--auto passed first" /usr/bin/env PATH="${__wrapper_fake_dir}:${PATH}" \
  "${SCRIPT_DIR}/rollcage" opencode

t "installed OpenCode can initialize isolated XDG state"
if opencode_bin="$(command -v opencode 2>/dev/null)"; then
  opencode_bin="$(readlink -f "$opencode_bin")"
  __runtime_root="${PROJECT_DIR}/opencode-runtime"
  expect_success "runs" sandboxed_with_bin "$opencode_bin" /usr/bin/env \
    XDG_CONFIG_HOME="${__runtime_root}/config" \
    XDG_DATA_HOME="${__runtime_root}/data" \
    XDG_STATE_HOME="${__runtime_root}/state" \
    XDG_CACHE_HOME="${__runtime_root}/cache" \
    "$opencode_bin" debug paths
else
  skip "opencode not installed"
fi

echo "=== Credential isolation ==="

t "Codex OAuth store remains blocked"
if [[ -f "${HOME}/.codex/auth.json" ]]; then
  expect_fail "blocked" sandboxed cat "${HOME}/.codex/auth.json"
else
  skip "no Codex auth store present"
fi

__keychain_file=""
for __kc in "${HOME}/Library/Keychains/"*(.N); do
  __keychain_file="$__kc"; break
done

t "OpenCode file auth does not require macOS keychain reads"
if [[ -n "$__keychain_file" ]]; then
  expect_fail "blocked" sandboxed cat "$__keychain_file"
else
  skip "no keychain database present"
fi

echo ""
echo "=== Results ==="
total=$((__test_pass + __test_fail))
echo "${__test_pass}/${total} passed, ${__test_skip} skipped"
if [[ $__test_fail -gt 0 ]]; then
  echo "${__test_fail} FAILED"
  exit 1
else
  echo "All tests passed."
  exit 0
fi
