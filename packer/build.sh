#!/usr/bin/env bash
# Build (and optionally push) the Zukan mobile CI base image — ZUK-1994.
#
# Runs on an Apple-Silicon build Mac (Tart is Apple-Silicon-only). Human step; see
# docs/mobile-cicd.md § "Base image" and the ZUK-1994 handoff runbook.
#
#   ./build.sh 2026.07.1            # build zukan-mobile-runner:2026.07.1
#   PUSH=1 ./build.sh 2026.07.1     # …and push to GHCR for the other hosts
#
# Prereqs on the host. tart's cirruslabs tap must be trusted first (Homebrew
# 4.x untrusted-tap gate; tart pulls in softnet). packer left Homebrew core in
# the HashiCorp BSL relicense, and sshpass is never in core — both need taps:
#   brew install jq
#   brew trust cirruslabs/cli && brew install cirruslabs/cli/tart
#   brew tap hashicorp/tap && brew install hashicorp/tap/packer
#   brew install hudochenkov/sshpass/sshpass
# (sshpass + jq are for the sibling runner agent.) For PUSH=1 also a
# `tart login ghcr.io` with a PAT that has write:packages.
set -euo pipefail

VERSION="${1:?usage: build.sh <version> (e.g. 2026.07.1)}"
IMAGE="zukan-mobile-runner-${VERSION}"
REGISTRY="${REGISTRY:-ghcr.io/zukantechnologies}"

cd "$(dirname "$0")"

packer init .
packer build -var "image_version=${VERSION}" zukan-mobile-runner.pkr.hcl

if [[ "${PUSH:-0}" == "1" ]]; then
  tart push "${IMAGE}" "${REGISTRY}/zukan-mobile-runner:${VERSION}"
  echo "Pushed ${REGISTRY}/zukan-mobile-runner:${VERSION}"
  echo "On each other mobile-runner host: tart pull ${REGISTRY}/zukan-mobile-runner:${VERSION}"
fi

echo "Done. Point mobile-runner-agent.sh at BASE_IMAGE=${IMAGE} (or the GHCR ref)."
