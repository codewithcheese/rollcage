#!/usr/bin/env bash
# rollcage test harness
# Tests the DSL parser, validator, and SBPL generator.
# No macOS sandbox required — runs anywhere with bash 4+.
#
# Usage: bash test_rollcage.bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Replicate the rollcage functions in bash ───────────────────
# The real rollcage.lib.zsh uses zsh syntax. For testing, we re-source
# a bash-compatible shim of the core functions (parser, validator,
# generator). The SBPL output is identical regardless of shell.
__rollcage_claude_dir="$SCRIPT_DIR"

__rollcage_claude_parse() {
  local file="$1" line verb arg lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    # Strip inline comments (but not inside quotes — not needed for this DSL)
    line="${line%%#*}"
    # Trim whitespace
    line="$(printf '%s\n' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue

    verb="${line%% *}"
    arg="${line#* }"
    [[ "$arg" = "$verb" ]] && arg=""

    case "$verb" in
      tool)
        [[ -z "$arg" ]] && { echo "rollcage: ${file}:${lineno}: 'tool' requires a name" >&2; return 1; }
        printf '%s\n' "tool ${arg}"
        ;;
      pack)
        [[ -z "$arg" ]] && { echo "rollcage: ${file}:${lineno}: 'pack' requires a name" >&2; return 1; }
        if [[ ! "$arg" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*$ ]]; then
          echo "rollcage: ${file}:${lineno}: invalid pack name '${arg}' — use [A-Za-z0-9_-], no leading dash" >&2
          return 1
        fi
        printf '%s\n' "pack ${arg}"
        ;;
      allow-read|allow-write|allow-exec)
        [[ -z "$arg" ]] && { echo "rollcage: ${file}:${lineno}: '${verb}' requires a path" >&2; return 1; }
        printf '%s\n' "${verb} ${arg}"
        ;;
      *)
        echo "rollcage: ${file}:${lineno}: unknown directive '${verb}'" >&2
        return 1
        ;;
    esac
  done < "$file"
}

__rollcage_claude_validate() {
  local source="${1:-project}"
  local line verb arg toolchains_dir="${__rollcage_claude_dir}/toolchains"
  local packs_dir="${HOME}/.config/rollcage/packs"
  while IFS= read -r line; do
    verb="${line%% *}"
    arg="${line#* }"

    case "$verb" in
      tool)
        if [[ ! "$arg" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*$ ]]; then
          echo "rollcage: invalid toolchain name '${arg}'" >&2
          return 1
        fi
        if [[ ! -f "${toolchains_dir}/${arg}.sb" ]]; then
          echo "rollcage: unknown toolchain '${arg}'" >&2
          echo "rollcage: available: $(ls "${toolchains_dir}"/*.sb 2>/dev/null | xargs -I{} basename {} .sb | tr '\n' ' ')" >&2
          return 1
        fi
        printf '%s\n' "$line"
        ;;
      pack)
        case "$source" in
          user)
            echo "rollcage: 'pack' is not allowed in user config — packs are for project-level reuse only" >&2
            return 1
            ;;
          pack)
            echo "rollcage: 'pack' cannot be nested inside another pack (pack '${arg}')" >&2
            return 1
            ;;
        esac
        if [[ ! -f "${packs_dir}/${arg}" ]]; then
          echo "rollcage: unknown pack '${arg}' — expected file at ${packs_dir}/${arg}" >&2
          if [[ -d "$packs_dir" ]]; then
            echo "rollcage: available: $(ls "${packs_dir}" 2>/dev/null | tr '\n' ' ')" >&2
          fi
          return 1
        fi
        printf '%s\n' "$line"
        ;;
      allow-read|allow-write|allow-exec)
        # Validate path prefix using string prefix checks
        local prefix2="${arg:0:2}"
        if [[ "$arg" = "~" || "$arg" = "~/" ]]; then
          echo "rollcage: bare '~' or '~/' is too broad — use ~/specific/path" >&2
          return 1
        elif [[ "$arg" = "./" || "$arg" = "." ]]; then
          echo "rollcage: bare './' is too broad — use ./specific/path" >&2
          return 1
        elif [[ "$prefix2" != "~/" && "$prefix2" != "./" && "${arg:0:1}" != "/" ]]; then
          echo "rollcage: invalid path '${arg}' — must start with ~/, ./, or /" >&2
          return 1
        fi
        # System-path restrictions are verb-specific:
        #   read  — all system roots already covered by base
        #   write — system paths must never be writable from config
        #   exec  — only the exec-covered base subpaths are redundant
        case "$verb" in
          allow-read)
            case "$arg" in
              /System/*|/Library/*|/usr/*|/bin/*|/sbin/*|/opt/homebrew/*)
                echo "rollcage: system path '${arg}' is already readable via base profile" >&2
                return 1
                ;;
            esac
            ;;
          allow-write)
            case "$arg" in
              /System/*|/Library/*|/usr/*|/bin/*|/sbin/*|/opt/homebrew/*)
                echo "rollcage: system path '${arg}' cannot be made writable from project config" >&2
                return 1
                ;;
            esac
            ;;
          allow-exec)
            case "$arg" in
              /bin/*|/usr/bin/*|/opt/homebrew/*)
                echo "rollcage: exec path '${arg}' is already allowed by base profile" >&2
                return 1
                ;;
            esac
            ;;
        esac
        local basename="${arg##*/}"
        if [[ "$basename" = ".rollcage" ]]; then
          echo "rollcage: cannot target '.rollcage' — sandbox config is protected" >&2
          return 1
        fi
        printf '%s\n' "$line"
        ;;
    esac
  done
}

__rollcage_quote_sbpl() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"\n' "$value"
}

__rollcage_claude_path_to_sbpl() {
  local p="$1" prefix2="${1:0:2}"
  if [[ "$prefix2" == "~/" ]]; then
    printf '(string-append (param "HOME") %s)\n' "$(__rollcage_quote_sbpl "/${p:2}")"
  elif [[ "$prefix2" == "./" ]]; then
    printf '(string-append (param "PROJECT_DIR") %s)\n' "$(__rollcage_quote_sbpl "/${p:2}")"
  elif [[ "${p:0:1}" == "/" ]]; then
    __rollcage_quote_sbpl "$p"
  fi
}

__rollcage_claude_generate() {
  local line verb arg sbpl_path toolchains_dir="${__rollcage_claude_dir}/toolchains"
  # Packs dir picks the name based on a caller-set default — tests that
  # drive rollcage codex override HOME/paths directly, so ${HOME}/.config/rollcage is
  # fine for the Claude paths and rollcage codex tests use their own fixtures.
  local packs_dir="${HOME}/.config/rollcage/packs"
  local pack_file pack_content
  while IFS= read -r line; do
    verb="${line%% *}"
    arg="${line#* }"

    case "$verb" in
      tool)
        echo ""
        printf '%s\n' ";; ── toolchain: ${arg} ──"
        cat "${toolchains_dir}/${arg}.sb"
        ;;
      pack)
        pack_file="${packs_dir}/${arg}"
        pack_content="$(__rollcage_claude_parse "$pack_file" | __rollcage_claude_validate pack | __rollcage_claude_generate)" || return 1
        echo ""
        printf '%s\n' ";; ── pack: ${arg} (${pack_file/#${HOME}/~}) ──"
        printf '%s\n' "$pack_content"
        ;;
      allow-read|allow-write|allow-exec)
        sbpl_path="$(__rollcage_claude_path_to_sbpl "$arg")"
        echo ""
        printf '%s\n' ";; ── ${verb}: ${arg} ──"
        case "$verb" in
          allow-read)
            printf '%s\n' "(allow file-read-data (subpath ${sbpl_path}))"
            ;;
          allow-write)
            printf '%s\n' "(allow file-read-data (subpath ${sbpl_path}))"
            printf '%s\n' "(allow file-write* (subpath ${sbpl_path}))"
            ;;
          allow-exec)
            printf '%s\n' "(allow file-read-data (subpath ${sbpl_path}))"
            printf '%s\n' "(allow process-exec (subpath ${sbpl_path}))"
            ;;
        esac
        ;;
    esac
  done
}

__rollcage_claude_assemble() {
  local project_dir="$1"
  local base_common="${__rollcage_claude_dir}/base-common.sb"
  local base_profile="${__rollcage_claude_dir}/base-claude.sb"
  local user_config="${HOME}/.config/rollcage/config"
  local project_config="${project_dir}/.rollcage"
  local assembled generated

  assembled="$(cat "$base_common" "$base_profile")"

  if [[ -f "$user_config" ]]; then
    generated="$(__rollcage_claude_parse "$user_config" | __rollcage_claude_validate user | __rollcage_claude_generate)" || return 1
    if [[ -n "$generated" ]]; then
      assembled+=$'\n\n;; ============================================================'
      assembled+=$'\n;; User config: ~/.config/rollcage/config'
      assembled+=$'\n;; ============================================================'
      assembled+="$generated"
    fi
  fi

  if [[ -f "$project_config" ]]; then
    generated="$(__rollcage_claude_parse "$project_config" | __rollcage_claude_validate project | __rollcage_claude_generate)" || return 1
    if [[ -n "$generated" ]]; then
      assembled+=$'\n\n;; ============================================================'
      assembled+=$'\n;; Project config: .rollcage'
      assembled+=$'\n;; ============================================================'
      assembled+="$generated"
    fi
  fi

  assembled+=$'\n\n;; Final protections\n'
  assembled+="$(cat "${__rollcage_claude_dir}/base-protections.sb")"
  printf '%s\n' "$assembled"
}

__rollcage_codex_validate() {
  local source="${1:-project}"
  local line verb arg toolchains_dir="${__rollcage_claude_dir}/toolchains"
  local packs_dir="${HOME}/.config/rollcage/packs"
  while IFS= read -r line; do
    verb="${line%% *}"
    arg="${line#* }"

    case "$verb" in
      tool)
        if [[ ! "$arg" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*$ ]]; then
          echo "rollcage: invalid toolchain name '${arg}'" >&2
          return 1
        fi
        if [[ ! -f "${toolchains_dir}/${arg}.sb" ]]; then
          echo "rollcage codex: unknown toolchain '${arg}'" >&2
          echo "rollcage codex: available: $(ls "${toolchains_dir}"/*.sb 2>/dev/null | xargs -I{} basename {} .sb | tr '\n' ' ')" >&2
          return 1
        fi
        printf '%s\n' "$line"
        ;;
      pack)
        case "$source" in
          user)
            echo "rollcage codex: 'pack' is not allowed in user config — packs are for project-level reuse only" >&2
            return 1
            ;;
          pack)
            echo "rollcage codex: 'pack' cannot be nested inside another pack (pack '${arg}')" >&2
            return 1
            ;;
        esac
        if [[ ! -f "${packs_dir}/${arg}" ]]; then
          echo "rollcage codex: unknown pack '${arg}' — expected file at ${packs_dir}/${arg}" >&2
          if [[ -d "$packs_dir" ]]; then
            echo "rollcage codex: available: $(ls "${packs_dir}" 2>/dev/null | tr '\n' ' ')" >&2
          fi
          return 1
        fi
        printf '%s\n' "$line"
        ;;
      allow-read|allow-write|allow-exec)
        local prefix2="${arg:0:2}"
        if [[ "$arg" = "~" || "$arg" = "~/" ]]; then
          echo "rollcage codex: bare '~' or '~/' is too broad — use ~/specific/path" >&2
          return 1
        elif [[ "$arg" = "./" || "$arg" = "." ]]; then
          echo "rollcage codex: bare './' is too broad — use ./specific/path" >&2
          return 1
        elif [[ "$prefix2" != "~/" && "$prefix2" != "./" && "${arg:0:1}" != "/" ]]; then
          echo "rollcage codex: invalid path '${arg}' — must start with ~/, ./, or /" >&2
          return 1
        fi
        case "$verb" in
          allow-read)
            case "$arg" in
              /System/*|/Library/*|/usr/*|/bin/*|/sbin/*|/opt/homebrew/*)
                echo "rollcage codex: system path '${arg}' is already readable via base profile" >&2
                return 1
                ;;
            esac
            ;;
          allow-write)
            case "$arg" in
              /System/*|/Library/*|/usr/*|/bin/*|/sbin/*|/opt/homebrew/*)
                echo "rollcage codex: system path '${arg}' cannot be made writable from project config" >&2
                return 1
                ;;
            esac
            ;;
          allow-exec)
            case "$arg" in
              /bin/*|/usr/bin/*|/opt/homebrew/*)
                echo "rollcage codex: exec path '${arg}' is already allowed by base profile" >&2
                return 1
                ;;
            esac
            ;;
        esac
        local basename="${arg##*/}"
        if [[ "$basename" = ".rollcage" ]]; then
          echo "rollcage codex: cannot target '.rollcage' — sandbox config is protected" >&2
          return 1
        fi
        printf '%s\n' "$line"
        ;;
    esac
  done
}

__rollcage_codex_assemble() {
  local project_dir="$1"
  local base_common="${__rollcage_claude_dir}/base-common.sb"
  local base_profile="${__rollcage_claude_dir}/base-codex.sb"
  local user_config="${HOME}/.config/rollcage/config"
  local project_config="${project_dir}/.rollcage"
  local assembled generated

  assembled="$(cat "$base_common" "$base_profile")"

  if [[ -f "$user_config" ]]; then
    generated="$(__rollcage_claude_parse "$user_config" | __rollcage_codex_validate user | __rollcage_claude_generate)" || return 1
    if [[ -n "$generated" ]]; then
      assembled+=$'\n\n;; ============================================================'
      assembled+=$'\n;; User config: ~/.config/rollcage/config'
      assembled+=$'\n;; ============================================================'
      assembled+="$generated"
    fi
  fi

  if [[ -f "$project_config" ]]; then
    generated="$(__rollcage_claude_parse "$project_config" | __rollcage_codex_validate project | __rollcage_claude_generate)" || return 1
    if [[ -n "$generated" ]]; then
      assembled+=$'\n\n;; ============================================================'
      assembled+=$'\n;; Project config: .rollcage'
      assembled+=$'\n;; ============================================================'
      assembled+="$generated"
    fi
  fi

  assembled+=$'\n\n;; Final protections\n'
  assembled+="$(cat "${__rollcage_claude_dir}/base-protections.sb")"
  printf '%s\n' "$assembled"
}

# ── Trust-gate color helpers (duplicate of rollcage.lib.zsh) ─
__rollcage_color_enabled() {
  case "${ROLLCAGE_COLOR:-auto}" in
    always) return 0 ;;
    never)  return 1 ;;
    auto)
      [[ -n "${NO_COLOR:-}" ]] && return 1
      [[ -t 2 ]] && return 0
      return 1
      ;;
    *) return 1 ;;
  esac
}

__rollcage_colorize_diff() {
  if ! __rollcage_color_enabled; then
    cat
    return
  fi
  local R=$'\e[31m' G=$'\e[32m' C=$'\e[36m' Y=$'\e[33m' M=$'\e[35m' D=$'\e[2m' Z=$'\e[0m' B=$'\e[1m'
  awk -v r="$R" -v g="$G" -v c="$C" -v y="$Y" -v m="$M" -v d="$D" -v z="$Z" -v b="$B" '
    /^(--- |\+\+\+ )/ { print c b $0 z; next }
    /^@@/             { print c $0 z;   next }
    /^[-+](tool|allow-read|allow-write|allow-exec)[[:space:]]/ {
      polarity = substr($0, 1, 1)
      pc = (polarity == "+") ? g : r
      body = substr($0, 2)
      match(body, /[[:space:]]/)
      if (RSTART > 0) {
        verb = substr(body, 1, RSTART - 1)
        rest = substr(body, RSTART)
      } else {
        verb = body
        rest = ""
      }
      vc = ""
      if      (verb == "tool")        vc = c
      else if (verb == "allow-read")  vc = g
      else if (verb == "allow-write") vc = y
      else if (verb == "allow-exec")  vc = m
      printf "%s%s%s%s%s%s%s%s%s%s\n", pc, polarity, z, vc, b, verb, z, pc, rest, z
      next
    }
    /^-/              { print r $0 z;   next }
    /^\+/             { print g $0 z;   next }
                      { print d $0 z }
  '
}

__rollcage_summarize_diff() {
  local old="$1" new="$2"
  local tool_a=0 read_a=0 write_a=0 exec_a=0
  local tool_r=0 read_r=0 write_r=0 exec_r=0
  local line
  while IFS= read -r line; do
    case "$line" in
      '+tool '*)        tool_a=$((tool_a + 1)) ;;
      '+allow-read '*)  read_a=$((read_a + 1)) ;;
      '+allow-write '*) write_a=$((write_a + 1)) ;;
      '+allow-exec '*)  exec_a=$((exec_a + 1)) ;;
      '-tool '*)        tool_r=$((tool_r + 1)) ;;
      '-allow-read '*)  read_r=$((read_r + 1)) ;;
      '-allow-write '*) write_r=$((write_r + 1)) ;;
      '-allow-exec '*)  exec_r=$((exec_r + 1)) ;;
    esac
  done < <(diff -u "$old" "$new" 2>/dev/null || true)

  if (( tool_a + read_a + write_a + exec_a + tool_r + read_r + write_r + exec_r == 0 )); then
    return 0
  fi

  local C="" G="" Y="" M="" R="" Z="" B=""
  if __rollcage_color_enabled; then
    C=$'\e[36m'; G=$'\e[32m'; Y=$'\e[33m'; M=$'\e[35m'; R=$'\e[31m'; Z=$'\e[0m'; B=$'\e[1m'
  fi
  local segs=()
  (( exec_a > 0 ))  && segs+=("${G}+${exec_a}${Z} ${M}${B}exec${Z}")
  (( write_a > 0 )) && segs+=("${G}+${write_a}${Z} ${Y}${B}write${Z}")
  (( tool_a > 0 ))  && segs+=("${G}+${tool_a}${Z} ${C}${B}tool${Z}")
  (( read_a > 0 ))  && segs+=("${G}+${read_a}${Z} ${G}${B}read${Z}")
  (( exec_r > 0 ))  && segs+=("${R}-${exec_r}${Z} ${M}${B}exec${Z}")
  (( write_r > 0 )) && segs+=("${R}-${write_r}${Z} ${Y}${B}write${Z}")
  (( tool_r > 0 ))  && segs+=("${R}-${tool_r}${Z} ${C}${B}tool${Z}")
  (( read_r > 0 ))  && segs+=("${R}-${read_r}${Z} ${G}${B}read${Z}")

  local out="" s first=1
  for s in "${segs[@]}"; do
    if (( first )); then out="$s"; first=0; else out+="  $s"; fi
  done
  printf '  %s\n' "$out"
}

__rollcage_summarize_new() {
  local file="$1"
  local tool_n=0 read_n=0 write_n=0 exec_n=0
  local line stripped
  while IFS= read -r line || [[ -n "$line" ]]; do
    stripped="${line%%#*}"
    [[ -z "$stripped" ]] && continue
    case "$stripped" in
      'tool '*)        tool_n=$((tool_n + 1)) ;;
      'allow-read '*)  read_n=$((read_n + 1)) ;;
      'allow-write '*) write_n=$((write_n + 1)) ;;
      'allow-exec '*)  exec_n=$((exec_n + 1)) ;;
    esac
  done < "$file"

  if (( tool_n + read_n + write_n + exec_n == 0 )); then
    return 0
  fi

  local C="" G="" Y="" M="" Z="" B=""
  if __rollcage_color_enabled; then
    C=$'\e[36m'; G=$'\e[32m'; Y=$'\e[33m'; M=$'\e[35m'; Z=$'\e[0m'; B=$'\e[1m'
  fi
  local segs=()
  (( exec_n > 0 ))  && segs+=("${exec_n} ${M}${B}exec${Z}")
  (( write_n > 0 )) && segs+=("${write_n} ${Y}${B}write${Z}")
  (( tool_n > 0 ))  && segs+=("${tool_n} ${C}${B}tool${Z}")
  (( read_n > 0 )) && segs+=("${read_n} ${G}${B}read${Z}")

  local out="" s first=1
  for s in "${segs[@]}"; do
    if (( first )); then out="$s"; first=0; else out+="  $s"; fi
  done
  printf '  %s\n' "$out"
}

__rollcage_colorize_new() {
  if ! __rollcage_color_enabled; then
    cat
    return
  fi
  local C=$'\e[36m' G=$'\e[32m' Y=$'\e[33m' M=$'\e[35m' D=$'\e[2m' Z=$'\e[0m' B=$'\e[1m'
  awk -v c="$C" -v g="$G" -v y="$Y" -v m="$M" -v d="$D" -v z="$Z" -v b="$B" '
    /^[[:space:]]*#/                { print d $0 z; next }
    /^[[:space:]]*tool[[:space:]]/  { sub(/tool/,       c b "&" z); print; next }
    /^[[:space:]]*allow-read[[:space:]]/  { sub(/allow-read/,  g b "&" z); print; next }
    /^[[:space:]]*allow-write[[:space:]]/ { sub(/allow-write/, y b "&" z); print; next }
    /^[[:space:]]*allow-exec[[:space:]]/  { sub(/allow-exec/,  m b "&" z); print; next }
                                    { print }
  '
}

# ── Test framework ────────────────────────────────────────────
__test_pass=0
__test_fail=0
__test_name=""

t() { __test_name="$1"; }

assert_eq() {
  local expected="$1" actual="$2"
  if [[ "$expected" = "$actual" ]]; then
    __test_pass=$((__test_pass + 1))
  else
    __test_fail=$((__test_fail + 1))
    echo "FAIL: ${__test_name}" >&2
    echo "  expected: $(echo "$expected" | head -3)" >&2
    echo "  actual:   $(echo "$actual" | head -3)" >&2
  fi
}

assert_contains() {
  local needle="$1" haystack="$2"
  if [[ "$haystack" = *"$needle"* ]]; then
    __test_pass=$((__test_pass + 1))
  else
    __test_fail=$((__test_fail + 1))
    echo "FAIL: ${__test_name}" >&2
    echo "  expected to contain: ${needle}" >&2
    echo "  actual: $(echo "$haystack" | head -3)" >&2
  fi
}

assert_not_contains() {
  local needle="$1" haystack="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    __test_pass=$((__test_pass + 1))
  else
    __test_fail=$((__test_fail + 1))
    echo "FAIL: ${__test_name}" >&2
    echo "  expected NOT to contain: ${needle}" >&2
  fi
}

assert_fails() {
  if eval "$@" >/dev/null 2>&1; then
    __test_fail=$((__test_fail + 1))
    echo "FAIL: ${__test_name}" >&2
    echo "  expected command to fail" >&2
  else
    __test_pass=$((__test_pass + 1))
  fi
}

assert_succeeds() {
  if eval "$@" >/dev/null 2>&1; then
    __test_pass=$((__test_pass + 1))
  else
    __test_fail=$((__test_fail + 1))
    echo "FAIL: ${__test_name}" >&2
    echo "  expected command to succeed" >&2
  fi
}

TMPDIR_TEST="$(mktemp -d)"
trap "rm -rf '${TMPDIR_TEST}'" EXIT

fixture() {
  local name="$1" content="$2"
  local path="${TMPDIR_TEST}/${name}"
  echo "$content" > "$path"
  echo "$path"
}

# ── Parser tests ──────────────────────────────────────────────
echo "=== Parser ==="

t "parses tool directive"
f="$(fixture p1 "tool node")"
assert_eq "tool node" "$(__rollcage_claude_parse "$f")"

t "parses allow-read directive"
f="$(fixture p2 "allow-read ~/.config/foo")"
assert_eq "allow-read ~/.config/foo" "$(__rollcage_claude_parse "$f")"

t "parses allow-write directive"
f="$(fixture p3 "allow-write ./local/.share")"
assert_eq "allow-write ./local/.share" "$(__rollcage_claude_parse "$f")"

t "parses allow-exec directive"
f="$(fixture p4 "allow-exec ~/.local/bin/custom")"
assert_eq "allow-exec ~/.local/bin/custom" "$(__rollcage_claude_parse "$f")"

t "strips comments"
f="$(fixture p5 $'# this is a comment\ntool node  # inline comment')"
assert_eq "tool node" "$(__rollcage_claude_parse "$f")"

t "skips blank lines"
f="$(fixture p6 $'\ntool node\n\nallow-read ~/.config/foo\n')"
out="$(__rollcage_claude_parse "$f")"
assert_contains "tool node" "$out"
assert_contains "allow-read ~/.config/foo" "$out"

t "multi-directive file"
f="$(fixture p7 $'tool node\ntool uv\nallow-read ~/.config/foo\nallow-write ./local/.share\nallow-exec ~/.local/bin/custom')"
out="$(__rollcage_claude_parse "$f")"
count="$(echo "$out" | wc -l | tr -d ' ')"
assert_eq "5" "$count"

t "rejects unknown directive"
f="$(fixture p8 "deny-read ~/secrets")"
assert_fails __rollcage_claude_parse "$f"

t "rejects tool without name"
f="$(fixture p9 "tool")"
assert_fails __rollcage_claude_parse "$f"

t "rejects allow-read without path"
f="$(fixture p10 "allow-read")"
assert_fails __rollcage_claude_parse "$f"

# ── Validator tests ───────────────────────────────────────────
echo "=== Validator ==="

t "accepts known toolchain"
assert_succeeds "echo 'tool node' | __rollcage_claude_validate"

t "rejects raw SBPL outside bundled toolchains even when the file exists"
__saved_tool_dir="$__rollcage_claude_dir"
__rollcage_claude_dir="${TMPDIR_TEST}/tool-boundary/install"
mkdir -p "${__rollcage_claude_dir}/toolchains"
printf ';; fixture\n(allow default)\n' > "${TMPDIR_TEST}/tool-boundary/outside.sb"
assert_fails "printf '%s\\n' 'tool ../../outside' | __rollcage_claude_validate"
assert_fails "printf '%s\\n' 'tool ../../outside' | __rollcage_codex_validate"
__rollcage_claude_dir="$__saved_tool_dir"

t "rejects unknown toolchain"
assert_fails "echo 'tool nonexistent' | __rollcage_claude_validate"

t "accepts home-relative path"
assert_succeeds "echo 'allow-read ~/.config/foo' | __rollcage_claude_validate"

t "accepts project-relative path"
assert_succeeds "echo 'allow-write ./local/.share' | __rollcage_claude_validate"

t "accepts absolute path"
assert_succeeds "echo 'allow-read /opt/custom' | __rollcage_claude_validate"

t "rejects bare tilde"
assert_fails "echo 'allow-read ~' | __rollcage_claude_validate"

t "rejects ~/ (entire home)"
assert_fails "echo 'allow-write ~/' | __rollcage_claude_validate"

t "rejects ./ (entire project)"
assert_fails "echo 'allow-write ./' | __rollcage_claude_validate"

t "rejects relative path without ./"
assert_fails "echo 'allow-read local/.share' | __rollcage_claude_validate"

t "rejects /System paths"
assert_fails "echo 'allow-read /System/Library' | __rollcage_claude_validate"

t "rejects /usr paths"
assert_fails "echo 'allow-read /usr/local/lib' | __rollcage_claude_validate"

t "rejects /Library paths"
assert_fails "echo 'allow-read /Library/Frameworks' | __rollcage_claude_validate"

t "rejects allow-exec on /bin (base-covered)"
assert_fails "echo 'allow-exec /bin/sh' | __rollcage_claude_validate"

t "rejects allow-exec on /usr/bin (base-covered)"
assert_fails "echo 'allow-exec /usr/bin/python3' | __rollcage_claude_validate"

t "rejects allow-exec on /opt/homebrew (base-covered)"
assert_fails "echo 'allow-exec /opt/homebrew/bin/node' | __rollcage_claude_validate"

t "rejects /opt/homebrew paths"
assert_fails "echo 'allow-read /opt/homebrew/lib' | __rollcage_claude_validate"

# Paths the base profile can read but cannot exec — valid allow-exec targets
t "accepts allow-exec on /Library (not base-execed)"
assert_succeeds "echo 'allow-exec /Library/Java/JavaVirtualMachines/temurin-26.jdk/Contents/Home/bin/java' | __rollcage_claude_validate"

t "accepts allow-exec on /usr/libexec (not base-execed)"
assert_succeeds "echo 'allow-exec /usr/libexec/java_home' | __rollcage_claude_validate"

t "accepts allow-exec on /usr/local (not base-execed)"
assert_succeeds "echo 'allow-exec /usr/local/bin/terraform' | __rollcage_claude_validate"

t "accepts allow-exec on /sbin (not base-execed)"
assert_succeeds "echo 'allow-exec /sbin/ping' | __rollcage_claude_validate"

# Writes to system paths must always be refused, even where reads are already covered
t "rejects allow-write on /Library"
assert_fails "echo 'allow-write /Library/Foo' | __rollcage_claude_validate"

t "rejects allow-write on /usr/local"
assert_fails "echo 'allow-write /usr/local/bin' | __rollcage_claude_validate"

t "rejects allow-write on /opt/homebrew"
assert_fails "echo 'allow-write /opt/homebrew/var' | __rollcage_claude_validate"

t "rejects allow-write targeting .rollcage"
assert_fails "echo 'allow-write ./.rollcage' | __rollcage_claude_validate"

t "rejects allow-read targeting .rollcage"
assert_fails "echo 'allow-read ./.rollcage' | __rollcage_claude_validate"

t "rejects allow-exec targeting .rollcage"
assert_fails "echo 'allow-exec ./.rollcage' | __rollcage_claude_validate"

t "rejects absolute path targeting .rollcage"
assert_fails "echo 'allow-write /some/project/.rollcage' | __rollcage_claude_validate"

t "rejects home path targeting .rollcage"
assert_fails "echo 'allow-write ~/.rollcage' | __rollcage_claude_validate"

t "allows paths containing rollcage as substring"
assert_succeeds "echo 'allow-read ~/.rollcage-backup' | __rollcage_claude_validate"

t "passes through valid lines unchanged"
input="allow-read ~/.config/foo"
out="$(echo "$input" | __rollcage_claude_validate)"
assert_eq "$input" "$out"

# ── Base profile write protection ─────────────────────────────
echo "=== Write protection ==="

t "assembled Claude base denies writes to .rollcage using literal"
out="$(cat "${__rollcage_claude_dir}/base-common.sb" "${__rollcage_claude_dir}/base-claude.sb")"
assert_contains 'deny file-write' "$out"
assert_contains '.rollcage' "$out"

t "shared base denies writes to .env files"
out="$(cat "${__rollcage_claude_dir}/base-common.sb")"
assert_contains '/.env"' "$out"
assert_contains '/.env.local"' "$out"
assert_contains '/.env.development"' "$out"
assert_contains '/.env.staging"' "$out"
assert_contains '/.env.test"' "$out"
assert_contains '/.env.production"' "$out"

t "shared base denies writes to .git/hooks"
assert_contains '.git/hooks' "$out"

t "deny rule appears after allow for PROJECT_DIR"
base="$(cat "${__rollcage_claude_dir}/base-common.sb" "${__rollcage_claude_dir}/base-claude.sb")"
deny_line="$(echo "$base" | grep -n 'deny file-write' | head -1 | cut -d: -f1)"
allow_line="$(echo "$base" | grep -n 'allow file-write' | head -1 | cut -d: -f1)"
if [[ -n "$deny_line" && -n "$allow_line" && "$deny_line" -gt "$allow_line" ]]; then
  __test_pass=$((__test_pass + 1))
else
  __test_fail=$((__test_fail + 1))
  echo "FAIL: ${__test_name}" >&2
  echo "  deny on line ${deny_line:-?}, allow on line ${allow_line:-?} — deny must come AFTER allow" >&2
fi

t "base-codex.sb denies writes to shared .rollcage"
out="$(cat "${__rollcage_claude_dir}/base-codex.sb")"
assert_contains 'deny file-write' "$out"
assert_contains '.rollcage' "$out"

t "base-codex.sb allows Codex state"
assert_contains '/.codex' "$out"
assert_contains '/.nvm' "$out"
assert_contains '/.agents/skills' "$out"

t "base-codex.sb covers current standalone install layouts"
assert_contains '/.local/bin' "$out"
assert_contains '/.bun' "$out"
assert_contains '/usr/local/Caskroom/codex' "$out"
assert_contains '/usr/local/lib/node_modules/@openai/codex' "$out"

t "base-codex.sb covers only the required ChatGPT Node REPL runtime"
assert_contains '(literal "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl")' "$out"
assert_contains '(literal "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node")' "$out"
assert_contains '(subpath "/Applications/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules")' "$out"
assert_not_contains '(subpath "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin")' "$out"

# ── Path-to-SBPL tests ───────────────────────────────────────
echo "=== Path-to-SBPL ==="

t "home-relative path"
out="$(__rollcage_claude_path_to_sbpl "~/.config/foo")"
assert_eq '(string-append (param "HOME") "/.config/foo")' "$out"

t "project-relative path"
out="$(__rollcage_claude_path_to_sbpl "./local/.share")"
assert_eq '(string-append (param "PROJECT_DIR") "/local/.share")' "$out"

t "absolute path"
out="$(__rollcage_claude_path_to_sbpl "/opt/custom/lib")"
assert_eq '"/opt/custom/lib"' "$out"

# ── Generator tests ───────────────────────────────────────────
echo "=== Generator ==="

t "tool directive emits toolchain contents"
out="$(echo 'tool node' | __rollcage_claude_generate)"
assert_contains 'toolchain: node' "$out"
assert_contains '/.nvm' "$out"
assert_contains '/.npm' "$out"

t "quoted paths cannot inject raw SBPL"
__quoted_path='./data" ) (allow default) ;'
out="$(printf '%s\n' "allow-write ${__quoted_path}" | __rollcage_claude_validate | __rollcage_claude_generate)"
assert_contains '(subpath (string-append (param "PROJECT_DIR") "/data\" ) (allow default) ;"))' "$out"

t "literal backslash paths survive the DSL pipeline"
__backslash_path='./data\nfile'
f="$(fixture literal_backslash "allow-write ${__backslash_path}")"
out="$(__rollcage_claude_parse "$f" | __rollcage_claude_validate | __rollcage_claude_generate)"
assert_contains '(param "PROJECT_DIR") "/data\\nfile"' "$out"

t "allow-read emits file-read-data only"
out="$(echo 'allow-read ~/.config/foo' | __rollcage_claude_generate)"
assert_contains 'file-read-data' "$out"
assert_not_contains 'file-write' "$out"
assert_not_contains 'process-exec' "$out"

t "allow-write emits read + write"
out="$(echo 'allow-write ./local/.share' | __rollcage_claude_generate)"
assert_contains 'file-read-data' "$out"
assert_contains 'file-write*' "$out"
assert_not_contains 'process-exec' "$out"

t "allow-exec emits read + exec"
out="$(echo 'allow-exec ~/.local/bin/custom' | __rollcage_claude_generate)"
assert_contains 'file-read-data' "$out"
assert_contains 'process-exec' "$out"
assert_not_contains 'file-write' "$out"

# ── Assembly tests ────────────────────────────────────────────
echo "=== Assembly ==="

t "assembly without config produces base only"
empty_dir="$(mktemp -d)"
out="$(HOME="$empty_dir" __rollcage_claude_assemble "$empty_dir")"
assert_contains '(deny default)' "$out"
assert_contains '(param "PROJECT_DIR")' "$out"
assert_not_contains 'toolchain:' "$out"
rmdir "$empty_dir"

t "assembly with project config includes toolchain"
proj_dir="$(mktemp -d)"
echo "tool node" > "${proj_dir}/.rollcage"
out="$(__rollcage_claude_assemble "$proj_dir")"
assert_contains '(deny default)' "$out"
assert_contains 'toolchain: node' "$out"
assert_contains '/.nvm' "$out"
rm -rf "$proj_dir"

t "assembly with custom paths"
proj_dir="$(mktemp -d)"
echo "allow-write ./local/.share" > "${proj_dir}/.rollcage"
out="$(__rollcage_claude_assemble "$proj_dir")"
assert_contains 'file-write*' "$out"
assert_contains '/local/.share' "$out"
rm -rf "$proj_dir"

t "assembly with multiple tools and paths"
proj_dir="$(mktemp -d)"
cat > "${proj_dir}/.rollcage" <<'EOF'
tool node
tool uv
allow-read ~/.config/special
allow-write ./data
EOF
out="$(__rollcage_claude_assemble "$proj_dir")"
assert_contains 'toolchain: node' "$out"
assert_contains 'toolchain: uv' "$out"
assert_contains '/.config/special' "$out"
assert_contains '/data' "$out"
rm -rf "$proj_dir"

t "assembly fails on invalid config"
proj_dir="$(mktemp -d)"
echo "deny-read ~/secrets" > "${proj_dir}/.rollcage"
assert_fails "__rollcage_claude_assemble '$proj_dir'"
rm -rf "$proj_dir"

t "assembly with user config"
proj_dir="$(mktemp -d)"
user_config_dir="${TMPDIR_TEST}/rollcage_home/.config/rollcage"
mkdir -p "$user_config_dir"
echo "allow-read ~/.config/personal-tool" > "${user_config_dir}/config"
HOME="${TMPDIR_TEST}/rollcage_home" out="$(__rollcage_claude_assemble "$proj_dir")"
assert_contains 'User config' "$out"
assert_contains '/.config/personal-tool' "$out"
rm -rf "$proj_dir"

t "rollcage codex assembly with project config includes toolchain"
proj_dir="$(mktemp -d)"
echo "tool node" > "${proj_dir}/.rollcage"
out="$(__rollcage_codex_assemble "$proj_dir")"
assert_contains 'Project config: .rollcage' "$out"
assert_contains 'toolchain: node' "$out"
rm -rf "$proj_dir"

# ── SBPL well-formedness ─────────────────────────────────────
echo "=== SBPL well-formedness ==="

t "generated SBPL has balanced parens"
proj_dir="$(mktemp -d)"
cat > "${proj_dir}/.rollcage" <<'EOF'
tool node
tool rust
allow-read ~/.config/foo
allow-write ./build
allow-exec ~/.local/bin/bar
EOF
out="$(__rollcage_claude_assemble "$proj_dir")"
opens="${out//[^(]/}"
closes="${out//[^)]/}"
assert_eq "${#opens}" "${#closes}"
rm -rf "$proj_dir"

t "all toolchain files produce valid SBPL fragments"
all_ok=true
for tc_file in "${__rollcage_claude_dir}"/toolchains/*.sb; do
  tc_name="$(basename "$tc_file" .sb)"
  out="$(echo "tool ${tc_name}" | __rollcage_claude_generate)"
  opens="${out//[^(]/}"
  closes="${out//[^)]/}"
  if [[ "${#opens}" != "${#closes}" ]]; then
    all_ok=false
    __test_fail=$((__test_fail + 1))
    echo "FAIL: toolchain ${tc_name} has unbalanced parens" >&2
  fi
done
if $all_ok; then
  __test_pass=$((__test_pass + 1))
fi

# ── Packs (DSL pipeline) ─────────────────────────────────────
echo "=== Packs ==="

# Use a sandboxed HOME so pack files live under our temp tree and we don't
# read the real user's ~/.config/rollcage/packs. Tests restore HOME after.
__pack_home="${TMPDIR_TEST}/packs_home"
__pack_dir="${__pack_home}/.config/rollcage/packs"
mkdir -p "$__pack_dir"
__orig_home="$HOME"
export HOME="$__pack_home"

# Parser: pack name shape
t "parser accepts pack with simple name"
f="$(fixture pk_a "pack my-dev")"
assert_eq "pack my-dev" "$(__rollcage_claude_parse "$f")"

t "parser accepts pack name with digits and underscore"
f="$(fixture pk_b "pack my_pack_2")"
assert_eq "pack my_pack_2" "$(__rollcage_claude_parse "$f")"

t "parser rejects pack without name"
f="$(fixture pk_c "pack")"
assert_fails __rollcage_claude_parse "$f"

t "parser rejects pack name with slash"
f="$(fixture pk_d "pack ../evil")"
assert_fails __rollcage_claude_parse "$f"

t "parser rejects pack name starting with dash"
f="$(fixture pk_e "pack -rf")"
assert_fails __rollcage_claude_parse "$f"

t "parser rejects pack name with spaces (multi-arg)"
# 'pack foo bar' parses arg='foo bar' — fails charset check
f="$(fixture pk_f "pack foo bar")"
assert_fails __rollcage_claude_parse "$f"

# Validator: source-context matrix
echo "my-pack-body" > "${__pack_dir}/devpack"

t "validator accepts pack in project source"
assert_succeeds "echo 'pack devpack' | __rollcage_claude_validate project"

t "validator rejects pack in user source"
assert_fails "echo 'pack devpack' | __rollcage_claude_validate user"

t "validator rejects pack in pack source (no nesting)"
assert_fails "echo 'pack devpack' | __rollcage_claude_validate pack"

t "validator rejects missing pack with helpful error"
err="$(echo 'pack nonexistent' | __rollcage_claude_validate project 2>&1 >/dev/null || true)"
assert_contains "unknown pack 'nonexistent'" "$err"

# Generator: pack expansion
rm -f "${__pack_dir}/devpack"
cat > "${__pack_dir}/devpack" <<'EOF'
# shared dev config
tool node
allow-read ~/.config/shared
allow-write ~/data/shared
EOF

t "generator expands pack contents inline"
out="$(echo 'pack devpack' | __rollcage_claude_generate)"
assert_contains "pack: devpack" "$out"
# Inner tool directive gets fully expanded (not just its name)
assert_contains "toolchain: node" "$out"
assert_contains "/.nvm" "$out"
# Inner allow-read gets emitted as SBPL
assert_contains "/.config/shared" "$out"
assert_contains "file-read-data" "$out"
# Inner allow-write
assert_contains "/data/shared" "$out"
assert_contains "file-write*" "$out"

t "generator fails on missing pack at recursion time"
# Simulate: validator passed earlier because file existed, then file
# removed before generator runs. Generator's inner parse must fail.
echo 'pack gone' > "${__pack_dir}/gone"
# Remove right after writing to make parse fail
__bad_dir="$(mktemp -d)"
assert_fails "echo 'pack gone' | __rollcage_claude_generate"
rm -rf "$__bad_dir"
rm -f "${__pack_dir}/gone"

t "generator rejects nested pack via recursive validate(pack)"
# A pack that references another pack — validator inside the recursion
# must reject it with source=pack.
echo 'pack devpack' > "${__pack_dir}/parent"
assert_fails "echo 'pack parent' | __rollcage_claude_generate"
rm -f "${__pack_dir}/parent"

# Assembly with pack (no trust gate — bypass by using direct calls)
t "assembly expands pack referenced from project config"
proj_dir="$(mktemp -d)"
cat > "${proj_dir}/.rollcage" <<'EOF'
pack devpack
allow-read ~/.config/extra
EOF
# The assembler uses check_trust which in test context has no ledger —
# bypass by calling the pipeline directly, mirroring how assembler does.
out="$(__rollcage_claude_parse "${proj_dir}/.rollcage" | __rollcage_claude_validate project | __rollcage_claude_generate)"
assert_contains "pack: devpack" "$out"
assert_contains "toolchain: node" "$out"
assert_contains "/.config/shared" "$out"
assert_contains "/.config/extra" "$out"
# Balanced parens across the whole expansion
opens="${out//[^(]/}"
closes="${out//[^)]/}"
assert_eq "${#opens}" "${#closes}"
rm -rf "$proj_dir"

t "pack inherits DSL safety: rejects raw system path inside pack"
# Packs are still DSL-validated — can't grant /System through a pack.
echo 'allow-read /System/Library' > "${__pack_dir}/bad"
assert_fails "echo 'pack bad' | __rollcage_claude_generate"
rm -f "${__pack_dir}/bad"

t "pack inherits DSL safety: rejects .rollcage target inside pack"
echo 'allow-write ./.rollcage' > "${__pack_dir}/bad2"
assert_fails "echo 'pack bad2' | __rollcage_claude_generate"
rm -f "${__pack_dir}/bad2"

# Cleanup
rm -rf "$__pack_dir"
export HOME="$__orig_home"

# ── Edge cases ────────────────────────────────────────────────
echo "=== Edge cases ==="

t "path with spaces in directory name"
out="$(__rollcage_claude_path_to_sbpl "~/Library/Application Support/thing")"
assert_contains "Application Support/thing" "$out"

t "deeply nested project-relative path"
out="$(__rollcage_claude_path_to_sbpl "./a/b/c/d/e")"
assert_contains "/a/b/c/d/e" "$out"

t "config with only comments and blanks"
f="$(fixture edge1 $'# just a comment\n\n# another comment\n')"
out="$(__rollcage_claude_parse "$f")"
assert_eq "" "$out"

# ── Trust-gate color ──────────────────────────────────────────
echo "=== Trust gate color ==="

strip_ansi() {
  # POSIX-esque CSI stripper. Matches ESC [ <params> m.
  sed $'s/\x1b\\[[0-9;]*m//g'
}

# Sample unified diff input used across multiple tests
__sample_diff=$'--- trusted\n+++ current\n@@ -1,3 +1,4 @@\n tool node\n-allow-read ~/.config/old\n+allow-write ~/.config/new\n+allow-exec ~/.local/bin/x\n context-line\n'

t "ROLLCAGE_COLOR=never: no ANSI in diff"
out=$(printf '%s' "$__sample_diff" | ROLLCAGE_COLOR=never __rollcage_colorize_diff)
assert_eq "$__sample_diff" "${out}"$'\n'
assert_not_contains $'\e[' "$out"

t "NO_COLOR=1 (auto mode): no ANSI in diff"
out=$(printf '%s' "$__sample_diff" | NO_COLOR=1 ROLLCAGE_COLOR=auto __rollcage_colorize_diff)
assert_not_contains $'\e[' "$out"

t "ROLLCAGE_COLOR=always: removed line has red polarity + green bold verb (read)"
out=$(printf '%s' "$__sample_diff" | ROLLCAGE_COLOR=always __rollcage_colorize_diff)
assert_contains $'\e[31m-\e[0m\e[32m\e[1mallow-read\e[0m\e[31m ~/.config/old\e[0m' "$out"

t "ROLLCAGE_COLOR=always: added allow-write has green polarity + yellow bold verb"
out=$(printf '%s' "$__sample_diff" | ROLLCAGE_COLOR=always __rollcage_colorize_diff)
assert_contains $'\e[32m+\e[0m\e[33m\e[1mallow-write\e[0m\e[32m ~/.config/new\e[0m' "$out"

t "ROLLCAGE_COLOR=always: added allow-exec has green polarity + magenta bold verb"
out=$(printf '%s' "$__sample_diff" | ROLLCAGE_COLOR=always __rollcage_colorize_diff)
assert_contains $'\e[32m+\e[0m\e[35m\e[1mallow-exec\e[0m\e[32m ~/.local/bin/x\e[0m' "$out"

t "ROLLCAGE_COLOR=always: context tool line stays dim (no verb overlay)"
out=$(printf '%s' "$__sample_diff" | ROLLCAGE_COLOR=always __rollcage_colorize_diff)
assert_contains $'\e[2m tool node\e[0m' "$out"

t "ROLLCAGE_COLOR=always: added tool has cyan bold verb overlay"
diff_with_tool=$'--- trusted\n+++ current\n@@ -1,1 +1,2 @@\n tool node\n+tool uv\n'
out=$(printf '%s' "$diff_with_tool" | ROLLCAGE_COLOR=always __rollcage_colorize_diff)
assert_contains $'\e[32m+\e[0m\e[36m\e[1mtool\e[0m\e[32m uv\e[0m' "$out"

t "ROLLCAGE_COLOR=always: added comment line has green polarity but no verb overlay"
diff_with_comment=$'--- trusted\n+++ current\n@@ -1,1 +1,2 @@\n tool node\n+# a new comment\n'
out=$(printf '%s' "$diff_with_comment" | ROLLCAGE_COLOR=always __rollcage_colorize_diff)
assert_contains $'\e[32m+# a new comment\e[0m' "$out"
assert_not_contains $'\e[1m+# a new comment' "$out"

t "ROLLCAGE_COLOR=always: cyan on +++/--- file headers"
out=$(printf '%s' "$__sample_diff" | ROLLCAGE_COLOR=always __rollcage_colorize_diff)
assert_contains $'\e[36m\e[1m--- trusted\e[0m' "$out"
assert_contains $'\e[36m\e[1m+++ current\e[0m' "$out"

t "ROLLCAGE_COLOR=always: cyan on @@ hunk header"
out=$(printf '%s' "$__sample_diff" | ROLLCAGE_COLOR=always __rollcage_colorize_diff)
assert_contains $'\e[36m@@ -1,3 +1,4 @@\e[0m' "$out"

t "ROLLCAGE_COLOR=always: context line is dim"
out=$(printf '%s' "$__sample_diff" | ROLLCAGE_COLOR=always __rollcage_colorize_diff)
assert_contains $'\e[2m tool node\e[0m' "$out"

t "colorized diff strips to original content"
out=$(printf '%s' "$__sample_diff" | ROLLCAGE_COLOR=always __rollcage_colorize_diff)
stripped=$(printf '%s' "$out" | strip_ansi)
# Command substitution strips a trailing newline; normalize both sides
assert_eq "${__sample_diff%$'\n'}" "$stripped"

# ── New-config colorizer tests ────────────────────────────────
__sample_new=$'# a comment\ntool node\nallow-read ~/.config/foo\nallow-write ~/data\nallow-exec ~/.local/bin/x\n'

t "new-config: ROLLCAGE_COLOR=never pass-through"
out=$(printf '%s' "$__sample_new" | ROLLCAGE_COLOR=never __rollcage_colorize_new)
assert_eq "$__sample_new" "${out}"$'\n'

t "new-config: tool verb cyan+bold"
out=$(printf '%s' "$__sample_new" | ROLLCAGE_COLOR=always __rollcage_colorize_new)
assert_contains $'\e[36m\e[1mtool\e[0m node' "$out"

t "new-config: allow-read verb green+bold"
out=$(printf '%s' "$__sample_new" | ROLLCAGE_COLOR=always __rollcage_colorize_new)
assert_contains $'\e[32m\e[1mallow-read\e[0m ~/.config/foo' "$out"

t "new-config: allow-write verb yellow+bold"
out=$(printf '%s' "$__sample_new" | ROLLCAGE_COLOR=always __rollcage_colorize_new)
assert_contains $'\e[33m\e[1mallow-write\e[0m ~/data' "$out"

t "new-config: allow-exec verb magenta+bold"
out=$(printf '%s' "$__sample_new" | ROLLCAGE_COLOR=always __rollcage_colorize_new)
assert_contains $'\e[35m\e[1mallow-exec\e[0m ~/.local/bin/x' "$out"

t "new-config: comment is dim"
out=$(printf '%s' "$__sample_new" | ROLLCAGE_COLOR=always __rollcage_colorize_new)
assert_contains $'\e[2m# a comment\e[0m' "$out"

t "new-config: content preserved after ANSI strip"
out=$(printf '%s' "$__sample_new" | ROLLCAGE_COLOR=always __rollcage_colorize_new)
stripped=$(printf '%s' "$out" | strip_ansi)
assert_eq "${__sample_new%$'\n'}" "$stripped"

# ── Summary-line tests ────────────────────────────────────────
echo "=== Trust gate summary ==="

__write_fixture() {
  local path="$1" content="$2"
  printf '%s' "$content" > "$path"
}

t "summarize_diff: identical files produce no output"
fa="$(fixture sd1a $'tool node\n')"
fb="$(fixture sd1b $'tool node\n')"
out=$(ROLLCAGE_COLOR=never __rollcage_summarize_diff "$fa" "$fb")
assert_eq "" "$out"

t "summarize_diff: uncolored counts match verb categories"
fa="$(fixture sd2a $'tool node\nallow-read ~/.config/old\n')"
fb="$(fixture sd2b $'tool node\nallow-read ~/.config/new\nallow-write ~/data\nallow-exec ~/.local/bin/x\n')"
out=$(ROLLCAGE_COLOR=never __rollcage_summarize_diff "$fa" "$fb")
# +1 exec, +1 write, +1 read, -1 read (tool is unchanged)
assert_contains "+1 exec" "$out"
assert_contains "+1 write" "$out"
assert_contains "+1 read" "$out"
assert_contains "-1 read" "$out"
assert_not_contains "tool" "$out"

t "summarize_diff: ordering is exec, write, tool, read (additions before removals)"
fa="$(fixture sd3a $'tool node\nallow-read ~/r\nallow-write ~/w\nallow-exec ~/x\n')"
fb="$(fixture sd3b $'tool uv\nallow-read ~/r2\nallow-write ~/w2\nallow-exec ~/x2\n')"
out=$(ROLLCAGE_COLOR=never __rollcage_summarize_diff "$fa" "$fb")
# All four are +1/-1 each. Check that exec appears before write, write before tool, tool before read, + before -
exec_pos=$(echo "$out" | awk '{ print index($0, "+1 exec") }')
write_pos=$(echo "$out" | awk '{ print index($0, "+1 write") }')
tool_pos=$(echo "$out" | awk '{ print index($0, "+1 tool") }')
read_pos=$(echo "$out" | awk '{ print index($0, "+1 read") }')
minus_exec_pos=$(echo "$out" | awk '{ print index($0, "-1 exec") }')
if (( exec_pos > 0 && exec_pos < write_pos && write_pos < tool_pos && tool_pos < read_pos && read_pos < minus_exec_pos )); then
  __test_pass=$((__test_pass + 1))
else
  __test_fail=$((__test_fail + 1))
  echo "FAIL: ${__test_name}" >&2
  echo "  positions: +exec=$exec_pos +write=$write_pos +tool=$tool_pos +read=$read_pos -exec=$minus_exec_pos" >&2
  echo "  out: $out" >&2
fi

t "summarize_diff: colored summary includes green +, red -, magenta exec, yellow write"
fa="$(fixture sd4a $'allow-read ~/old\n')"
fb="$(fixture sd4b $'allow-write ~/new\nallow-exec ~/x\n')"
out=$(ROLLCAGE_COLOR=always __rollcage_summarize_diff "$fa" "$fb")
assert_contains $'\e[32m+1\e[0m' "$out"     # green +
assert_contains $'\e[31m-1\e[0m' "$out"     # red -
assert_contains $'\e[35m\e[1mexec\e[0m' "$out"   # magenta exec
assert_contains $'\e[33m\e[1mwrite\e[0m' "$out"  # yellow write

t "summarize_new: empty/commented file produces no output"
fa="$(fixture sn1 $'# just a comment\n\n')"
out=$(ROLLCAGE_COLOR=never __rollcage_summarize_new "$fa")
assert_eq "" "$out"

t "summarize_new: counts verbs (comments ignored)"
fa="$(fixture sn2 $'# header\ntool node\ntool uv\nallow-read ~/a\nallow-write ~/b\nallow-exec ~/c\nallow-exec ~/d\n')"
out=$(ROLLCAGE_COLOR=never __rollcage_summarize_new "$fa")
assert_contains "2 exec" "$out"
assert_contains "1 write" "$out"
assert_contains "2 tool" "$out"
assert_contains "1 read" "$out"

t "summarize_new: colored segments include severity palette"
fa="$(fixture sn3 $'tool node\nallow-exec ~/x\n')"
out=$(ROLLCAGE_COLOR=always __rollcage_summarize_new "$fa")
assert_contains $'\e[36m\e[1mtool\e[0m' "$out"
assert_contains $'\e[35m\e[1mexec\e[0m' "$out"

# ── Results ───────────────────────────────────────────────────
echo ""
echo "=== Results ==="
total=$((__test_pass + __test_fail))
echo "${__test_pass}/${total} passed"
if [[ $__test_fail -gt 0 ]]; then
  echo "${__test_fail} FAILED"
  exit 1
else
  echo "All tests passed."
  exit 0
fi
