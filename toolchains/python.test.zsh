# Python (pyenv and python.org Framework) toolchain sandbox tests
tc_setup python

tc_fixture_dir "${HOME}/.pyenv/shims"
tc_fixture_dir "${HOME}/.pyenv/versions"
tc_fixture_file "${HOME}/.pyenv/version" "3.12"

# ── Access ──
t "python: read ~/.pyenv"
expect_success "allowed" tc_sandboxed cat "${HOME}/.pyenv/version"

t "python: write ~/.pyenv/shims"
expect_success "allowed" tc_sandboxed touch "${HOME}/.pyenv/shims/test-write"
rm -f "${HOME}/.pyenv/shims/test-write"

t "python: write ~/.pyenv/versions"
expect_success "allowed" tc_sandboxed touch "${HOME}/.pyenv/versions/test-write"
rm -f "${HOME}/.pyenv/versions/test-write"

# ── Usability ──
# pyenv binary is at /opt/homebrew/bin (base profile exec)
# pyenv-managed pythons are at ~/.pyenv/versions/ (toolchain exec)

__pyenv_bin="$(command -v pyenv 2>/dev/null || echo "")"
if [[ -n "$__pyenv_bin" ]]; then
  t "pyenv: pyenv --version"
  expect_success "runs" tc_sandboxed "$__pyenv_bin" --version

  t "pyenv: pyenv versions"
  expect_success "list" tc_sandboxed "$__pyenv_bin" versions
fi

# Find the pyenv-managed python — this exercises the toolchain exec rule
# Try multiple patterns: pyenv may use symlinks or different directory structures
__pyenv_python="$(find "${HOME}/.pyenv/versions" -path "*/bin/python3" \( -type f -o -type l \) 2>/dev/null | head -1)"
# Also try python (without the 3 suffix)
if [[ -z "$__pyenv_python" ]]; then
  __pyenv_python="$(find "${HOME}/.pyenv/versions" -path "*/bin/python" \( -type f -o -type l \) 2>/dev/null | head -1)"
fi
# If find returned empty, try pyenv which
if [[ -z "$__pyenv_python" && -n "$__pyenv_bin" ]]; then
  __pyenv_python="$("$__pyenv_bin" which python3 2>/dev/null || "$__pyenv_bin" which python 2>/dev/null || echo "")"
fi

if [[ -n "$__pyenv_python" ]]; then
  t "python: pyenv python --version"
  expect_success "runs" tc_sandboxed "$__pyenv_python" --version

  t "python: pyenv python eval"
  expect_success "eval" tc_sandboxed "$__pyenv_python" -c "print('sandbox ok')"

  t "python: pyenv python import stdlib"
  expect_success "import" tc_sandboxed "$__pyenv_python" -c "import json; print(json.dumps({'ok': True}))"
else
  echo "SKIP: no pyenv-managed python3 found — skipping python exec tests" >&2
fi

# python.org's Current link resolves to its installed version before policy match.
__framework_python="/Library/Frameworks/Python.framework/Versions/Current/bin/python3"
if [[ -x "$__framework_python" ]]; then
  t "python: Framework python --version"
  expect_success "runs" tc_sandboxed "$__framework_python" --version

  t "python: Framework python stdlib and project output"
  expect_success "compute and write" tc_sandboxed "$__framework_python" -c \
    "import json, pathlib, ssl, sqlite3; value = 6 * 7; pathlib.Path('framework-result.json').write_text(json.dumps(value)); assert json.loads(pathlib.Path('framework-result.json').read_text()) == 42"
  rm -f "${PROJECT_DIR}/framework-result.json"

  t "python: Framework interpreter retains home isolation"
  expect_fail "blocked" tc_sandboxed "$__framework_python" -c \
    "from pathlib import Path; Path.home().joinpath('.ssh/known_hosts').read_bytes()"
else
  echo "SKIP: no python.org Framework interpreter found" >&2
fi

# ── Isolation ──
t "python: ~/.ssh blocked"
expect_fail "blocked" tc_sandboxed cat "${HOME}/.ssh/known_hosts"

tc_cleanup
