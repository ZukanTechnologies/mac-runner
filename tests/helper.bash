# Shared bats helpers for the lib/common.sh suites.
#
# The idiom throughout this repo (established by tests/agent-op-read.bats) is
# to stub the *external commands* on PATH rather than to mock shell functions:
# the code under test then runs exactly as it does on a host, and the suite
# stays runnable on the Linux CI box where `sw_vers`, `fdesetup` and `tart`
# do not exist at all.

# Create an executable stub named $1 in the test's bin dir whose body is $2.
# The body is written verbatim, so it can read $STUB_STATE_DIR to record calls.
mr_stub() {
  local name="$1" body="$2"
  mkdir -p "$TEST_TMP/bin"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$TEST_TMP/bin/$name"
  chmod +x "$TEST_TMP/bin/$name"
}

# Record every invocation of a stub so a test can assert it was NOT called
# (the preflight contract is "no change before the gates pass").
mr_stub_calls() {
  cat "$STUB_STATE_DIR/$1-calls" 2>/dev/null || echo 0
}

mr_common_setup() {
  TEST_TMP="$(mktemp -d)"
  export TEST_TMP
  export STUB_STATE_DIR="$TEST_TMP"
  mkdir -p "$TEST_TMP/bin"
  export PATH="$TEST_TMP/bin:$PATH"
  # Every knob the library reads from the environment starts unset, so a test
  # that forgets to set one fails loudly instead of inheriting the dev's shell.
  unset IMAGE_VERSION SLOTS RUNNER_EXTRA_LABELS FORCE GH_ORG MR_LAUNCH_AGENTS
  # shellcheck source=/dev/null
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
}

mr_common_teardown() {
  rm -rf "$TEST_TMP"
}
