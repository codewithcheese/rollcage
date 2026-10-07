# opencode adapter for rollcage. Sourced by the dispatcher; no load-time effects.

__rollcage_launch_opencode() {
  local tmpdir="${TMPDIR:-/private/tmp}"
  local home_dir="$(readlink -f "${HOME}")"
  local project_dir="$(readlink -f "${PWD}")"
  tmpdir="$(readlink -f "$tmpdir")"

  local cache_dir="${tmpdir%/T*}/C"
  local volatile_dir="${tmpdir%/T*}/X"

  local opencode_bin
  if ! opencode_bin="$(command -v opencode 2>/dev/null)"; then
    echo "rollcage opencode: opencode not found in PATH" >&2
    return 127
  fi
  opencode_bin="$(readlink -f "$opencode_bin")"

  local rollcage_dir_resolved="$(readlink -f "${__rollcage_dir}")"
  local profile profile_path rc=0

  profile="$(__rollcage_assemble "$project_dir")" || return 1
  profile_path="${tmpdir}/rollcage-opencode-$$.sb"
  printf '%s\n' "$profile" > "$profile_path"

  local -a sandbox_args
  sandbox_args=(
    -D "PROJECT_DIR=${project_dir}"
    -D "TMPDIR=${tmpdir}"
    -D "CACHE_DIR=${cache_dir}"
    -D "VOLATILE_DIR=${volatile_dir}"
    -D "HOME=${home_dir}"
    -D "ROLLCAGE_DIR=${rollcage_dir_resolved}"
    -D "OPENCODE_BIN=${opencode_bin}"
    -f "$profile_path"
  )

  # Seatbelt is the permission boundary, so bypass OpenCode's application-level
  # approval prompts. The install itself remains read-only inside rollcage opencode;
  # upgrades happen outside while runtime state and plugin caches stay writable.
  env ROLLCAGE_ACTIVE=1 ROLLCAGE_CLI=opencode OPENCODE_DISABLE_AUTOUPDATE=1 \
    sandbox-exec "${sandbox_args[@]}" -- "$opencode_bin" --auto "$@"
  rc=$?

  rm -f "$profile_path"
  return $rc
}
