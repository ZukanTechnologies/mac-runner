#!/usr/bin/env bats
# Repo invariants (ZUK-2150) — the things that must stay true about what this
# repo owns, independent of any one helper's behavior.

load helper

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
}

@test "agent script is executable" {
  [ -x "$REPO/agent/mobile-runner-agent.sh" ]
}

@test "install.sh exists and is executable — it is the product" {
  # The README publishes a curl|bash one-liner pointing at this path on HEAD.
  # For most of this repo's life the file was missing and that command 404'd.
  [ -f "$REPO/install.sh" ]
  [ -x "$REPO/install.sh" ]
}

@test "install.sh is parseable by bash 3.2 — the shell that runs the one-liner" {
  # /bin/bash on macOS is still 3.2 and the entrypoint runs before Homebrew
  # exists, so a bash-4 construct here breaks every fresh install.
  [ -x /bin/bash ] || skip "no /bin/bash"
  run /bin/bash -n "$REPO/install.sh"
  [ "$status" -eq 0 ]
}

@test "every shell file parses" {
  local f
  for f in "$REPO"/install.sh "$REPO"/lib/*.sh "$REPO"/agent/*.sh; do
    run bash -n "$f"
    [ "$status" -eq 0 ] || {
      echo "failed to parse: $f"
      return 1
    }
  done
}

@test "plist template carries no credential value" {
  ! grep -E "ghp_|github_pat_" "$REPO/agent/com.zukan.mobile-runner-agent.plist.tmpl"
}

@test "no shell file carries a credential value" {
  ! grep -rE "ghp_[A-Za-z0-9]{20}|github_pat_[A-Za-z0-9_]{20}" \
      "$REPO/install.sh" "$REPO/lib" "$REPO/agent"
}

@test "IMAGE_VERSION pin exists and holds one valid version (FR-015)" {
  # The pin is the fleet's image audit trail and the default source of the
  # version every install pulls. It briefly lived in the zukan monorepo
  # instead — which is private, so the public installer could not read it.
  [ -f "$REPO/IMAGE_VERSION" ]
  # shellcheck source=/dev/null
  source "$REPO/lib/common.sh"
  run mr_read_pin "$REPO/IMAGE_VERSION"
  [ "$status" -eq 0 ]
}

@test "no stale in-repo copy of the image template has reappeared" {
  # The packer fork here drifted to a pre-ZUK-2131 template building Xcode
  # 26.5 while zukan built 26.6 — an image that cannot honestly carry the
  # xcode-26.6 capability label the mobile workflows gate on. The template has
  # one home (zukan's infra/mobile-ci/packer/); the PIN has one home (here).
  [ ! -e "$REPO/packer" ]
}
