#!/usr/bin/env bash
# Ephemeral mobile-runner agent — ZUK-1994 (research D12).
#
# Runs on each mobile-runner Mac host under launchd (one agent per VM slot;
# see com.zukan.mobile-runner-agent.plist). Loop:
#
#   tart clone base → tart run (headless) → JIT-register a GitHub Actions
#   runner INSIDE the VM → runner takes exactly ONE job → VM deleted.
#
# Clean per-job state comes from the clone-then-delete lifecycle — the
# base image is never mutated, so there is no config drift (the reason
# persistent runners were rejected in D12).
#
# Host env (set in the plist, values from the runbook):
#   ZUKAN_GH_PAT     Fine-grained PAT owned by the ZukanTechnologies org with
#                    org permission "Self-hosted runners: Read and write" (or a
#                    GitHub App token) — used ONLY to mint org-level JIT configs.
#   BASE_IMAGE       e.g. zukan-mobile-runner-2026.07.1 (local tart image)
#   SLOT             1..N — unique per agent instance on this host.
#   GH_ORG           org to register the runner under (default ZukanTechnologies).
#   RUNNER_GROUP_ID  org runner group id (default 1 = "Default"; the group must
#                    grant the zukan repo access).
#   RUNNER_EXTRA_LABELS  optional, comma-separated.
set -euo pipefail

ORG="${GH_ORG:-ZukanTechnologies}"

# Host prereqs (fail fast — a silently broken agent looks like "no runners"):
#   brew install jq; brew trust cirruslabs/cli && brew install cirruslabs/cli/tart
#   brew install hudochenkov/sshpass/sshpass
for bin in tart sshpass jq curl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "[agent] missing host dependency: $bin (brew install jq cirruslabs/cli/tart; brew install hudochenkov/sshpass/sshpass)" >&2; exit 1; }
done

BASE_IMAGE="${BASE_IMAGE:?set BASE_IMAGE to the tart base image name}"
SLOT="${SLOT:?set SLOT (unique per agent on this host)}"
HOSTTAG="$(hostname -s)"
# Force password auth (sshpass supplies it). Without this, ssh offers every
# key in the host's ssh-agent first and trips sshd's MaxAuthTries →
# "Too many authentication failures" before the password is ever tried.
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10
          -o PreferredAuthentications=password -o PubkeyAuthentication=no
          -o IdentitiesOnly=yes -o NumberOfPasswordPrompts=1)

while true; do
  STAMP="$(date +%s)"
  VM="ci-${HOSTTAG}-${SLOT}-${STAMP}"
  # Unique per cycle — a fixed name 409s ("already exists") if a prior JIT
  # runner lingers offline (e.g. a VM killed mid-run), wedging the slot.
  RUNNER_NAME="mobile-runner-${HOSTTAG}-${SLOT}-${STAMP}"
  LABELS="mobile-runner,macos,arm64${RUNNER_EXTRA_LABELS:+,${RUNNER_EXTRA_LABELS}}"

  echo "[agent] cloning ${BASE_IMAGE} → ${VM}"
  tart clone "${BASE_IMAGE}" "${VM}"

  cleanup() {
    tart stop "${VM}" 2>/dev/null || true
    tart delete "${VM}" 2>/dev/null || true
  }
  trap cleanup EXIT

  tart run --no-graphics "${VM}" &
  TART_PID=$!

  # Wait for the VM to get an IP + SSH.
  IP=""
  for _ in $(seq 1 60); do
    IP="$(tart ip "${VM}" 2>/dev/null || true)"
    [[ -n "${IP}" ]] && sshpass -p admin ssh "${SSH_OPTS[@]}" "admin@${IP}" true 2>/dev/null && break
    sleep 5
  done
  if [[ -z "${IP}" ]]; then
    echo "[agent] VM never came up; recycling" >&2
    cleanup; trap - EXIT; continue
  fi

  # Mint a single-job JIT runner config at the ORG level (ephemeral by
  # construction — GitHub deregisters it after one job).
  # shellcheck disable=SC2001  # sed keeps the quoted-JSON label join readable
  JIT_CONFIG="$(curl -fsS -X POST \
    -H "Authorization: Bearer ${ZUKAN_GH_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/${ORG}/actions/runners/generate-jitconfig" \
    -d "{\"name\":\"${RUNNER_NAME}\",\"runner_group_id\":${RUNNER_GROUP_ID:-1},\"labels\":[\"$(echo "${LABELS}" | sed 's/,/","/g')\"],\"work_folder\":\"_work\"}" \
    | jq -r '.encoded_jit_config')"
  if [[ -z "${JIT_CONFIG}" || "${JIT_CONFIG}" == "null" ]]; then
    echo "[agent] JIT config mint failed; backing off 60s" >&2
    cleanup; trap - EXIT; sleep 60; continue
  fi

  # Run exactly one job inside the VM, then tear the VM down.
  sshpass -p admin ssh "${SSH_OPTS[@]}" "admin@${IP}" \
    "source ~/.zprofile && cd ~/actions-runner && ./run.sh --jitconfig '${JIT_CONFIG}'" \
    || echo "[agent] runner exited non-zero (job failure is fine — VM is disposable)"

  cleanup
  trap - EXIT
  wait "${TART_PID}" 2>/dev/null || true
  echo "[agent] job cycle complete; next clone"
done
