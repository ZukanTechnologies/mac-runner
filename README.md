# mac-runner

One-command provisioning for Zukan's **ephemeral Mac CI runner hosts** — Apple-Silicon Macs that run GitHub Actions jobs inside disposable [Tart](https://tart.run) VMs (labels `self-hosted, mobile-runner, macos, arm64`).

Lifecycle per job: `tart clone` the base image → boot → JIT-register a **single-job** GitHub runner → run exactly one job → delete the VM. No state survives between jobs, so there is no config drift.

> **Status**: the one-line installer is being built (ZUK-2156…ZUK-2162). Until it lands, provision hosts with the [manual runbook](#manual-provisioning-runbook-interim) below — same end state.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ZukanTechnologies/mac-runner/HEAD/install.sh)"
```

One paste of the 1Password service-account token, at most one System Settings toggle, zero other questions.

© Zukan Technologies LLC. Published without a license grant — the code is public for provisioning convenience, not for reuse (deliberate decision, ZUK-2147).

## Prerequisites (fresh Mac)

1. Apple-Silicon Mac, macOS 15+.
2. Complete Setup Assistant as the CI user. **Decline FileVault** — auto-login is impossible while disk encryption is on, and Tart requires an unlocked `login.keychain` in a logged-in GUI session (macOS Virtualization framework behavior).
3. Have the `mac-runner-hosts` 1Password **service-account token** at hand (see [Credentials](#credentials-1password)).

## Configuration (env overrides)

The default install asks nothing beyond the token. Overrides are env-var prefixes to the same one-liner:

| Var | Default | Meaning |
|---|---|---|
| `SLOTS` | `2` | VM slots (max 2 — Apple Virtualization caps concurrent VMs per host) |
| `RUNNER_EXTRA_LABELS` | *(empty)* | Comma-separated labels appended to `mobile-runner,macos,arm64` |
| `IMAGE_VERSION` | *(required)* | Image version to pull; the blessed pin lives in zukan's `docs/mobile-cicd.md` |
| `FORCE` | `0` | `1` = don't wait for idle slots; terminates in-flight CI VMs (they retry on re-run) |

**Upgrades = re-run the same one-liner.** The installer is idempotent: it converges the host onto the current repo HEAD + image pin, prunes superseded images, and migrates legacy layouts. There is no other update mechanism.

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

## Base image — lives in the zukan repo, not here

> **This repo does not own the image template.** It is
> [`infra/mobile-ci/packer/`](https://github.com/ZukanTechnologies/zukan/tree/main/infra/mobile-ci/packer)
> in the zukan monorepo. Build, version and roll out from there;
> [`docs/mobile-cicd.md`](https://github.com/ZukanTechnologies/zukan/blob/main/docs/mobile-cicd.md)
> is the reference.
>
> A fork of the template used to live here at `packer/`, alongside an
> `IMAGE_VERSION` pin. The two copies drifted: this one stayed on the
> pre-ZUK-2131 template and built Xcode **26.5**, an image that cannot honestly
> carry the `xcode-26.6` capability label the mobile workflows gate on — while
> three pins (`2026.07.2` here, `2026.07.4` in the zukan agent plist,
> `2026.08.1` on the live host) disagreed. Both are deleted; one source of truth.

The image (`ghcr.io/zukantechnologies/zukan-mobile-runner:<version>`) bakes the heavy toolchain: macOS 26 Tahoe base + Xcode 26.6 (installed from a staged `.xip`), Android SDK/NDK, JDK 17, Node 24, CocoaPods, fastlane, Go, Postgres 17, Maestro, and the Actions runner binary. Light deps (`npm ci`, `npx eas-cli`) install per-job.

Two traps worth knowing before you build it (both documented in full in zukan's `docs/mobile-cicd.md`):

- **`packer build` must run in the logged-in GUI (Aqua) session.** Over a plain SSH connection it hangs at `Waiting for SSH` until timeout — Tart needs the GUI session, the same constraint the agent has below. Drive it remotely via a one-shot LaunchAgent; `launchctl asuser` needs root.
- **`no route to host` in the packer log is not a failure** — it's the guest booting, and the plugin recovers.

**Rollout**: bump the version in zukan, rebuild, push to GHCR, then point each host's `BASE_IMAGE` at the new version. Never point hosts at `latest`.

## Manual provisioning runbook (interim)

Until the installer lands, on a prepared Mac (prerequisites above):

```bash
# 1. Host settings
sudo pmset -a sleep 0 disksleep 0
# System Settings → Users & Groups → "Automatically log in as <CI user>"

# 2. Toolchain
brew install jq 1password-cli
brew trust cirruslabs/cli && brew install cirruslabs/cli/tart
brew install hudochenkov/sshpass/sshpass

# 3. Base image (version pinned in zukan — see docs/mobile-cicd.md)
tart login ghcr.io --username <ghcr-pull-pat.username>   # paste ghcr-pull-pat.credential
tart pull ghcr.io/zukantechnologies/zukan-mobile-runner:<version>

# 4. Agent
sudo mkdir -p /opt/zukan && sudo chown "$(whoami)" /opt/zukan
cp agent/mobile-runner-agent.sh /opt/zukan/ && chmod +x /opt/zukan/mobile-runner-agent.sh

# 5. One plist per slot (1..2): copy agent/com.zukan.mobile-runner-agent.plist.tmpl to
#    ~/Library/LaunchAgents/com.zukan.mobile-runner-agent.slot<N>.plist and edit
#    Label suffix, SLOT, BASE_IMAGE, log paths (see template header comments), then:
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.zukan.mobile-runner-agent.slot1.plist
```

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

### Troubleshooting

| Symptom (slot log) | Meaning | Fix |
|---|---|---|
| `missing host dependency: …` | brew prereq absent | install the named tool (see Toolchain above) |
| `VM never came up; recycling` | clone booted but no IP/SSH | usually transient; persistent → check free disk + `tart list` for orphans |
| `JIT config mint failed` | GitHub rejected the registration call | check `runner-jit-pat` validity/permission; runner group must grant the zukan repo |
| `op unreachable` / op read failures | 1Password outage or bad SA token | in-flight jobs unaffected; agent retries with backoff. Bad token → re-run installer with a fresh one |
| Runner offline in GitHub UI mid-job | VM killed mid-run | expected teardown noise — single-job JIT registrations are ephemeral; stale entries age out |
| Nothing registers after reboot | GUI session missing | auto-login must be ON (and FileVault OFF); check `defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser` |

**Host session rule**: the agent must run as a **LaunchAgent in the logged-in GUI session** (`gui/$(id -u)`), never a system LaunchDaemon — Tart needs the unlocked login keychain.

## Repo layout

| Path | What |
|---|---|
| `install.sh` | curl\|bash entrypoint *(lands in ZUK-2159)* |
| `lib/` | installer internals + pure helpers *(ZUK-2158/2160/2161)* |
| `agent/` | host slot-agent loop + launchd plist template |
| `tests/` | bats suite (run in CI with shellcheck) |

Planning artifacts (spec, plan, contracts, decision log): [`specs/027-mac-runner-bootstrap/`](https://github.com/ZukanTechnologies/zukan/blob/main/specs/027-mac-runner-bootstrap/spec.md) in the zukan monorepo. Fleet architecture narrative: zukan's `docs/mobile-cicd.md`.
