#!/bin/zsh
# Final protection enforcement for every CLI, including later grants and symlinks.
set -euo pipefail
repo="${0:A:h}"
if [[ "$(uname)" != Darwin ]] || ! command -v sandbox-exec >/dev/null; then
  print 'SKIP: macOS sandbox-exec required'
  exit 0
fi
# Keep the simulated home outside TMPDIR and PROJECT_DIR so cross-CLI read
# isolation is measured without a broad base grant covering the fixtures.
fixture_root="$(mktemp -d "${repo}/.rollcage-protection-test.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
fixture_home="$fixture_root/home"
project="$fixture_root/project"
control_targets="${fixture_root}/"'control "targets"\n'
mkdir -p "$fixture_home/.config/rollcage/packs" "$project" "$control_targets"
git -C "$project" init -q
resolved_tmp="$(readlink -f "${TMPDIR:-/private/tmp}")"
common_params=(-D "PROJECT_DIR=$project" -D "HOME=$fixture_home" -D "TMPDIR=$resolved_tmp"
  -D "CACHE_DIR=${resolved_tmp%/T*}/C" -D "VOLATILE_DIR=${resolved_tmp%/T*}/X"
  -D "ROLLCAGE_DIR=$repo" -D "OPENCODE_BIN=/usr/bin/true")
for key in OMP_CONFIG_ROOT OMP_AGENT_DIR OMP_DATA_ROOT OMP_STATE_ROOT OMP_CACHE_ROOT OMP_XDG_DATA_ROOT OMP_XDG_STATE_ROOT OMP_XDG_CACHE_ROOT; do
  common_params+=(-D "$key=$fixture_root/omp")
done
for cli in claude codex pi omp opencode; do
  mkdir -p "$fixture_home/.config/rollcage/trust/$cli/trusted.d"
  print fixture > "$fixture_home/.config/rollcage/trust/$cli/trusted"
done
cat > "$fixture_root/assemble.zsh" <<'EOF'
source "$1/rollcage.lib.zsh"
__rollcage_init "$2" "$1"
if [[ -f "$3/.rollcage" ]]; then
  __rollcage_trust "$3/.rollcage"
  __rollcage_check_pack_trusts "$3/.rollcage" <<< y >&2
fi
__rollcage_assemble "$3"
EOF
passed=0 failed=0
allowed() {
  if (cd "$project" && sandbox-exec "${common_params[@]}" -f "$fixture_root/profile.sb" -- "$@") > /dev/null 2> "$fixture_root/stderr"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    print -u2 "FAIL: expected allowed: $*"
    cat "$fixture_root/stderr" >&2
  fi
}
blocked() {
  if (cd "$project" && sandbox-exec "${common_params[@]}" -f "$fixture_root/profile.sb" -- "$@") > /dev/null 2> "$fixture_root/stderr"; then
    failed=$((failed + 1))
    print -u2 "FAIL: expected blocked: $*"
  else
    passed=$((passed + 1))
  fi
}
for cli in claude codex pi omp opencode; do
  print "=== $cli protections ==="
  # Confirm that only this CLI's trust store is readable with ordinary rules.
  rm -f "$project/.rollcage" "$fixture_home/.config/rollcage/config"
  /usr/bin/env HOME="$fixture_home" zsh -f "$fixture_root/assemble.zsh" "$repo" "$cli" "$project" > "$fixture_root/profile.sb"
  allowed /usr/bin/true
  allowed /bin/cat "$fixture_home/.config/rollcage/trust/$cli/trusted"
  for other in claude codex pi omp opencode; do
    [[ "$other" == "$cli" ]] && continue
    blocked /bin/cat "$fixture_home/.config/rollcage/trust/$other/trusted"
  done
  # Simulate an approved broad parent grant in user rules and a pack. Final
  # denies must win regardless of which generated layer grants the writes.
  printf 'allow-write %s\n' "$fixture_root" > "$fixture_home/.config/rollcage/config"
  printf 'allow-write %s\n' "$fixture_root" > "$fixture_home/.config/rollcage/packs/dev"
  printf 'pack dev\n' > "$project/.rollcage"
  /usr/bin/env HOME="$fixture_home" zsh -f "$fixture_root/assemble.zsh" "$repo" "$cli" "$project" > "$fixture_root/profile.sb"
  allowed /usr/bin/true
  allowed /usr/bin/touch "$project/ordinary-file"
  # Freezing ancestor entries must leave unrelated child state writable.
  allowed /bin/mkdir -p "$fixture_home/.config/unrelated-$cli"
  allowed /usr/bin/touch "$fixture_home/.config/unrelated-$cli/state"
  allowed /bin/rm "$fixture_home/.config/unrelated-$cli/state"
  blocked /bin/mv "$fixture_home/.config" "$fixture_home/.config-replaced"
  blocked /bin/mv "$project" "$fixture_root/project-replaced"
  for target in "$project/.rollcage" "$fixture_home/.config/rollcage/config" \
    "$fixture_home/.config/rollcage/packs/dev" "$fixture_home/.config/rollcage/trust/$cli/trusted"; do
    print replacement > "$project/replacement"
    blocked /bin/sh -c 'printf "injected\n" >> "$1"' sh "$target"
    blocked /bin/rm -f "$target"
    blocked /bin/mv -f "$target" "$project/moved-control"
    blocked /bin/mv -f "$project/replacement" "$target"
  done
  blocked /usr/bin/touch "$fixture_home/.config/rollcage/trust/$cli/trusted.d/new-snapshot"
  rm -f "$project/.rollcage"
  blocked /bin/sh -c 'printf "tool node\n" > "$1"' sh "$project/.rollcage"
  # Stowed configs and referenced packs can resolve outside their normal roots.
  rm -f "$fixture_home/.config/rollcage/config" "$fixture_home/.config/rollcage/packs/dev"
  printf 'allow-write %s\n' "$fixture_root" > "$control_targets/user"
  printf 'allow-write %s\n' "$fixture_root" > "$control_targets/pack"
  printf 'pack dev\n' > "$control_targets/project"
  ln -s "$control_targets/user" "$fixture_home/.config/rollcage/config"
  ln -s "$control_targets/pack" "$fixture_home/.config/rollcage/packs/dev"
  ln -s "$control_targets/project" "$project/.rollcage"
  /usr/bin/env HOME="$fixture_home" zsh -f "$fixture_root/assemble.zsh" "$repo" "$cli" "$project" > "$fixture_root/profile.sb"
  allowed /usr/bin/true
  blocked /bin/mv "$control_targets" "$fixture_root/control-replaced"
  for target in "$control_targets/"*; do
    blocked /bin/sh -c 'printf "injected\n" >> "$1"' sh "$target"
  done
  rm -f "$project/.rollcage" "$fixture_home/.config/rollcage/config" "$fixture_home/.config/rollcage/packs/dev"
  # Relocating the entire namespace must also protect other CLIs' trust state.
  namespace_target="$fixture_root/control namespace"
  mv "$fixture_home/.config/rollcage" "$namespace_target"
  ln -s "$namespace_target" "$fixture_home/.config/rollcage"
  printf 'allow-write %s\n' "$fixture_root" > "$namespace_target/config"
  /usr/bin/env HOME="$fixture_home" zsh -f "$fixture_root/assemble.zsh" "$repo" "$cli" "$project" > "$fixture_root/profile.sb"
  allowed /usr/bin/true
  for other in claude codex pi omp opencode; do
    blocked /bin/sh -c 'printf "injected\n" >> "$1"' sh "$namespace_target/trust/$other/trusted"
  done
  rm "$fixture_home/.config/rollcage"
  mv "$namespace_target" "$fixture_home/.config/rollcage"
  # Protect the physical intermediate pointer when two directories are symlinked.
  intermediate="$fixture_root/intermediate-config"
  mv "$fixture_home/.config" "$intermediate"
  mv "$intermediate/rollcage" "$namespace_target"
  ln -s "$namespace_target" "$intermediate/rollcage"
  ln -s "$intermediate" "$fixture_home/.config"
  /usr/bin/env HOME="$fixture_home" zsh -f "$fixture_root/assemble.zsh" "$repo" "$cli" "$project" > "$fixture_root/profile.sb"
  allowed /usr/bin/true
  blocked /bin/rm "$intermediate/rollcage"
  blocked /bin/mv "$intermediate/rollcage" "$fixture_root/replaced-pointer"
  rm "$fixture_home/.config" "$intermediate/rollcage"
  mv "$namespace_target" "$intermediate/rollcage"
  mv "$intermediate" "$fixture_home/.config"
done
print "$passed checks passed; $failed failed"
(( failed == 0 ))
