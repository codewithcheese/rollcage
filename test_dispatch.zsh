#!/bin/zsh
# Dispatcher contract tests. Mock Seatbelt and agents; no macOS sandbox required.
set -uo pipefail
repo="${0:A:h}"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT
fixture_home="$fixture_root/home"
fixture_bin="$fixture_root/bin"
fixture_project="$fixture_root/project with spaces"
mkdir -p "$fixture_home" "$fixture_bin" "$fixture_project" "$fixture_root/T" "$fixture_root/empty"
passed=0 failed=0
check() {
  if "$@"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    print -u2 "FAIL: $*"
  fi
}
run() {
  (cd "$fixture_project" && /usr/bin/env HOME="$fixture_home" CODEX_HOME="$fixture_home/.codex" \
    PATH="$fixture_bin:/usr/bin:/bin" TMPDIR="$fixture_root/T" CAPTURE_PATH="$fixture_root/args" \
    PARAMS_PATH="$fixture_root/params" PROFILE_COPY="$fixture_root/profile" FAKE_STATUS=23 \
    /bin/zsh -f "$repo/rollcage" "$@")
}
cat > "$fixture_bin/sandbox-exec" <<'EOF'
#!/bin/sh
: > "$PARAMS_PATH"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -D) printf '%s\n' "$2" >> "$PARAMS_PATH"; shift 2 ;;
    -f) /bin/cp "$2" "$PROFILE_COPY"; shift 2 ;;
    --) shift; exec "$@" ;;
    *) exit 90 ;;
  esac
done
exit 91
EOF
chmod +x "$fixture_bin/sandbox-exec"
run --help > "$fixture_root/stdout" 2> "$fixture_root/stderr"
check test "$?" = 0
check /usr/bin/grep -q 'rollcage <cli>' "$fixture_root/stdout"
run > /dev/null 2> "$fixture_root/stderr"
check test "$?" = 2
run unknown > /dev/null 2> "$fixture_root/stderr"
check test "$?" = 2
check /usr/bin/grep -q 'unsupported CLI' "$fixture_root/stderr"
run codex > /dev/null 2> "$fixture_root/stderr"
check test "$?" = 127
check /usr/bin/grep -q 'codex not found' "$fixture_root/stderr"
/usr/bin/env PATH="$fixture_root/empty" /bin/zsh -f "$repo/rollcage" codex 2> "$fixture_root/stderr"
check test "$?" = 1
check /usr/bin/grep -q 'refusing to launch without Seatbelt' "$fixture_root/stderr"

for cli in claude codex pi omp opencode; do
  cat > "$fixture_bin/$cli" <<'EOF'
#!/bin/sh
printf '%s\0' "$ROLLCAGE_ACTIVE" "$ROLLCAGE_CLI" "$@" >> "$CAPTURE_PATH"
if [ "$ROLLCAGE_CLI" = opencode ]; then
  test "$OPENCODE_DISABLE_AUTOUPDATE" = 1 || exit 92
fi
if [ "$RELOAD_ONCE" = 1 ] && [ ! -f "$CAPTURE_PATH.reloaded" ]; then
  touch "$CAPTURE_PATH.reloaded" "$ROLLCAGE_RELOAD_SENTINEL"
fi
exit "$FAKE_STATUS"
EOF
  chmod +x "$fixture_bin/$cli"
done
args=('argument with spaces' '' --help '*' $'line\nbreak')
for cli in claude codex pi omp opencode; do
  rm -f "$fixture_root/args"
  run "$cli" "${args[@]}" > /dev/null 2> "$fixture_root/stderr"
  check test "$?" = 23
  prefix=()
  case "$cli" in
    claude) prefix=(--dangerously-skip-permissions --plugin-dir "$repo") ;;
    codex) prefix=(--dangerously-bypass-approvals-and-sandbox --config check_for_update_on_startup=false) ;;
    omp) prefix=(--auto-approve) ;;
    opencode) prefix=(--auto) ;;
  esac
  printf '%s\0' 1 "$cli" "${prefix[@]}" "${args[@]}" > "$fixture_root/expected"
  check /usr/bin/cmp "$fixture_root/expected" "$fixture_root/args"
  check /usr/bin/grep -q '^ROLLCAGE_DIR=' "$fixture_root/params"
  check /usr/bin/grep -q 'Final protections:' "$fixture_root/profile"
  remaining=("$fixture_root/T/"rollcage-*(N))
  check test "${#remaining}" = 0
done
# Claude keeps its reload loop and resumes only after the first invocation.
rm -f "$fixture_root/args"
RELOAD_ONCE=1 run claude "${args[@]}" > /dev/null 2> "$fixture_root/stderr"
check test "$?" = 23
printf '%s\0' 1 claude --dangerously-skip-permissions --plugin-dir "$repo" "${args[@]}" \
  1 claude --dangerously-skip-permissions --plugin-dir "$repo" --continue > "$fixture_root/expected"
check /usr/bin/cmp "$fixture_root/expected" "$fixture_root/args"
# Rejection must prevent execution entirely.
# A legacy filename must be ignored, even when its contents are invalid.
printf 'not-a-valid-directive\n' > "$fixture_project/.xclaude"
rm -f "$fixture_root/args"
run codex < /dev/null > /dev/null 2> "$fixture_root/stderr"
check test "$?" = 23
check test -f "$fixture_root/args"
mv "$fixture_project/.xclaude" "$fixture_project/.rollcage"
rm -f "$fixture_root/args"
run codex < /dev/null > /dev/null 2> "$fixture_root/stderr"
check test "$?" = 1
check test ! -f "$fixture_root/args"
# Broken config symlinks must not silently select the base-only policy.
rm -f "$fixture_project/.rollcage" "$fixture_root/args"
ln -s "$fixture_root/missing-project-rules" "$fixture_project/.rollcage"
run codex < /dev/null > /dev/null 2> "$fixture_root/stderr"
check test "$?" = 1
check /usr/bin/grep -q 'readable regular file' "$fixture_root/stderr"
check test ! -f "$fixture_root/args"
rm "$fixture_project/.rollcage"
ln -s "$fixture_root/missing-user-rules" "$fixture_home/.config/rollcage/config"
run codex < /dev/null > /dev/null 2> "$fixture_root/stderr"
check test "$?" = 1
check /usr/bin/grep -q 'readable regular file' "$fixture_root/stderr"
check test ! -f "$fixture_root/args"
print "$passed checks passed; $failed failed"
(( failed == 0 ))
