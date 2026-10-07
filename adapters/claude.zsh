# claude adapter for rollcage. Sourced by the dispatcher; no load-time effects.

__rollcage_launch_claude() {
  local tmpdir="${TMPDIR:-/private/tmp}"
  # Resolve symlinks (Seatbelt uses real paths, /var -> /private/var)
  local home_dir="$(readlink -f "${HOME}")"
  local project_dir="$(readlink -f "${PWD}")"
  tmpdir="$(readlink -f "$tmpdir")"

  # TMPDIR is .../T or .../T/, siblings are .../C (cache) and .../X (volatile)
  # Cache: needed by Security framework (Spotlight mds) for keychain access
  # Volatile: needed by macOS for code-signing clones at process launch
  local cache_dir="${tmpdir%/T*}/C"
  local volatile_dir="${tmpdir%/T*}/X"

  local claude_bin
  if ! claude_bin="$(command -v claude 2>/dev/null)"; then
    echo "rollcage claude: claude not found in PATH" >&2
    return 127
  fi
  claude_bin="$(readlink -f "$claude_bin")"

  local rollcage_dir_resolved="$(readlink -f "${__rollcage_dir}")"
  local reload_sentinel="${tmpdir}/rollcage-claude-$$-reload"
  local rc=0
  local first_run=1
  local profile profile_path denial_log log_pid
  local -a claude_args

  while true; do
    # Re-assemble the sandbox profile each iteration so config changes take effect
    profile="$(__rollcage_assemble "$project_dir")" || return 1

    profile_path="${tmpdir}/rollcage-claude-$$.sb"
    printf '%s\n' "$profile" > "$profile_path"

    # Stream sandbox denials to a temp file outside the sandbox.
    # The hook script (inside the sandbox) reads this file since
    # /usr/bin/log refuses to run inside a sandbox.
    denial_log="${tmpdir}/rollcage-claude-$$-denials.log"
    setopt local_options no_monitor
    /usr/bin/log stream \
      --predicate 'eventMessage CONTAINS "Sandbox" AND eventMessage CONTAINS "deny"' \
      --style compact > "$denial_log" 2>/dev/null &
    log_pid=$!

    # First run uses original args; subsequent runs resume the session
    if (( first_run )); then
      claude_args=("$@")
      first_run=0
    else
      echo "rollcage claude: reloading sandbox profile..." >&2
      claude_args=(--continue)
    fi

    # ROLLCAGE_ACTIVE: public, stable env var for sandbox detection (documented in README)
    # ROLLCAGE_DENIAL_LOG: internal, read by sandbox-denial-hook.sh
    # ROLLCAGE_RELOAD_SENTINEL: internal, signals profile reload
    ROLLCAGE_ACTIVE=1 \
    ROLLCAGE_CLI=claude \
    ROLLCAGE_DENIAL_LOG="$denial_log" \
    ROLLCAGE_RELOAD_SENTINEL="$reload_sentinel" \
    sandbox-exec \
      -D "PROJECT_DIR=${project_dir}" \
      -D "TMPDIR=${tmpdir}" \
      -D "CACHE_DIR=${cache_dir}" \
      -D "VOLATILE_DIR=${volatile_dir}" \
      -D "HOME=${home_dir}" \
      -D "ROLLCAGE_DIR=${rollcage_dir_resolved}" \
      -f "$profile_path" \
      -- "$claude_bin" --dangerously-skip-permissions --plugin-dir "${__rollcage_dir}" "${claude_args[@]}"
    rc=$?

    # Cleanup per-iteration temp files
    kill "$log_pid" 2>/dev/null || true
    wait "$log_pid" 2>/dev/null || true
    rm -f "$profile_path" "$denial_log"

    # If the reload sentinel exists, loop to re-assemble and restart
    if [[ -f "$reload_sentinel" ]]; then
      rm -f "$reload_sentinel"
      continue
    fi

    # Normal exit — break out of the loop
    break
  done

  return $rc
}
