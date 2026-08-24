#!/usr/bin/env bash
# lib/install-main.sh — the real installer (ZUK-2160/T014, ZUK-2161/T015,
# ZUK-2164/T018). Never invoked directly by an operator: install.sh execs it
# from the clone at /opt/zukan/mac-runner.
#
# This is the acting half. Every decision it makes lives in lib/common.sh and
# is unit-tested; what is here is the sequence of side effects, in the order
# the data model requires:
#
#   preflight → sudo prep → toolchain → secrets → image → in-flight guard
#            → slots → prune → verify → report
#
# Two orderings are load-bearing, not stylistic:
#   * the image prune runs AFTER the slots restart, so a slot is never left
#     pointing at an image that has just been deleted;
#   * the in-flight guard runs BEFORE anything touches launchd, because
#     restarting a slot agent kills whatever CI job its VM is running.
#
# Exit codes: contracts/installer-cli.md (10/11 preflight, 20 secrets,
# 21 registry, 30 converge, 40 verify).

MR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091  # resolved at runtime from the clone, not statically
. "${MR_ROOT}/lib/common.sh"

MR_INSTALL_ROOT="${MR_INSTALL_ROOT:-/opt/zukan}"
MR_AGENT_SRC="${MR_ROOT}/agent/mobile-runner-agent.sh"
MR_AGENT_DEST="${MR_INSTALL_ROOT}/mobile-runner-agent.sh"
MR_PLIST_TMPL="${MR_ROOT}/agent/com.zukan.mobile-runner-agent.plist.tmpl"
MR_PIN_FILE="${MR_ROOT}/IMAGE_VERSION"
MR_LAUNCH_AGENTS="${MR_LAUNCH_AGENTS:-${HOME}/Library/LaunchAgents}"
MR_TOKEN_FILE="${ZUKAN_OP_TOKEN_FILE:-${HOME}/.config/zukan-runner/op-token}"
MR_VAULT="${MR_VAULT:-mac-runner}"
MR_GH_ORG="${GH_ORG:-ZukanTechnologies}"
MR_DISK_FLOOR_GB="${MR_DISK_FLOOR_GB:-120}"
# How long to wait for a slot agent to register a runner before calling the
# health check failed. Agents register at cycle start, so this is ~one clone.
MR_VERIFY_TIMEOUT_S="${MR_VERIFY_TIMEOUT_S:-300}"
# How long to wait for in-flight CI jobs to finish before giving up and telling
# the operator about FORCE=1. A mobile E2E job runs well under this.
MR_INFLIGHT_TIMEOUT_S="${MR_INFLIGHT_TIMEOUT_S:-2700}"

MR_GUI_DOMAIN="gui/$(id -u)"

# --- 1Password --------------------------------------------------------------

# Read one vault reference. Prints the secret on stdout and NOTHING else;
# diagnostics go to stderr. Tracing is disabled for the duration so that a
# `bash -x` run can never put a credential in a log (contract: Output).
mr_op_read() {
  local ref="$1" out err err_file rc class
  local restore_x=""
  case "$-" in *x*) restore_x=1; set +x ;; esac

  err_file="$(mktemp)"
  if out="$(OP_SERVICE_ACCOUNT_TOKEN="$(cat "$MR_TOKEN_FILE" 2>/dev/null)" \
            op read "$ref" 2>"$err_file")"; then
    rm -f "$err_file"
    [ -n "${out//[[:space:]]/}" ] || {
      mr_err "1Password returned an empty value for ${ref} — check the item in the ${MR_VAULT} vault"
      [ -n "$restore_x" ] && set -x
      return 1
    }
    printf '%s\n' "$out"
    [ -n "$restore_x" ] && set -x
    return 0
  fi
  err="$(cat "$err_file")"
  rm -f "$err_file"
  class="$(mr_op_error_class "$err")"
  case "$class" in
    missing-item) mr_err "1Password has no ${ref} — the ${MR_VAULT} vault is missing that item or field (see the credentials table in the README)" ;;
    bad-token)    mr_err "the 1Password service-account token was rejected. Rotate it and re-run this command; the file is ${MR_TOKEN_FILE}" ;;
    *)            mr_err "1Password is unreachable. Check the network and https://status.1password.com, then re-run this command" ;;
  esac
  rc=1
  [ -n "$restore_x" ] && set -x
  return "$rc"
}

mr_token_is_valid() {
  [ -r "$MR_TOKEN_FILE" ] || return 1
  OP_SERVICE_ACCOUNT_TOKEN="$(cat "$MR_TOKEN_FILE")" op whoami >/dev/null 2>&1
}

mr_prompt_for_token() {
  local token
  # The one question the default install asks (FR-002).
  printf '\n[install] Paste the 1Password service-account token for the "%s" vault.\n' "$MR_VAULT" >&2
  printf '[install] (Nothing will echo. 1Password -> Developer -> Service accounts -> mac-runner-hosts)\n' >&2
  printf '[install] token: ' >&2
  stty -echo 2>/dev/null
  IFS= read -r token
  stty echo 2>/dev/null
  printf '\n' >&2
  [ -n "$token" ] || { mr_err "no token entered. Re-run this command when you have it."; return 1; }
  mr_write_token "$token"
}

# The only place the token file is ever written. Creates under umask 077, sets
# the mode explicitly, CHECKS that it took, and renames into place — so there
# is never a moment where the real path exists with loose permissions, and a
# failed chmod cannot be mistaken for a securely stored token. This file is the
# one secret at rest on the host (FR-009).
mr_write_token() {
  local value="$1" tmp
  mkdir -p "$(dirname "$MR_TOKEN_FILE")" || {
    mr_err "could not create $(dirname "$MR_TOKEN_FILE")"
    return 1
  }
  tmp="${MR_TOKEN_FILE}.new.$$"
  ( umask 077; printf '%s\n' "$value" > "$tmp" ) || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || {
    mr_err "could not set owner-only permissions on the token file; refusing to store it"
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$MR_TOKEN_FILE" || { rm -f "$tmp"; return 1; }
  return 0
}

mr_converge_secrets() {
  if mr_token_is_valid; then
    mr_log "1Password: existing service-account token is valid"
    mr_summary_add unchanged "1Password service-account token"
  else
    if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
      # Scripted path (documented in the CLI contract): pre-supplying the token
      # skips the prompt entirely.
      mr_write_token "$OP_SERVICE_ACCOUNT_TOKEN" || return "$MR_EXIT_SECRETS"
    else
      mr_prompt_for_token || return "$MR_EXIT_SECRETS"
    fi
    if ! mr_token_is_valid; then
      mr_err "that token was rejected by 1Password (op whoami failed). Check you copied the whole value, then re-run this command."
      return "$MR_EXIT_SECRETS"
    fi
    mr_log "1Password: service-account token accepted and stored 0600 at ${MR_TOKEN_FILE}"
    mr_summary_add installed "1Password service-account token"
  fi
  return 0
}

# --- toolchain --------------------------------------------------------------

mr_brew_has() { brew list --formula "$1" >/dev/null 2>&1; }

mr_converge_toolchain() {
  local formula
  mr_log "power settings: disabling sleep (sudo)"
  if ! sudo pmset -a sleep 0 disksleep 0; then
    mr_err "could not set power settings (sudo pmset). A host that sleeps stops taking jobs. Re-run this command."
    return "$MR_EXIT_CONVERGE"
  fi

  # Both formulae come from third-party taps that Homebrew will not load until
  # they are trusted ("Trust non-official tap formulae, casks or commands so
  # Homebrew may load them"). The old runbook trusted only cirruslabs/cli and
  # left hudochenkov/sshpass to whatever the operator had done interactively —
  # which is not a thing a one-command install can rely on.
  #
  # `|| true` throughout: on a Homebrew where trust is not required, or is
  # spelled differently, this is a no-op and the install proceeds. A failure to
  # trust surfaces as the brew install failing right below, with its own
  # message, rather than as an opaque exit here.
  local tap
  for tap in cirruslabs/cli hudochenkov/sshpass; do
    brew trust --tap "$tap" >/dev/null 2>&1 || true
  done

  for formula in jq 1password-cli cirruslabs/cli/tart hudochenkov/sshpass/sshpass; do
    if mr_brew_has "${formula##*/}"; then
      mr_summary_add unchanged "brew ${formula##*/}"
      continue
    fi
    mr_log "toolchain: installing ${formula}"
    if ! brew install --quiet "$formula"; then
      mr_err "brew install ${formula} failed. Re-run this command to retry."
      return "$MR_EXIT_CONVERGE"
    fi
    mr_summary_add installed "brew ${formula##*/}"
  done
  return 0
}

# --- image ------------------------------------------------------------------

mr_tart_json() { tart list --format json 2>/dev/null; }

mr_converge_image() {
  local version ref listing have_size need free
  version="$1"
  ref="$(mr_base_image_ref "$version")"
  listing="$(mr_tart_json)"

  if printf '%s' "$listing" | mr_image_names 2>/dev/null | mr_image_ref_present "$ref"; then
    mr_log "image: ${ref} already present"
    mr_summary_add unchanged "image ${ref}"
    return 0
  fi

  # FR-004: re-check disk against the real requirement immediately before the
  # download starts. The best available estimate of how big the incoming image
  # is, is how big the one already on this host is.
  local existing
  existing="$(printf '%s' "$listing" | mr_image_names | while IFS= read -r n; do
    mr_image_version_of "$n" >/dev/null 2>&1 && printf '%s\n' "$n"
  done | head -1)"
  have_size=""
  if [ -n "$existing" ]; then
    have_size="$(printf '%s' "$listing" | mr_image_size_gb "$existing")" || have_size=""
  fi
  need="$(mr_disk_requirement_gb "$have_size" "$MR_DISK_FLOOR_GB")" || need="$MR_DISK_FLOOR_GB"
  # Fails closed for the same reason the in-flight guard does: this gates a
  # tens-of-GB download, and an unreadable `df` is not permission to start it.
  if ! free="$(mr_free_disk_gb /)"; then
    mr_err "could not read free disk space, so the ${ref} pull is refused rather than started blind. Check 'df -g /' and re-run this command."
    return "$MR_EXIT_REMEDIABLE"
  fi
  if [ "$free" -lt "$need" ]; then
    mr_err "not enough free disk to pull ${ref}: need ~${need} GB, have ${free} GB. The previous image is only removed after the new one is running, so both must fit. Free some space, then re-run this command."
    return "$MR_EXIT_REMEDIABLE"
  fi

  local ghcr_user ghcr_pat
  ghcr_user="$(mr_op_read "op://${MR_VAULT}/ghcr-pull-pat/username")" || return "$MR_EXIT_SECRETS"
  ghcr_pat="$(mr_op_read "op://${MR_VAULT}/ghcr-pull-pat/credential")" || return "$MR_EXIT_SECRETS"

  mr_log "registry: signing in to ghcr.io as ${ghcr_user}"
  if ! printf '%s' "$ghcr_pat" | tart login ghcr.io --username "$ghcr_user" --password-stdin; then
    mr_err "ghcr.io sign-in failed. The ghcr-pull-pat item in the ${MR_VAULT} vault needs a classic PAT with read:packages, and its username field must name that PAT's account."
    return "$MR_EXIT_REGISTRY"
  fi
  unset ghcr_pat

  mr_log "image: pulling ${ref} (tens of GB — this is the slow part)"
  if ! tart pull "$ref"; then
    mr_err "could not pull ${ref}. Check that version exists in the registry (the IMAGE_VERSION pin) and that ghcr-pull-pat can read it. Re-run this command to resume."
    return "$MR_EXIT_REGISTRY"
  fi
  mr_summary_add installed "image ${ref}"
  return 0
}

# Runs only after the slots are back up on the new image (see file header).
mr_prune_images() {
  local keep_version="$1" name pruned=0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    mr_log "image: removing superseded ${name}"
    if tart delete "$name" >/dev/null 2>&1; then
      mr_summary_add removed "image ${name}"
      pruned=$((pruned + 1))
    else
      # Not fatal: Tart evicts least-recently-used OCI-cache entries by itself
      # when it needs the room, so the worst case is disk it reclaims later.
      mr_warn "could not remove ${name}; Tart will reclaim it from its cache when it needs the space."
    fi
  done <<EOF
$(mr_tart_json | mr_image_names | mr_image_prune_list "$keep_version")
EOF
  [ "$pruned" -eq 0 ] && mr_log "image: nothing superseded to remove"
  return 0
}

# --- in-flight guard (FR-008) -----------------------------------------------

# Prints the number of running ci-* VMs. Returns NON-ZERO when the listing
# could not be read at all — "I don't know" must not be reported as "0",
# because 0 is what tells the guard it is safe to restart the slots.
mr_count_running_ci_vms() {
  local listing
  listing="$(mr_tart_json)" || return 1
  [ -n "$listing" ] || return 1
  printf '%s' "$listing" | mr_running_ci_vm_names | grep -c . || true
}

# Actually stop and delete the running ci-* clones.
#
# Without this, FORCE=1 only PRINTED that it was terminating them: on an
# otherwise converged host, mr_converge_slots finds matching plists and loaded
# agents, changes nothing, and the install reports success while the in-flight
# VM keeps running. The announcement has to be true.
mr_terminate_ci_vms() {
  local vm
  for vm in $(mr_tart_json | mr_running_ci_vm_names); do
    [ -n "$vm" ] || continue
    mr_log "slots: terminating ${vm}"
    tart stop "$vm" >/dev/null 2>&1 || true
    tart delete "$vm" >/dev/null 2>&1 || mr_warn "could not delete ${vm}; it will be recycled by its slot agent"
    mr_summary_add removed "in-flight VM ${vm}"
  done
  return 0
}

mr_wait_for_idle() {
  local waited=0 running action unknown=0
  while :; do
    if ! running="$(mr_count_running_ci_vms)"; then
      # tart should be working by now — the toolchain and image steps both
      # used it moments ago — so this is most likely transient. Retry a few
      # times rather than either blocking for the full timeout or treating an
      # unreadable host as idle and tearing down a live job.
      unknown=$((unknown + 1))
      if [ "$unknown" -le 3 ]; then
        mr_warn "could not read 'tart list' to check for in-flight jobs (attempt ${unknown}/3); retrying"
        sleep 5
        continue
      fi
      if [ "${FORCE:-0}" = "1" ]; then
        mr_warn "still cannot read 'tart list', but FORCE=1 — restarting slots anyway"
        return 0
      fi
      # Fails CLOSED. The guard exists to avoid killing a running CI job, and
      # "I cannot tell" is exactly when proceeding is unsafe. Stopping costs a
      # re-run; guessing wrong costs somebody's job.
      mr_err "cannot read 'tart list' to tell whether a CI job is running on this host, so the slot restart is refused rather than done blind. Re-run this command, or re-run with FORCE=1 to restart regardless."
      return "$MR_EXIT_CONVERGE"
    fi
    unknown=0
    action="$(mr_inflight_action "$running" "${FORCE:-0}")"
    case "$action" in
      proceed)
        [ "$waited" -gt 0 ] && mr_log "slots: idle now, continuing"
        return 0
        ;;
      force)
        mr_log "slots: FORCE=1 — terminating ${running} in-flight CI VM(s); their jobs are ephemeral and retry on the next cycle"
        mr_terminate_ci_vms
        return 0
        ;;
    esac
    if [ "$waited" -ge "$MR_INFLIGHT_TIMEOUT_S" ]; then
      mr_err "still ${running} CI job(s) running on this host after $((waited / 60)) minutes. Wait and re-run, or re-run with FORCE=1 to terminate them (they retry automatically)."
      return "$MR_EXIT_CONVERGE"
    fi
    # The contract calls for a countdown, and a 45-minute silent wait looks
    # indistinguishable from a hang: announce once, then tick every 5 minutes
    # with the time left.
    if [ "$waited" -eq 0 ]; then
      mr_log "slots: ${running} CI job(s) in flight — waiting for them to finish (FORCE=1 skips this and terminates them)"
    elif [ $((waited % 300)) -eq 0 ]; then
      mr_log "slots: still ${running} in flight; $(( (MR_INFLIGHT_TIMEOUT_S - waited) / 60 )) min left before giving up"
    fi
    sleep 15
    waited=$((waited + 15))
  done
}

# --- slots ------------------------------------------------------------------

mr_bootout_slot() {
  local slot="$1" label
  label="$(mr_plist_label "$slot")"
  launchctl bootout "${MR_GUI_DOMAIN}/${label}" >/dev/null 2>&1 || true
}

mr_converge_agent_script() {
  mkdir -p "$MR_INSTALL_ROOT" 2>/dev/null || {
    sudo mkdir -p "$MR_INSTALL_ROOT" && sudo chown "$(id -u):$(id -g)" "$MR_INSTALL_ROOT"
  } || return "$MR_EXIT_CONVERGE"

  if [ -f "$MR_AGENT_DEST" ] && cmp -s "$MR_AGENT_SRC" "$MR_AGENT_DEST"; then
    mr_summary_add unchanged "agent ${MR_AGENT_DEST}"
    return 0
  fi

  # Write beside it and rename, never `cp` over the top. bash reads a script
  # incrementally as it runs, so overwriting the file in place would splice new
  # bytes into the agent that is running a CI job right now. A rename gives the
  # new file a new inode; the running agent keeps reading the old one until the
  # slot converge below restarts it.
  local tmp="${MR_AGENT_DEST}.new.$$"
  cp "$MR_AGENT_SRC" "$tmp" || return "$MR_EXIT_CONVERGE"
  chmod 755 "$tmp" || { rm -f "$tmp"; return "$MR_EXIT_CONVERGE"; }
  mv -f "$tmp" "$MR_AGENT_DEST" || { rm -f "$tmp"; return "$MR_EXIT_CONVERGE"; }
  mr_summary_add changed "agent ${MR_AGENT_DEST}"
  return 0
}

# Render every desired slot into a staging directory. Touches nothing on the
# host — this is the phase that is allowed to fail.
mr_render_all_slots() {
  local slots="$1" image="$2" staging="$3" slot labels log_path
  labels="${RUNNER_EXTRA_LABELS:-}"
  for slot in $(seq 1 "$slots"); do
    log_path="$(mr_default_log_path "$slot")"
    if ! mr_render_plist "$MR_PLIST_TMPL" "$slot" "$image" "$labels" "$log_path" "$MR_GH_ORG" \
         > "${staging}/slot${slot}.plist"; then
      mr_err "could not render the launchd plist for slot ${slot}. Nothing on this host has been changed — every slot is rendered before any is touched — so re-running this command is safe."
      return 1
    fi
  done
  return 0
}

# Install one staged plist, with rollback.
#
# launchd has no atomic swap: replacing a slot's definition means bootout then
# bootstrap, so there is an unavoidable window. Two things narrow it:
#
#   * the new plist is written BEFORE the old agent is unloaded, so a failed
#     copy costs nothing — the running agent is untouched;
#   * a failed bootstrap restores the previous definition and reloads it.
#
# The rollback matters most for the likeliest failure there is: running the
# installer over ssh instead of in the GUI session. That fails bootstrap for
# every slot, and without rollback it would take a working host down.
#
# Rolling back a legacy slot restores its plaintext-PAT plist. That is the
# right trade: the credential was already on disk, and a host with no agent is
# worse than a host still waiting to be migrated on the next run.
mr_install_slot() {
  local slot="$1" staged="$2" path backup

  path="$(mr_plist_path "$slot")"
  backup=""
  if [ -f "$path" ]; then
    backup="${path}.mr-backup.$$"
    if ! cp "$path" "$backup"; then
      mr_err "could not back up the current slot ${slot} definition; refusing to replace it."
      return "$MR_EXIT_CONVERGE"
    fi
  fi

  if ! cp "$staged" "$path"; then
    mr_err "could not write ${path}. The existing slot ${slot} agent is still loaded and untouched."
    [ -n "$backup" ] && mv -f "$backup" "$path"
    return "$MR_EXIT_CONVERGE"
  fi

  mr_bootout_slot "$slot"
  if launchctl bootstrap "$MR_GUI_DOMAIN" "$path"; then
    [ -n "$backup" ] && rm -f "$backup"
    return 0
  fi

  mr_err "launchctl could not load slot ${slot}. This must run in the logged-in GUI session (not over ssh, not as a LaunchDaemon) — see the README's host session rule."
  if [ -n "$backup" ]; then
    mr_warn "restoring the previous slot ${slot} definition and reloading it"
    mv -f "$backup" "$path"
    launchctl bootstrap "$MR_GUI_DOMAIN" "$path" >/dev/null 2>&1 \
      || mr_warn "could not reload the previous slot ${slot} agent either; this host has no agent on slot ${slot} until a successful run or a reboot"
  else
    rm -f "$path"
  fi
  return "$MR_EXIT_CONVERGE"
}

# Install the staged plists. Only reached once every one of them rendered.
mr_apply_slot_converge() {
  local slots="$1" image="$2" staging="$3" slot path rendered stale legacy

  mkdir -p "$MR_LAUNCH_AGENTS" || return "$MR_EXIT_CONVERGE"

  # The legacy hand-provisioned layout is NOT deleted separately. Its plist
  # sits at the same path as the slot's new one, so mr_install_slot replaces it
  # in one step — and a legacy plist can never match the rendered secretless
  # one, so it always takes that path. This loop only records the migration.
  for legacy in $(mr_legacy_slots "$MR_LAUNCH_AGENTS"); do
    if [ "$legacy" -le "$slots" ]; then
      mr_log "slots: slot ${legacy} is the legacy layout with the token embedded in its plist — replacing it"
      mr_summary_add changed "slot ${legacy} migrated off the embedded credential"
    fi
  done

  # Bring up the slots we WANT first. Obsolete ones are retired only once
  # these are running, so a failure here can never leave the host with
  # everything unloaded — reducing 2 slots to 1 used to delete slot 2 up
  # front, so a slot 1 that then failed to bootstrap took both down.
  for slot in $(seq 1 "$slots"); do
    path="$(mr_plist_path "$slot")"
    rendered="$(cat "${staging}/slot${slot}.plist")"

    if [ -f "$path" ] && [ "$rendered" = "$(cat "$path")" ] && \
       launchctl print "${MR_GUI_DOMAIN}/$(mr_plist_label "$slot")" >/dev/null 2>&1; then
      mr_summary_add unchanged "slot ${slot}"
      continue
    fi

    mr_install_slot "$slot" "${staging}/slot${slot}.plist" || return "$MR_EXIT_CONVERGE"
    mr_log "slots: slot ${slot} loaded on ${image}"
    mr_summary_add changed "slot ${slot}"
  done

  # Now that the wanted slots are up, retire the rest (US2-AC4).
  for stale in $(mr_slots_to_remove "$slots" "$MR_LAUNCH_AGENTS"); do
    mr_log "slots: removing slot ${stale} (SLOTS=${slots})"
    mr_bootout_slot "$stale"
    if rm -f "$(mr_plist_path "$stale")"; then
      mr_summary_add removed "slot ${stale}"
    else
      mr_warn "unloaded slot ${stale} but could not delete $(mr_plist_path "$stale") — it will not load again, but remove it by hand"
    fi
  done

  return 0
}

# Two phases, deliberately: render everything, then change the host.
#
# These used to be one loop that removed the legacy plists first and rendered
# each replacement as it went. A render failure partway through therefore left
# the host with its old agents unloaded and deleted and no new ones — on the
# live host, mobile CI silently stops — while the error said "Nothing was
# loaded; re-running this command is safe", which was not true.
#
# Nothing here touches the host, not even mkdir: the render phase writes only
# into a staging directory, so "nothing has been changed" is literally true.
mr_converge_slots() {
  local slots="$1" image="$2" staging rc

  staging="$(mktemp -d)" || {
    mr_err "could not create a staging directory for the slot plists."
    return "$MR_EXIT_CONVERGE"
  }

  if ! mr_render_all_slots "$slots" "$image" "$staging"; then
    rm -rf "$staging"
    return "$MR_EXIT_CONVERGE"
  fi

  mr_apply_slot_converge "$slots" "$image" "$staging"
  rc=$?
  rm -rf "$staging"
  return "$rc"
}

# --- verify (FR-007) --------------------------------------------------------

# Postcondition 2 of the CLI contract: no credential at rest but the 0600
# token file.
#
# The contract words this as "`grep -R ZUKAN_GH_PAT ~/Library/LaunchAgents` is
# empty", but that literal check cannot pass any more: the plist template
# carries a "never add ZUKAN_GH_PAT here" warning in its comment header, so a
# correctly rendered plist contains the string. Checked here the way
# mr_plist_is_legacy does it — the launchd KEY — plus a scan for anything that
# looks like an actual GitHub token value, which is the real concern.
# Does the org listing show a runner from this host?
#
# Paginates. Single-job JIT registrations are ephemeral by construction and a
# VM killed mid-job leaves an offline entry behind, so the org listing
# accumulates stale runners — checking only the first 100 would report a
# healthy host as failed (exit 40) once the fleet had churned enough.
mr_host_runner_registered() {
  local pat="$1" hosttag="$2" page=1 body count
  while [ "$page" -le 20 ]; do
    body="$(curl -fsS -H "Authorization: Bearer ${pat}" -H "Accept: application/vnd.github+json" \
      "https://api.github.com/orgs/${MR_GH_ORG}/actions/runners?per_page=100&page=${page}" 2>/dev/null)" || return 1
    # Must be ONLINE, not merely present. Single-job JIT registrations are
    # ephemeral and a VM killed mid-job leaves an offline entry behind, so a
    # host that has ever worked keeps stale entries under its own name prefix
    # forever — matching those would pass verification instantly on a host
    # whose newly loaded agent never registers at all.
    if printf '%s' "$body" | jq -e --arg h "mobile-runner-${hosttag}-" \
         '.runners // [] | map(select(.name | startswith($h)) | select(.status == "online")) | length > 0' >/dev/null 2>&1; then
      return 0
    fi
    count="$(printf '%s' "$body" | jq -r '.runners // [] | length' 2>/dev/null)"
    case "$count" in
      ''|*[!0-9]*) return 1 ;;
    esac
    [ "$count" -lt 100 ] && return 1
    page=$((page + 1))
  done
  return 1
}

mr_verify_no_credentials_at_rest() {
  local dir mode ok=0 offenders
  dir="$(mr_launch_agents_dir)"

  offenders="$(mr_legacy_slots "$dir")"
  if [ -n "$offenders" ]; then
    mr_err "verify: slot plist(s) still define a credential key under ${dir}: $(echo "$offenders" | tr '\n' ' ')"
    ok=1
  fi

  if [ -d "$dir" ] && grep -rlqE "ghp_[A-Za-z0-9]{20}|github_pat_[A-Za-z0-9_]{20}" "$dir" 2>/dev/null; then
    mr_err "verify: something under ${dir} contains a GitHub token value"
    ok=1
  fi

  if [ -e "$MR_TOKEN_FILE" ]; then
    # BSD and GNU `stat` disagree on flags (-f '%Lp' vs -c '%a'), and the
    # suite runs on both, so read the mode off `ls`. The path is a fixed
    # constant, not a glob, so SC2012's filename concern does not apply.
    # shellcheck disable=SC2012
    mode="$(ls -l "$MR_TOKEN_FILE" 2>/dev/null | cut -c1-10)"
    case "$mode" in
      -rw-------) ;;
      *)
        mr_err "verify: ${MR_TOKEN_FILE} is ${mode}, expected -rw------- (owner only)"
        ok=1
        ;;
    esac
  fi

  return "$ok"
}

# Postcondition 3 of the CLI contract — nothing superseded left behind.
#
# A leftover SLOT fails the run: it is entirely ours to remove, and one left
# loaded keeps taking jobs it should not.
#
# A leftover IMAGE only warns. Tart owns its OCI cache and prunes it LRU when
# it needs the space ("Tart will remove the least recently accessed VMs from
# OCI cache ... until enough free space is available"), and it documents no
# manual command for evicting a cached reference — so a cache entry we could
# not delete costs disk that Tart reclaims on its own. Failing the whole
# install over that would report a broken host on every upgrade.
mr_verify_no_leftovers() {
  local slots="$1" version="$2" ok=0 leftover
  leftover="$(mr_slots_to_remove "$slots" "$(mr_launch_agents_dir)")"
  if [ -n "$leftover" ]; then
    mr_err "verify: slot plist(s) above SLOTS=${slots} still present: $(echo "$leftover" | tr '\n' ' ')"
    ok=1
  fi
  leftover="$(mr_tart_json | mr_image_names | mr_image_prune_list "$version")"
  if [ -n "$leftover" ]; then
    mr_warn "superseded image(s) still on disk: $(echo "$leftover" | tr '\n' ' ') — Tart reclaims its OCI cache automatically when it needs the space"
  fi
  return "$ok"
}

mr_verify() {
  local slots="$1" version="$2" slot failures=0 pat waited hosttag

  if mr_tart_json | mr_image_names | mr_image_ref_present "$(mr_base_image_ref "$version")"; then
    mr_log "verify: image $(mr_base_image_ref "$version") present"
  else
    mr_err "verify: $(mr_base_image_ref "$version") is not on this host — the agents clone that reference, so a bare local copy of the same version is not a substitute"
    failures=$((failures + 1))
  fi

  for slot in $(seq 1 "$slots"); do
    if launchctl print "${MR_GUI_DOMAIN}/$(mr_plist_label "$slot")" >/dev/null 2>&1; then
      mr_log "verify: slot ${slot} agent loaded"
    else
      mr_err "verify: slot ${slot} agent is not loaded — check $(mr_default_log_path "$slot")"
      failures=$((failures + 1))
    fi
  done

  # Contract postcondition 2 — no credential at rest but the token file. This
  # is the security promise the whole epic exists for, so it is asserted on the
  # host after the run rather than inferred from the converge having succeeded.
  if mr_verify_no_credentials_at_rest; then
    mr_log "verify: no credential at rest beyond the 0600 token file"
  else
    failures=$((failures + 1))
  fi

  # Contract postcondition 3 — nothing left over: no slot above SLOTS, no
  # legacy plist, no superseded image.
  if mr_verify_no_leftovers "$slots" "$version"; then
    mr_log "verify: no superseded slots or images left behind"
  else
    failures=$((failures + 1))
  fi

  # Registration: agents JIT-register at the START of a cycle, so a healthy
  # host shows a runner within about one VM boot.
  hosttag="$(hostname -s)"
  if pat="$(mr_op_read "op://${MR_VAULT}/runner-jit-pat/credential")"; then
    waited=0
    while [ "$waited" -lt "$MR_VERIFY_TIMEOUT_S" ]; do
      if mr_host_runner_registered "$pat" "$hosttag"; then
        mr_log "verify: this host has a runner registered with ${MR_GH_ORG}"
        break
      fi
      sleep 15
      waited=$((waited + 15))
    done
    if [ "$waited" -ge "$MR_VERIFY_TIMEOUT_S" ]; then
      mr_err "verify: no runner from this host appeared in the ${MR_GH_ORG} org listing within $((MR_VERIFY_TIMEOUT_S / 60)) minutes — check $(mr_default_log_path 1)"
      failures=$((failures + 1))
    fi
    unset pat
  else
    mr_err "verify: could not read the JIT PAT to check registration (the install itself completed)"
    failures=$((failures + 1))
  fi

  [ "$failures" -eq 0 ] || return "$MR_EXIT_VERIFY"
  return 0
}

# --- main -------------------------------------------------------------------

main() {
  # Set here, not at file scope: the test suite sources this file, and `set -u`
  # leaking into the caller turns any unset variable there into a hard failure.
  set -uo pipefail

  local slots version ref rc

  slots="$(mr_resolve_slots)" || exit "$MR_EXIT_REMEDIABLE"
  version="$(mr_resolve_image_version "$MR_PIN_FILE")" || exit "$MR_EXIT_REMEDIABLE"
  # What every slot plist clones from; see mr_base_image_ref for why this is
  # the registry reference and not the bare local name.
  ref="$(mr_base_image_ref "$version")"

  mr_summary_reset
  mr_log "converging this host: ${slots} slot(s), image ${ref}"

  # Re-run the full read-only gate here too: install.sh checked it before
  # Homebrew, but a run started from a local checkout skips that path.
  mr_preflight_readonly "$MR_DISK_FLOOR_GB" || exit $?

  mr_converge_toolchain || exit $?
  mr_converge_secrets   || exit $?
  mr_converge_image "$version" || exit $?
  mr_converge_agent_script || exit $?
  mr_wait_for_idle || exit $?
  mr_converge_slots "$slots" "$ref" || exit $?
  mr_prune_images "$version"

  rc=0
  mr_verify "$slots" "$version" || rc=$?

  mr_summary_print
  printf '\n'
  if mr_summary_changed_anything; then
    mr_log "slot logs: $(mr_default_log_path 1)$([ "$slots" -gt 1 ] && printf ', %s' "$(mr_default_log_path 2)")"
  else
    mr_log "nothing to change — this host was already converged"
  fi

  if [ "$rc" -ne 0 ]; then
    mr_err "install completed but a health check did not pass (see verify lines above). Re-running the same command is safe and resumes."
    exit "$rc"
  fi

  mr_log "done. Next steps: nothing — this host is provisioned."
  exit 0
}

# Sourced by the test suite (MR_SOURCE_ONLY=1) → expose functions only, so the
# converge helpers can be exercised against stubbed launchctl/tart without
# running an install. Same guard shape as install.sh, and for the same reason:
# BASH_SOURCE is not a reliable discriminator once a script is exec'd.
if [ -z "${MR_SOURCE_ONLY:-}" ]; then
  main "$@"
fi
