#!/usr/bin/env bats
# ZUK-2163 (T017) — reconciliation helpers in lib/common.sh.
#
# Re-running the one-liner is the only upgrade, convergence and migration path
# (FR-006), so the decisions it makes are worth pinning precisely: which slots
# to remove, which plists are the legacy secret-bearing layout, which images to
# prune, and whether an in-flight CI job blocks the slot restart (FR-008).

load helper

setup() {
  mr_common_setup
  AGENTS_DIR="$TEST_TMP/LaunchAgents"
  mkdir -p "$AGENTS_DIR"
}

teardown() {
  mr_common_teardown
}

# Write a plist for slot $1 into AGENTS_DIR; $2 = "legacy" adds the embedded PAT.
seed_slot() {
  local slot="$1" kind="${2:-current}" path
  path="$AGENTS_DIR/com.zukan.mobile-runner-agent.slot${slot}.plist"
  {
    echo '<plist version="1.0"><dict>'
    echo "  <key>Label</key><string>com.zukan.mobile-runner-agent.slot${slot}</string>"
    echo '  <key>EnvironmentVariables</key><dict>'
    echo "    <key>SLOT</key><string>${slot}</string>"
    [ "$kind" = "legacy" ] && echo '    <key>ZUKAN_GH_PAT</key><string>ghp_secretvalue</string>'
    echo '  </dict>'
    echo '</dict></plist>'
  } > "$path"
}

# --- observing what is on the host -----------------------------------------

@test "observe: an empty LaunchAgents dir yields no slots" {
  run mr_observed_slots "$AGENTS_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "observe: slots are discovered from plist filenames" {
  seed_slot 1
  seed_slot 2
  run mr_observed_slots "$AGENTS_DIR"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "1" ]
  [ "${lines[1]}" = "2" ]
}

@test "observe: unrelated LaunchAgents are ignored" {
  seed_slot 1
  touch "$AGENTS_DIR/com.apple.something.plist"
  touch "$AGENTS_DIR/com.zukan.other-agent.plist"
  run mr_observed_slots "$AGENTS_DIR"
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "1" ]
}

@test "observe: a missing directory is empty, not an error" {
  # First run on a fresh Mac: ~/Library/LaunchAgents may not exist yet.
  run mr_observed_slots "$TEST_TMP/absent"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "observe: slots are ordered numerically" {
  seed_slot 2
  seed_slot 1
  run mr_observed_slots "$AGENTS_DIR"
  [ "${lines[0]}" = "1" ]
  [ "${lines[1]}" = "2" ]
}

# --- legacy layout detection (US2-AC3) --------------------------------------

@test "legacy: a plist with an embedded PAT is legacy" {
  seed_slot 1 legacy
  run mr_plist_is_legacy "$AGENTS_DIR/com.zukan.mobile-runner-agent.slot1.plist"
  [ "$status" -eq 0 ]
}

@test "legacy: a rendered secretless plist is not legacy" {
  seed_slot 1
  run mr_plist_is_legacy "$AGENTS_DIR/com.zukan.mobile-runner-agent.slot1.plist"
  [ "$status" -ne 0 ]
}

@test "legacy: the migration set names only the PAT-bearing slots" {
  seed_slot 1 legacy
  seed_slot 2
  run mr_legacy_slots "$AGENTS_DIR"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "1" ]
}

@test "legacy: a missing plist is not legacy (and does not error)" {
  run mr_plist_is_legacy "$AGENTS_DIR/absent.plist"
  [ "$status" -ne 0 ]
}

@test "legacy: a plist rendered from the real template is NOT legacy" {
  # Regression: the template's comment header says "never add ZUKAN_GH_PAT
  # here", so a substring search classifies the installer's own freshly
  # rendered output as the legacy layout — and a converged host would be
  # torn down and re-migrated on every re-run, restarting live CI slots.
  mr_render_plist "$BATS_TEST_DIRNAME/../agent/com.zukan.mobile-runner-agent.plist.tmpl" \
    1 zukan-mobile-runner-2026.08.1 "" /tmp/slot1.log \
    > "$AGENTS_DIR/com.zukan.mobile-runner-agent.slot1.plist"
  run mr_plist_is_legacy "$AGENTS_DIR/com.zukan.mobile-runner-agent.slot1.plist"
  [ "$status" -ne 0 ]
}

@test "legacy: the real legacy plist shape (a PAT key in EnvironmentVariables) is detected" {
  seed_slot 1 legacy
  run mr_legacy_slots "$AGENTS_DIR"
  [ "${lines[0]}" = "1" ]
}

# --- slot reduction (US2-AC4) ----------------------------------------------

@test "reduce: SLOTS=1 removes slot 2" {
  seed_slot 1
  seed_slot 2
  run mr_slots_to_remove 1 "$AGENTS_DIR"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "2" ]
}

@test "reduce: SLOTS=2 with two slots removes nothing" {
  seed_slot 1
  seed_slot 2
  run mr_slots_to_remove 2 "$AGENTS_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "reduce: growing from 1 to 2 removes nothing" {
  seed_slot 1
  run mr_slots_to_remove 2 "$AGENTS_DIR"
  [ "$output" = "" ]
}

@test "reduce: a stray high-numbered slot from an older layout is removed" {
  seed_slot 1
  seed_slot 4
  run mr_slots_to_remove 2 "$AGENTS_DIR"
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "4" ]
}

# --- image prune (US2-AC2) --------------------------------------------------
#
# The helpers below read tart's output on stdin rather than shelling out, so
# the decision is testable without a tart stub and cannot be confused by a
# future change to tart's CLI surface.
#
# An image appears in two shapes: the OCI-cache entry the installer pulls
# (ghcr.io/…/zukan-mobile-runner:VER) and the bare local VM packer leaves on a
# build host (zukan-mobile-runner-VER). The prune keys on the VERSION so it
# recognizes both.

# Write $@ as one name per line into a fixture the test redirects into stdin.
names() {
  printf '%s\n' "$@" > "$TEST_TMP/names"
}

@test "version-of: the OCI reference shape is recognized" {
  run mr_image_version_of "ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1"
  [ "$status" -eq 0 ]
  [ "$output" = "2026.08.1" ]
}

@test "version-of: the bare local-VM shape is recognized" {
  run mr_image_version_of "zukan-mobile-runner-2026.08.1"
  [ "$status" -eq 0 ]
  [ "$output" = "2026.08.1" ]
}

@test "version-of: an ephemeral ci-* clone is not one of ours" {
  run mr_image_version_of "ci-macmini-1-1712345678"
  [ "$status" -ne 0 ]
}

@test "version-of: someone else's image is not one of ours" {
  run mr_image_version_of "ghcr.io/cirruslabs/macos-sequoia-base:latest"
  [ "$status" -ne 0 ]
}

@test "present: the pinned version is found in the OCI shape" {
  # This is how the pin actually appears after `tart pull`: in the OCI cache
  # under its registry reference, NOT as a bare local VM name.
  names ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1
  run mr_image_present 2026.08.1 < "$TEST_TMP/names"
  [ "$status" -eq 0 ]
}

@test "present: the pinned version is found in the bare local shape" {
  names zukan-mobile-runner-2026.08.1
  run mr_image_present 2026.08.1 < "$TEST_TMP/names"
  [ "$status" -eq 0 ]
}

@test "present: a different version is not the pin" {
  names ghcr.io/zukantechnologies/zukan-mobile-runner:2026.07.4
  run mr_image_present 2026.08.1 < "$TEST_TMP/names"
  [ "$status" -ne 0 ]
}

@test "prune: a superseded OCI entry is pruned, the pinned one kept" {
  names ghcr.io/zukantechnologies/zukan-mobile-runner:2026.07.4 \
        ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1
  run mr_image_prune_list 2026.08.1 < "$TEST_TMP/names"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "ghcr.io/zukantechnologies/zukan-mobile-runner:2026.07.4" ]
}

@test "prune: a superseded bare local VM is pruned too" {
  names zukan-mobile-runner-2026.07.4 ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1
  run mr_image_prune_list 2026.08.1 < "$TEST_TMP/names"
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "zukan-mobile-runner-2026.07.4" ]
}

@test "prune: both shapes of the PINNED version survive" {
  # A build host has the local VM packer made and the OCI entry it pushed.
  # Neither is superseded.
  names zukan-mobile-runner-2026.08.1 ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1
  run mr_image_prune_list 2026.08.1 < "$TEST_TMP/names"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "prune: unrelated images on the host are never touched" {
  names ghcr.io/cirruslabs/macos-sequoia-base my-own-vm zukan-mobile-runner-2026.07.4
  run mr_image_prune_list 2026.08.1 < "$TEST_TMP/names"
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "zukan-mobile-runner-2026.07.4" ]
}

@test "prune: ephemeral ci-* clones are never pruned — they belong to the agent" {
  names ci-macmini-1-1712345678 ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1
  run mr_image_prune_list 2026.08.1 < "$TEST_TMP/names"
  [ "$output" = "" ]
}

@test "prune: nothing to prune yields empty output and success" {
  names ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1
  run mr_image_prune_list 2026.08.1 < "$TEST_TMP/names"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "prune: refuses to run without a version to keep rather than pruning everything" {
  names ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1
  run mr_image_prune_list < "$TEST_TMP/names"
  [ "$status" -ne 0 ]
}

# --- tart list parsing ------------------------------------------------------

json_fixture() {
  printf '%s' "$1" > "$TEST_TMP/tart.json"
}

@test "tart: running ci-* VMs are extracted from the JSON listing" {
  json_fixture '[{"Source":"local","Name":"ci-mini-1-1712","State":"running"},
                 {"Source":"local","Name":"zukan-mobile-runner-2026.08.1","State":"stopped"}]'
  run mr_running_ci_vm_names < "$TEST_TMP/tart.json"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "ci-mini-1-1712" ]
}

@test "tart: a stopped ci-* clone is not in flight" {
  json_fixture '[{"Source":"local","Name":"ci-mini-1-1712","State":"stopped"}]'
  run mr_running_ci_vm_names < "$TEST_TMP/tart.json"
  [ "$output" = "" ]
}

@test "tart: a running non-ci VM is not one of ours" {
  json_fixture '[{"Source":"local","Name":"someones-dev-vm","State":"running"}]'
  run mr_running_ci_vm_names < "$TEST_TMP/tart.json"
  [ "$output" = "" ]
}

@test "tart: local image names are extracted, remote entries skipped" {
  json_fixture '[{"Source":"local","Name":"zukan-mobile-runner-2026.08.1","State":"stopped"},
                 {"Source":"oci","Name":"ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1","State":"stopped"}]'
  run mr_local_image_names < "$TEST_TMP/tart.json"
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "zukan-mobile-runner-2026.08.1" ]
}

@test "tart: every entry is listed regardless of source" {
  # The pinned image lives in the OCI cache, so anything that filters on
  # Source == "local" cannot see it — which is why presence and prune read
  # mr_image_names, not mr_local_image_names.
  json_fixture '[{"Source":"local","Name":"ci-mini-1-1712","State":"running"},
                 {"Source":"oci","Name":"ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1","State":"stopped"}]'
  run mr_image_names < "$TEST_TMP/tart.json"
  [ "${#lines[@]}" -eq 2 ]
}

@test "tart: an empty listing parses to nothing" {
  json_fixture '[]'
  run mr_running_ci_vm_names < "$TEST_TMP/tart.json"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# --- in-flight guard decision table (FR-008) --------------------------------

@test "guard: idle host proceeds" {
  run mr_inflight_action 0 0
  [ "$status" -eq 0 ]
  [ "$output" = "proceed" ]
}

@test "guard: idle host with FORCE=1 still just proceeds" {
  run mr_inflight_action 0 1
  [ "$output" = "proceed" ]
}

@test "guard: a running job waits by default" {
  run mr_inflight_action 1 0
  [ "$output" = "wait" ]
}

@test "guard: FORCE=1 with a running job terminates it" {
  run mr_inflight_action 1 1
  [ "$output" = "force" ]
}

@test "guard: two running jobs behave like one" {
  run mr_inflight_action 2 0
  [ "$output" = "wait" ]
}

@test "guard: FORCE only counts as set when it is exactly 1" {
  # A truthy-looking value must not silently terminate someone's CI job.
  run mr_inflight_action 1 "yes"
  [ "$output" = "wait" ]
  run mr_inflight_action 1 "0"
  [ "$output" = "wait" ]
  run mr_inflight_action 1 ""
  [ "$output" = "wait" ]
}

# --- run summary ------------------------------------------------------------

@test "summary: an unchanged run reports no changes" {
  mr_summary_reset
  mr_summary_add unchanged "image zukan-mobile-runner-2026.08.1"
  run mr_summary_print
  [ "$status" -eq 0 ]
  [[ "$output" == *"unchanged:"* ]]
  # Match the indented bucket heading, not the bare word: "unchanged:" itself
  # ends in "changed:" and would satisfy a substring check either way.
  [[ "$output" != *"  changed:"* ]]
}

@test "summary: buckets are reported separately" {
  mr_summary_reset
  mr_summary_add installed "slot 1"
  mr_summary_add changed "image → 2026.08.1"
  mr_summary_add removed "slot 2"
  run mr_summary_print
  [[ "$output" == *"slot 1"* ]]
  [[ "$output" == *"2026.08.1"* ]]
  [[ "$output" == *"slot 2"* ]]
}

@test "summary: a run that changed nothing is distinguishable from one that did" {
  mr_summary_reset
  run mr_summary_changed_anything
  [ "$status" -ne 0 ]
  mr_summary_reset
  mr_summary_add changed "slot 1"
  run mr_summary_changed_anything
  [ "$status" -eq 0 ]
}
