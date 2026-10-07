# Rust toolchain sandbox tests
tc_setup rust

tc_fixture_dir "${HOME}/.cargo/bin"
tc_fixture_dir "${HOME}/.cargo/registry"
tc_fixture_dir "${HOME}/.cargo/git"
tc_fixture_file "${HOME}/.cargo/env"
tc_fixture_dir "${HOME}/.rustup/tmp"
tc_fixture_dir "${HOME}/.rustup/downloads"
tc_fixture_dir "${HOME}/.rustup/update-hashes"
tc_fixture_dir "${HOME}/.rustup/toolchains"

# ── Access ──
t "rust: read ~/.cargo"
expect_success "allowed" tc_sandboxed cat "${HOME}/.cargo/env"

t "rust: read ~/.rustup"
tc_fixture_file "${HOME}/.rustup/settings.toml"
expect_success "allowed" tc_sandboxed cat "${HOME}/.rustup/settings.toml"

t "rust: write ~/.cargo/registry"
expect_success "allowed" tc_sandboxed touch "${HOME}/.cargo/registry/test-write"
rm -f "${HOME}/.cargo/registry/test-write"

t "rust: write ~/.cargo/.package-cache-mutate"
expect_success "allowed" tc_sandboxed touch "${HOME}/.cargo/.package-cache-mutate"

t "rust: write ~/.cargo/.global-cache"
expect_success "allowed" tc_sandboxed touch "${HOME}/.cargo/.global-cache"

t "rust: write ~/.rustup/tmp for channel sync"
expect_success "allowed" tc_sandboxed touch "${HOME}/.rustup/tmp/rollcage-claude-test-write"
rm -f "${HOME}/.rustup/tmp/rollcage-claude-test-write"

t "rust: write ~/.rustup/downloads for component archives"
expect_success "allowed" tc_sandboxed touch "${HOME}/.rustup/downloads/rollcage-claude-test-write"
rm -f "${HOME}/.rustup/downloads/rollcage-claude-test-write"

t "rust: write ~/.rustup/update-hashes for channel state"
expect_success "allowed" tc_sandboxed touch "${HOME}/.rustup/update-hashes/rollcage-claude-test-write"
rm -f "${HOME}/.rustup/update-hashes/rollcage-claude-test-write"

t "rust: write ~/.rustup/toolchains for pinned toolchain installs"
expect_success "allowed" tc_sandboxed touch "${HOME}/.rustup/toolchains/rollcage-claude-test-write"
rm -f "${HOME}/.rustup/toolchains/rollcage-claude-test-write"

t "rust: ~/.rustup/settings.toml remains read-only"
expect_fail "blocked" tc_sandboxed touch "${HOME}/.rustup/settings.toml"

# ── Usability ──
__cargo="${HOME}/.cargo/bin/cargo"
if [[ ! -x "$__cargo" ]]; then
  __cargo="$(command -v cargo 2>/dev/null || echo "")"
fi
if [[ -z "$__cargo" ]]; then
  echo "SKIP: cargo binary not found" >&2
  tc_cleanup
  return 0 2>/dev/null || exit 0
fi

t "rust: cargo --version"
expect_success "runs" tc_sandboxed "$__cargo" --version

__rustc="${HOME}/.cargo/bin/rustc"
if [[ ! -x "$__rustc" ]]; then
  __rustc="$(command -v rustc 2>/dev/null || echo "${HOME}/.cargo/bin/rustc")"
fi

t "rust: rustc --version"
expect_success "runs" tc_sandboxed "$__rustc" --version

# cargo init + build
t "rust: cargo init"
expect_success "cargo init" tc_sandboxed "$__cargo" init "${PROJECT_DIR}/rust-test"

t "rust: cargo build"
expect_success "cargo build" tc_sandboxed /bin/sh -c "cd '${PROJECT_DIR}/rust-test' && '${__cargo}' build 2>&1"

t "rust: compiled binary exists"
expect_success "binary" tc_sandboxed test -f "${PROJECT_DIR}/rust-test/target/debug/rust-test"

rm -rf "${PROJECT_DIR}/rust-test"

# NOTE: cargo install is NOT tested because it builds in $TMPDIR
# and build scripts need exec from there, which we intentionally
# block (TMPDIR exec is an escape vector). cargo init + cargo build
# above prove the toolchain works for normal project builds.

# ── Isolation ──
t "rust: ~/.ssh blocked"
expect_fail "blocked" tc_sandboxed cat "${HOME}/.ssh/known_hosts"

tc_cleanup
