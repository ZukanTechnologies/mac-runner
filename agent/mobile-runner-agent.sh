#!/usr/bin/env bash
# Ephemeral mobile-runner agent — ZUK-1994 (research D12), credentials
# hardened in ZUK-2154 (spec 027-mac-runner-bootstrap, FR-010).
#
# Runs on each mobile-runner Mac host under launchd (one agent per VM slot;
# see com.zukan.mobile-runner-agent.plist.tmpl). Loop:
#
#   op-read the JIT PAT → tart clone base → tart run (headless) →
#   JIT-register a GitHub Actions runner INSIDE the VM → runner takes
#   exactly ONE job → VM deleted.
#
# Clean per-job state comes from the clone-then-delete lifecycle — the
# base image is never mutated, so there is no config drift (the reason
# persistent runners were rejected in D12).
#
# Credentials (FR-010 — nothing at rest but the service-account token):
#   The GitHub JIT-registration PAT is fetched from 1Password at EVERY
#   cycle via `op read op://mac-runner/runner-jit-pat/credential`, using
#   the service-account token file (0600). Rotating the PAT in 1Password
#   requires no host visits. ZUKAN_GH_PAT as an env var is a LOCAL-DEBUG
#   override only — never set it in a plist.
#
# Host env (set in the plist by the installer):
#   BASE_IMAGE       e.g. zukan-mobile-runner-2026.07.2 (local tart image)
#   SLOT             1..N — unique per agent instance on this host.
#   GH_ORG           org to register the runner under (default ZukanTechnologies).
#   RUNNER_GROUP_ID  org runner group id (default 1 = "Default"; the group must
#                    grant the zukan repo access).
#   RUNNER_EXTRA_LABELS  optional, comma-separated.
#   ZUKAN_OP_TOKEN_FILE  service-account token path
#                        (default ~/.config/zukan-runner/op-token).
#   OP_RETRY_DELAY   seconds between op-read retries (default 5; tests use 0).

ORG="${GH_ORG:-ZukanTechnologies}"
OP_ITEM_REF="${OP_ITEM_REF:-op://mac-runner/runner-jit-pat/credential}"
OP_RETRY_DELAY="${OP_RETRY_DELAY:-5}"

log() { echo "[agent] $*" >&2; }

# Fetch the JIT-registration PAT. Prints the PAT on stdout; diagnostics go
# to stderr. Retries ×3 with backoff, then logs one of three distinguishable
# failure classes: "missing item", "bad token", "op unreachable".
resolve_zukan_gh_pat() {
  if [[ -n "${ZUKAN_GH_PAT:-}" ]]; then
    log "using ZUKAN_GH_PAT env override (local debug only)"
    printf '%s\n' "${ZUKAN_GH_PAT}"
    return 0
  fi

  local token_file="${ZUKAN_OP_TOKEN_FILE:-${HOME}/.config/zukan-runner/op-token}"
  if [[ ! -r "${token_file}" ]]; then
    log "op token file missing/unreadable: ${token_file} — run the mac-runner installer"
    return 1
  fi

  local attempt out
  for attempt in 1 2 3; do
    if out="$(OP_SERVICE_ACCOUNT_TOKEN="$(cat "${token_file}")" op read "${OP_ITEM_REF}" 2>&1)"; then
      printf '%s\n' "${out}"
      return 0
    fi
    log "op read failed (attempt ${attempt}/3): ${out}"
    [[ ${attempt} -lt 3 ]] && sleep "${OP_RETRY_DELAY}"
  done

  case "${out}" in
    *"isn't an item"*|*"not found"*|*"no vault"*)
      log "op read failed: missing item (${OP_ITEM_REF}) — check the mac-runner vault" ;;
    *401*|*Unauthorized*|*"invalid service account token"*)
      log "op read failed: bad token — rotate the service-account token, then re-run the installer" ;;
    *)
      log "op unreachable — check network / 1Password status; in-flight jobs are unaffected" ;;
  esac
  return 1
}

main() {
  # Host prereqs (fail fast — a silently broken agent looks like "no runners"):
  #   brew install jq 1password-cli; brew trust cirruslabs/cli && brew install cirruslabs/cli/tart
  #   brew install hudochenkov/sshpass/sshpass
  local bin
  for bin in tart sshpass jq curl op; do
    command -v "$bin" >/dev/null 2>&1 || { log "missing host dependency: $bin (brew install jq 1password-cli cirruslabs/cli/tart; brew install hudochenkov/sshpass/sshpass)"; exit 1; }
  done

  BASE_IMAGE="${BASE_IMAGE:?set BASE_IMAGE to the tart base image name}"
  SLOT="${SLOT:?set SLOT (unique per agent on this host)}"
  local HOSTTAG
  HOSTTAG="$(hostname -s)"
  # Force password auth (sshpass supplies it). Without this, ssh offers every
  # key in the host's ssh-agent first and trips sshd's MaxAuthTries →
  # "Too many authentication failures" before the password is ever tried.
  local SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10
                  -o PreferredAuthentications=password -o PubkeyAuthentication=no
                  -o IdentitiesOnly=yes -o NumberOfPasswordPrompts=1)

  while true; do
    # Fetch the PAT BEFORE any VM exists: a credential failure can never
    # orphan or kill a VM (FR-010 / in-flight safety).
    local PAT
    if ! PAT="$(resolve_zukan_gh_pat)"; then
      log "credential fetch failed; backing off 60s"
      sleep 60
      continue
    fi

    local STAMP VM RUNNER_NAME LABELS
    STAMP="$(date +%s)"
    VM="ci-${HOSTTAG}-${SLOT}-${STAMP}"
    # Unique per cycle — a fixed name 409s ("already exists") if a prior JIT
    # runner lingers offline (e.g. a VM killed mid-run), wedging the slot.
    RUNNER_NAME="mobile-runner-${HOSTTAG}-${SLOT}-${STAMP}"
    LABELS="mobile-runner,macos,arm64${RUNNER_EXTRA_LABELS:+,${RUNNER_EXTRA_LABELS}}"

    log "cloning ${BASE_IMAGE} → ${VM}"
    tart clone "${BASE_IMAGE}" "${VM}"

    cleanup() {
      tart stop "${VM}" 2>/dev/null || true
      tart delete "${VM}" 2>/dev/null || true
    }
    trap cleanup EXIT

    tart run --no-graphics "${VM}" &
    local TART_PID=$!

    # Wait for the VM to get an IP + SSH.
    local IP=""
    for _ in $(seq 1 60); do
      IP="$(tart ip "${VM}" 2>/dev/null || true)"
      [[ -n "${IP}" ]] && sshpass -p admin ssh "${SSH_OPTS[@]}" "admin@${IP}" true 2>/dev/null && break
      sleep 5
    done
    if [[ -z "${IP}" ]]; then
      log "VM never came up; recycling"
      cleanup; trap - EXIT; continue
    fi

    # Mint a single-job JIT runner config at the ORG level (ephemeral by
    # construction — GitHub deregisters it after one job).
    local JIT_CONFIG
    # shellcheck disable=SC2001  # sed keeps the quoted-JSON label join readable
    JIT_CONFIG="$(curl -fsS -X POST \
      -H "Authorization: Bearer ${PAT}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/orgs/${ORG}/actions/runners/generate-jitconfig" \
      -d "{\"name\":\"${RUNNER_NAME}\",\"runner_group_id\":${RUNNER_GROUP_ID:-1},\"labels\":[\"$(echo "${LABELS}" | sed 's/,/","/g')\"],\"work_folder\":\"_work\"}" \
      | jq -r '.encoded_jit_config')"
    if [[ -z "${JIT_CONFIG}" || "${JIT_CONFIG}" == "null" ]]; then
      log "JIT config mint failed; backing off 60s"
      cleanup; trap - EXIT; sleep 60; continue
    fi

    # Run exactly one job inside the VM, then tear the VM down.
    sshpass -p admin ssh "${SSH_OPTS[@]}" "admin@${IP}" \
      "source ~/.zprofile && cd ~/actions-runner && ./run.sh --jitconfig '${JIT_CONFIG}'" \
      || log "runner exited non-zero (job failure is fine — VM is disposable)"

    cleanup
    trap - EXIT
    wait "${TART_PID}" 2>/dev/null || true
    log "job cycle complete; next clone"
  done
}

# Executed → run the loop; sourced (tests) → expose functions only.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  main "$@"
fi
