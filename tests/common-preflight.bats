#!/usr/bin/env bats
# ZUK-2156 (T010) — preflight predicates in lib/common.sh.
#
# FR-004: every gate runs BEFORE the installer changes anything, each failure
# names its own remediation, and the failure classes map onto the two preflight
# exit codes in contracts/installer-cli.md:
#
#   10 — unsupported machine  (Intel Mac, macOS < 15)  → operator can't fix it
#   11 — operator-remediable  (FileVault On, low disk) → operator can
#
# The system probes are stubbed as commands on PATH, so this suite runs on the
# Linux CI box where sw_vers/fdesetup/defaults do not exist.

load helper

setup() {
  mr_common_setup
  # Healthy defaults; each test overrides the one probe it is about.
  mr_stub uname 'echo arm64'
  mr_stub sw_vers 'echo 26.1'
  mr_stub fdesetup 'echo "FileVault is Off."'
  mr_stub defaults 'echo ci'
  mr_stub df 'echo "Filesystem 1G-blocks Used Available Capacity Mounted"; echo "/dev/disk3s5 926 400 500 45% /"'
}

teardown() {
  mr_common_teardown
}

# --- architecture -----------------------------------------------------------

@test "arch: arm64 is supported" {
  run mr_arch_is_supported
  [ "$status" -eq 0 ]
}

@test "arch: Intel is not supported" {
  mr_stub uname 'echo x86_64'
  run mr_arch_is_supported
  [ "$status" -ne 0 ]
}

# --- macOS version ----------------------------------------------------------

@test "macos: major version is parsed off sw_vers" {
  mr_stub sw_vers 'echo 15.4.1'
  run mr_macos_major
  [ "$status" -eq 0 ]
  [ "$output" = "15" ]
}

@test "macos: 15 is the supported floor" {
  mr_stub sw_vers 'echo 15.0'
  run mr_macos_is_supported
  [ "$status" -eq 0 ]
}

@test "macos: 26 (Tahoe) is supported — the floor is a minimum, not a match" {
  mr_stub sw_vers 'echo 26.1'
  run mr_macos_is_supported
  [ "$status" -eq 0 ]
}

@test "macos: 14 is below the floor" {
  mr_stub sw_vers 'echo 14.7.2'
  run mr_macos_is_supported
  [ "$status" -ne 0 ]
}

# --- FileVault --------------------------------------------------------------

@test "filevault: 'FileVault is On.' reads as on" {
  mr_stub fdesetup 'echo "FileVault is On."'
  run mr_filevault_is_on
  [ "$status" -eq 0 ]
}

@test "filevault: 'FileVault is Off.' reads as off" {
  run mr_filevault_is_on
  [ "$status" -ne 0 ]
}

@test "filevault: an in-progress encryption counts as on, not off" {
  # `fdesetup status` during conversion prints the progress form. Treating an
  # unrecognized answer as "Off" would let the installer proceed onto a host
  # that cannot auto-login once conversion finishes.
  mr_stub fdesetup 'echo "FileVault is On, but conversion is in progress."'
  run mr_filevault_is_on
  [ "$status" -eq 0 ]
}

@test "filevault: an unreadable status is treated as on (fail closed)" {
  mr_stub fdesetup 'echo "some future wording" ; exit 1'
  run mr_filevault_is_on
  [ "$status" -eq 0 ]
}

# --- auto-login -------------------------------------------------------------

@test "autologin: a configured user is reported" {
  mr_stub defaults 'echo ci'
  run mr_autologin_user
  [ "$status" -eq 0 ]
  [ "$output" = "ci" ]
}

@test "autologin: an unset key yields empty, not the defaults error text" {
  # `defaults read … autoLoginUser` exits 1 with "does not exist" on stdout.
  mr_stub defaults 'echo "The domain/default pair of (/Library/Preferences/com.apple.loginwindow, autoLoginUser) does not exist"; exit 1'
  run mr_autologin_user
  [ "$output" = "" ]
}

@test "autologin: predicate is false when unset" {
  mr_stub defaults 'exit 1'
  run mr_autologin_is_set
  [ "$status" -ne 0 ]
}

@test "autologin: predicate is true when set" {
  run mr_autologin_is_set
  [ "$status" -eq 0 ]
}

# --- free disk --------------------------------------------------------------

@test "disk: available GB is read from the Available column" {
  run mr_free_disk_gb /
  [ "$status" -eq 0 ]
  [ "$output" = "500" ]
}

@test "disk: floor is met when free >= floor" {
  run mr_disk_meets_floor 120 /
  [ "$status" -eq 0 ]
}

@test "disk: floor is not met when free < floor" {
  mr_stub df 'echo "Filesystem 1G-blocks Used Available Capacity Mounted"; echo "/dev/disk3s5 926 900 40 96% /"'
  run mr_disk_meets_floor 120 /
  [ "$status" -ne 0 ]
}

@test "disk: an unparseable df is a failure, not an accidental pass" {
  mr_stub df 'echo "df: /: Operation not permitted"; exit 1'
  run mr_disk_meets_floor 120 /
  [ "$status" -ne 0 ]
}

# --- the gate: exit-code classes -------------------------------------------

@test "preflight: a healthy host returns 0" {
  run mr_preflight_readonly 120
  [ "$status" -eq 0 ]
}

@test "preflight: Intel returns 10 (unsupported machine)" {
  mr_stub uname 'echo x86_64'
  run mr_preflight_readonly 120
  [ "$status" -eq 10 ]
}

@test "preflight: macOS below the floor returns 10" {
  mr_stub sw_vers 'echo 14.7'
  run mr_preflight_readonly 120
  [ "$status" -eq 10 ]
}

@test "preflight: FileVault On returns 11 (operator-remediable) and says so" {
  mr_stub fdesetup 'echo "FileVault is On."'
  run mr_preflight_readonly 120
  [ "$status" -eq 11 ]
  [[ "$output" == *"FileVault"* ]]
}

@test "preflight: insufficient disk returns 11" {
  mr_stub df 'echo "Filesystem 1G-blocks Used Available Capacity Mounted"; echo "/dev/disk3s5 926 900 40 96% /"'
  run mr_preflight_readonly 120
  [ "$status" -eq 11 ]
}

@test "preflight: hardware is gated before FileVault — the unfixable answer wins" {
  # Both are wrong here. An Intel Mac with FileVault on must be told 10 (send
  # the machine back), not 11 (turn a setting off and retry pointlessly).
  mr_stub uname 'echo x86_64'
  mr_stub fdesetup 'echo "FileVault is On."'
  run mr_preflight_readonly 120
  [ "$status" -eq 10 ]
}

@test "preflight: every failure names a remediation" {
  mr_stub fdesetup 'echo "FileVault is On."'
  run mr_preflight_readonly 120
  [ "$status" -ne 0 ]
  # The contract requires a one-line remediation on every non-zero exit.
  [[ "$output" == *"[install]"* ]]
}

# --- disk requirement, recomputed once the host's real image size is known ---

@test "disk req: with no image pulled yet the static floor stands" {
  run mr_disk_requirement_gb "" 120
  [ "$status" -eq 0 ]
  [ "$output" = "120" ]
}

@test "disk req: an installed image sizes the requirement (image + headroom)" {
  export MR_DISK_HEADROOM_GB=20
  run mr_disk_requirement_gb 64 120
  [ "$status" -eq 0 ]
  [ "$output" = "84" ]
}

@test "disk req: a zero-size reading falls back rather than demanding nothing" {
  run mr_disk_requirement_gb 0 120
  [ "$output" = "120" ]
}

@test "disk req: junk from tart falls back to the floor" {
  run mr_disk_requirement_gb "unknown" 120
  [ "$output" = "120" ]
}

@test "disk req: a junk fallback is an error, not a silent zero" {
  run mr_disk_requirement_gb 64 ""
  [ "$status" -ne 0 ]
}

@test "image size: the named local image's size is read from the tart listing" {
  printf '%s' '[{"Source":"local","Name":"zukan-mobile-runner-2026.08.1","Size":64,"State":"stopped"}]' > "$TEST_TMP/tart.json"
  run mr_local_image_size_gb zukan-mobile-runner-2026.08.1 < "$TEST_TMP/tart.json"
  [ "$status" -eq 0 ]
  [ "$output" = "64" ]
}

@test "image size: an image that is not on the host reports nothing" {
  printf '%s' '[]' > "$TEST_TMP/tart.json"
  run mr_local_image_size_gb zukan-mobile-runner-2026.08.1 < "$TEST_TMP/tart.json"
  [ "$status" -ne 0 ]
  [ "$output" = "" ]
}
