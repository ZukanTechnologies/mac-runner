#!/usr/bin/env bash
# lib/common.sh — pure helpers for the mac-runner installer (ZUK-2158, T012).
#
# Everything here is a decision, not an action: preflight predicates, plist
# rendering, pin parsing, slot/image reconciliation, and the run summary. The
# side effects (brew, launchctl, tart, sudo) live in lib/install-main.sh, which
# sources this file. That split is what makes the installer testable — see
# tests/common-*.bats, and plan.md § Complexity Tracking for why the acting
# half is covered by shellcheck plus a scripted acceptance run instead.
#
# Rules for this file:
#   * No side effects at source time, and no `set -e` — it is sourced.
#   * Value-returning functions print ONLY the value on stdout; every
#     diagnostic goes to stderr, so `$(...)` can never capture a warning.
#   * bash 3.2 compatible: /bin/bash on macOS is still 3.2, and the whole
#     point of the curl|bash entrypoint is that it runs before Homebrew.

# --- constants --------------------------------------------------------------

MR_MIN_MACOS="${MR_MIN_MACOS:-15}"
# Apple's Virtualization framework allows at most 2 concurrent VMs per host.
MR_MAX_SLOTS="${MR_MAX_SLOTS:-2}"
MR_DEFAULT_SLOTS="${MR_DEFAULT_SLOTS:-2}"
MR_IMAGE_PREFIX="zukan-mobile-runner"
MR_REGISTRY="${MR_REGISTRY:-ghcr.io/zukantechnologies}"
MR_LABEL_PREFIX="com.zukan.mobile-runner-agent"
# Slack on top of "room for a second copy of the image", for the runner's own
# work dirs and the OS.
MR_DISK_HEADROOM_GB="${MR_DISK_HEADROOM_GB:-20}"

MR_NL='
'

# Exit-code contract, shared with lib/install-main.sh and documented in
# specs/027-mac-runner-bootstrap/contracts/installer-cli.md. Defined here so
# both halves agree; common.sh itself only returns the two preflight classes.
# shellcheck disable=SC2034
{
  MR_EXIT_UNSUPPORTED=10   # Intel Mac, macOS below the floor — operator can't fix
  MR_EXIT_REMEDIABLE=11    # FileVault on, low disk, aborted auto-login pause
  MR_EXIT_SECRETS=20       # bad token, missing vault item, 1Password unreachable
  MR_EXIT_REGISTRY=21      # tart login / tart pull failed
  MR_EXIT_CONVERGE=30      # render or launchctl failure
  MR_EXIT_VERIFY=40        # installed, but a health check did not pass
}

# --- output -----------------------------------------------------------------

mr_log()  { printf '[install] %s\n' "$*"; }
mr_warn() { printf '[install][warn] %s\n' "$*" >&2; }
mr_err()  { printf '[install] %s\n' "$*" >&2; }

mr_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# --- preflight predicates (FR-004) ------------------------------------------

mr_arch_is_supported() {
  [ "$(uname -m 2>/dev/null)" = "arm64" ]
}

mr_macos_major() {
  local v
  v="$(sw_vers -productVersion 2>/dev/null)" || return 1
  v="${v%%.*}"
  case "$v" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$v"
}

mr_macos_is_supported() {
  local major
  major="$(mr_macos_major)" || return 1
  [ "$major" -ge "$MR_MIN_MACOS" ]
}

# True when FileVault is on. Deliberately fails CLOSED: an unrecognized or
# errored `fdesetup status` reads as "on", because proceeding onto a host that
# turns out to be encrypted produces a runner that silently stops working at
# the next reboot (no auto-login ⇒ no GUI session ⇒ no Tart).
mr_filevault_is_on() {
  local out
  out="$(fdesetup status 2>/dev/null)" || return 0
  case "$out" in
    *"FileVault is Off"*) return 1 ;;
    *"FileVault is On"*)  return 0 ;;
    *)                    return 0 ;;
  esac
}

mr_autologin_user() {
  local out
  out="$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null)" || return 1
  out="$(mr_trim "$out")"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

mr_autologin_is_set() {
  mr_autologin_user >/dev/null 2>&1
}

mr_free_disk_gb() {
  local path="${1:-/}" out
  out="$(df -g "$path" 2>/dev/null | awk 'NR==2 {print $4}')"
  case "$out" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$out"
}

mr_disk_meets_floor() {
  local floor="$1" path="${2:-/}" free
  free="$(mr_free_disk_gb "$path")" || return 1
  [ "$free" -ge "$floor" ]
}

# The read-only gate. Returns 0, 10 or 11 and changes nothing on the host —
# FR-004 requires every check to run before the first mutation.
#
# Order matters: the checks an operator CANNOT fix are evaluated first, so an
# Intel Mac with FileVault on is told "wrong machine" (10) rather than sent to
# System Settings to flip a toggle that will not help (11).
mr_preflight_readonly() {
  local floor="${1:-120}"

  if ! mr_arch_is_supported; then
    mr_err "unsupported hardware: runner hosts must be Apple Silicon (this Mac reports $(uname -m 2>/dev/null)). Nothing was changed."
    return "$MR_EXIT_UNSUPPORTED"
  fi

  if ! mr_macos_is_supported; then
    mr_err "unsupported macOS: need ${MR_MIN_MACOS} or newer for the Virtualization behavior Tart depends on (found $(sw_vers -productVersion 2>/dev/null || echo unknown)). Nothing was changed."
    return "$MR_EXIT_UNSUPPORTED"
  fi

  if mr_filevault_is_on; then
    mr_err "FileVault is on. Auto-login is impossible on an encrypted disk, and Tart needs the unlocked login keychain of a logged-in GUI session. Turn it off in System Settings -> Privacy & Security -> FileVault, then re-run this command."
    return "$MR_EXIT_REMEDIABLE"
  fi

  if ! mr_disk_meets_floor "$floor" /; then
    mr_err "not enough free disk: need at least ${floor} GB (two base-image versions coexist during an upgrade). Free some space, then re-run this command."
    return "$MR_EXIT_REMEDIABLE"
  fi

  return 0
}

# --- image pin (FR-015) -----------------------------------------------------

mr_version_is_valid() {
  local re='^[0-9]{4}\.[0-9]{2}\.[0-9]+$'
  [[ "$1" =~ $re ]]
}

# Read the single blessed image version out of the repo's IMAGE_VERSION file.
#
# Strict on purpose. Before this file existed the fleet ran three different
# versions at once (2026.07.2 pinned, 2026.07.4 in a plist, 2026.08.1 on the
# host), so a pin that is empty, multi-line, or a moving tag like `latest` is
# an error rather than something to interpret.
mr_read_pin() {
  local file="$1" raw value extra
  if [ -z "$file" ]; then
    mr_err "mr_read_pin: no pin file given"
    return 1
  fi
  if [ ! -r "$file" ]; then
    mr_err "image pin file missing or unreadable: ${file}"
    return 1
  fi

  # Count NON-EMPTY lines, read from the file rather than from a command
  # substitution: `$(cat …)` strips trailing newlines, so counting after it
  # would accept "2026.08.1\n\n\n" as single-line while the check claims to
  # enforce one line. Trailing blank lines are harmless and tolerated; a second
  # VALUE is two answers and is refused.
  extra="$(grep -c '[^[:space:]]' "$file" 2>/dev/null | tr -d '[:space:]')"
  if [ -z "$extra" ] || [ "$extra" -gt 1 ]; then
    mr_err "image pin file must hold exactly one version, found ${extra:-0} values: ${file}"
    return 1
  fi

  raw="$(cat "$file")"

  value="$(mr_trim "$raw")"
  if [ -z "$value" ]; then
    mr_err "image pin file is empty: ${file}"
    return 1
  fi
  if ! mr_version_is_valid "$value"; then
    mr_err "image pin is not a version (got '${value}'): ${file} must hold a single YYYY.MM.N value — hosts never track a moving tag"
    return 1
  fi

  printf '%s\n' "$value"
}

mr_resolve_image_version() {
  local pin_file="$1" v
  if [ -n "${IMAGE_VERSION:-}" ]; then
    v="$(mr_trim "$IMAGE_VERSION")"
    if ! mr_version_is_valid "$v"; then
      mr_err "IMAGE_VERSION override is not a version: '${IMAGE_VERSION}' (expected YYYY.MM.N)"
      return 1
    fi
    printf '%s\n' "$v"
    return 0
  fi
  mr_read_pin "$pin_file"
}

# The name a host's agent clones from, and the value the installer renders into
# every plist's BASE_IMAGE.
#
# This is the fully-qualified OCI reference, NOT the bare local name. `tart
# pull` puts a remote image in the OCI cache (~/.tart/cache/OCIs/); it does not
# create a locally-runnable VM under a bare name. `tart clone <ref> <vm>` reads
# straight from that cache. The bare name exists only on the Mac that ran
# packer, which is why zukan's build.sh epilogue says to point BASE_IMAGE at
# "${IMAGE} (or the GHCR ref)" — every host but the build host needs the ref.
mr_base_image_ref() {
  printf '%s/%s:%s\n' "$MR_REGISTRY" "$MR_IMAGE_PREFIX" "$1"
}

# The bare local-VM name. Still meaningful on a build host, where packer leaves
# one behind, and on hosts provisioned before the pull/clone distinction was
# understood — so the prune path has to recognize it.
mr_base_image_name() {
  printf '%s-%s\n' "$MR_IMAGE_PREFIX" "$1"
}

# The version an image name refers to, in either shape; non-zero when the name
# is not one of ours (an ephemeral `ci-*` clone, or somebody else's VM).
#
# The OCI shape is matched against the FULL registry prefix, not just a
# trailing "zukan-mobile-runner:". This answer feeds the prune list, and a
# suffix match would classify `ghcr.io/someone-else/zukan-mobile-runner:X` as
# ours and delete it.
mr_image_version_of() {
  local name="$1"
  case "$name" in
    "${MR_IMAGE_PREFIX}"-*)
      printf '%s\n' "${name#"${MR_IMAGE_PREFIX}"-}" ;;
    "${MR_REGISTRY}/${MR_IMAGE_PREFIX}":*)
      printf '%s\n' "${name##*:}" ;;
    *)
      return 1 ;;
  esac
}

# Is the exact reference the agents clone from on this host? Reads names on
# stdin.
#
# Deliberately an EXACT match on the reference, not "some shape of this
# version". A host that already has the bare local VM — the Mac that built the
# image, or one provisioned before the pull/clone distinction was understood —
# has nothing the agent can use: the plist says clone the registry reference,
# and that reference is not in the OCI cache. Accepting the bare name here
# would skip the GHCR login and pull, and the first agent cycle would then try
# to fetch the image itself with no registry credentials established. So the
# bare name means "still needs pulling", which is exactly right.
mr_image_ref_present() {
  local want="$1" name
  [ -n "$want" ] || return 1
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$name" = "$want" ] && return 0
  done
  return 1
}

# --- slots ------------------------------------------------------------------

mr_validate_slots() {
  local n="$1"
  case "$n" in
    ''|*[!0-9]*)
      mr_err "SLOTS must be a whole number between 1 and ${MR_MAX_SLOTS} (got '${n}')"
      return 1
      ;;
  esac
  if [ "$n" -lt 1 ] || [ "$n" -gt "$MR_MAX_SLOTS" ]; then
    mr_err "SLOTS must be between 1 and ${MR_MAX_SLOTS} — Apple's Virtualization framework allows at most ${MR_MAX_SLOTS} concurrent VMs per host (got '${n}')"
    return 1
  fi
  return 0
}

mr_resolve_slots() {
  local n="${SLOTS:-$MR_DEFAULT_SLOTS}"
  mr_validate_slots "$n" || return 1
  printf '%s\n' "$n"
}

mr_plist_label() { printf '%s.slot%s\n' "$MR_LABEL_PREFIX" "$1"; }

# One source of truth for where slot plists live. The installer both SCANS this
# directory (to find slots to remove or migrate) and WRITES into it; if the two
# were derived separately, overriding one would silently strand the other.
mr_launch_agents_dir() { printf '%s\n' "${MR_LAUNCH_AGENTS:-${HOME}/Library/LaunchAgents}"; }
mr_plist_path()        { printf '%s/%s.slot%s.plist\n' "$(mr_launch_agents_dir)" "$MR_LABEL_PREFIX" "$1"; }
mr_default_log_path() { printf '/tmp/zukan-mobile-runner-agent.slot%s.log\n' "$1"; }

# --- plist render (FR-009) --------------------------------------------------

# Values are substituted into XML <string> elements, so & < > would produce an
# unparseable plist — and launchd's diagnostic for a malformed plist is opaque
# enough that the failure would land on the operator, not here. `&` and `\` are
# also active in a sed replacement, and `|` is the delimiter. Every legitimate
# value (image name, label list, log path) is plain ASCII, so reject rather
# than escape: a value that needs escaping is a bug upstream.
mr_value_is_renderable() {
  case "$1" in
    *"&"*|*"<"*|*">"*|*"|"*|*"\\"*|*"$MR_NL"*) return 1 ;;
  esac
  return 0
}

mr_render_plist() {
  local tmpl="$1" slot="$2" image="$3" labels="$4" log_path="$5" org="${6:-ZukanTechnologies}" v out

  mr_validate_slots "$slot" || return 1
  if [ ! -r "$tmpl" ]; then
    mr_err "plist template missing or unreadable: ${tmpl}"
    return 1
  fi

  for v in "$image" "$labels" "$log_path" "$org"; do
    if ! mr_value_is_renderable "$v"; then
      mr_err "refusing to render slot ${slot}: value contains a character that would break the plist XML ('${v}')"
      return 1
    fi
  done

  out="$(sed -e "s|{{SLOT}}|${slot}|g" \
             -e "s|{{BASE_IMAGE}}|${image}|g" \
             -e "s|{{EXTRA_LABELS}}|${labels}|g" \
             -e "s|{{LOG_PATH}}|${log_path}|g" \
             -e "s|{{GH_ORG}}|${org}|g" \
             "$tmpl")" || return 1

  case "$out" in
    *"{{"*)
      mr_err "plist template still has an unsubstituted placeholder — template and installer are out of sync"
      return 1
      ;;
  esac

  printf '%s\n' "$out"
}

# --- reconciliation (FR-006) ------------------------------------------------

mr_observed_slots() {
  local dir="$1" f base slot
  [ -d "$dir" ] || return 0
  for f in "${dir}/${MR_LABEL_PREFIX}".slot*.plist; do
    [ -e "$f" ] || continue
    base="${f##*/}"
    slot="${base#"${MR_LABEL_PREFIX}.slot"}"
    slot="${slot%.plist}"
    case "$slot" in
      ''|*[!0-9]*) continue ;;
    esac
    printf '%s\n' "$slot"
  done | sort -n
}

# The legacy hand-provisioned layout embedded the org PAT in the plist. Its
# presence is the migration trigger (US2-AC3) and, until the host is converged,
# a credential sitting at rest on disk.
#
# Matches the KEY, not the word: the current template carries a "never add
# ZUKAN_GH_PAT here" warning in its comment header, so a bare substring search
# classifies every correctly-rendered plist as legacy and the installer
# re-migrates a converged host on every single run.
mr_plist_is_legacy() {
  local path="$1"
  [ -r "$path" ] || return 1
  grep -q '<key>[[:space:]]*ZUKAN_GH_PAT[[:space:]]*</key>' "$path" 2>/dev/null
}

mr_legacy_slots() {
  local dir="$1" slot
  for slot in $(mr_observed_slots "$dir"); do
    if mr_plist_is_legacy "${dir}/${MR_LABEL_PREFIX}.slot${slot}.plist"; then
      printf '%s\n' "$slot"
    fi
  done
  return 0
}

mr_slots_to_remove() {
  local desired="$1" dir="$2" slot
  for slot in $(mr_observed_slots "$dir"); do
    if [ "$slot" -gt "$desired" ]; then
      printf '%s\n' "$slot"
    fi
  done
  return 0
}

# Reads image names on stdin, prints the ones to delete. Keyed on the VERSION
# to keep, so it recognizes both shapes — the OCI cache entry the installer
# pulls and the bare local VM packer leaves on a build host.
#
# Only our own images are ever candidates: a `ci-*` clone belongs to a running
# agent cycle, and anything else on the host belongs to its owner.
mr_image_prune_list() {
  local keep="$1" name v
  if [ -z "$keep" ]; then
    mr_err "mr_image_prune_list: refusing to build a prune list without the version to keep"
    return 1
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    v="$(mr_image_version_of "$name")" || continue
    [ "$v" = "$keep" ] && continue
    printf '%s\n' "$name"
  done
  return 0
}

# `tart list --format json` on stdin. Parsing JSON rather than the columnar
# output keeps these immune to a change in tart's table formatting.
#
# The field names come from tart's VMInfo struct, which encodes its Swift
# property names verbatim: Source, Name, Disk, Size, Accessed, Running, State.
# Two values are worth writing down because guessing them wrong fails silently
# — jq just yields nothing, which reads exactly like "no VMs":
#   * Source is "local" or "OCI" — capital OCI.
#   * State is the State enum's raw value: "running" | "suspended" | "stopped".
#
# Running (a Bool from vmDir.running()) is checked first because it is
# unambiguous; State is the fallback so this keeps working on a tart that
# predates the boolean.
mr_running_ci_vm_names() {
  jq -r '.[] | select((.Running == true) or (.State == "running")) | select(.Name | startswith("ci-")) | .Name'
}

# Every entry tart knows about, local VMs and OCI-cache images alike.
#
# There is deliberately no Source == "local" variant. The pinned image lives in
# the OCI cache, so a local-only filter cannot see it — that filter is what hid
# the pulled image from the presence check in the first place, and a helper
# sitting here offering it again is an invitation to repeat that.
mr_image_names() {
  jq -r '.[] | .Name'
}

# Size in GB of one image, from the same JSON — any source, for the same
# reason mr_image_names has no local-only variant. Empty when tart does not
# know the image (nothing pulled yet).
mr_image_size_gb() {
  local name="$1" out
  [ -n "$name" ] || return 1
  out="$(jq -r --arg n "$name" '.[] | select(.Name == $n) | .Size' 2>/dev/null)"
  case "$out" in
    ''|null|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$out"
}

# How much free disk this run actually needs (FR-004: re-checked with the real
# number before the download begins, not just the bootstrap floor).
#
# During an upgrade the old and new images coexist until the prune that follows
# the slot restart, so the requirement is "about another one of these" — and
# the size of the image already on the host is the best available estimate of
# the next one. With nothing pulled yet there is nothing to measure, so the
# conservative static floor stands.
mr_disk_requirement_gb() {
  local observed="$1" fallback="$2"
  case "$fallback" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$observed" in
    ''|*[!0-9]*) printf '%s\n' "$fallback"; return 0 ;;
  esac
  [ "$observed" -gt 0 ] || { printf '%s\n' "$fallback"; return 0; }
  printf '%s\n' "$(( observed + MR_DISK_HEADROOM_GB ))"
}

# The in-flight guard (FR-008): restarting slot agents kills whatever VM they
# are running, so the default is to wait. FORCE must be exactly "1" — a
# truthy-looking value like "yes" must not cost someone a running CI job.
mr_inflight_action() {
  local running="${1:-0}" force="${2:-0}"
  case "$running" in
    ''|*[!0-9]*) running=0 ;;
  esac
  if [ "$running" -eq 0 ]; then
    printf 'proceed\n'
    return 0
  fi
  if [ "$force" = "1" ]; then
    printf 'force\n'
    return 0
  fi
  printf 'wait\n'
  return 0
}

# --- 1Password error classification -----------------------------------------

# Turn op's stderr into one of: bad-token | missing-item | unreachable.
#
# The three call for different actions — rotate the service-account token, fix
# the vault, or wait — and the installer contract requires them to be told
# apart (exit 20 "distinguished from bad token"). Never echo op's raw output:
# it can carry vault metadata into a log.
#
# agent/mobile-runner-agent.sh deliberately carries its own copy of this
# logic: it runs from /opt/zukan/mobile-runner-agent.sh, a standalone copy
# outside the clone, so it cannot source this file.
mr_op_error_class() {
  case "$1" in
    *"isn't an item"*|*"not found"*|*"no vault"*|*"isn't a vault"*)
      printf 'missing-item\n' ;;
    *401*|*Unauthorized*|*"invalid service account token"*|*"invalid session token"*)
      printf 'bad-token\n' ;;
    *)
      printf 'unreachable\n' ;;
  esac
}

# --- run summary (FR-007) ---------------------------------------------------

mr_summary_reset() {
  MR_SUM_INSTALLED=""
  MR_SUM_CHANGED=""
  MR_SUM_REMOVED=""
  MR_SUM_UNCHANGED=""
}

mr_summary_add() {
  local bucket="$1" item="$2"
  case "$bucket" in
    installed) MR_SUM_INSTALLED="${MR_SUM_INSTALLED}${item}${MR_NL}" ;;
    changed)   MR_SUM_CHANGED="${MR_SUM_CHANGED}${item}${MR_NL}" ;;
    removed)   MR_SUM_REMOVED="${MR_SUM_REMOVED}${item}${MR_NL}" ;;
    unchanged) MR_SUM_UNCHANGED="${MR_SUM_UNCHANGED}${item}${MR_NL}" ;;
    *)
      mr_err "mr_summary_add: unknown bucket '${bucket}'"
      return 1
      ;;
  esac
  return 0
}

mr_summary_changed_anything() {
  [ -n "${MR_SUM_INSTALLED}${MR_SUM_CHANGED}${MR_SUM_REMOVED}" ]
}

mr_summary_print() {
  local bucket val line
  printf '\n[install] summary\n'
  for bucket in installed changed removed unchanged; do
    case "$bucket" in
      installed) val="$MR_SUM_INSTALLED" ;;
      changed)   val="$MR_SUM_CHANGED" ;;
      removed)   val="$MR_SUM_REMOVED" ;;
      unchanged) val="$MR_SUM_UNCHANGED" ;;
      *)         val="" ;;
    esac
    [ -n "$val" ] || continue
    printf '  %s:\n' "$bucket"
    printf '%s' "$val" | while IFS= read -r line; do
      [ -n "$line" ] && printf '    - %s\n' "$line"
    done
  done
  return 0
}

mr_summary_reset
