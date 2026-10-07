# Metal compiler cache sandbox tests
tc_setup metal
tc_fixture_dir "${CACHE_DIR}/com.apple.metalfe"

# Exercise extension issuance itself: a cache write does not prove that the
# compiler service can receive an extension. The SPI declaration and free()
# ownership follow WebKit's SandboxSPI.h and SandboxExtensionCocoa.mm:
# https://github.com/WebKit/WebKit/blob/main/Source/WTF/wtf/spi/darwin/SandboxSPI.h
__metal_source="${PROJECT_DIR}/metal-extension-test.c"
__metal_bin="${PROJECT_DIR}/metal-extension-test"
__metal_base="${PROJECT_DIR}/metal-base-test.sb"
tc_fixture_file "$__metal_source"
tc_fixture_file "$__metal_bin"
tc_fixture_file "$__metal_base"
cat > "$__metal_source" <<'EOF'
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern char *sandbox_extension_issue_file(const char *, const char *, uint32_t);

int main(int argc, char **argv) {
    if (argc != 4) return 2;
    int expect_allowed = strcmp(argv[1], "allow") == 0;
    char *token = sandbox_extension_issue_file(argv[2], argv[3], 0);
    if (token) {
        free(token);
        if (expect_allowed) return 0;
        fprintf(stderr, "extension unexpectedly issued for %s\n", argv[3]);
        return 1;
    }
    if (!expect_allowed && (errno == EPERM || errno == EACCES)) return 0;
    perror("sandbox_extension_issue_file");
    return 1;
}
EOF
cat "${SCRIPT_DIR}/base-common.sb" "${SCRIPT_DIR}/base-claude.sb" > "$__metal_base"

__metal_with_base() {
  # tc_sandboxed uses this dynamically scoped profile path with the same params.
  local __tc_profile_path="$__metal_base"
  tc_sandboxed "$@"
}

t "metal: compile extension issuance probe"
if /usr/bin/clang -Wall -Wextra -Werror "$__metal_source" -lsandbox -o "$__metal_bin"; then
  __test_pass=$((__test_pass + 1))

  t "metal: base profile cannot issue compiler cache extensions"
  expect_success "permission denied" __metal_with_base "$__metal_bin" deny \
    com.apple.app-sandbox.read-write "${CACHE_DIR}/com.apple.metalfe"

  t "metal: toolchain permits compiler cache extensions"
  expect_success "extension issued" tc_sandboxed "$__metal_bin" allow \
    com.apple.app-sandbox.read-write "${CACHE_DIR}/com.apple.metalfe"

  t "metal: extensions outside compiler cache remain blocked"
  expect_success "permission denied" tc_sandboxed "$__metal_bin" deny \
    com.apple.app-sandbox.read-write "$CACHE_DIR"

  t "metal: other extension classes remain blocked"
  expect_success "permission denied" tc_sandboxed "$__metal_bin" deny \
    com.apple.app-sandbox.read "${CACHE_DIR}/com.apple.metalfe"
else
  __test_fail=$((__test_fail + 1))
  echo "FAIL: ${__test_name} — could not compile extension issuance probe" >&2
fi

t "metal: cache remains writable by child processes"
expect_success "allowed" tc_sandboxed /bin/sh -c \
  "touch '${CACHE_DIR}/com.apple.metalfe/rollcage-claude-metal-test-$$' && rm '${CACHE_DIR}/com.apple.metalfe/rollcage-claude-metal-test-$$'"

t "metal: ~/.ssh remains blocked"
expect_fail "blocked" tc_sandboxed cat "${HOME}/.ssh/known_hosts"

tc_cleanup
