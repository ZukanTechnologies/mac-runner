# mac-runner

One-command provisioning for Zukan's **ephemeral Mac CI runner hosts** — Apple-Silicon Macs that run GitHub Actions jobs inside disposable [Tart](https://tart.run) VMs (labels `self-hosted, mobile-runner, macos, arm64`).

Lifecycle per job: `tart clone` the base image → boot → JIT-register a **single-job** GitHub runner → run exactly one job → delete the VM. No state survives between jobs, so there is no config drift.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ZukanTechnologies/mac-runner/HEAD/install.sh)"
```

One paste of the 1Password service-account token, at most one System Settings toggle, zero other questions. **Re-running that same command is the upgrade path, the repair path, and the only way host configuration ever changes.**

© Zukan Technologies LLC. Published without a license grant — the code is public for provisioning convenience, not for reuse (deliberate decision, ZUK-2147).

## Prerequisites (fresh Mac)

1. Apple-Silicon Mac, macOS 15+, ~120 GB free.
2. Complete Setup Assistant as the CI user, and run the installer as that same user. **Decline FileVault** — auto-login is impossible while disk encryption is on, and Tart requires an unlocked `login.keychain` in a logged-in GUI session (macOS Virtualization framework behavior).
3. Have the `mac-runner-hosts` 1Password **service-account token** at hand (see [Credentials](#credentials-1password)).

## Configuration (env overrides)

The default install asks nothing beyond the token. Overrides are env-var prefixes to the same one-liner:

| Var | Default | Meaning |
|---|---|---|
| `SLOTS` | `2` | VM slots (max 2 — Apple Virtualization caps concurrent VMs per host) |
| `RUNNER_EXTRA_LABELS` | *(empty)* | Comma-separated labels appended to `mobile-runner,macos,arm64` |
| `IMAGE_VERSION` | the repo's [`IMAGE_VERSION`](IMAGE_VERSION) pin | Escape hatch for pulling a version other than the blessed pin |
| `FORCE` | `0` | `1` = don't wait for idle slots; terminates in-flight CI VMs (they retry on re-run) |
| `GH_ORG` | `ZukanTechnologies` | Org used for JIT registration and the post-install verification |
| `OP_SERVICE_ACCOUNT_TOKEN` | *(prompted)* | Pre-supplying it skips the interactive prompt, for scripted installs |

```bash
SLOTS=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ZukanTechnologies/mac-runner/HEAD/install.sh)"
```

## What the installer does

It converges the host — observe, then change only what differs — in this order:

1. **Preflight**, read-only: Apple Silicon, macOS 15+, FileVault off, free disk. Nothing on the host changes until all of these pass.
2. **Auto-login**: if unset, prints the exact System Settings path and waits. This is the one manual step; it cannot be scripted without an undocumented OS hack, which this repo will not do. It must name **the account you run the installer as** — slot agents are LaunchAgents that load only in that user's GUI session, so a Mac auto-logging in as someone else comes back from a reboot with no runner and no visible sign of it.
3. **Toolchain**: `sudo pmset` (no sleep), Homebrew, `jq`, `1password-cli`, `cirruslabs/cli/tart`, `sshpass`.
4. **Itself**: clones/updates this repo to `/opt/zukan/mac-runner` and re-execs from there, so one run uses one consistent revision.
5. **Secrets**: prompts once for the service-account token, stores it `0600`, validates it, signs in to `ghcr.io` with the op-read pull PAT.
6. **Image**: pulls the pinned version, re-checking free disk against the real requirement first.
7. **Slots**: waits for in-flight CI jobs to finish (`FORCE=1` skips), then renders and loads one launchd agent per slot; removes slots beyond `SLOTS` and migrates any legacy plist that has a credential embedded in it.
8. **Prune**: removes superseded images — *after* the slots are running on the new one.
9. **Verify + report**: image at pin, agents loaded, a runner from this host visible in the org listing, then a summary of what was installed / changed / removed / unchanged.

Every step is safe to interrupt. Re-running resumes.

## Credentials (1Password)

One vault, one read-only service account, two items. Full contract: [`specs/027-mac-runner-bootstrap/contracts/secrets-vault.md`](https://github.com/ZukanTechnologies/zukan/blob/main/specs/027-mac-runner-bootstrap/contracts/secrets-vault.md) in the zukan repo.

| What | Value |
|---|---|
| Vault | `mac-runner` |
| Service account | `mac-runner-hosts` — read-only on that vault only; its token is the **only secret at rest on a host** (`~/.config/zukan-runner/op-token`, 0600) |
| `runner-jit-pat` / `credential` | Fine-grained PAT, org `ZukanTechnologies`, permission **Self-hosted runners: Read and write**. The agent `op read`s it **every cycle** — it is never stored on the host |
| `ghcr-pull-pat` / `credential` + `username` | Classic PAT with `read:packages` + the account it belongs to, for the non-interactive `tart login ghcr.io` (base image is a private GHCR package) |

### Rotation drills

- **JIT PAT**: replace the item's credential in 1Password → revoke the old PAT on GitHub. Effective next job cycle on every host; zero host visits.
- **GHCR PAT**: replace the item value; used on each host's next install/upgrade run.
- **SA token**: create a new token → re-run the installer on each host (the one rotation that touches hosts, by design).

## Image version pin — this repo owns it

[`IMAGE_VERSION`](IMAGE_VERSION) holds the single blessed version every host installs. Its git history is the fleet's image audit trail.

**Rolling out a new image:**

1. Build and push it from zukan: `PUSH=1 infra/mobile-ci/packer/build.sh <version>` on a fleet Mac.
2. Open a PR here bumping `IMAGE_VERSION` to that version. **This is the rollout** — no host is edited by hand, and no plist carries a version literal.
3. Re-run the one-liner on each host. Each converges: pulls the new image, restarts its slots on it, prunes the old one.

The installer rejects a pin that is empty, multi-line, or a moving tag such as `latest`. A host tracking `latest` cannot be reasoned about after the fact, and before this file existed the fleet was running three different versions at once.

### The image template lives in zukan, not here

> **This repo does not own the image template.** It is
> [`infra/mobile-ci/packer/`](https://github.com/ZukanTechnologies/zukan/tree/main/infra/mobile-ci/packer)
> in the zukan monorepo. Build and version it from there;
> [`docs/mobile-cicd.md`](https://github.com/ZukanTechnologies/zukan/blob/main/docs/mobile-cicd.md)
> is the reference.
>
> A fork of the template used to live here at `packer/`. The two copies
> drifted: this one stayed on the pre-ZUK-2131 template and built Xcode
> **26.5**, an image that cannot honestly carry the `xcode-26.6` capability
> label the mobile workflows gate on. The fork is gone; the **pin** stays here,
> because the installer is public and the zukan repo is private — a host cannot
> read a pin it has no credentials for.

The image (`ghcr.io/zukantechnologies/zukan-mobile-runner:<version>`) bakes the heavy toolchain: macOS 26 Tahoe base + Xcode 26.6 (installed from a staged `.xip`), Android SDK/NDK, JDK 17, Node 24, CocoaPods, fastlane, Go, Postgres 17, Maestro, and the Actions runner binary. Light deps (`npm ci`, `npx eas-cli`) install per-job.

Two traps worth knowing before you build it (both documented in full in zukan's `docs/mobile-cicd.md`):

- **`packer build` must run in the logged-in GUI (Aqua) session.** Over a plain SSH connection it hangs at `Waiting for SSH` until timeout — Tart needs the GUI session, the same constraint the agent has. Drive it remotely via a one-shot LaunchAgent; `launchctl asuser` needs root.
- **`no route to host` in the packer log is not a failure** — it's the guest booting, and the plugin recovers.

## Operations

```bash
# Are runners registering? (agents JIT-register at cycle start, ~1–2 min after load)
gh api orgs/ZukanTechnologies/actions/runners --jq '.runners[]|{name,status,labels:[.labels[].name]}'

# Slot agent control
launchctl bootout  "gui/$(id -u)/com.zukan.mobile-runner-agent.slot1"   # stop
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.zukan.mobile-runner-agent.slot1.plist  # start
launchctl kickstart -k "gui/$(id -u)/com.zukan.mobile-runner-agent.slot1"  # restart

# Logs (per slot)
tail -f /tmp/zukan-mobile-runner-agent.slot1.log
```

### Installer exit codes

Every non-zero exit prints a one-line remediation. Re-running the same command always resumes or converges — there is no cleanup step to run first.

| Code | Meaning | What to do |
|---|---|---|
| `10` | Unsupported machine (Intel, macOS < 15) | Use a different Mac; nothing was changed |
| `11` | Operator-remediable (FileVault on, low disk, auto-login pause aborted) | Fix the named condition, re-run |
| `20` | Secrets (bad token, missing vault item, 1Password unreachable — distinguished) | Follow the message; only a bad token needs rotating |
| `21` | Registry (`tart login` or `tart pull` failed) | Check the pinned version exists in GHCR and `ghcr-pull-pat` can read it |
| `30` | Converge (render or launchctl failure) | Usually the GUI-session rule below; state is safe to re-run |
| `40` | Verify (installed, but a health check failed) | The install landed; check the named check and the slot log |

### Troubleshooting

| Symptom (slot log) | Meaning | Fix |
|---|---|---|
| `missing host dependency: …` | brew prereq absent | re-run the installer; it converges the toolchain |
| `VM never came up; recycling` | clone booted but no IP/SSH | usually transient; persistent → check free disk + `tart list` for orphans |
| `JIT config mint failed` | GitHub rejected the registration call | check `runner-jit-pat` validity/permission; runner group must grant the zukan repo |
| `op unreachable` / op read failures | 1Password outage or bad SA token | in-flight jobs unaffected; agent retries with backoff. Bad token → re-run installer with a fresh one |
| Runner offline in GitHub UI mid-job | VM killed mid-run | expected teardown noise — single-job JIT registrations are ephemeral; stale entries age out |
| Nothing registers after reboot | GUI session missing | auto-login must be ON (and FileVault OFF); check `defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser` |

**Host session rule**: the agent must run as a **LaunchAgent in the logged-in GUI session** (`gui/$(id -u)`), never a system LaunchDaemon — Tart needs the unlocked login keychain. The installer must be run from a Terminal in that session too, not over a bare ssh connection.

## Manual provisioning (fallback only)

The installer automates all of this. It is kept here because it is what to fall back on if the installer itself is broken, and it is the fastest way to understand what a host is.

```bash
sudo pmset -a sleep 0 disksleep 0
# System Settings → Users & Groups → "Automatically log in as <CI user>"

brew install jq 1password-cli
brew trust cirruslabs/cli && brew install cirruslabs/cli/tart
brew install hudochenkov/sshpass/sshpass

tart login ghcr.io --username <ghcr-pull-pat.username>   # paste ghcr-pull-pat.credential
tart pull ghcr.io/zukantechnologies/zukan-mobile-runner:$(cat IMAGE_VERSION)

sudo mkdir -p /opt/zukan && sudo chown "$(whoami)" /opt/zukan
cp agent/mobile-runner-agent.sh /opt/zukan/ && chmod +x /opt/zukan/mobile-runner-agent.sh

# One plist per slot (1..2): copy agent/com.zukan.mobile-runner-agent.plist.tmpl to
# ~/Library/LaunchAgents/com.zukan.mobile-runner-agent.slot<N>.plist and replace
# {{SLOT}} {{BASE_IMAGE}} {{EXTRA_LABELS}} {{LOG_PATH}}, then:
#
# {{BASE_IMAGE}} is the full registry reference
# (ghcr.io/zukantechnologies/zukan-mobile-runner:<version>), NOT a bare local
# name — `tart pull` fills the OCI cache, not a runnable local VM, so a bare
# name only resolves on the Mac that built the image.
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.zukan.mobile-runner-agent.slot1.plist
```

## Repo layout

| Path | What |
|---|---|
| `install.sh` | curl\|bash entrypoint: preflight, toolchain, clone, re-exec |
| `lib/common.sh` | pure helpers — preflight predicates, plist render, pin parse, reconciliation |
| `lib/install-main.sh` | the installer proper: secrets, image, slots, prune, verify, report |
| `IMAGE_VERSION` | the blessed base-image version pin |
| `agent/` | host slot-agent loop + launchd plist template |
| `tests/` | bats suite (run in CI on Linux and macOS, with shellcheck) |

### Working on this repo

```bash
shellcheck install.sh lib/*.sh agent/*.sh
bats tests/
```

`main` is branch-protected because its HEAD is a production input: every install on every host runs whatever is on it.

Planning artifacts (spec, plan, contracts, decision log): [`specs/027-mac-runner-bootstrap/`](https://github.com/ZukanTechnologies/zukan/blob/main/specs/027-mac-runner-bootstrap/spec.md) in the zukan monorepo. Fleet architecture narrative: zukan's `docs/mobile-cicd.md`.
