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
| `IMAGE_VERSION` | [`IMAGE_VERSION`](IMAGE_VERSION) file | Escape-hatch image override |
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

## Base image

> **`packer/` in this repo is the source of truth for the image.**
>
> It was previously a pre-ZUK-2131 fork that built Xcode **26.5** while the zukan
> monorepo's `infra/mobile-ci/packer/` built **26.6** — two copies, silently
> divergent, and building from this one produced an image that could not honestly
> carry the `xcode-26.6` capability label the mobile workflows gate on. The live
> template has been ported here and the monorepo copy removed.
>
> The **agent** half (`agent/`) is deliberately NOT consolidated: hosts are
> provisioned by [`troymccabe/setup`](https://github.com/troymccabe/setup) →
> `mac/runner/setup`, and the zukan monorepo's `infra/mobile-ci/runner/` still
> drives the Refractor host. This repo owns the image; it does not own the fleet.

The image (`ghcr.io/zukantechnologies/zukan-mobile-runner:<version>`) bakes the heavy toolchain: Cirrus macOS+Xcode base, Android SDK/NDK, JDK 17, Node 24, CocoaPods, fastlane, Go, Postgres 17, Maestro, and the Actions runner binary. Light deps (`npm ci`, `npx eas-cli`) install per-job.

The monorepo template additionally needs `~/XcodesCache/Xcode_26.6.xip` staged by
hand before a build — Apple requires a developer account, so it cannot be
fetched by the template (`xcodes download 26.6 --directory ~/XcodesCache`).

**Building** (human step, on any fleet Mac):

```bash
brew install jq
brew trust cirruslabs/cli && brew install cirruslabs/cli/tart
brew tap hashicorp/tap && brew install hashicorp/tap/packer
brew install hudochenkov/sshpass/sshpass

./packer/build.sh 2026.08.1            # build
PUSH=1 ./packer/build.sh 2026.08.1     # …and push to GHCR (needs tart login with write:packages)
```

### ⚠️ Packer must run in the logged-in GUI (Aqua) session

`packer build` **hangs at `Waiting for SSH` until it times out** when launched
over a plain SSH connection. This is the same constraint the runner agent has —
Tart drives `Virtualization.framework`, which needs a logged-in GUI session — but
it is easy to miss here because "on any fleet Mac" reads like it can be driven
remotely. It can, just not directly from an SSH shell.

Sitting at the machine (or in a Screen Sharing session), the commands above work
as written. To drive a build **remotely**, run it as a one-shot LaunchAgent,
which executes inside the Aqua session:

```bash
# ~/Library/LaunchAgents/dev.zukan.packerbuild.plist — RunAtLoad, KeepAlive=false,
# ProgramArguments = /bin/bash <a script that cd's to packer/ and runs build.sh>
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.zukan.packerbuild.plist
tail -f <the plist's StandardOutPath>
```

`launchctl asuser $(id -u) …` is the obvious alternative and **does not work
unprivileged** — it needs root (`Could not switch to audit session … Operation
not permitted`), so on a host without passwordless sudo the LaunchAgent is the
practical route.

**Do not kill a run that is sitting on `no route to host`.** That message is the
guest still booting; the plugin re-resolves the IP and recovers on its own
(`handshake complete!` follows within a minute or so). Three otherwise-healthy
builds were abandoned mid-flight before this was understood.

### Host sizing

`vm_memory_gb` defaults to **16**, which is unbuildable on a 16 GB Mac — the VM
starves the host. On a 16 GB host, override:

```bash
PKR_VAR_vm_memory_gb=10 PKR_VAR_vm_cpu_count=6 ./packer/build.sh 2026.08.1
```

Disk: the build needs the base image plus a VM that grows to ~53 GB, so budget
~110 GB free. Clones are APFS copy-on-write, so an *ephemeral* VM costs only its
write-delta (~3 GB per job) — but `du` reports shared blocks against every file
that references them, so it will read ~50 GB per clone. Trust
`diskutil info / | grep "Container Free Space"` over `du` here.

**Rollout**: open a PR bumping [`IMAGE_VERSION`](IMAGE_VERSION), merge, then re-run the installer on each host. The pin's git history is the fleet's image audit trail. Never point hosts at `latest`.

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

# 3. Base image (version from the IMAGE_VERSION file)
tart login ghcr.io --username <ghcr-pull-pat.username>   # paste ghcr-pull-pat.credential
tart pull ghcr.io/zukantechnologies/zukan-mobile-runner:$(cat IMAGE_VERSION)

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
| `IMAGE_VERSION` | the blessed image pin — bump via PR to roll out |
| `agent/` | host slot-agent loop + launchd plist template |
| `packer/` | base-image definition + build script |
| `tests/` | bats suite (run in CI with shellcheck) |

Planning artifacts (spec, plan, contracts, decision log): [`specs/027-mac-runner-bootstrap/`](https://github.com/ZukanTechnologies/zukan/blob/main/specs/027-mac-runner-bootstrap/spec.md) in the zukan monorepo. Fleet architecture narrative: zukan's `docs/mobile-cicd.md`.
