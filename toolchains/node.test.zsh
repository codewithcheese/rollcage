# Node.js toolchain (node, npm, npx, corepack, pnpm) sandbox tests
tc_setup node

tc_fixture_dir "${HOME}/.nvm/versions/node"
tc_fixture_file "${HOME}/.nvm/default-packages"
tc_fixture_dir "${HOME}/.npm/_cacache"
tc_fixture_dir "${HOME}/.cache/node/corepack"
tc_fixture_dir "${HOME}/.pnpm-store/v3"
tc_fixture_dir "${HOME}/.local/share/pnpm"
tc_fixture_dir "${HOME}/.config/pnpm"
tc_fixture_file "${HOME}/.config/pnpm/rc" "store-dir=~/.pnpm-store"

# ── Access ──
t "node: read ~/.nvm"
expect_success "allowed" tc_sandboxed cat "${HOME}/.nvm/default-packages"

t "node: write ~/.npm"
expect_success "allowed" tc_sandboxed touch "${HOME}/.npm/test-write"
rm -f "${HOME}/.npm/test-write"

t "node: ~/.nvm not writable (read-only)"
expect_fail "blocked" tc_sandboxed touch "${HOME}/.nvm/test-write"

t "node: read ~/.cache/node (corepack)"
tc_fixture_file "${HOME}/.cache/node/corepack/lastKnownGood.json" '{"pnpm":"9.0.0"}'
expect_success "allowed" tc_sandboxed cat "${HOME}/.cache/node/corepack/lastKnownGood.json"

t "node: write ~/.cache/node (corepack)"
expect_success "allowed" tc_sandboxed touch "${HOME}/.cache/node/corepack/test-write"
rm -f "${HOME}/.cache/node/corepack/test-write"

t "node: read ~/.pnpm-store"
tc_fixture_file "${HOME}/.pnpm-store/test-data"
expect_success "allowed" tc_sandboxed cat "${HOME}/.pnpm-store/test-data"

t "node: write ~/.pnpm-store"
expect_success "allowed" tc_sandboxed touch "${HOME}/.pnpm-store/test-write"
rm -f "${HOME}/.pnpm-store/test-write"

t "node: read pnpm config"
expect_success "allowed" tc_sandboxed cat "${HOME}/.config/pnpm/rc"

# macOS pnpm layouts: dependencies and managed engines are mutable caches.
for __pnpm_cache in \
  "${HOME}/Library/pnpm/store" \
  "${HOME}/Library/pnpm/package-manager-store" \
  "${HOME}/Library/pnpm/.tools/pnpm"; do
  __pnpm_fixture="${__pnpm_cache}/rollcage-claude-test-$$"
  tc_fixture_dir "$__pnpm_fixture"
  tc_fixture_file "${__pnpm_fixture}/readable" pnpm-cache-test
  tc_fixture_file "${__pnpm_fixture}/executable" $'#!/bin/sh\necho pnpm-cache-exec'
  chmod +x "${__pnpm_fixture}/executable"
  t "node: read ${__pnpm_cache}"
  expect_success "allowed" tc_sandboxed /bin/cat "${__pnpm_fixture}/readable"
  t "node: write ${__pnpm_cache}"
  expect_success "allowed" tc_sandboxed /usr/bin/touch "${__pnpm_fixture}/written"
  rm -f "${__pnpm_fixture}/written"
  t "node: execute ${__pnpm_cache}"
  expect_success "runs" tc_sandboxed "${__pnpm_fixture}/executable"
done

# The engine lockfile's atomic temp files are allowed only at this level.
tc_fixture_dir "${HOME}/Library/pnpm/global/v11"
__pnpm_atomic="${HOME}/Library/pnpm/global/v11/.tmpRollcage$$"
t "node: pnpm engine atomic lockfile write"
expect_success "allowed" tc_sandboxed /usr/bin/touch "$__pnpm_atomic"
rm -f "$__pnpm_atomic"
tc_fixture_dir "${HOME}/Library/pnpm/global/v11/rollcage-claude-test-$$"
t "node: nested global app temp files not writable"
expect_fail "blocked" tc_sandboxed /usr/bin/touch "${HOME}/Library/pnpm/global/v11/rollcage-claude-test-$$/.tmpForbidden"
t "node: arbitrary global root files not writable"
expect_fail "blocked" tc_sandboxed /usr/bin/touch "${HOME}/Library/pnpm/global/v11/rollcage-claude-forbidden-$$"
t "node: lockfile temp pattern requires a literal dot"
expect_fail "blocked" tc_sandboxed /usr/bin/touch "${HOME}/Library/pnpm/global/v11/xtmpRollcage$$"
tc_fixture_dir "${HOME}/Library/pnpm/bin"
t "node: global pnpm bins not writable"
expect_fail "blocked" tc_sandboxed /usr/bin/touch "${HOME}/Library/pnpm/bin/rollcage-claude-forbidden-$$"
tc_fixture_dir "${HOME}/Library/Preferences/pnpm"
t "node: pnpm configuration not writable"
expect_fail "blocked" tc_sandboxed /usr/bin/touch "${HOME}/Library/Preferences/pnpm/rollcage-claude-forbidden-$$"
tc_fixture_dir "${HOME}/.pnpm-state"
t "node: macOS pnpm state writable"
expect_success "allowed" tc_sandboxed /usr/bin/touch "${HOME}/.pnpm-state/rollcage-claude-test-$$"
rm -f "${HOME}/.pnpm-state/rollcage-claude-test-$$"

# ── Usability ──
# Find node binary: try nvm versions first, then fall back to PATH
__node_bin="$(find "${HOME}/.nvm/versions" -name "node" \( -type f -o -type l \) 2>/dev/null | head -1)"
if [[ -z "$__node_bin" ]]; then
  __node_bin="$(command -v node 2>/dev/null || echo "")"
fi
if [[ -z "$__node_bin" ]]; then
  echo "SKIP: node binary not found" >&2
  tc_cleanup
  return 0 2>/dev/null || exit 0
fi
__node_dir="$(dirname "$__node_bin")"
# Resolve npm/npx full paths for use inside sandbox-exec
__npm_bin="${__node_dir}/npm"
[[ -x "$__npm_bin" ]] || __npm_bin="$(command -v npm 2>/dev/null || echo "${__node_dir}/npm")"
__npx_bin="${__node_dir}/npx"
[[ -x "$__npx_bin" ]] || __npx_bin="$(command -v npx 2>/dev/null || echo "${__node_dir}/npx")"

t "node: node --version"
expect_success "runs" tc_sandboxed "$__node_bin" --version

# npm install
t "node: npm install"
mkdir -p "${PROJECT_DIR}/node-test"
echo '{"name":"sandbox-test","private":true}' > "${PROJECT_DIR}/node-test/package.json"
expect_success "npm install" tc_sandboxed /bin/sh -c "cd '${PROJECT_DIR}/node-test' && '${__npm_bin}' install is-odd --prefer-offline 2>&1"

t "node: node_modules created"
expect_success "exists" tc_sandboxed test -d "${PROJECT_DIR}/node-test/node_modules/is-odd"

t "node: node require installed package"
expect_success "require" tc_sandboxed "$__node_bin" -e "require('${PROJECT_DIR}/node-test/node_modules/is-odd')"

rm -rf "${PROJECT_DIR}/node-test"

# npx (downloads + executes from ~/.npm/_npx/)
# Use a package with an actual CLI binary (is-odd is a library, not a CLI)
t "node: npx executes package"
expect_success "npx" tc_sandboxed /bin/sh -c "cd '${PROJECT_DIR}' && '${__npx_bin}' --yes semver 1.2.3 2>&1"

# node eval
t "node: node eval"
expect_success "eval" tc_sandboxed "$__node_bin" -e "console.log(JSON.stringify({ok:true}))"

# node http (exercises network from sandbox)
t "node: node http request"
expect_success "http" tc_sandboxed "$__node_bin" -e "require('https').get('https://httpbin.org/get',r=>{r.on('data',()=>{});r.on('end',()=>console.log('ok'))})"

# ── pnpm usability ──
__pnpm="${HOME}/.local/share/pnpm/pnpm"
if [[ ! -x "$__pnpm" ]]; then
  __pnpm="$(command -v pnpm 2>/dev/null || echo "")"
fi
if [[ -n "$__pnpm" ]]; then
  t "node: pnpm --version"
  expect_success "runs" tc_sandboxed "$__pnpm" --version

  # pnpm add
  t "node: pnpm add"
  mkdir -p "${PROJECT_DIR}/pnpm-test"
  echo '{"name":"sandbox-test","private":true}' > "${PROJECT_DIR}/pnpm-test/package.json"
  expect_success "pnpm add" tc_sandboxed /bin/sh -c "cd '${PROJECT_DIR}/pnpm-test' && '$__pnpm' add is-odd 2>&1"

  t "node: pnpm node_modules created"
  expect_success "exists" tc_sandboxed test -d "${PROJECT_DIR}/pnpm-test/node_modules/is-odd"

  t "node: pnpm-lock.yaml created"
  expect_success "lockfile" tc_sandboxed test -f "${PROJECT_DIR}/pnpm-test/pnpm-lock.yaml"

  # A local CLI must run through pnpm's shorthand dispatch, not just --version.
  mkdir -p "${PROJECT_DIR}/pnpm-test/node_modules/.bin"
  printf '#!/bin/sh\necho pnpm-cli-ok\n' > "${PROJECT_DIR}/pnpm-test/node_modules/.bin/rollcage-claude-probe"
  chmod +x "${PROJECT_DIR}/pnpm-test/node_modules/.bin/rollcage-claude-probe"
  t "node: pnpm dispatches project CLI"
  expect_success "runs" tc_sandboxed /bin/sh -c "cd '${PROJECT_DIR}/pnpm-test' && '$__pnpm' rollcage-claude-probe"

  # Version pins exercise managed-engine downloads and global lockfile writes.
  mkdir -p "${PROJECT_DIR}/pnpm-pin-test"
  echo '{"name":"sandbox-pin-test","private":true,"packageManager":"pnpm@10.34.1"}' > "${PROJECT_DIR}/pnpm-pin-test/package.json"
  t "node: pnpm honors project version pin"
  expect_success "10.34.1" tc_sandboxed /bin/sh -c "cd '${PROJECT_DIR}/pnpm-pin-test' && actual=\$( '$__pnpm' --version ) && [ \"\$actual\" = 10.34.1 ]"
  rm -rf "${PROJECT_DIR}/pnpm-pin-test"

  rm -rf "${PROJECT_DIR}/pnpm-test"

  # pnpm dlx (downloads + executes from store)
  t "node: pnpm dlx executes package"
  expect_success "dlx" tc_sandboxed /bin/sh -c "cd '${PROJECT_DIR}' && '$__pnpm' dlx semver 1.2.3 2>&1"
else
  echo "SKIP: pnpm binary not found" >&2
fi

# ── Isolation ──
t "node: ~/.ssh blocked"
expect_fail "blocked" tc_sandboxed cat "${HOME}/.ssh/known_hosts"

t "node: ~/.cargo not granted"
expect_fail "isolated" tc_sandboxed cat "${HOME}/.cargo/test" 2>/dev/null

tc_cleanup
