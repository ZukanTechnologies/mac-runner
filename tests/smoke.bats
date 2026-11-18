#!/usr/bin/env bats
# Repo invariants (ZUK-2150) — the things that must stay true about what this
# repo owns, independent of any one helper's behavior.

load helper

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
}

@test "the engine pins are present and well-formed" {
  # This repo ships no runner loop. It pins one: a commit sha of the engine
  # repo, and the checksum of the file at that commit. Both are production
  # inputs — every host installs whatever they say.
  # shellcheck source=/dev/null
  source "$REPO/lib/common.sh"
  local commit sha
  commit="$(mr_read_ref_pin "$REPO/SETUP_VERSION")" || return 1
  mr_commit_is_valid "$commit" || { echo "SETUP_VERSION is not a commit sha: $commit"; return 1; }
  sha="$(mr_read_ref_pin "$REPO/SETUP_SHA256")" || return 1
  mr_sha256_is_valid "$sha" || { echo "SETUP_SHA256 is not a sha256: $sha"; return 1; }
}

@test "the runner version pin is a version" {
  # shellcheck source=/dev/null
  source "$REPO/lib/common.sh"
  local v; v="$(mr_read_ref_pin "$REPO/RUNNER_VERSION")" || return 1
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "not a runner version: $v"; return 1; }
}

@test "this repo implements no runner loop of its own" {
  # The whole point of the wrapper: one engine, pinned, not a second copy that
  # drifts. A re-introduced agent script is the regression to catch.
  [ ! -e "$REPO/agent" ] || { echo "agent/ is back — the engine is pinned, not vendored"; return 1; }
}

@test "install.sh exists and is executable — it is the product" {
  # The README publishes a curl|bash one-liner pointing at this path on HEAD.
  # For most of this repo's life the file was missing and that command 404'd.
  [ -f "$REPO/install.sh" ]
  [ -x "$REPO/install.sh" ]
}

@test "every shell file is parseable by bash 3.2" {
  # /bin/bash on macOS is still 3.2 and there is no point at which this code is
  # guaranteed a newer one: the entrypoint runs before Homebrew exists, it
  # `exec bash lib/install-main.sh` (still /bin/bash unless someone has put a
  # brewed bash first on PATH), and the agent's launchd plist puts
  # /opt/homebrew/bin ahead of /bin but installs no bash there. A bash-4
  # construct in any of these breaks a fresh install with a syntax error.
  [ -x /bin/bash ] || skip "no /bin/bash"
  local f
  for f in "$REPO"/install.sh "$REPO"/lib/*.sh; do
    run /bin/bash -n "$f"
    [ "$status" -eq 0 ] || {
      echo "not bash-3.2 parseable: $f"
      echo "$output"
      return 1
    }
  done
}

@test "every shell file parses" {
  local f
  for f in "$REPO"/install.sh "$REPO"/lib/*.sh; do
    run bash -n "$f"
    [ "$status" -eq 0 ] || {
      echo "failed to parse: $f"
      return 1
    }
  done
}

@test "no shell file carries a credential value" {
  ! grep -rE "ghp_[A-Za-z0-9]{20}|github_pat_[A-Za-z0-9_]{20}" \
      "$REPO/install.sh" "$REPO/lib"
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
