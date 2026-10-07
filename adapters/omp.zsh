# omp adapter for rollcage. Sourced by the dispatcher; no load-time effects.

__rollcage_launch_omp() {
  local tmpdir="${TMPDIR:-/private/tmp}"
  local home_dir="$(readlink -f "${HOME}")"
  local project_dir="$(readlink -f "${PWD}")"
  tmpdir="$(readlink -f "$tmpdir")"

  local cache_dir="${tmpdir%/T*}/C"
  local volatile_dir="${tmpdir%/T*}/X"

  # Mirror OMP's config/profile path resolution before entering Seatbelt so
  # the profile grants only the active OMP-owned roots. OMP_PROFILE takes
  # precedence even when explicitly empty; PI_PROFILE is the legacy fallback.
  local profile_raw=""
  if (( ${+OMP_PROFILE} )); then
    profile_raw="${OMP_PROFILE}"
  else
    profile_raw="${PI_PROFILE:-}"
  fi
  local profile="${profile_raw#"${profile_raw%%[![:space:]]*}"}"
  profile="${profile%"${profile##*[![:space:]]}"}"
  [[ "$profile" == "default" ]] && profile=""
  if [[ -n "$profile" && ! "$profile" =~ '^[a-z0-9][a-z0-9._-]{0,63}$' ]]; then
    # OMP will report the invalid profile cleanly; use the default roots only
    # for assembling the sandbox that allows it to reach that error path.
    profile=""
  fi

  local config_base="${home_dir}/${PI_CONFIG_DIR:-.omp}"
  config_base="${config_base:A}"
  local omp_config_root="$config_base"
  [[ -n "$profile" ]] && omp_config_root="${config_base}/profiles/${profile}"
  omp_config_root="${omp_config_root:A}"

  local default_agent_dir="${omp_config_root}/agent"
  local omp_agent_dir="$default_agent_dir"
  if [[ -z "$profile" && -n "${PI_CODING_AGENT_DIR:-}" ]]; then
    if [[ "${PI_CODING_AGENT_DIR}" == /* ]]; then
      omp_agent_dir="${PI_CODING_AGENT_DIR:A}"
    else
      omp_agent_dir="${project_dir}/${PI_CODING_AGENT_DIR}"
      omp_agent_dir="${omp_agent_dir:A}"
    fi
  fi

  local omp_data_root="$omp_config_root"
  local omp_state_root="$omp_config_root"
  local omp_cache_root="$omp_config_root"
  local omp_xdg_data_root="$omp_config_root"
  local omp_xdg_state_root="$omp_config_root"
  local omp_xdg_cache_root="$omp_config_root"

  # OMP activates each XDG category independently only when its app/profile
  # root already exists and the default derived agent directory is active.
  # The app roots are still passed when absent so `omp config init-xdg` can
  # create them from inside rollcage omp; they never widen to the surrounding XDG home.
  local xdg_value xdg_app_root xdg_profile_root
  if [[ -n "${XDG_DATA_HOME:-}" ]]; then
    xdg_value="${XDG_DATA_HOME}"
    [[ "$xdg_value" != /* ]] && xdg_value="${project_dir}/${xdg_value}"
    omp_xdg_data_root="${xdg_value:A}/omp"
    omp_xdg_data_root="${omp_xdg_data_root:A}"
    xdg_profile_root="$omp_xdg_data_root"
    [[ -n "$profile" ]] && xdg_profile_root="${omp_xdg_data_root}/profiles/${profile}"
    if [[ "$omp_agent_dir" == "$default_agent_dir" && -e "$xdg_profile_root" ]]; then
      omp_data_root="${xdg_profile_root:A}"
    fi
  fi
  if [[ -n "${XDG_STATE_HOME:-}" ]]; then
    xdg_value="${XDG_STATE_HOME}"
    [[ "$xdg_value" != /* ]] && xdg_value="${project_dir}/${xdg_value}"
    omp_xdg_state_root="${xdg_value:A}/omp"
    omp_xdg_state_root="${omp_xdg_state_root:A}"
    xdg_profile_root="$omp_xdg_state_root"
    [[ -n "$profile" ]] && xdg_profile_root="${omp_xdg_state_root}/profiles/${profile}"
    if [[ "$omp_agent_dir" == "$default_agent_dir" && -e "$xdg_profile_root" ]]; then
      omp_state_root="${xdg_profile_root:A}"
    fi
  fi
  if [[ -n "${XDG_CACHE_HOME:-}" ]]; then
    xdg_value="${XDG_CACHE_HOME}"
    [[ "$xdg_value" != /* ]] && xdg_value="${project_dir}/${xdg_value}"
    omp_xdg_cache_root="${xdg_value:A}/omp"
    omp_xdg_cache_root="${omp_xdg_cache_root:A}"
    xdg_profile_root="$omp_xdg_cache_root"
    [[ -n "$profile" ]] && xdg_profile_root="${omp_xdg_cache_root}/profiles/${profile}"
    if [[ "$omp_agent_dir" == "$default_agent_dir" && -e "$xdg_profile_root" ]]; then
      omp_cache_root="${xdg_profile_root:A}"
    fi
  fi

  local omp_bin
  if ! omp_bin="$(command -v omp 2>/dev/null)"; then
    echo "rollcage omp: omp not found in PATH" >&2
    return 127
  fi
  omp_bin="$(readlink -f "$omp_bin")"

  local rollcage_dir_resolved="$(readlink -f "${__rollcage_dir}")"
  local assembled_profile profile_path rc=0

  assembled_profile="$(__rollcage_assemble "$project_dir")" || return 1
  profile_path="${tmpdir}/rollcage-omp-$$.sb"
  printf '%s\n' "$assembled_profile" > "$profile_path"

  local -a sandbox_args
  sandbox_args=(
    -D "PROJECT_DIR=${project_dir}"
    -D "TMPDIR=${tmpdir}"
    -D "CACHE_DIR=${cache_dir}"
    -D "VOLATILE_DIR=${volatile_dir}"
    -D "HOME=${home_dir}"
    -D "ROLLCAGE_DIR=${rollcage_dir_resolved}"
    -D "OMP_CONFIG_ROOT=${omp_config_root}"
    -D "OMP_AGENT_DIR=${omp_agent_dir}"
    -D "OMP_DATA_ROOT=${omp_data_root}"
    -D "OMP_STATE_ROOT=${omp_state_root}"
    -D "OMP_CACHE_ROOT=${omp_cache_root}"
    -D "OMP_XDG_DATA_ROOT=${omp_xdg_data_root}"
    -D "OMP_XDG_STATE_ROOT=${omp_xdg_state_root}"
    -D "OMP_XDG_CACHE_ROOT=${omp_xdg_cache_root}"
    -f "$profile_path"
  )

  # Seatbelt is the permission boundary, so bypass OMP's application-level
  # approval prompts. OAuth callbacks and API traffic use the shared profile's
  # network access; credentials remain in ~/.omp/agent/agent.db.
  env ROLLCAGE_ACTIVE=1 ROLLCAGE_CLI=omp \
    sandbox-exec "${sandbox_args[@]}" -- "$omp_bin" --auto-approve "$@"
  rc=$?

  rm -f "$profile_path"
  return $rc
}
