#!/usr/bin/env bats
# ZUK-2153 — agent credential handling (FR-010): the JIT PAT is op-read at
# each cycle with retry ×3 + backoff, failures log distinguishable classes,
# and a fetch failure can never touch a VM (fetch precedes clone).

setup() {
  TEST_TMP="$(mktemp -d)"
  export STUB_STATE_DIR="$TEST_TMP"
  export ZUKAN_OP_TOKEN_FILE="$TEST_TMP/op-token"
  echo "sa-token" > "$ZUKAN_OP_TOKEN_FILE"
  export OP_RETRY_DELAY=0
  unset ZUKAN_GH_PAT STUB_OP_MODE

  mkdir -p "$TEST_TMP/bin"
  cat > "$TEST_TMP/bin/op" <<'STUB'
#!/usr/bin/env bash
count_file="$STUB_STATE_DIR/op-calls"
count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
echo "$count" > "$count_file"
mode="${STUB_OP_MODE:-success}"
if [[ "$mode" == "fail_then_success" && $count -ge 3 ]]; then mode=success; fi
case "$mode" in
  success)      echo "test-pat" ;;
  bad_token)    echo "(401) Unauthorized: invalid service account token" >&2; exit 1 ;;
  missing_item) echo "\"runner-jit-pat\" isn't an item in the \"mac-runner\" vault" >&2; exit 1 ;;
  *)            echo "error: connection refused" >&2; exit 1 ;;
esac
STUB
  chmod +x "$TEST_TMP/bin/op"
  export PATH="$TEST_TMP/bin:$PATH"

  # Sourcing (not executing) loads functions without entering the agent loop.
  # shellcheck source=/dev/null
  source "$BATS_TEST_DIRNAME/../agent/mobile-runner-agent.sh"
}

teardown() {
  rm -rf "$TEST_TMP"
}

op_calls() {
  cat "$STUB_STATE_DIR/op-calls" 2>/dev/null || echo 0
}

@test "ZUKAN_GH_PAT env override wins and never calls op (local debug path)" {
  export ZUKAN_GH_PAT="debug-pat"
  run resolve_zukan_gh_pat
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "debug-pat" ]
  [ "$(op_calls)" -eq 0 ]
}

@test "success path returns the credential from op in one call" {
  run resolve_zukan_gh_pat
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "test-pat" ]
  [ "$(op_calls)" -eq 1 ]
}

@test "transient failure retries and succeeds on attempt 3" {
  export STUB_OP_MODE=fail_then_success
  run resolve_zukan_gh_pat
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "test-pat" ]
  [ "$(op_calls)" -eq 3 ]
}

@test "persistent network failure exhausts 3 attempts and logs 'op unreachable'" {
  export STUB_OP_MODE=unreachable
  run resolve_zukan_gh_pat
  [ "$status" -eq 1 ]
  [ "$(op_calls)" -eq 3 ]
  [[ "$output" == *"op unreachable"* ]]
}

@test "invalid service-account token logs 'bad token' distinguishably" {
  export STUB_OP_MODE=bad_token
  run resolve_zukan_gh_pat
  [ "$status" -eq 1 ]
  [[ "$output" == *"bad token"* ]]
  [[ "$output" != *"op unreachable"* ]]
}

@test "missing vault item logs 'missing item' with the op reference" {
  export STUB_OP_MODE=missing_item
  run resolve_zukan_gh_pat
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing item"* ]]
  [[ "$output" == *"runner-jit-pat"* ]]
}

@test "missing token file fails fast, names the path, never calls op" {
  export ZUKAN_OP_TOKEN_FILE="$TEST_TMP/nonexistent"
  run resolve_zukan_gh_pat
  [ "$status" -eq 1 ]
  [[ "$output" == *"$TEST_TMP/nonexistent"* ]]
  [ "$(op_calls)" -eq 0 ]
}

@test "credential fetch precedes VM clone in the cycle (in-flight VM safety)" {
  agent="$BATS_TEST_DIRNAME/../agent/mobile-runner-agent.sh"
  # skip the function definition and comment lines; compare real call sites
  fetch_line="$(grep -n 'resolve_zukan_gh_pat' "$agent" | grep -vE '\(\)|^[0-9]+: *#' | head -1 | cut -d: -f1)"
  clone_line="$(grep -n 'tart clone' "$agent" | grep -vE '^[0-9]+: *#' | head -1 | cut -d: -f1)"
  [ -n "$fetch_line" ] && [ -n "$clone_line" ]
  [ "$fetch_line" -lt "$clone_line" ]
}
