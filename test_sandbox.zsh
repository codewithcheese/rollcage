#!/bin/zsh
# rollcage sandbox integration tests
# Runs on macOS only — tests that sandbox-exec with the assembled
# profile actually blocks/allows the right filesystem operations.
#
# Usage:
#   zsh test_sandbox.zsh                          # base + all toolchains
#   zsh test_sandbox.zsh --toolchain node         # base + one toolchain
#   zsh test_sandbox.zsh --toolchain node,uv      # base + specific toolchains
#   zsh test_sandbox.zsh --with-config path/.rollcage  # base + custom config
#
# Requires: macOS with sandbox-exec, shasum

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
__rollcage_dir="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/rollcage.lib.zsh"
__rollcage_init claude "$SCRIPT_DIR"

# ── Pre-flight checks ────────────────────────────────────────
if [[ "$(uname)" != "Darwin" ]]; then
  echo "SKIP: sandbox tests require macOS" >&2
  exit 0
fi

if ! command -v sandbox-exec &>/dev/null; then
  echo "SKIP: sandbox-exec not found" >&2
  exit 0
fi

# ── Test framework ────────────────────────────────────────────
__test_pass=0
__test_fail=0
__test_skip=0
__test_name=""

t() { __test_name="$1"; }

expect_success() {
  local desc="$1"; shift
  local __stderr_file="${TMPDIR_RESOLVED}/rollcage-claude-test-stderr-$$.txt"
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
    # Show recent sandbox denials from system log (filter to Sandbox kernel messages only)
    echo "  sandbox denials:" >&2
    /usr/bin/log show --last 5s \
      --predicate 'eventMessage CONTAINS "Sandbox" AND eventMessage CONTAINS "deny"' \
      --style compact 2>/dev/null \
      | grep "Sandbox:" \
      | grep -v "mobileassetd\|suggestd\|biomesyncd\|runningboardd\|dasd\|online-auth" \
      | tail -10 \
      | sed 's/^/    /' >&2
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

# ── Setup ─────────────────────────────────────────────────────
# Resolve symlinks — Seatbelt uses real paths (/var -> /private/var)
PROJECT_DIR="$(readlink -f "$(mktemp -d)")"
TMPDIR_RESOLVED="$(readlink -f "${TMPDIR:-/private/tmp}")"
CACHE_DIR="${TMPDIR_RESOLVED%/T*}/C"
VOLATILE_DIR="${TMPDIR_RESOLVED%/T*}/X"
ROLLCAGE_DIR="$(readlink -f "${SCRIPT_DIR}")"
HOME_DIR="${HOME}"

# Bypass trust gate — tests manage their own configs
__rollcage_trust_dir="$(mktemp -d)"
__rollcage_trusted_file="${__rollcage_trust_dir}/trusted"
__rollcage_trusted_copies="${__rollcage_trust_dir}/trusted.d"

# Create test fixtures in the project dir
echo "hello" > "${PROJECT_DIR}/testfile.txt"
mkdir -p "${PROJECT_DIR}/subdir"
echo "nested" > "${PROJECT_DIR}/subdir/nested.txt"

# Create sensitive directory fixtures so tests don't skip on CI.
# These are real directories with real files — the sandbox must
# block access to them even though they exist.
__fixtures_created=()
__ensure_fixture() {
  local dir="$1" file="$2"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir"
    __fixtures_created+=("$dir")
  fi
  if [[ -n "$file" && ! -f "${dir}/${file}" ]]; then
    echo "rollcage-claude-test-fixture" > "${dir}/${file}"
    __fixtures_created+=("${dir}/${file}")
  fi
}

__ensure_fixture "${HOME}/.ssh" "known_hosts"
__ensure_fixture "${HOME}/.aws" "credentials"
__ensure_fixture "${HOME}/.gnupg" ""
__ensure_fixture "${HOME}/.docker" "config.json"
__ensure_fixture "${HOME}/.claude" ""
# git excludesFile (granted) plus a sibling probe (must stay blocked — proves
# the grant is literal, not a subpath over ~/.config/git).
__ensure_fixture "${HOME}/.config/git" "ignore"
__ensure_fixture "${HOME}/.config/git" "rollcage-claude-blocked-probe"
mkdir -p "${HOME}/Desktop" "${HOME}/Documents" "${HOME}/Downloads" 2>/dev/null || true
[[ -f "${HOME}/.zsh_history" ]] || { echo "fixture" > "${HOME}/.zsh_history"; __fixtures_created+=("${HOME}/.zsh_history"); }

cleanup() {
  rm -rf "$PROJECT_DIR" "$__rollcage_trust_dir"
  rm -f "${PROFILE_PATH:-}"
  # Remove fixtures we created (reverse order to remove files before dirs)
  local f
  for f in "${(Oa)__fixtures_created[@]}"; do
    if [[ -d "$f" ]]; then
      rmdir "$f" 2>/dev/null || true
    else
      rm -f "$f" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT

# ── Parse arguments ───────────────────────────────────────────
__toolchain_filter=""
__run_toolchains=true
if [[ "${1:-}" = "--with-config" && -n "${2:-}" ]]; then
  cp "$2" "${PROJECT_DIR}/.rollcage"
  __rollcage_trust "${PROJECT_DIR}/.rollcage"
elif [[ "${1:-}" = "--toolchain" ]]; then
  if [[ -n "${2:-}" ]]; then
    __toolchain_filter="${2}"
  else
    __run_toolchains=false
  fi
fi

PROFILE="$(__rollcage_assemble "$PROJECT_DIR")"
PROFILE_PATH="${TMPDIR_RESOLVED}/rollcage-claude-test-$$.sb"
printf '%s\n' "$PROFILE" > "$PROFILE_PATH"

# Helper: run a command inside the sandbox
sandboxed() {
  # Ensure CWD is readable by the sandbox — tools call getcwd() on startup
  cd "$PROJECT_DIR"
  sandbox-exec \
    -D "PROJECT_DIR=${PROJECT_DIR}" \
    -D "TMPDIR=${TMPDIR_RESOLVED}" \
    -D "CACHE_DIR=${CACHE_DIR}" \
    -D "VOLATILE_DIR=${VOLATILE_DIR}" \
    -D "HOME=${HOME_DIR}" \
    -D "ROLLCAGE_DIR=${ROLLCAGE_DIR}" \
    -f "$PROFILE_PATH" \
    -- "$@"
}

echo "=== Profile ==="
echo "  base-claude.sb + project config assembled to: ${PROFILE_PATH}"
echo "  project dir: ${PROJECT_DIR}"
echo ""

# ── Tests: base profile (reads) ──────────────────────────────
echo "=== Read access ==="

t "read project file"
expect_success "allowed" sandboxed cat "${PROJECT_DIR}/testfile.txt"

t "read nested project file"
expect_success "allowed" sandboxed cat "${PROJECT_DIR}/subdir/nested.txt"

t "read system binary"
expect_success "allowed" sandboxed cat /bin/echo

t "read /etc/hosts"
expect_success "allowed" sandboxed cat /private/etc/hosts

t "read ~/.claude directory"
expect_success "allowed" sandboxed ls "${HOME}/.claude"

t "read ~/.config/git/ignore (git excludesFile)"
expect_success "allowed" sandboxed cat "${HOME}/.config/git/ignore"

# ── Tests: base profile (blocked reads) ──────────────────────
echo "=== Blocked reads ==="

t "read ~/.ssh"
expect_fail "blocked" sandboxed cat "${HOME}/.ssh/known_hosts"

t "read ~/.aws"
expect_fail "blocked" sandboxed cat "${HOME}/.aws/credentials"

t "read ~/Desktop"
expect_fail "blocked" sandboxed ls "${HOME}/Desktop"

t "read ~/Documents"
expect_fail "blocked" sandboxed ls "${HOME}/Documents"

t "read ~/Downloads"
expect_fail "blocked" sandboxed ls "${HOME}/Downloads"

t "read ~/.gnupg"
expect_fail "blocked" sandboxed ls "${HOME}/.gnupg"

t "read ~/.docker"
expect_fail "blocked" sandboxed cat "${HOME}/.docker/config.json"

t "read ~/.zsh_history"
expect_fail "blocked" sandboxed cat "${HOME}/.zsh_history"

t "read ~/.config/git sibling (literal grant, not subpath)"
expect_fail "blocked" sandboxed cat "${HOME}/.config/git/rollcage-claude-blocked-probe"

# ── Tests: base profile (writes) ─────────────────────────────
echo "=== Write access ==="

t "write to project dir"
expect_success "allowed" sandboxed touch "${PROJECT_DIR}/newfile.txt"

t "write to project subdir"
expect_success "allowed" sandboxed touch "${PROJECT_DIR}/subdir/newfile.txt"

t "write to tmp"
expect_success "allowed" sandboxed touch "/private/tmp/rollcage-claude-test-$$"
rm -f "/private/tmp/rollcage-claude-test-$$"

# ── Tests: base profile (blocked writes) ─────────────────────
echo "=== Blocked writes ==="

t "write to home root"
expect_fail "blocked" sandboxed touch "${HOME}/rollcage-claude-test-should-not-exist"

t "write to ~/Desktop"
expect_fail "blocked" sandboxed touch "${HOME}/Desktop/rollcage-claude-test"

t "write to ~/.ssh"
expect_fail "blocked" sandboxed touch "${HOME}/.ssh/rollcage-claude-test"

t "write to .rollcage config"
# .rollcage must exist first — deny applies to the literal path
echo "tool node" > "${PROJECT_DIR}/.rollcage"
expect_fail "blocked" sandboxed /bin/sh -c "echo 'allow-read ~/.ssh' >> '${PROJECT_DIR}/.rollcage'"

t "create .rollcage where none exists"
rm -f "${PROJECT_DIR}/.rollcage"
expect_fail "blocked" sandboxed /bin/sh -c "echo 'allow-read ~/.ssh' > '${PROJECT_DIR}/.rollcage'"

t "write to .env"
echo "OLD_SECRET=xxx" > "${PROJECT_DIR}/.env"
expect_fail "blocked" sandboxed /bin/sh -c "echo 'NEW_KEY=stolen' >> '${PROJECT_DIR}/.env'"

t "write to .env.local"
echo "LOCAL_SECRET=xxx" > "${PROJECT_DIR}/.env.local"
expect_fail "blocked" sandboxed /bin/sh -c "echo 'KEY=val' >> '${PROJECT_DIR}/.env.local'"

t "write to .env.production"
echo "PROD_SECRET=xxx" > "${PROJECT_DIR}/.env.production"
expect_fail "blocked" sandboxed /bin/sh -c "echo 'KEY=val' >> '${PROJECT_DIR}/.env.production'"

t "write to .git/hooks"
mkdir -p "${PROJECT_DIR}/.git/hooks"
expect_fail "blocked" sandboxed /bin/sh -c "echo '#!/bin/sh' > '${PROJECT_DIR}/.git/hooks/pre-commit'"

t "regular project file still writable"
expect_success "allowed" sandboxed touch "${PROJECT_DIR}/normal-file.txt"

# ── Tests: base profile (exec) ───────────────────────────────
echo "=== Exec access ==="

t "exec /bin/echo"
expect_success "allowed" sandboxed /bin/echo "hello"

t "exec /usr/bin/env"
expect_success "allowed" sandboxed /usr/bin/env echo "hello"

t "exec project script"
printf '#!/bin/sh\necho ok\n' > "${PROJECT_DIR}/test.sh"
chmod +x "${PROJECT_DIR}/test.sh"
expect_success "allowed" sandboxed "${PROJECT_DIR}/test.sh"

# ── Tests: escape vectors ────────────────────────────────────
echo "=== Escape vectors ==="

t "symlink escape: link to ~/.ssh from project dir"
ln -sf "${HOME}/.ssh" "${PROJECT_DIR}/ssh-link"
expect_fail "blocked" sandboxed cat "${PROJECT_DIR}/ssh-link/known_hosts"

t "path traversal via .."
expect_fail "blocked" sandboxed cat "${PROJECT_DIR}/../../.ssh/known_hosts"

t "/tmp script writing then executing"
# Write a script to /tmp, then try to exec it — should fail
# because /tmp is not in the exec allowlist
sandboxed /bin/sh -c "echo '#!/bin/sh\ncat ~/.ssh/id_rsa' > /private/tmp/rollcage-claude-escape-$$.sh && chmod +x /private/tmp/rollcage-claude-escape-$$.sh" 2>/dev/null || true
if [[ -f "/private/tmp/rollcage-claude-escape-$$.sh" ]]; then
  expect_fail "blocked" sandboxed /private/tmp/rollcage-claude-escape-$$.sh
  rm -f "/private/tmp/rollcage-claude-escape-$$.sh"
else
  # The write itself might have succeeded but the inner cat would fail
  # Either way, the escape vector is blocked
  __test_pass=$((__test_pass + 1))
fi

t "child process inherits sandbox"
expect_fail "blocked" sandboxed /bin/sh -c "cat ${HOME}/.ssh/known_hosts"

# ── Cleanup test artifacts ────────────────────────────────────
rm -f "${PROJECT_DIR}/ssh-link" "${PROJECT_DIR}/newfile.txt" "${PROJECT_DIR}/subdir/newfile.txt" "${PROJECT_DIR}/test.sh" "${PROJECT_DIR}/normal-file.txt"
rm -f "${PROJECT_DIR}/.env" "${PROJECT_DIR}/.env.local" "${PROJECT_DIR}/.env.production"
rm -rf "${PROJECT_DIR}/.git"
rm -f "${PROJECT_DIR}/.rollcage"

# ── Toolchain tests ──────────────────────────────────────────
# Each toolchain has a .test.zsh file alongside its .sb fragment.
# Source the shared helpers, then run each test file.

if $__run_toolchains; then
  source "${SCRIPT_DIR}/toolchains/test_helpers.zsh"

  for tc_test_file in "${SCRIPT_DIR}"/toolchains/*.test.zsh; do
    tc_name="$(basename "$tc_test_file" .test.zsh)"
    # Filter to specific toolchains if --toolchain <names> was given
    if [[ -n "$__toolchain_filter" ]]; then
      if [[ ",$__toolchain_filter," != *",$tc_name,"* ]]; then
        continue
      fi
    fi
    echo "=== Toolchain: ${tc_name} ==="
    source "$tc_test_file"
  done
fi

# ── Results ───────────────────────────────────────────────────
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
