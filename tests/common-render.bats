#!/usr/bin/env bats
# ZUK-2157 (T011) — plist rendering, pin parsing and slot bounds.
#
# The rendered plist is the one artifact the installer writes into launchd, so
# the invariants it has to carry are: every placeholder substituted, no XML
# breakage from a substituted value, and — the whole point of FR-009 — no
# credential anywhere in it.

load helper

setup() {
  mr_common_setup
  TMPL="$BATS_TEST_DIRNAME/../agent/com.zukan.mobile-runner-agent.plist.tmpl"
  PIN_FILE="$TEST_TMP/IMAGE_VERSION"
  echo "2026.08.1" > "$PIN_FILE"
}

teardown() {
  mr_common_teardown
}

# --- pin parsing ------------------------------------------------------------

@test "pin: a clean pin file parses" {
  run mr_read_pin "$PIN_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = "2026.08.1" ]
}

@test "pin: trailing whitespace and a missing final newline are tolerated" {
  printf '  2026.08.1  ' > "$PIN_FILE"
  run mr_read_pin "$PIN_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = "2026.08.1" ]
}

@test "pin: an empty pin file is rejected" {
  : > "$PIN_FILE"
  run mr_read_pin "$PIN_FILE"
  [ "$status" -ne 0 ]
}

@test "pin: a missing pin file is rejected by name" {
  run mr_read_pin "$TEST_TMP/nope"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nope"* ]]
}

@test "pin: a second line is rejected — the pin is a single value" {
  printf '2026.08.1\n2026.07.4\n' > "$PIN_FILE"
  run mr_read_pin "$PIN_FILE"
  [ "$status" -ne 0 ]
}

@test "pin: a shell-injecting value is rejected" {
  echo '2026.08.1; rm -rf /' > "$PIN_FILE"
  run mr_read_pin "$PIN_FILE"
  [ "$status" -ne 0 ]
}

@test "pin: 'latest' is rejected — hosts never track a moving tag" {
  echo "latest" > "$PIN_FILE"
  run mr_read_pin "$PIN_FILE"
  [ "$status" -ne 0 ]
}

@test "version resolve: the pin file is the default source" {
  run mr_resolve_image_version "$PIN_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = "2026.08.1" ]
}

@test "version resolve: IMAGE_VERSION env overrides the pin (documented escape hatch)" {
  export IMAGE_VERSION=2026.09.3
  run mr_resolve_image_version "$PIN_FILE"
  [ "$status" -eq 0 ]
  [ "$output" = "2026.09.3" ]
}

@test "version resolve: a malformed env override is rejected, not passed through" {
  export IMAGE_VERSION="latest"
  run mr_resolve_image_version "$PIN_FILE"
  [ "$status" -ne 0 ]
}

@test "base image name is derived from the version" {
  run mr_base_image_name 2026.08.1
  [ "$status" -eq 0 ]
  [ "$output" = "zukan-mobile-runner-2026.08.1" ]
}

@test "base image REF is the registry reference, not the bare local name" {
  # This is the value that lands in every plist's BASE_IMAGE. `tart pull` puts
  # a remote image in the OCI cache, not into a locally-runnable VM under a
  # bare name, so an agent told to clone the bare name fails on any host that
  # did not itself build the image.
  run mr_base_image_ref 2026.08.1
  [ "$status" -eq 0 ]
  [ "$output" = "ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1" ]
}

@test "render: the base image ref survives rendering into the plist" {
  # It contains / and : — neither is XML-unsafe, but both would be a problem
  # if the renderer's sed delimiter or escaping ever changed.
  run mr_render_plist "$TMPL" 1 "$(mr_base_image_ref 2026.08.1)" "" /tmp/slot1.log
  [ "$status" -eq 0 ]
  [[ "$output" == *"ghcr.io/zukantechnologies/zukan-mobile-runner:2026.08.1"* ]]
}

# --- slot bounds ------------------------------------------------------------

@test "slots: 1 and 2 are accepted" {
  run mr_validate_slots 1
  [ "$status" -eq 0 ]
  run mr_validate_slots 2
  [ "$status" -eq 0 ]
}

@test "slots: 3 is rejected — Apple Virtualization caps concurrent VMs at 2" {
  run mr_validate_slots 3
  [ "$status" -ne 0 ]
  [[ "$output" == *"2"* ]]
}

@test "slots: 0 is rejected" {
  run mr_validate_slots 0
  [ "$status" -ne 0 ]
}

@test "slots: non-numeric is rejected" {
  run mr_validate_slots "two"
  [ "$status" -ne 0 ]
}

@test "slots: default is 2 when SLOTS is unset" {
  run mr_resolve_slots
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "slots: SLOTS env is honored" {
  export SLOTS=1
  run mr_resolve_slots
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

# --- plist render -----------------------------------------------------------

@test "render: every placeholder is substituted" {
  run mr_render_plist "$TMPL" 1 zukan-mobile-runner-2026.08.1 "" /tmp/slot1.log
  [ "$status" -eq 0 ]
  [[ "$output" != *"{{"* ]]
}

@test "render: slot number lands in the label and the SLOT variable" {
  run mr_render_plist "$TMPL" 2 zukan-mobile-runner-2026.08.1 "" /tmp/slot2.log
  [ "$status" -eq 0 ]
  [[ "$output" == *"com.zukan.mobile-runner-agent.slot2"* ]]
}

@test "render: base image and log path land in the output" {
  run mr_render_plist "$TMPL" 1 zukan-mobile-runner-2026.08.1 "" /tmp/slot1.log
  [[ "$output" == *"zukan-mobile-runner-2026.08.1"* ]]
  [[ "$output" == *"/tmp/slot1.log"* ]]
}

@test "render: extra labels land in the output" {
  run mr_render_plist "$TMPL" 1 img "xcode-26.6,perf" /tmp/slot1.log
  [[ "$output" == *"xcode-26.6,perf"* ]]
}

@test "render: the rendered plist defines no credential key (FR-009)" {
  # The template's comment header names ZUKAN_GH_PAT to warn against adding it,
  # so the assertion is about the launchd KEY, not the word appearing in the
  # file. (mr_plist_is_legacy has to draw the same distinction — a substring
  # match there re-migrates a converged host on every run.)
  run mr_render_plist "$TMPL" 1 img "" /tmp/slot1.log
  [ "$status" -eq 0 ]
  [[ "$output" != *"<key>ZUKAN_GH_PAT</key>"* ]]
}

@test "render: the rendered plist carries no credential value" {
  run mr_render_plist "$TMPL" 1 img "" /tmp/slot1.log
  [[ "$output" != *"ghp_"* ]]
  [[ "$output" != *"github_pat_"* ]]
}

@test "render: the output is well-formed XML" {
  mr_render_plist "$TMPL" 1 zukan-mobile-runner-2026.08.1 "" /tmp/slot1.log > "$TEST_TMP/out.plist"
  # xmllint ships with macOS and is present on the CI image; skip rather than
  # pretend to have checked if it is ever absent.
  command -v xmllint >/dev/null 2>&1 || skip "xmllint unavailable"
  run xmllint --noout "$TEST_TMP/out.plist"
  [ "$status" -eq 0 ]
}

@test "render: an ampersand in a value is rejected, not silently emitted" {
  # Raw & < > inside a <string> makes the plist unparseable, and launchd's
  # failure for a malformed plist is opaque. The template header makes this
  # the renderer's job.
  run mr_render_plist "$TMPL" 1 img "a&b" /tmp/slot1.log
  [ "$status" -ne 0 ]
}

@test "render: angle brackets in a value are rejected" {
  run mr_render_plist "$TMPL" 1 "img<x>" "" /tmp/slot1.log
  [ "$status" -ne 0 ]
}

@test "render: an out-of-range slot is rejected before any output" {
  run mr_render_plist "$TMPL" 3 img "" /tmp/slot3.log
  [ "$status" -ne 0 ]
  [[ "$output" != *"<plist"* ]]
}

@test "render: a missing template is reported by path" {
  run mr_render_plist "$TEST_TMP/absent.tmpl" 1 img "" /tmp/slot1.log
  [ "$status" -ne 0 ]
  [[ "$output" == *"absent.tmpl"* ]]
}

# --- derived paths ----------------------------------------------------------

@test "paths: plist path is per slot under LaunchAgents" {
  # bats runs each test in its own process, so clobbering HOME is contained.
  export HOME="$TEST_TMP"
  run mr_plist_path 1
  [ "$output" = "$TEST_TMP/Library/LaunchAgents/com.zukan.mobile-runner-agent.slot1.plist" ]
}

@test "paths: default log path is per slot" {
  run mr_default_log_path 2
  [ "$output" = "/tmp/zukan-mobile-runner-agent.slot2.log" ]
}

@test "paths: launchd label is per slot" {
  run mr_plist_label 2
  [ "$output" = "com.zukan.mobile-runner-agent.slot2" ]
}
