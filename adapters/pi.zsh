# pi adapter for rollcage. Sourced by the dispatcher; no load-time effects.

__rollcage_launch_pi() {
  local tmpdir="${TMPDIR:-/private/tmp}"
  local home_dir="$(readlink -f "${HOME}")"
  local project_dir="$(readlink -f "${PWD}")"
  tmpdir="$(readlink -f "$tmpdir")"

  local cache_dir="${tmpdir%/T*}/C"
  local volatile_dir="${tmpdir%/T*}/X"

  local pi_bin
  if ! pi_bin="$(command -v pi 2>/dev/null)"; then
    echo "rollcage pi: pi not found in PATH" >&2
    return 127
  fi

  local rollcage_dir_resolved="$(readlink -f "${__rollcage_dir}")"
  local profile profile_path rc=0

  profile="$(__rollcage_assemble "$project_dir")" || return 1
  profile_path="${tmpdir}/rollcage-pi-$$.sb"
  printf '%s\n' "$profile" > "$profile_path"

  local -a sandbox_args
  sandbox_args=(
    -D "PROJECT_DIR=${project_dir}"
    -D "TMPDIR=${tmpdir}"
    -D "CACHE_DIR=${cache_dir}"
    -D "VOLATILE_DIR=${volatile_dir}"
    -D "HOME=${home_dir}"
    -D "ROLLCAGE_DIR=${rollcage_dir_resolved}"
    -f "$profile_path"
  )

  # Public sandbox markers are inherited by all child processes.
  env ROLLCAGE_ACTIVE=1 ROLLCAGE_CLI=pi \
    sandbox-exec "${sandbox_args[@]}" -- "$pi_bin" "$@"
  rc=$?

  rm -f "$profile_path"
  return $rc
}
