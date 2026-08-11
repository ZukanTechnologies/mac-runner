#!/usr/bin/env bats
# Harness smoke test (ZUK-2150) — proves the bats CI job runs and pins the
# invariants of what this repo owns.
#
# The IMAGE_VERSION format test and the packer/build.sh executable check were
# removed when the image template moved to zukan's infra/mobile-ci/packer/:
# this repo no longer carries either file, so those assertions pinned nothing
# here. The template's own invariants are covered where it now lives.

@test "agent script is executable" {
  [ -x "$BATS_TEST_DIRNAME/../agent/mobile-runner-agent.sh" ]
}

@test "plist template carries no credential value" {
  ! grep -E "ghp_|github_pat_" "$BATS_TEST_DIRNAME/../agent/com.zukan.mobile-runner-agent.plist.tmpl"
}

@test "no stale in-repo copy of the image template has reappeared" {
  # The fork here drifted to a pre-ZUK-2131 template building Xcode 26.5 while
  # zukan built 26.6 — an image that cannot honestly carry the xcode-26.6
  # capability label the mobile workflows gate on. One source of truth: if a
  # packer/ dir or IMAGE_VERSION pin shows up here again, that drift is back.
  [ ! -e "$BATS_TEST_DIRNAME/../packer" ]
  [ ! -e "$BATS_TEST_DIRNAME/../IMAGE_VERSION" ]
}
