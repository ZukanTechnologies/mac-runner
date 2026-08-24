#!/usr/bin/env bats
# ZUK-2164 (T018) — the converge steps in lib/install-main.sh.
#
# The plan scopes the acting half to shellcheck plus a manual acceptance run,
# but these two steps get real tests anyway: between them they restart live CI
# slots and replace the script a running agent is executing. Getting either
# wrong costs a job (or a host), and both are drivable against stubbed
# launchctl/tart without touching the machine.

load helper

setup() {
  mr_common_setup

  export MR_INSTALL_ROOT="$TEST_TMP/opt/zukan"
  export MR_LAUNCH_AGENTS="$TEST_TMP/LaunchAgents"
  mkdir -p "$MR_INSTALL_ROOT" "$MR_LAUNCH_AGENTS"

  # launchctl: records every call so the test can assert what was asked of it.
  # `print` answers "is this slot loaded?" — STUB_LAUNCHCTL_PRINT_RC=1 models a
  # slot that is not loaded (a fresh host).
  mr_stub launchctl '
    printf "%s\n" "$*" >> "$STUB_STATE_DIR/launchctl.log"
    case "$1" in
      print) exit "${STUB_LAUNCHCTL_PRINT_RC:-0}" ;;
    esac
    exit 0'
  mr_stub tart 'echo "[]"'

  # shellcheck source=/dev/null
  MR_SOURCE_ONLY=1 source "$BATS_TEST_DIRNAME/../lib/install-main.sh"
  mr_summary_reset
}

teardown() {
  mr_common_teardown
}

launchctl_log() { cat "$STUB_STATE_DIR/launchctl.log" 2>/dev/null || true; }

seed_legacy_slot() {
  local slot="$1"
  cat > "${MR_LAUNCH_AGENTS}/com.zukan.mobile-runner-agent.slot${slot}.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.zukan.mobile-runner-agent.slot${slot}</string>
  <key>EnvironmentVariables</key><dict>
    <key>SLOT</key><string>${slot}</string>
    <key>ZUKAN_GH_PAT</key><string>ghp_0000000000000000000000000000AAAAAAAA</string>
  </dict>
</dict></plist>
EOF
}

# --- slot converge, fresh host ---------------------------------------------

@test "fresh: SLOTS=2 writes and loads two slot plists" {
  export STUB_LAUNCHCTL_PRINT_RC=1
  run mr_converge_slots 2 ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1
  [ "$status" -eq 0 ]
  [ -f "${MR_LAUNCH_AGENTS}/com.zukan.mobile-runner-agent.slot1.plist" ]
  [ -f "${MR_LAUNCH_AGENTS}/com.zukan.mobile-runner-agent.slot2.plist" ]
  [[ "$(launchctl_log)" == *"bootstrap"* ]]
}

@test "fresh: the written plists carry the pinned image and no credential key" {
  export STUB_LAUNCHCTL_PRINT_RC=1
  mr_converge_slots 1 ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1
  run cat "${MR_LAUNCH_AGENTS}/com.zukan.mobile-runner-agent.slot1.plist"
  [[ "$output" == *"ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1"* ]]
  [[ "$output" != *"<key>ZUKAN_GH_PAT</key>"* ]]
  [[ "$output" != *"{{"* ]]
}

@test "fresh: RUNNER_EXTRA_LABELS reaches the plist" {
  export STUB_LAUNCHCTL_PRINT_RC=1
  export RUNNER_EXTRA_LABELS="xcode-26.6"
  mr_converge_slots 1 ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1
  run cat "${MR_LAUNCH_AGENTS}/com.zukan.mobile-runner-agent.slot1.plist"
  [[ "$output" == *"xcode-26.6"* ]]
}

# --- idempotency (SC-003) ---------------------------------------------------

@test "idempotent: a second run with nothing changed touches no slot" {
  export STUB_LAUNCHCTL_PRINT_RC=1
  mr_converge_slots 2 ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1

  # Second pass: plists match and launchctl now reports both slots loaded.
  export STUB_LAUNCHCTL_PRINT_RC=0
  : > "$STUB_STATE_DIR/launchctl.log"
  mr_summary_reset
  run mr_converge_slots 2 ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1
  [ "$status" -eq 0 ]
  [[ "$(launchctl_log)" != *"bootstrap"* ]]
  [[ "$(launchctl_log)" != *"bootout"* ]]
}

@test "idempotent: a second run reports nothing changed" {
  export STUB_LAUNCHCTL_PRINT_RC=1
  mr_converge_slots 1 ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1
  export STUB_LAUNCHCTL_PRINT_RC=0
  mr_summary_reset
  mr_converge_slots 1 ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1
  run mr_summary_changed_anything
  [ "$status" -ne 0 ]
}

@test "upgrade: a new pin re-renders and reloads the slot" {
  export STUB_LAUNCHCTL_PRINT_RC=1
  mr_converge_slots 1 ghcr.io/zukantechnologies/zukan-mobile-runner:2026.07.4
  export STUB_LAUNCHCTL_PRINT_RC=0
  : > "$STUB_STATE_DIR/launchctl.log"
  run mr_converge_slots 1 ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1
  [ "$status" -eq 0 ]
  [[ "$(launchctl_log)" == *"bootstrap"* ]]
  run cat "${MR_LAUNCH_AGENTS}/com.zukan.mobile-runner-agent.slot1.plist"
  [[ "$output" == *"2026.08.1"* ]]
  [[ "$output" != *"2026.07.4"* ]]
}

# --- slot reduction (US2-AC4) ----------------------------------------------

@test "reduce: SLOTS=1 unloads and deletes slot 2 rather than leaving it running" {
  export STUB_LAUNCHCTL_PRINT_RC=1
  mr_converge_slots 2 ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1
  : > "$STUB_STATE_DIR/launchctl.log"
  mr_summary_reset

  run mr_converge_slots 1 ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1
  [ "$status" -eq 0 ]
  [ ! -f "${MR_LAUNCH_AGENTS}/com.zukan.mobile-runner-agent.slot2.plist" ]
  [ -f "${MR_LAUNCH_AGENTS}/com.zukan.mobile-runner-agent.slot1.plist" ]
  [[ "$(launchctl_log)" == *"bootout"*"slot2"* ]]
}

# --- legacy migration (US2-AC3, the live host) ------------------------------

@test "migrate: a PAT-bearing plist is unloaded, replaced, and the secret is gone" {
  seed_legacy_slot 1
  export STUB_LAUNCHCTL_PRINT_RC=1
  run mr_converge_slots 1 ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1
  [ "$status" -eq 0 ]
  run cat "${MR_LAUNCH_AGENTS}/com.zukan.mobile-runner-agent.slot1.plist"
  [[ "$output" != *"ghp_0000000000000000000000000000AAAAAAAA"* ]]
  [[ "$output" != *"<key>ZUKAN_GH_PAT</key>"* ]]
}

@test "migrate: no credential is left anywhere under LaunchAgents afterwards" {
  seed_legacy_slot 1
  seed_legacy_slot 2
  export STUB_LAUNCHCTL_PRINT_RC=1
  mr_converge_slots 2 ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1
  # This is the contract's postcondition 2, checked the way it is written there.
  run grep -rl "ghp_" "$MR_LAUNCH_AGENTS"
  [ "$status" -ne 0 ]
}

@test "migrate: the legacy slot is booted out before being replaced" {
  # Rewriting the plist under a loaded agent without unloading it first leaves
  # launchd running the old definition — PAT and all — until the next reboot.
  seed_legacy_slot 1
  export STUB_LAUNCHCTL_PRINT_RC=1
  mr_converge_slots 1 ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1
  [[ "$(launchctl_log)" == *"bootout"*"slot1"* ]]
}

# --- agent script converge --------------------------------------------------

@test "agent: the script is installed at the stable exec path" {
  run mr_converge_agent_script
  [ "$status" -eq 0 ]
  [ -x "${MR_INSTALL_ROOT}/mobile-runner-agent.sh" ]
  run cmp -s "$BATS_TEST_DIRNAME/../agent/mobile-runner-agent.sh" "${MR_INSTALL_ROOT}/mobile-runner-agent.sh"
  [ "$status" -eq 0 ]
}

@test "agent: an unchanged script is left alone on a re-run" {
  mr_converge_agent_script
  mr_summary_reset
  mr_converge_agent_script
  run mr_summary_changed_anything
  [ "$status" -ne 0 ]
}

@test "agent: an update replaces the file by rename, never in place" {
  # bash reads a script incrementally as it runs. Overwriting the agent in
  # place splices new bytes into the process that is running a CI job right
  # now; a rename gives the new content a new inode and leaves that process
  # reading the old one until the slot converge restarts it.
  printf '#!/usr/bin/env bash\n# stale\n' > "${MR_INSTALL_ROOT}/mobile-runner-agent.sh"
  local before
  before="$(ls -i "${MR_INSTALL_ROOT}/mobile-runner-agent.sh" | awk '{print $1}')"

  run mr_converge_agent_script
  [ "$status" -eq 0 ]

  local after
  after="$(ls -i "${MR_INSTALL_ROOT}/mobile-runner-agent.sh" | awk '{print $1}')"
  [ "$before" != "$after" ]
}

@test "agent: no temp file is left behind" {
  printf '#!/usr/bin/env bash\n# stale\n' > "${MR_INSTALL_ROOT}/mobile-runner-agent.sh"
  mr_converge_agent_script
  run bash -c "ls '${MR_INSTALL_ROOT}'/*.new.* 2>/dev/null"
  [ "$status" -ne 0 ]
}

# --- in-flight guard wiring -------------------------------------------------

@test "guard: an idle host is not made to wait" {
  mr_stub tart 'echo "[]"'
  run mr_count_running_ci_vms
  [ "$output" = "0" ]
  run mr_wait_for_idle
  [ "$status" -eq 0 ]
}

@test "guard: a running CI VM is counted" {
  mr_stub tart 'echo "[{\"Source\":\"local\",\"Name\":\"ci-mini-1-1712\",\"State\":\"running\"}]"'
  run mr_count_running_ci_vms
  [ "$output" = "1" ]
}

@test "guard: FORCE=1 proceeds through a running job and says what it is doing" {
  mr_stub tart 'echo "[{\"Source\":\"local\",\"Name\":\"ci-mini-1-1712\",\"State\":\"running\"}]"'
  export FORCE=1
  run mr_wait_for_idle
  [ "$status" -eq 0 ]
  [[ "$output" == *"terminating"* ]]
}

@test "guard: without FORCE a busy host gives up rather than killing the job" {
  mr_stub tart 'echo "[{\"Source\":\"local\",\"Name\":\"ci-mini-1-1712\",\"State\":\"running\"}]"'
  mr_stub sleep 'exit 0'
  export MR_INFLIGHT_TIMEOUT_S=30
  run mr_wait_for_idle
  [ "$status" -eq 30 ]
  [[ "$output" == *"FORCE=1"* ]]
}

# --- verify postconditions (contract "Guarantees" 2 and 3) ------------------

@test "verify: a leftover credential in a plist fails the check" {
  seed_legacy_slot 1
  run mr_verify_no_credentials_at_rest
  [ "$status" -ne 0 ]
  [[ "$output" == *"credential key"* ]]
}

@test "verify: a stray token value anywhere under LaunchAgents fails the check" {
  # Not in a plist the slot scanner would look at — the concern is a token
  # sitting on disk at all, whatever file someone left it in.
  printf 'ghp_0000000000000000000000000000AAAAAAAA\n' > "${MR_LAUNCH_AGENTS}/notes.txt"
  run mr_verify_no_credentials_at_rest
  [ "$status" -ne 0 ]
  [[ "$output" == *"token value"* ]]
}

@test "verify: a converged host passes the credential check" {
  export STUB_LAUNCHCTL_PRINT_RC=1
  mr_converge_slots 1 ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1
  run mr_verify_no_credentials_at_rest
  [ "$status" -eq 0 ]
}

@test "verify: a token file with loose permissions fails the check" {
  export MR_TOKEN_FILE="$TEST_TMP/op-token"
  printf 'tok\n' > "$MR_TOKEN_FILE"
  chmod 644 "$MR_TOKEN_FILE"
  run mr_verify_no_credentials_at_rest
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected -rw-------"* ]]
}

@test "verify: a 0600 token file passes the check" {
  export MR_TOKEN_FILE="$TEST_TMP/op-token"
  printf 'tok\n' > "$MR_TOKEN_FILE"
  chmod 600 "$MR_TOKEN_FILE"
  run mr_verify_no_credentials_at_rest
  [ "$status" -eq 0 ]
}

@test "verify: a slot above SLOTS is reported as a leftover" {
  export STUB_LAUNCHCTL_PRINT_RC=1
  mr_converge_slots 2 ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1
  run mr_verify_no_leftovers 1 2026.08.1
  [ "$status" -ne 0 ]
  [[ "$output" == *"above SLOTS=1"* ]]
}

@test "verify: a superseded image warns but does not fail the run" {
  # Tart prunes its own OCI cache LRU and documents no manual eviction, so a
  # cache entry we could not delete is disk Tart reclaims later — not a broken
  # host. A leftover SLOT is a different matter (next test).
  mr_stub tart 'echo "[{\"Source\":\"OCI\",\"Name\":\"ghcr.io/zukantechnologies/zukan-mobile-runner:2026.07.4\",\"State\":\"stopped\"}]"'
  run mr_verify_no_leftovers 0 2026.08.1
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026.07.4"* ]]
  [[ "$output" == *"[warn]"* ]]
}

@test "verify: a fully converged host reports no leftovers" {
  export STUB_LAUNCHCTL_PRINT_RC=1
  mr_converge_slots 2 ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1
  mr_stub tart 'echo "[{\"Source\":\"OCI\",\"Name\":\"ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1\",\"State\":\"stopped\"}]"'
  run mr_verify_no_leftovers 2 2026.08.1
  [ "$status" -eq 0 ]
}

@test "converge: the plist BASE_IMAGE is a clonable registry reference" {
  # The end-to-end shape of the codex finding: what lands in launchd must be
  # something `tart clone` can resolve on a host that never built the image.
  export STUB_LAUNCHCTL_PRINT_RC=1
  mr_converge_slots 1 "$(mr_base_image_ref 2026.08.1)"
  run cat "${MR_LAUNCH_AGENTS}/com.zukan.mobile-runner-agent.slot1.plist"
  [[ "$output" == *"<string>ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1</string>"* ]]
  [[ "$output" != *"<string>zukan-mobile-runner-2026.08.1</string>"* ]]
}

# --- token file handling (FR-009) -------------------------------------------

@test "token: written owner-only, atomically, with no temp file left behind" {
  export MR_TOKEN_FILE="$TEST_TMP/config/op-token"
  run mr_write_token "sa-token-value"
  [ "$status" -eq 0 ]
  [ "$(ls -l "$MR_TOKEN_FILE" | cut -c1-10)" = "-rw-------" ]
  [ "$(cat "$MR_TOKEN_FILE")" = "sa-token-value" ]
  run bash -c "ls '$TEST_TMP/config'/*.new.* 2>/dev/null"
  [ "$status" -ne 0 ]
}

@test "token: replacing an existing loose-permission file ends owner-only" {
  export MR_TOKEN_FILE="$TEST_TMP/config/op-token"
  mkdir -p "$TEST_TMP/config"
  printf 'old\n' > "$MR_TOKEN_FILE"
  chmod 644 "$MR_TOKEN_FILE"
  mr_write_token "new-token"
  [ "$(ls -l "$MR_TOKEN_FILE" | cut -c1-10)" = "-rw-------" ]
  [ "$(cat "$MR_TOKEN_FILE")" = "new-token" ]
}

@test "token: an unwritable directory fails instead of reporting success" {
  export MR_TOKEN_FILE="/proc/nonexistent-dir/op-token"
  run mr_write_token "sa-token-value"
  [ "$status" -ne 0 ]
}

# --- org runner lookup paginates (stale JIT entries accumulate) -------------

@test "runners: an online host runner on page 1 is found" {
  mr_stub curl 'printf "{\"runners\":[{\"name\":\"mobile-runner-mymac-1-1712\",\"status\":\"online\"}]}"'
  run mr_host_runner_registered fake-pat mymac
  [ "$status" -eq 0 ]
}

@test "runners: a STALE OFFLINE entry from a previous install does not count" {
  # Single-job JIT registrations are ephemeral and a VM killed mid-job leaves
  # an offline entry behind, so a host that has ever worked keeps entries
  # under its own name prefix forever. Accepting those would pass
  # verification instantly on a host whose new agent never registers.
  mr_stub curl 'printf "{\"runners\":[{\"name\":\"mobile-runner-mymac-1-1600\",\"status\":\"offline\"}]}"'
  run mr_host_runner_registered fake-pat mymac
  [ "$status" -ne 0 ]
}

@test "runners: a live runner alongside stale offline ones is found" {
  mr_stub curl 'printf "{\"runners\":[{\"name\":\"mobile-runner-mymac-1-1600\",\"status\":\"offline\"},{\"name\":\"mobile-runner-mymac-2-1712\",\"status\":\"online\"}]}"'
  run mr_host_runner_registered fake-pat mymac
  [ "$status" -eq 0 ]
}

@test "runners: another host's online runner is not ours" {
  mr_stub curl 'printf "{\"runners\":[{\"name\":\"mobile-runner-otherhost-1-1712\",\"status\":\"online\"}]}"'
  run mr_host_runner_registered fake-pat mymac
  [ "$status" -ne 0 ]
}

@test "runners: a host runner on page 2 is found — the listing is paginated" {
  # Single-job JIT registrations are ephemeral and a VM killed mid-job leaves
  # an offline entry, so the org listing accumulates stale runners. Checking
  # only the first 100 would call a healthy host failed (exit 40).
  # Match on "&page=N": the URL also contains "per_page=100", so a bare
  # "page=1" glob matches EVERY page (per_page=100 contains page=100 contains
  # page=1) and the stub would answer page 1 forever.
  mr_stub curl '
    case "$*" in
      *"&page=1"*)
        printf "{\"runners\":["
        i=0; while [ $i -lt 100 ]; do
          [ $i -gt 0 ] && printf ","
          printf "{\"name\":\"mobile-runner-otherhost-1-%d\"}" "$i"
          i=$((i+1))
        done
        printf "]}" ;;
      *"&page=2"*)
        printf "{\"runners\":[{\"name\":\"mobile-runner-mymac-1-1712\",\"status\":\"online\"}]}" ;;
    esac'
  run mr_host_runner_registered fake-pat mymac
  [ "$status" -eq 0 ]
}

@test "runners: a short page ends the search instead of paging forever" {
  mr_stub curl 'printf "{\"runners\":[{\"name\":\"mobile-runner-otherhost-1-1\"}]}"'
  run mr_host_runner_registered fake-pat mymac
  [ "$status" -ne 0 ]
}

@test "runners: an API failure is not mistaken for 'registered'" {
  mr_stub curl 'exit 22'
  run mr_host_runner_registered fake-pat mymac
  [ "$status" -ne 0 ]
}

# --- the guard must not read "cannot tell" as "idle" ------------------------

@test "guard: an unreadable tart listing is not counted as zero" {
  # 0 is the answer that tells the guard it is safe to restart the slots. A
  # broken or transiently failing tart must not produce it.
  mr_stub tart 'exit 2'
  run mr_count_running_ci_vms
  [ "$status" -ne 0 ]
}

@test "guard: empty tart output is also 'unknown', not 'idle'" {
  mr_stub tart 'printf ""'
  run mr_count_running_ci_vms
  [ "$status" -ne 0 ]
}

@test "guard: an unreadable listing retries, then FAILS CLOSED" {
  # The guard exists to avoid killing a running CI job. "I cannot tell" is
  # exactly when proceeding is unsafe: stopping costs a re-run, guessing wrong
  # costs somebody's job.
  mr_stub tart 'exit 2'
  mr_stub sleep 'exit 0'
  run mr_wait_for_idle
  [ "$status" -eq 30 ]
  [[ "$output" == *"retrying"* ]]
  [[ "$output" == *"refused rather than done blind"* ]]
}

@test "guard: FORCE=1 is the documented override for an unreadable listing" {
  mr_stub tart 'exit 2'
  mr_stub sleep 'exit 0'
  export FORCE=1
  run mr_wait_for_idle
  [ "$status" -eq 0 ]
  [[ "$output" == *"FORCE=1"* ]]
}

@test "guard: FORCE=1 actually stops and deletes the in-flight VMs" {
  # It used to only PRINT that it was terminating them. On an otherwise
  # converged host nothing else restarts a slot, so the install reported
  # success while the VM kept running.
  mr_stub tart '
    printf "%s\n" "$*" >> "$STUB_STATE_DIR/tart.log"
    case "$1" in
      list) echo "[{\"Source\":\"local\",\"Name\":\"ci-mini-1-1712\",\"Running\":true,\"State\":\"running\"}]" ;;
    esac
    exit 0'
  export FORCE=1
  run mr_wait_for_idle
  [ "$status" -eq 0 ]
  local log
  log="$(cat "$STUB_STATE_DIR/tart.log")"
  [[ "$log" == *"stop ci-mini-1-1712"* ]]
  [[ "$log" == *"delete ci-mini-1-1712"* ]]
}

@test "guard: without FORCE nothing is terminated" {
  mr_stub tart '
    printf "%s\n" "$*" >> "$STUB_STATE_DIR/tart.log"
    case "$1" in
      list) echo "[{\"Source\":\"local\",\"Name\":\"ci-mini-1-1712\",\"Running\":true,\"State\":\"running\"}]" ;;
    esac
    exit 0'
  mr_stub sleep 'exit 0'
  export MR_INFLIGHT_TIMEOUT_S=30
  run mr_wait_for_idle
  [ "$status" -eq 30 ]
  local log
  log="$(cat "$STUB_STATE_DIR/tart.log")"
  [[ "$log" != *"delete"* ]]
}

@test "guard: a listing that recovers on retry is read normally" {
  mr_stub tart '
    n_file="$STUB_STATE_DIR/tart-calls"
    n=$(( $(cat "$n_file" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$n_file"
    [ "$n" -lt 2 ] && exit 2
    echo "[]"'
  mr_stub sleep 'exit 0'
  run mr_wait_for_idle
  [ "$status" -eq 0 ]
  [[ "$output" != *"refused rather than done blind"* ]]
}

@test "image: an unreadable df refuses the pull instead of starting it blind" {
  # This gates a tens-of-GB download; an unreadable `df` is not permission.
  mr_stub tart 'echo "[]"'
  mr_stub df 'exit 1'
  run mr_converge_image 2026.08.1
  [ "$status" -eq 11 ]
  [[ "$output" == *"refused rather than started blind"* ]]
}

@test "guard: a long wait reports progress instead of looking hung" {
  # The contract asks for a countdown; a silent 45-minute wait is
  # indistinguishable from a hang.
  mr_stub tart 'echo "[{\"Source\":\"local\",\"Name\":\"ci-mini-1-1712\",\"Running\":true,\"State\":\"running\"}]"'
  mr_stub sleep 'exit 0'
  export MR_INFLIGHT_TIMEOUT_S=600
  run mr_wait_for_idle
  [ "$status" -eq 30 ]
  [[ "$output" == *"min left before giving up"* ]]
}

# --- render before mutate: a failure must not strip a working host ---------

@test "atomic: a render failure leaves the legacy plist in place and loaded" {
  # The regression. Converge used to delete the legacy plists first and render
  # each replacement as it went, so a render failure partway through left the
  # host with its old agents unloaded and deleted and no new ones — on the live
  # host, mobile CI silently stops — while the error claimed nothing had been
  # changed.
  seed_legacy_slot 1
  export STUB_LAUNCHCTL_PRINT_RC=1
  # An XML-unsafe label is the cheapest way to make rendering fail.
  export RUNNER_EXTRA_LABELS="a&b"

  run mr_converge_slots 1 ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1
  [ "$status" -eq 30 ]

  # The host is exactly as it was.
  [ -f "${MR_LAUNCH_AGENTS}/com.zukan.mobile-runner-agent.slot1.plist" ]
  grep -q "ZUKAN_GH_PAT" "${MR_LAUNCH_AGENTS}/com.zukan.mobile-runner-agent.slot1.plist"
  [[ "$(launchctl_log)" != *"bootout"* ]]
}

@test "atomic: the render-failure message is true about what happened" {
  seed_legacy_slot 1
  export RUNNER_EXTRA_LABELS="a&b"
  run mr_converge_slots 1 ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1
  [[ "$output" == *"Nothing on this host has been changed"* ]]
}

@test "atomic: slot 2 failing to render does not disturb slot 1 either" {
  # Rendering is all-or-nothing across slots, not per slot.
  seed_legacy_slot 1
  seed_legacy_slot 2
  export STUB_LAUNCHCTL_PRINT_RC=1
  export RUNNER_EXTRA_LABELS="a<b"
  run mr_converge_slots 2 ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1
  [ "$status" -eq 30 ]
  grep -q "ZUKAN_GH_PAT" "${MR_LAUNCH_AGENTS}/com.zukan.mobile-runner-agent.slot1.plist"
  grep -q "ZUKAN_GH_PAT" "${MR_LAUNCH_AGENTS}/com.zukan.mobile-runner-agent.slot2.plist"
  [[ "$(launchctl_log)" != *"bootout"* ]]
}

@test "atomic: no staging directory is left behind on success or failure" {
  export STUB_LAUNCHCTL_PRINT_RC=1
  mr_converge_slots 1 ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1
  local after_ok
  after_ok="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' -newer "$TEST_TMP" -type d 2>/dev/null | wc -l | tr -d ' ')"

  export RUNNER_EXTRA_LABELS="a&b"
  run mr_converge_slots 1 ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1
  [ "$status" -eq 30 ]
  local after_fail
  after_fail="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' -newer "$TEST_TMP" -type d 2>/dev/null | wc -l | tr -d ' ')"
  [ "$after_fail" -le "$after_ok" ]
}
