#!/usr/bin/env bats
# Harness smoke test (ZUK-2150) — proves the bats CI job runs, and pins the
# IMAGE_VERSION file format the installer will parse (calendar versioning).

@test "IMAGE_VERSION exists and is a single calendar-version line" {
  run cat "$BATS_TEST_DIRNAME/../IMAGE_VERSION"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]+$ ]]
}

@test "agent script and packer build script are executable" {
  [ -x "$BATS_TEST_DIRNAME/../agent/mobile-runner-agent.sh" ]
  [ -x "$BATS_TEST_DIRNAME/../packer/build.sh" ]
}

@test "plist template carries no credential value" {
  ! grep -E "ghp_|github_pat_" "$BATS_TEST_DIRNAME/../agent/com.zukan.mobile-runner-agent.plist.tmpl"
}
