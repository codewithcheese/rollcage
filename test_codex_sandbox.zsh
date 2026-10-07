#!/bin/zsh
# rollcage codex sandbox integration tests
# Runs on macOS only. Exercises the Codex-specific base profile without
# requiring Codex to be installed; if codex exists, verifies it can start.
#
# Usage: zsh test_codex_sandbox.zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
__rollcage_dir="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/rollcage.lib.zsh"
__rollcage_init codex "$SCRIPT_DIR"
source "${SCRIPT_DIR}/adapters/codex.zsh"

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
  local __stderr_file="${TMPDIR_RESOLVED}/rollcage-codex-test-stderr-$$.txt"
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
  local path="$1" content="${2:-rollcage-codex-test-fixture}"
  __ensure_dir "${path:h}"
  if [[ ! -f "$path" ]]; then
    /bin/echo "$content" > "$path"
    __fixtures_created+=("$path")
  fi
}

__ensure_executable() {
  local path="$1"
  __ensure_file "$path" $'#!/bin/sh\necho rollcage-codex-test\n'
  /bin/chmod +x "$path"
}

__ensure_dir "${HOME}/.codex"
__ensure_file "${HOME}/.codex/rollcage-codex-test-readable-$$"
__ensure_file "${HOME}/.agents/skills/rollcage-codex-test-$$/SKILL.md"
__ensure_file "${HOME}/.ssh/known_hosts"
__ensure_executable "${HOME}/.local/bin/rollcage-codex-standalone-test-$$"
__ensure_executable "${HOME}/.bun/bin/rollcage-codex-bun-test-$$"

/bin/echo "hello" > "${PROJECT_DIR}/testfile.txt"

NODE_REPL_CONFIG_HOME="${PROJECT_DIR}/node-repl-codex-home"
/bin/mkdir -p "${NODE_REPL_CONFIG_HOME}"
/bin/cat > "${NODE_REPL_CONFIG_HOME}/config.toml" <<'EOF'
[mcp_servers.node_repl]
args = []
command = "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl"
EOF

cleanup() {
  rm -rf "$PROJECT_DIR" "$__rollcage_trust_dir"
  rm -f "${PROFILE_PATH:-}"
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

PROFILE="$(__rollcage_assemble "$PROJECT_DIR")"
PROFILE_PATH="${TMPDIR_RESOLVED}/rollcage-codex-test-$$.sb"
printf '%s\n' "$PROFILE" > "$PROFILE_PATH"

sandboxed() {
  cd "$PROJECT_DIR"
  ROLLCAGE_ACTIVE=1 ROLLCAGE_CLI=codex sandbox-exec \
    -D "PROJECT_DIR=${PROJECT_DIR}" \
    -D "TMPDIR=${TMPDIR_RESOLVED}" \
    -D "CACHE_DIR=${CACHE_DIR}" \
    -D "VOLATILE_DIR=${VOLATILE_DIR}" \
    -D "HOME=${HOME_DIR}" \
    -D "ROLLCAGE_DIR=${ROLLCAGE_DIR}" \
    -f "$PROFILE_PATH" \
    -- "$@"
}

echo "=== rollcage codex profile ==="
echo "  base-common.sb + base-codex.sb assembled to: ${PROFILE_PATH}"
echo "  project dir: ${PROJECT_DIR}"
echo ""

echo "=== Read access ==="

t "read project file"
expect_success "allowed" sandboxed cat "${PROJECT_DIR}/testfile.txt"

t "read Codex state"
expect_success "allowed" sandboxed cat "${HOME}/.codex/rollcage-codex-test-readable-$$"

t "read user-level cross-agent skills"
expect_success "allowed" sandboxed cat "${HOME}/.agents/skills/rollcage-codex-test-$$/SKILL.md"

t "read ~/.ssh remains blocked"
expect_fail "blocked" sandboxed cat "${HOME}/.ssh/known_hosts"

echo "=== Write access ==="

t "write project file"
expect_success "allowed" sandboxed touch "${PROJECT_DIR}/newfile.txt"

t "write Codex state"
expect_success "allowed" sandboxed touch "${HOME}/.codex/rollcage-codex-test-write-$$"
rm -f "${HOME}/.codex/rollcage-codex-test-write-$$"

t "acquire and release Codex session file lock"
expect_success "allowed" sandboxed /usr/bin/perl -e '
use Fcntl qw(:flock);
open(my $lock, "+<", $ARGV[0]) or die "open: $!";
flock($lock, LOCK_EX | LOCK_NB) or die "lock: $!";
flock($lock, LOCK_UN) or die "unlock: $!";
' "${HOME}/.codex/rollcage-codex-test-readable-$$"

t "user-level cross-agent skills remain read-only"
expect_fail "blocked" sandboxed touch "${HOME}/.agents/skills/rollcage-codex-test-$$/test-write"

t "write home root remains blocked"
expect_fail "blocked" sandboxed touch "${HOME}/rollcage-codex-test-should-not-exist"

t "write to existing .rollcage config is blocked"
/bin/echo "tool node" > "${PROJECT_DIR}/.rollcage"
expect_fail "blocked" sandboxed /bin/sh -c "echo 'allow-read ~/.ssh' >> '${PROJECT_DIR}/.rollcage'"

t "create .rollcage config is blocked"
rm -f "${PROJECT_DIR}/.rollcage"
expect_fail "blocked" sandboxed /bin/sh -c "echo 'allow-read ~/.ssh' > '${PROJECT_DIR}/.rollcage'"

echo "=== Exec access ==="

t "exec direct-release style ~/.local/bin binary"
expect_success "allowed" sandboxed "${HOME}/.local/bin/rollcage-codex-standalone-test-$$"

t "exec bun-global style binary"
expect_success "allowed" sandboxed "${HOME}/.bun/bin/rollcage-codex-bun-test-$$"

t "tmp script execution remains blocked"
sandboxed /bin/sh -c "printf '#!/bin/sh\necho bad\n' > /private/tmp/rollcage-codex-exec-$$ && chmod +x /private/tmp/rollcage-codex-exec-$$" 2>/dev/null || true
if [[ -f "/private/tmp/rollcage-codex-exec-$$" ]]; then
  expect_fail "blocked" sandboxed "/private/tmp/rollcage-codex-exec-$$"
  rm -f "/private/tmp/rollcage-codex-exec-$$"
else
  __test_pass=$((__test_pass + 1))
fi

t "ROLLCAGE_CLI is visible"
expect_success "visible" sandboxed /bin/sh -c 'test "$ROLLCAGE_CLI" = codex'

t "shared ROLLCAGE_ACTIVE is visible"
expect_success "visible" sandboxed /bin/sh -c 'test "$ROLLCAGE_ACTIVE" = 1'

t "installed codex can start"
if codex_bin="$(command -v codex 2>/dev/null)"; then
  expect_success "runs" sandboxed "$codex_bin" --version
else
  skip "codex not installed"
fi

echo "=== ChatGPT Node REPL ==="

rollcage_codex_detects_chatgpt_node_repl() {
  CODEX_HOME="${NODE_REPL_CONFIG_HOME}" __rollcage_codex_uses_chatgpt_node_repl
}

t "rollcage codex detects the ChatGPT-bundled Node REPL config"
expect_success "detected" rollcage_codex_detects_chatgpt_node_repl

__node_repl_bin="/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl"
__node_kernel_bin="/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node"
__node_repl_npm="/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/npm"

if [[ -x "$__node_repl_bin" && -x "$__node_kernel_bin" ]]; then
  t "Node REPL server can start"
  expect_success "runs" sandboxed "$__node_repl_bin" --help

  /bin/cat > "${PROJECT_DIR}/node-repl-requests.jsonl" <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"rollcage-codex-test","version":"1"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"js","arguments":{"code":"nodeRepl.write(6 * 7)"}}}
EOF

  t "Node REPL evaluates JavaScript under the outer sandbox"
  expect_success "evaluates" sandboxed /bin/sh -c "
    NODE_REPL_NODE_PATH='$__node_kernel_bin' \
    NODE_REPL_NODE_MODULE_DIRS='/Applications/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules' \
    '$__node_repl_bin' --disable-sandbox \
      < '${PROJECT_DIR}/node-repl-requests.jsonl' \
      > '${PROJECT_DIR}/node-repl-output.jsonl' &
    repl_pid=\$!
    found=1
    attempts=0
    while [ \$attempts -lt 100 ]; do
      if /usr/bin/grep -q '\"text\":\"42\"' '${PROJECT_DIR}/node-repl-output.jsonl'; then
        found=0
        break
      fi
      attempts=\$((attempts + 1))
      /bin/sleep 0.1
    done
    /bin/kill \$repl_pid 2>/dev/null || true
    wait \$repl_pid 2>/dev/null || true
    exit \$found
  "

  if [[ -e "$__node_repl_npm" ]]; then
    t "adjacent bundled npm remains non-executable"
    expect_fail "blocked" sandboxed "$__node_repl_npm" --version
  else
    t "adjacent bundled npm remains non-executable"; skip "bundled npm not installed"
  fi
else
  t "Node REPL server can start"; skip "ChatGPT-bundled Node REPL not installed"
  t "Node REPL evaluates JavaScript under the outer sandbox"; skip "ChatGPT-bundled Node REPL not installed"
  t "adjacent bundled npm remains non-executable"; skip "ChatGPT-bundled Node REPL not installed"
fi

echo "=== gh toolchain: keyring (keychain) access ==="

# gh stores its OAuth token in the macOS login keychain by default. Unlike
# base-claude.sb (Claude), base-codex.sb does not grant keychain read — Codex keeps
# its own auth in ~/.codex/auth.json — so `tool gh` must supply it, or
# `gh auth status` reports the token invalid. Guard both directions:
# the base alone must block keychain reads; `tool gh` must allow them.
__keychain_file=""
for __kc in "${HOME}/Library/Keychains/"*(.N); do
  __keychain_file="$__kc"; break
done

if [[ -z "$__keychain_file" ]]; then
  t "gh keyring: keychain read blocked by base (no tool gh)"; skip "no keychain database present"
  t "gh keyring: tool gh grants keychain read"; skip "no keychain database present"
else
  t "gh keyring: keychain read blocked by base (no tool gh)"
  expect_fail "blocked" sandboxed cat "$__keychain_file"

  # A second profile that opts into the gh toolchain must gain keychain read.
  /bin/echo "tool gh" > "${PROJECT_DIR}/.rollcage"
  __rollcage_trust "${PROJECT_DIR}/.rollcage" >/dev/null 2>&1
  GH_PROFILE_PATH="${TMPDIR_RESOLVED}/rollcage-codex-gh-test-$$.sb"
  __rollcage_assemble "$PROJECT_DIR" > "$GH_PROFILE_PATH"
  rm -f "${PROJECT_DIR}/.rollcage"

  sandboxed_gh() {
    cd "$PROJECT_DIR"
    ROLLCAGE_ACTIVE=1 ROLLCAGE_CLI=codex sandbox-exec \
      -D "PROJECT_DIR=${PROJECT_DIR}" \
      -D "TMPDIR=${TMPDIR_RESOLVED}" \
      -D "CACHE_DIR=${CACHE_DIR}" \
      -D "VOLATILE_DIR=${VOLATILE_DIR}" \
      -D "HOME=${HOME_DIR}" \
      -D "ROLLCAGE_DIR=${ROLLCAGE_DIR}" \
      -f "$GH_PROFILE_PATH" \
      -- "$@"
  }

  t "gh keyring: tool gh grants keychain read"
  expect_success "allowed" sandboxed_gh cat "$__keychain_file"
  rm -f "$GH_PROFILE_PATH"
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
