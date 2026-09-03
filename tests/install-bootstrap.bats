#!/usr/bin/env bats
# ZUK-2159 (T013) — the curl|bash entrypoint.
#
# install.sh carries a small duplicate of the preflight predicates because it
# runs before lib/common.sh is on the machine at all. The duplication is the
# point of this suite: every gate is checked against the authoritative version
# on the same stubbed host, so the two cannot drift apart silently.
#
# Nothing here may reach a mutating step. Every scenario is arranged to exit at
# a gate — a test that installed Homebrew on the developer's machine would be a
# worse bug than anything it could catch.

load helper

setup() {
  mr_common_setup   # sources lib/common.sh (mr_*)
  REPO="$BATS_TEST_DIRNAME/.."
  # Healthy host by default; each test breaks exactly one thing.
  mr_stub uname 'echo arm64'
  mr_stub sw_vers 'echo 26.1'
  mr_stub fdesetup 'echo "FileVault is Off."'
  mr_stub defaults 'echo ci'
  mr_stub df 'echo "Filesystem 1G-blocks Used Available Capacity Mounted"; echo "/dev/disk3s5 926 400 500 45% /"'
  # A stub for anything that would change the machine, so a regression that
  # slips past a gate is a loud failure here rather than a real install.
  mr_stub brew 'echo "REFUSED: brew was called from a test" >&2; exit 99'
  mr_stub git 'echo "REFUSED: git was called from a test" >&2; exit 99'
  mr_stub sudo 'echo "REFUSED: sudo was called from a test" >&2; exit 99'
  # shellcheck source=/dev/null
  MR_SOURCE_ONLY=1 source "$REPO/install.sh"
}

teardown() {
  mr_common_teardown
}

# --- the guard that makes the one-liner work -------------------------------

@test "curl|bash actually runs main" {
  # `bash -c "$(curl ...)"` leaves BASH_SOURCE empty, so the conventional
  # `[[ ${BASH_SOURCE[0]} == $0 ]]` guard is FALSE there and main would never
  # run — the published one-liner would silently do nothing. This reproduces
  # that invocation shape exactly and asserts the preflight really executed.
  mr_stub uname 'echo x86_64'
  run bash -c "$(cat "$REPO/install.sh")"
  [ "$status" -eq 10 ]
  [[ "$output" == *"Apple Silicon"* ]]
}

@test "sourcing with MR_SOURCE_ONLY does not run main" {
  # If it did, this suite would provision the developer's laptop.
  run bash -c "MR_SOURCE_ONLY=1 . '$REPO/install.sh'; echo sourced-ok"
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "sourced-ok" ]
}

# --- agreement with lib/common.sh ------------------------------------------

# bats runs test bodies under `set -e`, so a predicate returning non-zero would
# abort the test rather than be compared. `rc=0; f || rc=$?` captures it, and
# MR_LAST_BS carries install.sh's own verdict out for a further assertion.
both_agree() {
  local bs=0 mr=0
  "$1" >/dev/null 2>&1 || bs=$?
  "$2" >/dev/null 2>&1 || mr=$?
  MR_LAST_BS=$bs
  [ "$bs" -eq "$mr" ] || {
    echo "disagreement: $1=$bs vs $2=$mr"
    return 1
  }
}

@test "drift: arch verdict matches lib/common.sh on arm64" {
  both_agree bs_arch_is_supported mr_arch_is_supported
  [ "$MR_LAST_BS" -eq 0 ]
}

@test "drift: arch verdict matches lib/common.sh on Intel" {
  mr_stub uname 'echo x86_64'
  both_agree bs_arch_is_supported mr_arch_is_supported
  [ "$MR_LAST_BS" -ne 0 ]
}

@test "drift: macOS floor matches lib/common.sh across versions" {
  local v
  for v in 14.7 15.0 26.1; do
    mr_stub sw_vers "echo $v"
    both_agree bs_macos_is_supported mr_macos_is_supported || {
      echo "  ...on macOS $v"
      return 1
    }
  done
}

@test "drift: FileVault verdict matches lib/common.sh, including the fail-closed cases" {
  # Off / On / mid-conversion / unreadable — the last two are the ones where a
  # naive reading would say "off" and let the install proceed.
  mr_stub fdesetup 'echo "FileVault is Off."'
  both_agree bs_filevault_is_on mr_filevault_is_on
  [ "$MR_LAST_BS" -ne 0 ]

  mr_stub fdesetup 'echo "FileVault is On."'
  both_agree bs_filevault_is_on mr_filevault_is_on
  [ "$MR_LAST_BS" -eq 0 ]

  mr_stub fdesetup 'echo "FileVault is On, but conversion is in progress."'
  both_agree bs_filevault_is_on mr_filevault_is_on
  [ "$MR_LAST_BS" -eq 0 ]

  mr_stub fdesetup 'echo "unknown"; exit 1'
  both_agree bs_filevault_is_on mr_filevault_is_on
  [ "$MR_LAST_BS" -eq 0 ]   # fail closed: unreadable means "on"
}

@test "drift: free-disk reading matches lib/common.sh" {
  run bs_free_disk_gb
  local bs="$output"
  run mr_free_disk_gb /
  [ "$bs" = "$output" ]
}

@test "drift: the preflight exit code matches lib/common.sh" {
  local case_name
  for case_name in intel oldos filevault lowdisk healthy; do
    case "$case_name" in
      intel)     mr_stub uname 'echo x86_64' ;;
      oldos)     mr_stub uname 'echo arm64'; mr_stub sw_vers 'echo 14.7' ;;
      filevault) mr_stub sw_vers 'echo 26.1'; mr_stub fdesetup 'echo "FileVault is On."' ;;
      lowdisk)   mr_stub fdesetup 'echo "FileVault is Off."'
                 mr_stub df 'echo h; echo "/dev/disk3s5 926 900 40 96% /"' ;;
      healthy)   mr_stub df 'echo h; echo "/dev/disk3s5 926 400 500 45% /"' ;;
    esac
    local bs=0 mr=0
    bs_preflight >/dev/null 2>&1 || bs=$?
    mr_preflight_readonly 120 >/dev/null 2>&1 || mr=$?
    [ "$bs" -eq "$mr" ] || {
      echo "disagreement on '$case_name': install.sh=$bs common.sh=$mr"
      return 1
    }
  done
}

# --- preflight gates stop before anything is installed ----------------------

@test "gate: an Intel Mac exits 10 without calling brew, git or sudo" {
  mr_stub uname 'echo x86_64'
  run bash -c "$(cat "$REPO/install.sh")"
  [ "$status" -eq 10 ]
  [[ "$output" != *"REFUSED"* ]]
  [[ "$output" == *"Nothing was changed"* ]]
}

@test "gate: FileVault on exits 11 and names the setting to change" {
  mr_stub fdesetup 'echo "FileVault is On."'
  run bash -c "$(cat "$REPO/install.sh")"
  [ "$status" -eq 11 ]
  [[ "$output" == *"FileVault"* ]]
  [[ "$output" != *"REFUSED"* ]]
}

@test "gate: a full disk exits 11 before installing anything" {
  mr_stub df 'echo h; echo "/dev/disk3s5 926 920 10 99% /"'
  run bash -c "$(cat "$REPO/install.sh")"
  [ "$status" -eq 11 ]
  [[ "$output" != *"REFUSED"* ]]
}

@test "gate: auto-login unset pauses, and aborting leaves the host untouched" {
  mr_stub defaults 'exit 1'
  # Closed stdin stands in for the operator pressing Ctrl-C at the pause.
  run bash -c "$(cat "$REPO/install.sh")" < /dev/null
  [ "$status" -eq 11 ]
  [[ "$output" == *"Users & Groups"* ]]
  [[ "$output" != *"REFUSED"* ]]
}

@test "gate: the auto-login pause names the current user, not a placeholder" {
  mr_stub defaults 'exit 1'
  run bash -c "$(cat "$REPO/install.sh")" < /dev/null
  [[ "$output" == *"$(id -un)"* ]]
}

@test "gate: a host with auto-login already on does not pause" {
  mr_stub defaults "echo $(id -un)"
  run bs_require_autologin
  [ "$status" -eq 0 ]
  [[ "$output" == *"enabled for '$(id -un)'"* ]]
}

# --- 1Password error classification (shared with the installer) ------------

@test "op errors: a missing vault item is distinguished" {
  run mr_op_error_class "\"runner-jit-pat\" isn't an item in the \"mac-runner\" vault"
  [ "$output" = "missing-item" ]
}

@test "op errors: a rejected token is distinguished" {
  run mr_op_error_class "(401) Unauthorized: invalid service account token"
  [ "$output" = "bad-token" ]
}

@test "op errors: anything else is treated as unreachable, not as a bad token" {
  # The three call for different actions — rotate the token, fix the vault, or
  # wait — so a network blip must not send an operator off rotating secrets.
  run mr_op_error_class "error: connection refused"
  [ "$output" = "unreachable" ]
}

# --- auto-login must name the account that will own the LaunchAgents --------

@test "autologin: a different user's auto-login is rejected, not accepted" {
  # The slot agents live in ~/Library/LaunchAgents and load only in that
  # user's GUI session. A Mac that auto-logs in as someone else comes back
  # from a reboot with no runner, and nothing about it looks broken.
  mr_stub defaults 'echo somebody-else'
  run bs_require_autologin
  [ "$status" -eq 11 ]
  [[ "$output" == *"somebody-else"* ]]
  [[ "$output" == *"$(id -un)"* ]]
}

@test "autologin: the installing user's own auto-login is accepted" {
  mr_stub defaults "echo $(id -un)"
  run bs_require_autologin
  [ "$status" -eq 0 ]
}

@test "gate: a mismatched auto-login stops the install before any change" {
  mr_stub defaults 'echo somebody-else'
  run bash -c "$(cat "$REPO/install.sh")" < /dev/null
  [ "$status" -eq 11 ]
  [[ "$output" != *"REFUSED"* ]]
}
