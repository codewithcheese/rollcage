# Shared helpers for toolchain sandbox tests.
# Sourced by each toolchains/*.test.zsh file.
#
# Provides:
#   tc_setup <name>       — assemble a profile with this toolchain
#   tc_sandboxed <cmd...> — run a command inside the toolchain sandbox
#   tc_fixture_dir <path> — create a fixture directory (cleaned up automatically)
#   tc_fixture_file <path> [content] — create a fixture file
#   expect_success <desc> <cmd...>
#   expect_fail <desc> <cmd...>
#   tc_has_cmd <cmd>      — check if a command exists on the host

# These must be set by the runner before sourcing:
#   PROJECT_DIR, TMPDIR_RESOLVED, CACHE_DIR, HOME_DIR
#   __rollcage_trust, __rollcage_assemble (from rollcage.lib.zsh)

__tc_profile_path=""
__tc_fixtures=()

tc_setup() {
  local tc_name="$1"

  # Write .rollcage and pre-trust it
  echo "tool ${tc_name}" > "${PROJECT_DIR}/.rollcage"
  __rollcage_trust "${PROJECT_DIR}/.rollcage"

  local tc_profile
  tc_profile="$(__rollcage_assemble "$PROJECT_DIR")"
  __tc_profile_path="${TMPDIR_RESOLVED}/rollcage-claude-tc-${tc_name}-$$.sb"
  printf '%s\n' "$tc_profile" > "$__tc_profile_path"
}

tc_sandboxed() {
  # cd to PROJECT_DIR so tools don't try to read the inherited CWD
  # (which may not be in the sandbox allowlist)
  cd "$PROJECT_DIR"
  sandbox-exec \
    -D "PROJECT_DIR=${PROJECT_DIR}" \
    -D "TMPDIR=${TMPDIR_RESOLVED}" \
    -D "CACHE_DIR=${CACHE_DIR}" \
    -D "VOLATILE_DIR=${VOLATILE_DIR}" \
    -D "HOME=${HOME_DIR}" \
    -D "ROLLCAGE_DIR=${ROLLCAGE_DIR}" \
    -f "$__tc_profile_path" \
    -- "$@"
}


tc_fixture_dir() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    /bin/mkdir -p "$dir"
    __tc_fixtures+=("$dir")
  fi
}

tc_fixture_file() {
  local path="$1"
  local content="${2:-rollcage-claude-test-fixture}"
  local dir="${path%/*}"
  tc_fixture_dir "$dir"
  if [[ ! -f "$path" ]]; then
    echo "$content" > "$path"
    __tc_fixtures+=("$path")
  fi
}

tc_cleanup() {
  /bin/rm -f "$__tc_profile_path"
  # Reverse order: files before dirs
  local f
  for f in "${(Oa)__tc_fixtures[@]}"; do
    if [[ -d "$f" ]]; then
      /bin/rmdir "$f" 2>/dev/null || true
    else
      /bin/rm -f "$f" 2>/dev/null || true
    fi
  done
  __tc_fixtures=()
  /bin/rm -f "${PROJECT_DIR}/.rollcage"
}

tc_has_cmd() {
  command -v "$1" &>/dev/null
}
