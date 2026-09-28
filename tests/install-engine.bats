#!/usr/bin/env bats
# The wrapper contract: pin an engine, prove its bytes, and hand it one
# environment per slot.
#
# This repo implements no runner loop. What it owns is the mapping from Zukan's
# opinions to the engine's inputs, and the order in which slots are converged.
# Both are drivable against a stubbed engine without touching a Mac.

load helper

setup() {
  mr_common_setup

  export MR_INSTALL_ROOT="$TEST_TMP/opt/zukan"
  export MR_LAUNCH_AGENTS="$TEST_TMP/LaunchAgents"
  export HOME="$TEST_TMP/home"
  mkdir -p "$MR_INSTALL_ROOT" "$MR_LAUNCH_AGENTS" "$HOME"

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
  MR_INSTALL_PAT="ghp_installtimeonly"
}

teardown() { mr_common_teardown; }

launchctl_log() { cat "$STUB_STATE_DIR/launchctl.log" 2>/dev/null || true; }

# A stand-in for troymccabe/setup. Records the environment it was handed, and
# produces the two artifacts the real engine produces and this repo reads back:
# a config.env recording its inputs, and a launchd plist at its label.
# STUB_ENGINE_FAIL=<slot>|all makes that slot's run fail.
stub_engine() {
  cat > "$MR_ENGINE_DEST" <<'ENGINE'
#!/usr/bin/env bash
printf '%s\n' "--- run ---" >> "$STUB_STATE_DIR/engine.env"
for k in GH_ORG RUNNER_GROUP SHARED_LABEL EXTRA_LABELS BASE_IMAGE RUNNER_VERSION \
         REQUIRE_XCODE OP_ITEM_REF OP_TOKEN_FILE LAUNCHD_LABEL CONFIG_DIR \
         VM_PREFIX VM_MEMORY_MB VM_CPU_COUNT HOST_RESERVE_MB GH_PAT; do
  eval "v=\${$k-<unset>}"
  printf '%s=%s\n' "$k" "$v" >> "$STUB_STATE_DIR/engine.env"
done
fail="${STUB_ENGINE_FAIL:-}"
if [ -n "$fail" ]; then
  case "$LAUNCHD_LABEL" in
    *"slot${fail}") exit 30 ;;
  esac
  [ "$fail" = "all" ] && exit 30
fi
mkdir -p "$CONFIG_DIR"
for k in GH_ORG RUNNER_GROUP SHARED_LABEL EXTRA_LABELS BASE_IMAGE RUNNER_VERSION \
         REQUIRE_XCODE OP_ITEM_REF OP_TOKEN_FILE VM_PREFIX VM_MEMORY_MB \
         VM_CPU_COUNT HOST_RESERVE_MB; do
  eval "v=\${$k-}"
  printf '%s="%s"\n' "$k" "$v" >> "$CONFIG_DIR/config.env"
done
mkdir -p "$MR_LAUNCH_AGENTS"
cat > "${MR_LAUNCH_AGENTS}/${LAUNCHD_LABEL}.plist" <<P
<plist version="1.0"><dict>
  <key>Label</key><string>${LAUNCHD_LABEL}</string>
  <key>EnvironmentVariables</key><dict>
    <key>CONFIG_DIR</key><string>${CONFIG_DIR}</string>
  </dict>
</dict></plist>
P
exit 0
ENGINE
  chmod 755 "$MR_ENGINE_DEST"
  : > "$STUB_STATE_DIR/engine.env"
}

engine_env() { cat "$STUB_STATE_DIR/engine.env" 2>/dev/null || true; }
engine_runs() { grep -c -- "--- run ---" "$STUB_STATE_DIR/engine.env" 2>/dev/null || echo 0; }

seed_legacy_slot() {
  cat > "${MR_LAUNCH_AGENTS}/com.zukan.mobile-runner-agent.slot${1}.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.zukan.mobile-runner-agent.slot${1}</string>
  <key>EnvironmentVariables</key><dict>
    <key>ZUKAN_GH_PAT</key><string>ghp_0000000000000000000000000000AAAAAAAA</string>
  </dict>
</dict></plist>
EOF
}

IMG="zukan-mobile-runner-2026.08.1"
RV="2.337.0"

# --- the slot -> engine mapping ---------------------------------------------

@test "each slot gets its own label, config dir and VM prefix" {
  local one two
  one="$(mr_slot_env 1 "$IMG" "$RV")"
  two="$(mr_slot_env 2 "$IMG" "$RV")"
  [[ "$one" == *"VM_PREFIX=ephem-s1-"* ]] || { echo "$one"; return 1; }
  [[ "$two" == *"VM_PREFIX=ephem-s2-"* ]] || { echo "$two"; return 1; }
  [[ "$one" == *"LAUNCHD_LABEL=com.zukan.mobile-runner-agent.slot1"* ]] || return 1
  [[ "$two" == *"LAUNCHD_LABEL=com.zukan.mobile-runner-agent.slot2"* ]] || return 1
  [[ "$one" == *"CONFIG_DIR=${HOME}/.gha-runner/slot1"* ]] || return 1
  [[ "$two" == *"CONFIG_DIR=${HOME}/.gha-runner/slot2"* ]] || return 1
}

@test "VM prefixes are disjoint — overlapping ones destroy each other's jobs" {
  # Not merely different: the engine reaps with startswith, so one prefix must
  # never be a prefix of another.
  local p1 p2
  p1="$(mr_vm_prefix 1)"; p2="$(mr_vm_prefix 2)"
  [ "$p1" != "$p2" ] || return 1
  case "$p2" in "$p1"*) echo "$p2 starts with $p1"; return 1 ;; esac
  case "$p1" in "$p2"*) echo "$p1 starts with $p2"; return 1 ;; esac
}

@test "the slot environment never carries a credential" {
  # GH_PAT is install-time only and is passed separately, so it can never be
  # recorded as one of this slot's persistent inputs.
  local env; env="$(mr_slot_env 1 "$IMG" "$RV")"
  [[ "$env" != *"GH_PAT="* ]] || { echo "GH_PAT in slot env"; return 1; }
  [[ "$env" == *"OP_ITEM_REF=op://"* ]] || { echo "no vault reference"; return 1; }
}

@test "a mobile image without Xcode is a broken image, not a legitimate one" {
  [[ "$(mr_slot_env 1 "$IMG" "$RV")" == *"REQUIRE_XCODE=1"* ]]
}

@test "capability labels are never asserted — the engine probes them" {
  export RUNNER_EXTRA_LABELS="xcode-26.6,macos-major-26,image-2026.07.4,maestro"
  local env; env="$(mr_slot_env 1 "$IMG" "$RV")"
  [[ "$env" == *"EXTRA_LABELS=maestro"* ]] || { echo "$env"; return 1; }
  [[ "$env" != *"xcode-26.6"* ]]      || { echo "asserted xcode-*"; return 1; }
  [[ "$env" != *"macos-major-26"* ]]  || { echo "asserted macos-major-*"; return 1; }
  [[ "$env" != *"image-2026.07.4"* ]] || { echo "asserted image-*"; return 1; }
}

@test "probed-namespace labels are matched case-insensitively" {
  export RUNNER_EXTRA_LABELS="Xcode-26.6,IMAGE-x,keep-me"
  [ "$(mr_extra_labels)" = "keep-me" ] || { echo "got '$(mr_extra_labels)'"; return 1; }
}

@test "dropped labels are reported, not silently discarded" {
  export RUNNER_EXTRA_LABELS="xcode-26.6,maestro"
  [[ "$(mr_dropped_labels)" == *"xcode-26.6"* ]] || return 1
  [[ "$(mr_dropped_labels)" != *"maestro"* ]]    || return 1
}

@test "whitespace around an extra label does not leak into the engine" {
  export RUNNER_EXTRA_LABELS="maestro, node-22 "
  [ "$(mr_extra_labels)" = "maestro,node-22" ] || { echo "got '$(mr_extra_labels)'"; return 1; }
}

@test "the fleet label workflows route on is present" {
  [[ "$(mr_slot_env 1 "$IMG" "$RV")" == *"SHARED_LABEL=mobile-runner"* ]]
}

# --- engine fetch and verification ------------------------------------------

@test "the engine is fetched at the pinned commit and installed at a stable path" {
  local commit; commit="$(mr_read_ref_pin "$BATS_TEST_DIRNAME/../SETUP_VERSION")"
  mr_stub curl "printf '%s\n' \"\$*\" >> \"\$STUB_STATE_DIR/curl.log\"
                cat \"$BATS_TEST_DIRNAME/../SETUP_VERSION\" >/dev/null
                out=\"\"; prev=\"\"; for a in \"\$@\"; do [ \"\$prev\" = \"-o\" ] && out=\"\$a\"; prev=\"\$a\"; done
                printf 'engine-bytes\n' > \"\$out\""
  # Checksum of exactly what the stub serves.
  printf 'engine-bytes\n' > "$TEST_TMP/expected"
  mr_file_sha256 "$TEST_TMP/expected" > "$TEST_TMP/sha"
  export MR_SETUP_SHA_FILE="$TEST_TMP/SETUP_SHA256"
  cp "$TEST_TMP/sha" "$MR_SETUP_SHA_FILE"

  run mr_converge_engine
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -x "$MR_ENGINE_DEST" ] || { echo "engine not installed"; return 1; }
  grep -q "$commit" "$STUB_STATE_DIR/curl.log" || { echo "did not fetch the pinned commit"; return 1; }
}

@test "a checksum mismatch refuses to run the engine and installs nothing" {
  mr_stub curl 'prev=""; for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
                printf "tampered\n" > "$out"'
  run mr_converge_engine
  [ "$status" -ne 0 ] || { echo "ran a mismatched engine"; return 1; }
  [[ "$output" == *"checksum mismatch"* ]] || { echo "$output"; return 1; }
  [ ! -e "$MR_ENGINE_DEST" ] || { echo "installed it anyway"; return 1; }
}

@test "a checksum mismatch names both sides and points at the fix" {
  mr_stub curl 'prev=""; for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
                printf "tampered\n" > "$out"'
  run mr_converge_engine
  [[ "$output" == *"expected"* && "$output" == *"got"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"SETUP_SHA256 must be bumped"* ]] || { echo "$output"; return 1; }
}

@test "SETUP_VERSION must be a commit sha, never a tag or branch" {
  export MR_SETUP_PIN_FILE="$TEST_TMP/PIN"
  printf 'mac-runner/v1.1.0\n' > "$MR_SETUP_PIN_FILE"
  run mr_converge_engine
  [ "$status" -ne 0 ]
  [[ "$output" == *"40-character commit sha"* ]] || { echo "$output"; return 1; }
}

@test "SETUP_VERSION rejects a short sha" {
  export MR_SETUP_PIN_FILE="$TEST_TMP/PIN"
  printf 'b72dab9\n' > "$MR_SETUP_PIN_FILE"
  run mr_converge_engine
  [ "$status" -ne 0 ]
}

@test "pin files may carry comments — they hold a sha nobody can read otherwise" {
  export MR_SETUP_PIN_FILE="$TEST_TMP/PIN"
  printf '# troymccabe/setup @ mac-runner/v1.1.0\nb72dab9d8384ed5757aa8f9b23f4ac4e9ce4265a\n' \
    > "$MR_SETUP_PIN_FILE"
  run mr_read_ref_pin "$MR_SETUP_PIN_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = "b72dab9d8384ed5757aa8f9b23f4ac4e9ce4265a" ]
}

@test "a pin file holding two values is refused" {
  export MR_SETUP_PIN_FILE="$TEST_TMP/PIN"
  printf 'aaa\nbbb\n' > "$MR_SETUP_PIN_FILE"
  run mr_read_ref_pin "$MR_SETUP_PIN_FILE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"exactly one value"* ]] || { echo "$output"; return 1; }
}

@test "an engine already matching the pin is left alone" {
  stub_engine
  # Point the checksum pin at what is already installed.
  export MR_SETUP_SHA_FILE="$TEST_TMP/SETUP_SHA256"
  mr_file_sha256 "$MR_ENGINE_DEST" > "$MR_SETUP_SHA_FILE"
  mr_stub curl 'echo "curl must not run" >&2; exit 1'
  run mr_converge_engine
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# --- slot converge -----------------------------------------------------------

@test "fresh: SLOTS=2 runs the engine once per slot" {
  export STUB_LAUNCHCTL_PRINT_RC=1
  stub_engine
  run mr_converge_slots 2 "$IMG" "$RV"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(engine_runs)" -eq 2 ] || { echo "engine ran $(engine_runs) times"; return 1; }
  [[ "$(engine_env)" == *"VM_PREFIX=ephem-s1-"* ]] || return 1
  [[ "$(engine_env)" == *"VM_PREFIX=ephem-s2-"* ]] || return 1
}

@test "fresh: the install-time PAT reaches the engine but is not a slot input" {
  export STUB_LAUNCHCTL_PRINT_RC=1
  stub_engine
  mr_converge_slots 1 "$IMG" "$RV"
  [[ "$(engine_env)" == *"GH_PAT=ghp_installtimeonly"* ]] || { echo "PAT never reached the engine"; return 1; }
  # ...and the engine records its inputs without it, because OP_ITEM_REF is set.
  ! grep -q "GH_PAT" "$(mr_slot_config_dir 1)/config.env" || { echo "PAT persisted"; return 1; }
}

@test "idempotent: a converged slot with no drift does not re-run the engine" {
  export STUB_LAUNCHCTL_PRINT_RC=1
  stub_engine
  mr_converge_slots 1 "$IMG" "$RV"
  local first; first="$(engine_runs)"
  export STUB_LAUNCHCTL_PRINT_RC=0     # now loaded
  mr_converge_slots 1 "$IMG" "$RV"
  [ "$(engine_runs)" -eq "$first" ] || { echo "re-ran the engine on a converged host"; return 1; }
}

@test "drift: a new image pin re-runs the engine for that slot" {
  export STUB_LAUNCHCTL_PRINT_RC=1
  stub_engine
  mr_converge_slots 1 "$IMG" "$RV"
  local first; first="$(engine_runs)"
  export STUB_LAUNCHCTL_PRINT_RC=0
  mr_converge_slots 1 "zukan-mobile-runner-2026.09.1" "$RV"
  [ "$(engine_runs)" -gt "$first" ] || { echo "image change did not re-converge"; return 1; }
}

@test "drift: a runner-version bump re-runs the engine" {
  export STUB_LAUNCHCTL_PRINT_RC=1
  stub_engine
  mr_converge_slots 1 "$IMG" "$RV"
  local first; first="$(engine_runs)"
  export STUB_LAUNCHCTL_PRINT_RC=0
  mr_converge_slots 1 "$IMG" "2.338.0"
  [ "$(engine_runs)" -gt "$first" ] || { echo "runner bump did not re-converge"; return 1; }
}

@test "drift: an unloaded agent re-converges even when config matches" {
  stub_engine
  export STUB_LAUNCHCTL_PRINT_RC=1     # never loaded
  mr_converge_slots 1 "$IMG" "$RV"
  local first; first="$(engine_runs)"
  mr_converge_slots 1 "$IMG" "$RV"
  [ "$(engine_runs)" -gt "$first" ] || { echo "a dead agent was left dead"; return 1; }
}

@test "reduce: SLOTS=1 boots out slot 2 and removes its config" {
  export STUB_LAUNCHCTL_PRINT_RC=1
  stub_engine
  mr_converge_slots 2 "$IMG" "$RV"
  [ -f "${MR_LAUNCH_AGENTS}/com.zukan.mobile-runner-agent.slot2.plist" ]
  mr_converge_slots 1 "$IMG" "$RV"
  [ ! -f "${MR_LAUNCH_AGENTS}/com.zukan.mobile-runner-agent.slot2.plist" ] \
    || { echo "slot 2 plist survived"; return 1; }
  [ ! -d "$(mr_slot_config_dir 2)" ] || { echo "slot 2 config survived"; return 1; }
  [[ "$(launchctl_log)" == *"bootout"* ]] || { echo "never booted out"; return 1; }
}

@test "order: a slot that fails to converge leaves the stale slot running" {
  # Retiring slot 2 before slot 1 is up would take the host to zero agents.
  export STUB_LAUNCHCTL_PRINT_RC=1
  stub_engine
  mr_converge_slots 2 "$IMG" "$RV"
  export STUB_ENGINE_FAIL=1
  run mr_converge_slots 1 "$IMG" "$RV"
  [ "$status" -ne 0 ]
  [ -f "${MR_LAUNCH_AGENTS}/com.zukan.mobile-runner-agent.slot2.plist" ] \
    || { echo "retired slot 2 even though slot 1 failed"; return 1; }
}

@test "rollback: a failed converge restores the previous slot definition" {
  export STUB_LAUNCHCTL_PRINT_RC=1
  stub_engine
  mr_converge_slots 1 "$IMG" "$RV"
  local path="${MR_LAUNCH_AGENTS}/com.zukan.mobile-runner-agent.slot1.plist"
  printf 'PREVIOUS-DEFINITION\n' > "$path"
  export STUB_ENGINE_FAIL=all
  run mr_install_slot 1 "$IMG" "$RV"
  [ "$status" -ne 0 ]
  grep -q "PREVIOUS-DEFINITION" "$path" || { echo "did not restore: $(cat "$path")"; return 1; }
}

@test "rollback: a failed converge says the GUI session is the likely cause" {
  stub_engine
  export STUB_ENGINE_FAIL=all
  run mr_install_slot 1 "$IMG" "$RV"
  [[ "$output" == *"GUI session"* ]] || { echo "$output"; return 1; }
}

@test "rollback: no backup file is left behind on success" {
  export STUB_LAUNCHCTL_PRINT_RC=1
  stub_engine
  mr_converge_slots 1 "$IMG" "$RV"
  mr_converge_slots 1 "zukan-mobile-runner-2026.09.1" "$RV"
  run bash -c "ls ${MR_LAUNCH_AGENTS}/*.mr-backup.* 2>/dev/null | wc -l"
  [ "$(echo "$output" | tr -d ' ')" = "0" ] || { echo "backups left: $output"; return 1; }
}

@test "migrate: a PAT-bearing legacy plist is replaced and the secret is gone" {
  export STUB_LAUNCHCTL_PRINT_RC=1
  stub_engine
  seed_legacy_slot 1
  run mr_converge_slots 1 "$IMG" "$RV"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ! grep -rq "ghp_0000000000000000000000000000AAAAAAAA" "$MR_LAUNCH_AGENTS" \
    || { echo "the embedded PAT survived migration"; return 1; }
}
