# codex adapter for rollcage. Sourced by the dispatcher; no load-time effects.

__rollcage_launch_codex() {
  local tmpdir="${TMPDIR:-/private/tmp}"
  local home_dir="$(readlink -f "${HOME}")"
  local project_dir="$(readlink -f "${PWD}")"
  tmpdir="$(readlink -f "$tmpdir")"

  local cache_dir="${tmpdir%/T*}/C"
  local volatile_dir="${tmpdir%/T*}/X"

  local codex_bin
  if ! codex_bin="$(command -v codex 2>/dev/null)"; then
    echo "rollcage codex: codex not found in PATH" >&2
    return 127
  fi

  local rollcage_dir_resolved="$(readlink -f "${__rollcage_dir}")"
  local profile profile_path rc=0

  profile="$(__rollcage_assemble "$project_dir")" || return 1
  profile_path="${tmpdir}/rollcage-codex-$$.sb"
  printf '%s\n' "$profile" > "$profile_path"

  local -a sandbox_args codex_args
  sandbox_args=(
    -D "PROJECT_DIR=${project_dir}"
    -D "TMPDIR=${tmpdir}"
    -D "CACHE_DIR=${cache_dir}"
    -D "VOLATILE_DIR=${volatile_dir}"
    -D "HOME=${home_dir}"
    -D "ROLLCAGE_DIR=${rollcage_dir_resolved}"
    -f "$profile_path"
  )
  codex_args=(--dangerously-bypass-approvals-and-sandbox)

  # Codex's installation is read-only inside Seatbelt; upgrades must run outside.
  codex_args+=(--config check_for_update_on_startup=false)

  # ChatGPT.app's Node REPL normally asks Codex to create a child Seatbelt
  # sandbox. macOS rejects nested sandbox-exec calls, so run that child
  # directly; it still inherits Rollcage's codex outer Seatbelt profile.
  if __rollcage_codex_uses_chatgpt_node_repl; then
    codex_args+=(--config 'mcp_servers.node_repl.args=["--disable-sandbox"]')
  fi

  codex_args+=("$@")

  # Public sandbox markers are inherited by all child processes.
  env ROLLCAGE_ACTIVE=1 ROLLCAGE_CLI=codex \
    sandbox-exec "${sandbox_args[@]}" -- "$codex_bin" "${codex_args[@]}"
  rc=$?

  rm -f "$profile_path"
  return $rc
}

# Disable only the ChatGPT Node REPL child sandbox when it is registered.
__rollcage_codex_uses_chatgpt_node_repl() {
  local codex_home="${CODEX_HOME:-${HOME}/.codex}"
  local config_file="${codex_home}/config.toml"

  [[ -r "$config_file" ]] || return 1

  /usr/bin/awk '
    /^[[:space:]]*\[[[:space:]]*mcp_servers[.]"?node_repl"?[[:space:]]*\][[:space:]]*(#.*)?$/ {
      in_node_repl = 1
      next
    }
    /^[[:space:]]*\[/ {
      in_node_repl = 0
    }
    in_node_repl && /^[[:space:]]*command[[:space:]]*=[[:space:]]*"\/Applications\/ChatGPT[.]app\/Contents\/Resources\/cua_node\/bin\/node_repl"[[:space:]]*(#.*)?$/ {
      found = 1
    }
    END {
      exit(found ? 0 : 1)
    }
  ' "$config_file"
}
