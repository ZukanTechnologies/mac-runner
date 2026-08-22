#!/usr/bin/env bash
# install.sh — the curl|bash entrypoint (ZUK-2159, T013).
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ZukanTechnologies/mac-runner/HEAD/install.sh)"
#
# Deliberately thin. It runs on a Mac that has nothing yet — no Homebrew, no
# Command Line Tools, no git — so all it does is:
#
#   1. read-only preflight (nothing on the host changes until these pass)
#   2. install Homebrew (which installs the CLT, and with it git)
#   3. clone or update /opt/zukan/mac-runner
#   4. exec lib/install-main.sh out of that clone
#
# Everything else lives in the clone, so a single run uses one consistent
# revision of the agent, template and pin — no per-file raw URLs, no skew.
#
# bash 3.2 only: this is parsed by /bin/bash on a stock Mac, before Homebrew
# exists. No associative arrays, no `mapfile`, no `${var^^}`.
#
# The preflight predicates below are a deliberate SMALL duplicate of the
# authoritative ones in lib/common.sh, which is not on the machine yet at this
# point. tests/install-bootstrap.bats asserts the two agree, so the duplication
# cannot drift silently.

MR_REPO_URL="${MR_REPO_URL:-https://github.com/ZukanTechnologies/mac-runner.git}"
MR_REPO_REF="${MR_REPO_REF:-main}"
MR_INSTALL_ROOT="${MR_INSTALL_ROOT:-/opt/zukan}"
MR_CLONE_DIR="${MR_CLONE_DIR:-${MR_INSTALL_ROOT}/mac-runner}"

# Conservative floor for the bootstrap check. The base image declares a 140 GB
# sparse disk and materializes well under that, but an upgrade briefly holds
# two versions. lib/install-main.sh re-checks against the size of the image
# actually on this host once the pin is known (FR-004), which is the number
# that matters; this one only stops an obviously-too-full disk before we start
# installing packages. Override with MR_DISK_FLOOR_GB.
MR_DISK_FLOOR_GB="${MR_DISK_FLOOR_GB:-120}"

MR_EXIT_UNSUPPORTED=10
MR_EXIT_REMEDIABLE=11
MR_EXIT_CONVERGE=30

bs_log()  { printf '[install] %s\n' "$*"; }
bs_err()  { printf '[install] %s\n' "$*" >&2; }

# --- preflight (mirror of lib/common.sh; see header) ------------------------

bs_arch_is_supported() { [ "$(uname -m 2>/dev/null)" = "arm64" ]; }

bs_macos_major() {
  local v
  v="$(sw_vers -productVersion 2>/dev/null)" || return 1
  v="${v%%.*}"
  case "$v" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$v"
}

bs_macos_is_supported() {
  local major
  major="$(bs_macos_major)" || return 1
  [ "$major" -ge 15 ]
}

# Fails closed, exactly like mr_filevault_is_on: an unreadable status counts
# as "on", because a host that turns out to be encrypted loses auto-login and
# stops taking jobs at its next reboot.
bs_filevault_is_on() {
  local out
  out="$(fdesetup status 2>/dev/null)" || return 0
  case "$out" in
    *"FileVault is Off"*) return 1 ;;
    *"FileVault is On"*)  return 0 ;;
    *)                    return 0 ;;
  esac
}

bs_autologin_user() {
  local out
  out="$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

bs_free_disk_gb() {
  local out
  out="$(df -g / 2>/dev/null | awk 'NR==2 {print $4}')"
  case "$out" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$out"
}

bs_preflight() {
  if ! bs_arch_is_supported; then
    bs_err "unsupported hardware: runner hosts must be Apple Silicon (this Mac reports $(uname -m 2>/dev/null)). Nothing was changed."
    return "$MR_EXIT_UNSUPPORTED"
  fi
  if ! bs_macos_is_supported; then
    bs_err "unsupported macOS: need 15 or newer for the Virtualization behavior Tart depends on (found $(sw_vers -productVersion 2>/dev/null || echo unknown)). Nothing was changed."
    return "$MR_EXIT_UNSUPPORTED"
  fi
  if bs_filevault_is_on; then
    bs_err "FileVault is on. Auto-login is impossible on an encrypted disk, and Tart needs the unlocked login keychain of a logged-in GUI session. Turn it off in System Settings -> Privacy & Security -> FileVault, then re-run this command."
    return "$MR_EXIT_REMEDIABLE"
  fi
  local free
  if ! free="$(bs_free_disk_gb)" || [ "$free" -lt "$MR_DISK_FLOOR_GB" ]; then
    bs_err "not enough free disk: need at least ${MR_DISK_FLOOR_GB} GB (two base-image versions coexist during an upgrade). Free some space, then re-run this command."
    return "$MR_EXIT_REMEDIABLE"
  fi
  return 0
}

# The one human-remediable step that can't be scripted without an undocumented
# OS hack (FR-005 forbids the kcpassword route), so: pause, guide, re-check.
# Auto-login must name the account running this installer, not merely *an*
# account. The slot agents are LaunchAgents in ~/Library/LaunchAgents and load
# only in that user's GUI session — so a Mac that auto-logs in as somebody else
# comes back from a reboot with no runner at all, and nothing about it looks
# broken until jobs stop being picked up.
bs_autologin_matches_me() {
  local user me
  user="$(bs_autologin_user)" || return 1
  me="$(id -un)"
  [ "$user" = "$me" ]
}

bs_require_autologin() {
  local user me
  me="$(id -un)"
  if bs_autologin_matches_me; then
    bs_log "auto-login: enabled for '${me}'"
    return 0
  fi
  if user="$(bs_autologin_user)"; then
    bs_err "auto-login is set to '${user}', but this installer is running as '${me}' and its slot agents load only in ${me}'s GUI session. Set auto-login to '${me}' in System Settings -> Users & Groups (or re-run this command as '${user}'), then try again."
    return "$MR_EXIT_REMEDIABLE"
  fi
  cat <<EOF

[install] One manual step is needed, and only this one.

  Tart can only boot a VM inside a logged-in GUI session, so this Mac must log
  itself back in after a reboot. Turn on:

      System Settings -> Users & Groups -> Automatically log in as
        -> $(id -un)

  Then come back here and press Return. Ctrl-C is safe — nothing has been
  changed yet, and re-running the same command resumes from here.

EOF
  printf '[install] press Return once auto-login is on: '
  read -r _ || {
    bs_err "aborted at the auto-login step. Nothing was changed. Re-run the same command to resume."
    return "$MR_EXIT_REMEDIABLE"
  }
  if bs_autologin_matches_me; then
    bs_log "auto-login: enabled for '${me}'"
    return 0
  fi
  bs_err "auto-login is still not set to '${me}'. Set it in System Settings -> Users & Groups, then re-run the same command."
  return "$MR_EXIT_REMEDIABLE"
}

# --- toolchain --------------------------------------------------------------

bs_brew_shellenv() {
  local p
  for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$p" ]; then
      eval "$("$p" shellenv)"
      return 0
    fi
  done
  return 1
}

bs_ensure_homebrew() {
  if bs_brew_shellenv; then
    bs_log "homebrew: present"
    return 0
  fi
  bs_log "homebrew: installing (this also installs the Command Line Tools, and with them git)"
  # NONINTERACTIVE=1 suppresses the "Press RETURN to continue" gate — the
  # install has to stay at one question total (FR-002).
  if ! NONINTERACTIVE=1 /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
    bs_err "Homebrew install failed. Re-run the same command to retry."
    return "$MR_EXIT_CONVERGE"
  fi
  if ! bs_brew_shellenv; then
    bs_err "Homebrew installed but 'brew' is not where it is expected (/opt/homebrew/bin/brew). Re-run the same command to retry."
    return "$MR_EXIT_CONVERGE"
  fi
  return 0
}

bs_sync_clone() {
  if [ ! -d "$MR_INSTALL_ROOT" ]; then
    bs_log "creating ${MR_INSTALL_ROOT} (sudo)"
    sudo mkdir -p "$MR_INSTALL_ROOT" || return "$MR_EXIT_CONVERGE"
    sudo chown "$(id -u):$(id -g)" "$MR_INSTALL_ROOT" || return "$MR_EXIT_CONVERGE"
  fi

  if [ -d "$MR_CLONE_DIR/.git" ]; then
    bs_log "updating ${MR_CLONE_DIR} to origin/${MR_REPO_REF}"
    # Hard reset, never merge: the clone is a cache of repo HEAD, and local
    # edits on a runner host are exactly the drift this repo exists to end.
    git -C "$MR_CLONE_DIR" fetch --quiet --depth 1 origin "$MR_REPO_REF" || return "$MR_EXIT_CONVERGE"
    git -C "$MR_CLONE_DIR" reset --quiet --hard FETCH_HEAD || return "$MR_EXIT_CONVERGE"
  else
    bs_log "cloning ${MR_REPO_URL} into ${MR_CLONE_DIR}"
    rm -rf "$MR_CLONE_DIR"
    git clone --quiet --depth 1 --branch "$MR_REPO_REF" "$MR_REPO_URL" "$MR_CLONE_DIR" || return "$MR_EXIT_CONVERGE"
  fi
  return 0
}

# Where is this script running from? A local checkout (./install.sh) uses its
# own tree; the curl|bash path has no file at all and goes through the clone.
bs_local_checkout_dir() {
  local src dir
  src="${BASH_SOURCE[0]:-}"
  [ -n "$src" ] || return 1
  [ -f "$src" ] || return 1
  dir="$(cd "$(dirname "$src")" 2>/dev/null && pwd)" || return 1
  [ -f "${dir}/lib/install-main.sh" ] || return 1
  printf '%s\n' "$dir"
}

main() {
  set -uo pipefail

  bs_log "mac-runner installer — https://github.com/ZukanTechnologies/mac-runner"

  bs_preflight || exit $?
  bs_require_autologin || exit $?

  local root
  if root="$(bs_local_checkout_dir)"; then
    bs_log "running from the local checkout at ${root} (skipping the clone step)"
  else
    bs_ensure_homebrew || exit $?
    bs_sync_clone || exit $?
    root="$MR_CLONE_DIR"
  fi

  exec bash "${root}/lib/install-main.sh"
}

# Sourced by the test suite (MR_SOURCE_ONLY=1) → expose functions only.
# The usual `[[ ${BASH_SOURCE[0]} == $0 ]]` guard cannot be used here: under
# `bash -c "$(curl ...)"` there is no BASH_SOURCE at all, so that test is false
# and main would never run — i.e. the published one-liner would do nothing.
if [ -z "${MR_SOURCE_ONLY:-}" ]; then
  main "$@"
fi
