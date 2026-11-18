# mac-runner

One-command provisioning for Zukan's **ephemeral Mac CI runner hosts** — Apple-Silicon Macs that run GitHub Actions jobs inside disposable [Tart](https://tart.run) VMs.

Lifecycle per job: `tart clone` the base image → boot → JIT-register a **single-job** GitHub runner → run exactly one job → delete the VM. No state survives between jobs, so there is no config drift.

**This repo does not implement that loop.** It is an opinionated wrapper around [`troymccabe/setup`](https://github.com/troymccabe/setup)'s `mac/runner/setup`, which is the engine. This repo owns Zukan's *opinions* — which image, which runner version, which labels, how many slots, where the credential lives — and the host lifecycle around them. See [Architecture](#architecture-this-repo-pins-an-engine).

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
| `SLOTS` | `2` | VM slots (max 2 — Apple Virtualization caps concurrent VMs per host). Each slot is one engine install; actual concurrency is gated by RAM, so a 16 GB host serialises two slots |
| `RUNNER_EXTRA_LABELS` | *(empty)* | Comma-separated labels for capabilities **the VM cannot report** (e.g. `maestro`). `macos-major-*` / `xcode-*` / `image-*` entries are stripped — those are probed. Runners always carry `self-hosted, macOS, arm64` plus `mobile-runner` and the host label |
| `IMAGE_VERSION` | the repo's [`IMAGE_VERSION`](IMAGE_VERSION) pin | Escape hatch for a version other than the blessed pin |
| `RUNNER_VERSION` | the repo's [`RUNNER_VERSION`](RUNNER_VERSION) pin | `actions/runner` version every VM runs. **Authoritative** — a runner baked into the image is replaced when it disagrees |
| `FORCE` | `0` | `1` = don't wait for idle slots; terminates in-flight CI VMs (they retry on re-run) |
| `GH_ORG` | `ZukanTechnologies` | Org used for JIT registration and the post-install verification |
| `MR_RUNNER_GROUP` | `macos-fleet` | Org runner group the slots register into |
| `MR_SHARED_LABEL` | `mobile-runner` | The fleet label workflows route on |
| `MR_VM_MEMORY_MB` / `MR_VM_CPU_COUNT` | `12288` / `6` | Per-VM sizing handed to the engine |
| `MR_HOST_RESERVE_MB` | `4096` | RAM kept free for the host; this is what gates real concurrency |
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
6. **Engine**: fetches `mac/runner/setup` at the `SETUP_VERSION` commit, **verifies its sha256 against `SETUP_SHA256`**, and installs it at `/opt/zukan/gha-runner-setup`. A mismatch refuses to run it.
7. **Image**: materialises the pinned version as a **local** Tart VM, re-checking free disk against the real requirement first.
8. **Slots**: waits for in-flight CI jobs to finish (`FORCE=1` skips), then runs the engine once per slot; removes slots beyond `SLOTS` and migrates any legacy plist that has a credential embedded in it.
9. **Prune**: removes superseded images — *after* the slots are running on the new one.
10. **Verify + report**: image at pin, agents loaded, a runner from this host visible in the org listing, then a summary of what was installed / changed / removed / unchanged.

Every step is safe to interrupt. Re-running resumes.

## Architecture: this repo pins an engine

```
ZukanTechnologies/mac-runner   ← opinions + host lifecycle (this repo)
        │  SETUP_VERSION  commit sha of the engine
        │  SETUP_SHA256   checksum of the file at that commit
        │  IMAGE_VERSION  which base image
        │  RUNNER_VERSION which actions/runner
        ▼
troymccabe/setup  mac/runner/setup   ← the engine: orchestrator loop,
                                       JIT registration, capability probing,
                                       VM lifecycle, launchd agent
```

One slot = one engine install. Three inputs must differ between slots, and the installer derives all three:

| Slot | `LAUNCHD_LABEL` | `CONFIG_DIR` | `VM_PREFIX` |
|---|---|---|---|
| 1 | `com.zukan.mobile-runner-agent.slot1` | `~/.gha-runner/slot1` | `ephem-s1-` |
| 2 | `com.zukan.mobile-runner-agent.slot2` | `~/.gha-runner/slot2` | `ephem-s2-` |

`VM_PREFIX` is the one that is not merely tidiness. Each engine reaps the VMs carrying its prefix **at startup** — which happens on a KeepAlive restart and at every login, not just on install — so two slots sharing a prefix would destroy each other's running jobs. Prefixes must be *disjoint*, not merely different: matching is `startswith`, so `ephem-` would also match `ephem-s1-…`.

### Why pin rather than vendor

`SETUP_VERSION` is a **commit sha, never a tag or branch**: tags can be moved and branches always move, and either would silently change what every host installs. `SETUP_SHA256` is checked before the file is executed — the pin says *which* revision, the checksum says the bytes we got *are* that revision, and a pinned URL still traverses the network.

Bumping the engine is those two files plus a re-run. They must move together; the installer refuses on mismatch and names both sides.

### Capability labels are probed, never asserted

The engine SSHes into each booted VM and reads `sw_vers` and `xcodebuild -version` before registering, so it owns the `macos-major-*`, `xcode-*` and `image-*` namespaces. **Entries in those namespaces are stripped from `RUNNER_EXTRA_LABELS`** and the installer says so once.

A static capability label says what *should* be in the image; only the VM knows what *is*. An asserted label that has drifted is worse than no gate at all — it routes a job confidently to the wrong toolchain. Put capabilities the VM cannot report (`maestro`, `node-22`) in `RUNNER_EXTRA_LABELS`; anything it *can* report comes from the probe.

`REQUIRE_XCODE=1` is set for this fleet: a mobile-runner image with no Xcode is a broken image, so the VM is recycled rather than registered half-labelled.

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

# Logs (per slot) — the engine writes these
tail -f ~/.gha-runner/slot1/orchestrator.log
tail -f ~/.gha-runner/slot1/orchestrator.err
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

If the installer cannot run, converge one slot by hand with the engine directly.
Get the pinned engine and check it before running it:

```bash
COMMIT=$(grep -v '^#' SETUP_VERSION | tr -d '[:space:]')
WANT=$(grep -v '^#' SETUP_SHA256  | tr -d '[:space:]')
curl -fsSL "https://raw.githubusercontent.com/troymccabe/setup/${COMMIT}/mac/runner/setup" -o /tmp/engine
[ "$(shasum -a 256 /tmp/engine | cut -d' ' -f1)" = "$WANT" ] || { echo "checksum mismatch"; exit 1; }

# System Settings → Users & Groups → "Automatically log in as <CI user>"
# (FileVault must be off), then, from the logged-in GUI session:
GH_ORG=ZukanTechnologies GH_PAT=<install-time PAT> \
OP_ITEM_REF=op://mac-runner/runner-jit-pat/credential \
RUNNER_GROUP=macos-fleet SHARED_LABEL=mobile-runner REQUIRE_XCODE=1 \
BASE_IMAGE=zukan-mobile-runner-$(cat IMAGE_VERSION) \
RUNNER_VERSION=$(grep -v '^#' RUNNER_VERSION | tr -d '[:space:]') \
LAUNCHD_LABEL=com.zukan.mobile-runner-agent.slot1 \
CONFIG_DIR="$HOME/.gha-runner/slot1" VM_PREFIX=ephem-s1- \
  bash /tmp/engine
```

`BASE_IMAGE` is a **local** Tart VM name, not a registry reference: `tart pull`
fills the OCI cache, which Tart auto-prunes under disk pressure, and a per-job
clone against a remote ref degenerates into re-downloading the image every
cycle. The installer materialises the local VM for you; by hand, `tart clone
ghcr.io/zukantechnologies/zukan-mobile-runner:<version>
zukan-mobile-runner-<version>` first.

For a second slot, repeat with `slot2` / `ephem-s2-`. The prefixes must not
overlap — the engine refuses if they do.

## Repo layout

| Path | What |
|---|---|
| `install.sh` | curl\|bash entrypoint: preflight, toolchain, clone, re-exec |
| `lib/common.sh` | pure helpers — preflight predicates, pin parse, slot→engine env, drift, reconciliation |
| `lib/install-main.sh` | the installer proper: secrets, engine, image, slots, prune, verify, report |
| `SETUP_VERSION` | commit sha of the engine (`troymccabe/setup`) |
| `SETUP_SHA256` | checksum of `mac/runner/setup` at that commit |
| `IMAGE_VERSION` | the blessed base-image version pin |
| `RUNNER_VERSION` | the `actions/runner` version every VM runs |
| `tests/` | bats suite (run in CI on Linux and macOS, with shellcheck) |

### Working on this repo

```bash
shellcheck install.sh lib/*.sh
bats tests/
```

`main` is branch-protected because its HEAD is a production input: every install on every host runs whatever is on it.

Planning artifacts (spec, plan, contracts, decision log): [`specs/027-mac-runner-bootstrap/`](https://github.com/ZukanTechnologies/zukan/blob/main/specs/027-mac-runner-bootstrap/spec.md) in the zukan monorepo. Fleet architecture narrative: zukan's `docs/mobile-cicd.md`.
