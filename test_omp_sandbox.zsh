#!/bin/zsh
# rollcage omp sandbox integration tests
# Runs on macOS only. Exercises OMP auto-approval, state/auth, eval/plugin
# execution, debugger and fallback-browser paths, and isolation; if omp exists,
# verifies a stateful command can start.
#
# Usage: zsh test_omp_sandbox.zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
__rollcage_dir="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/rollcage.lib.zsh"
__rollcage_init omp "$SCRIPT_DIR"

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
  local __stderr_file="${TMPDIR_RESOLVED}/rollcage-omp-test-stderr-$$.txt"
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
__python_env_root_existed=0
[[ -d "${HOME}/.omp/python-env" ]] && __python_env_root_existed=1
__ensure_dir() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    /bin/mkdir -p "$dir"
    __fixtures_created+=("$dir")
  fi
}

__ensure_file() {
  local path="$1" content="${2:-rollcage-omp-test-fixture}"
  __ensure_dir "${path:h}"
  if [[ ! -f "$path" ]]; then
    /bin/echo "$content" > "$path"
    __fixtures_created+=("$path")
  fi
}

__ensure_executable() {
  local path="$1"
  __ensure_file "$path" $'#!/bin/sh\necho rollcage-omp-test\n'
  /bin/chmod +x "$path"
}

__test_agent_dir="${HOME}/.omp/rollcage-omp-test-agent-$$"
__wrapper_fake_dir="${PROJECT_DIR}/wrapper-bin"
__wrapper_fake="${__wrapper_fake_dir}/omp"
__ensure_dir "$__test_agent_dir"
__ensure_dir "${HOME}/.omp/agent/extensions"
__ensure_dir "${HOME}/.omp/agent/sessions"
__ensure_dir "${HOME}/.omp/plugins"
__ensure_dir "${HOME}/.omp/python-env/bin"
__ensure_dir "${HOME}/.omp/puppeteer/chrome-test"
__ensure_file "${HOME}/.omp/agent/agent.db.rollcage-omp-test-$$"
__ensure_file "${HOME}/.config/rollcage/trust/omp/rollcage-omp-test-readable-$$"
__ensure_file "${HOME}/.ssh/known_hosts"
__ensure_executable "${HOME}/.omp/agent/extensions/rollcage-omp-ext-test-$$"
__ensure_executable "${HOME}/.omp/plugins/rollcage-omp-plugin-test-$$"
__ensure_executable "${HOME}/.omp/python-env/bin/rollcage-omp-python-test-$$"
__ensure_executable "${HOME}/.omp/puppeteer/chrome-test/rollcage-omp-chrome-test-$$"
__ensure_executable "${HOME}/.omp/agent/sessions/rollcage-omp-session-test-$$"
__ensure_file "$__wrapper_fake" $'#!/bin/sh\ntest "$1" = "--auto-approve"\n'
/bin/chmod +x "$__wrapper_fake"

/bin/echo "hello" > "${PROJECT_DIR}/testfile.txt"

cleanup() {
  rm -rf "$PROJECT_DIR" "$__rollcage_trust_dir" "$__test_agent_dir"
  rm -f "${PROFILE_PATH:-}" "${CHROME_PROFILE_PATH:-}"
  local f i
  # Fixtures are recorded parent-before-child; remove them in reverse creation
  # order so test-created directories are empty before rmdir reaches them.
  for (( i=${#__fixtures_created[@]}; i >= 1; i-- )); do
    f="${__fixtures_created[$i]}"
    if [[ -d "$f" ]]; then
      rmdir "$f" 2>/dev/null || true
    else
      rm -f "$f" 2>/dev/null || true
    fi
  done
  # These roots may have been created by mkdir -p for a unique child fixture.
  # rmdir is intentionally non-recursive and succeeds only when they are empty.
  if [[ $__python_env_root_existed -eq 0 ]]; then
    rmdir "${HOME}/.omp/python-env" 2>/dev/null || true
  fi
}
trap cleanup EXIT

PROFILE="$(__rollcage_assemble "$PROJECT_DIR")"
PROFILE_PATH="${TMPDIR_RESOLVED}/rollcage-omp-test-$$.sb"
printf '%s\n' "$PROFILE" > "$PROFILE_PATH"

sandboxed() {
  cd "$PROJECT_DIR"
  ROLLCAGE_ACTIVE=1 ROLLCAGE_CLI=omp sandbox-exec \
    -D "PROJECT_DIR=${PROJECT_DIR}" \
    -D "TMPDIR=${TMPDIR_RESOLVED}" \
    -D "CACHE_DIR=${CACHE_DIR}" \
    -D "VOLATILE_DIR=${VOLATILE_DIR}" \
    -D "HOME=${HOME_DIR}" \
    -D "ROLLCAGE_DIR=${ROLLCAGE_DIR}" \
    -D "OMP_CONFIG_ROOT=${HOME_DIR}/.omp" \
    -D "OMP_AGENT_DIR=${HOME_DIR}/.omp/agent" \
    -D "OMP_DATA_ROOT=${HOME_DIR}/.omp" \
    -D "OMP_STATE_ROOT=${HOME_DIR}/.omp" \
    -D "OMP_CACHE_ROOT=${HOME_DIR}/.omp" \
    -D "OMP_XDG_DATA_ROOT=${HOME_DIR}/.omp" \
    -D "OMP_XDG_STATE_ROOT=${HOME_DIR}/.omp" \
    -D "OMP_XDG_CACHE_ROOT=${HOME_DIR}/.omp" \
    -f "$PROFILE_PATH" \
    -- "$@"
}

echo "=== rollcage omp profile ==="
echo "  base-common.sb + base-omp.sb assembled to: ${PROFILE_PATH}"
echo "  project dir: ${PROJECT_DIR}"
echo ""

echo "=== Read and write access ==="

t "read project file"
expect_success "allowed" sandboxed cat "${PROJECT_DIR}/testfile.txt"

t "read OMP auth store"
expect_success "allowed" sandboxed cat "${HOME}/.omp/agent/agent.db.rollcage-omp-test-$$"

t "read rollcage omp user config"
expect_success "allowed" sandboxed cat "${HOME}/.config/rollcage/trust/omp/rollcage-omp-test-readable-$$"

t "read ~/.ssh remains blocked"
expect_fail "blocked" sandboxed cat "${HOME}/.ssh/known_hosts"

t "write project file"
expect_success "allowed" sandboxed touch "${PROJECT_DIR}/newfile.txt"

t "write OMP auth and session state"
expect_success "allowed" sandboxed touch "${__test_agent_dir}/agent.db"

t "write home root remains blocked"
expect_fail "blocked" sandboxed touch "${HOME}/rollcage-omp-test-should-not-exist"

t "write rollcage omp trust store remains blocked"
expect_fail "blocked" sandboxed touch "${HOME}/.config/rollcage/trust/omp/rollcage-omp-test-write-$$"

t "write to existing .rollcage config is blocked"
/bin/echo "tool node" > "${PROJECT_DIR}/.rollcage"
expect_fail "blocked" sandboxed /bin/sh -c "echo 'allow-read ~/.ssh' >> '${PROJECT_DIR}/.rollcage'"

t "create .rollcage config is blocked"
rm -f "${PROJECT_DIR}/.rollcage"
expect_fail "blocked" sandboxed /bin/sh -c "echo 'allow-read ~/.ssh' > '${PROJECT_DIR}/.rollcage'"

echo "=== OMP code, REPL, and debugger execution ==="

t "exec OMP extension helper"
expect_success "allowed" sandboxed "${HOME}/.omp/agent/extensions/rollcage-omp-ext-test-$$"

t "exec OMP plugin helper"
expect_success "allowed" sandboxed "${HOME}/.omp/plugins/rollcage-omp-plugin-test-$$"

t "exec OMP managed Python environment helper"
expect_success "allowed" sandboxed "${HOME}/.omp/python-env/bin/rollcage-omp-python-test-$$"

t "exec OMP-downloaded Puppeteer browser helper"
expect_success "allowed" sandboxed "${HOME}/.omp/puppeteer/chrome-test/rollcage-omp-chrome-test-$$"

t "exec under OMP sessions is blocked"
expect_fail "blocked" sandboxed "${HOME}/.omp/agent/sessions/rollcage-omp-session-test-$$"

t "system Google Chrome stays blocked without tool chrome"
__system_chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [[ -f "$__system_chrome" ]]; then
  expect_fail "blocked" sandboxed /usr/bin/head -c 1 "$__system_chrome"

  CHROME_PROFILE_PATH="${TMPDIR_RESOLVED}/rollcage-omp-chrome-test-$$.sb"
  {
    /bin/cat "$PROFILE_PATH"
    /bin/cat "${SCRIPT_DIR}/toolchains/chrome.sb"
  } > "$CHROME_PROFILE_PATH"

  chrome_sandboxed() {
    cd "$PROJECT_DIR"
    ROLLCAGE_ACTIVE=1 ROLLCAGE_CLI=omp sandbox-exec \
      -D "PROJECT_DIR=${PROJECT_DIR}" \
      -D "TMPDIR=${TMPDIR_RESOLVED}" \
      -D "CACHE_DIR=${CACHE_DIR}" \
      -D "VOLATILE_DIR=${VOLATILE_DIR}" \
      -D "HOME=${HOME_DIR}" \
      -D "ROLLCAGE_DIR=${ROLLCAGE_DIR}" \
      -D "OMP_CONFIG_ROOT=${HOME_DIR}/.omp" \
      -D "OMP_AGENT_DIR=${HOME_DIR}/.omp/agent" \
      -D "OMP_DATA_ROOT=${HOME_DIR}/.omp" \
      -D "OMP_STATE_ROOT=${HOME_DIR}/.omp" \
      -D "OMP_CACHE_ROOT=${HOME_DIR}/.omp" \
      -D "OMP_XDG_DATA_ROOT=${HOME_DIR}/.omp" \
      -D "OMP_XDG_STATE_ROOT=${HOME_DIR}/.omp" \
      -D "OMP_XDG_CACHE_ROOT=${HOME_DIR}/.omp" \
      -f "$CHROME_PROFILE_PATH" \
      -- "$@"
  }

  t "tool chrome exposes system Google Chrome"
  expect_success "allowed" chrome_sandboxed /usr/bin/head -c 1 "$__system_chrome"
else
  skip "Google Chrome is not installed"
fi

t "python.org interpreter can support the Python REPL"
__python_framework="/Library/Frameworks/Python.framework/Versions/3.12/bin/python3"
if [[ -x "$__python_framework" ]]; then
  expect_success "runs" sandboxed "$__python_framework" -c 'print("ok")'
else
  skip "python.org framework interpreter not installed"
fi

t "Apple LLDB can support OMP DAP debugging"
__lldb_bin=""
if [[ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/lldb" ]]; then
  __lldb_bin="/Applications/Xcode.app/Contents/Developer/usr/bin/lldb"
elif [[ -x "/Library/Developer/CommandLineTools/usr/bin/lldb" ]]; then
  __lldb_bin="/Library/Developer/CommandLineTools/usr/bin/lldb"
fi
if [[ -n "$__lldb_bin" ]]; then
  expect_success "runs" sandboxed "$__lldb_bin" --version
else
  skip "lldb not installed"
fi

t "tmp script execution remains blocked"
sandboxed /bin/sh -c "printf '#!/bin/sh\necho bad\n' > /private/tmp/rollcage-omp-exec-$$ && chmod +x /private/tmp/rollcage-omp-exec-$$" 2>/dev/null || true
if [[ -f "/private/tmp/rollcage-omp-exec-$$" ]]; then
  expect_fail "blocked" sandboxed "/private/tmp/rollcage-omp-exec-$$"
  rm -f "/private/tmp/rollcage-omp-exec-$$"
else
  __test_pass=$((__test_pass + 1))
fi

t "ROLLCAGE_CLI is visible"
expect_success "visible" sandboxed /bin/sh -c 'test "$ROLLCAGE_CLI" = omp'

t "shared ROLLCAGE_ACTIVE is visible"
expect_success "visible" sandboxed /bin/sh -c 'test "$ROLLCAGE_ACTIVE" = 1'

t "rollcage omp auto-approves OMP tool calls"
expect_success "--auto-approve passed first" /usr/bin/env PATH="${__wrapper_fake_dir}:${PATH}" \
  "${SCRIPT_DIR}/rollcage" omp

t "installed OMP can initialize its SQLite-backed state"
if omp_bin="$(command -v omp 2>/dev/null)"; then
  omp_bin="$(readlink -f "$omp_bin")"
  expect_success "runs" sandboxed env PI_CODING_AGENT_DIR="$__test_agent_dir" "$omp_bin" config path
else
  skip "omp not installed"
fi

echo "=== Credential isolation ==="

__keychain_file=""
for __kc in "${HOME}/Library/Keychains/"*(.N); do
  __keychain_file="$__kc"; break
done

t "OMP OAuth does not require macOS keychain reads"
if [[ -n "$__keychain_file" ]]; then
  expect_fail "blocked" sandboxed cat "$__keychain_file"
else
  skip "no keychain database present"
fi

t "Codex OAuth store remains blocked"
if [[ -f "${HOME}/.codex/auth.json" ]]; then
  expect_fail "blocked" sandboxed cat "${HOME}/.codex/auth.json"
else
  skip "no Codex auth store present"
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
