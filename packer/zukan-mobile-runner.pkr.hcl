# Zukan mobile CI base image — ZUK-1994 (spec 026, research D12).
#
# Declarative Packer template for the ephemeral mobile-runner VMs.
# Built with the Tart builder (packer-plugin-tart) on a mobile-runner Mac
# (Apple Silicon; Tart VMs only run on the host they were pulled to, so
# the image is built once and `tart push`ed to GHCR for the other hosts).
#
# Layering (research D12): the HEAVY toolchain is baked here — Xcode via
# the Cirrus Labs base image, Android SDK, JDK, Node, CocoaPods, fastlane,
# Maestro, Go + Postgres (the E2E jobs run the Zukan API + fixture DB
# inside the VM; mobile-runner VMs have no Docker). LIGHT per-job deps
# (npm ci, npx eas-cli) install at job time so the image doesn't churn
# with every lockfile bump.
#
# Build + push:  ./build.sh <version>       (see build.sh in this dir)
# Consumed by:   ../runner/mobile-runner-agent.sh (clones per job, deletes after)

packer {
  required_plugins {
    tart = {
      version = ">= 1.14.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

variable "image_version" {
  type        = string
  description = "Version tag for the output image (e.g. 2026.07.1). Bump on every template change."
}

variable "base_image" {
  type = string
  # Cirrus Labs publishes macOS images with Xcode preinstalled; pin the
  # Xcode version the app builds with (Expo SDK 57 / iOS 26 SDK). NOTE: the
  # macos-tahoe-xcode line tops out at 26.5 — 26.6 only exists for
  # macos-sequoia-xcode. Verify a tag is published before bumping:
  #   curl -s "https://ghcr.io/token?scope=repository:cirruslabs/macos-tahoe-xcode:pull" \
  #     | jq -r .token | xargs -I{} curl -s -H "Authorization: Bearer {}" \
  #     https://ghcr.io/v2/cirruslabs/macos-tahoe-xcode/tags/list | jq -r '.tags[]'
  default = "ghcr.io/cirruslabs/macos-tahoe-xcode:26.5"
}

variable "vm_cpu_count" {
  type    = number
  default = 6
}

variable "vm_memory_gb" {
  type    = number
  default = 16
}

variable "android_cmdline_tools" {
  type    = string
  default = "13114758" # cmdline-tools "latest" build id — bump deliberately
}

variable "actions_runner_version" {
  type = string
  # Must be recent enough that GitHub doesn't hard-deprecate it ("Runner
  # version X is deprecated and cannot receive messages"). The runner
  # self-updates for minor drift, but a stale baked binary is rejected before
  # it can update — bump this to a current actions/runner release when it ages.
  default = "2.335.1"
}

source "tart-cli" "zukan_mobile_runner" {
  vm_base_name = var.base_image
  vm_name      = "zukan-mobile-runner-${var.image_version}"
  cpu_count    = var.vm_cpu_count
  memory_gb    = var.vm_memory_gb
  # No disk_size_gb: the macos-*-xcode base image already ships a 140 GB disk
  # and Tart can only GROW a disk, not shrink it (a smaller value errors:
  # "new disk size … should be larger than the current disk size"). Clones are
  # APFS copy-on-write, so each ephemeral VM only consumes its write-delta, not
  # a full 140 GB — no need to grow it either.
  headless     = true
  ssh_username = "admin" # cirruslabs image default
  ssh_password = "admin"
  ssh_timeout  = "120s"
}

build {
  sources = ["source.tart-cli.zukan_mobile_runner"]

  # ── Homebrew toolchain (idempotent; base image ships brew) ──────────
  provisioner "shell" {
    inline = [
      "source ~/.zprofile || true",
      "brew install --quiet node@24 cocoapods fastlane watchman go postgresql@17 temurin@17 jq gh",
      "brew link --overwrite --force node@24",
      "echo 'export PATH=\"/opt/homebrew/opt/node@24/bin:/opt/homebrew/opt/postgresql@17/bin:$PATH\"' >> ~/.zprofile",
    ]
  }

  # ── Android SDK (cmdline-tools + platform/build tools) ──────────────
  provisioner "shell" {
    inline = [
      "source ~/.zprofile || true",
      "export ANDROID_HOME=$HOME/android-sdk",
      "mkdir -p $ANDROID_HOME/cmdline-tools",
      "curl -fsSL -o /tmp/clt.zip https://dl.google.com/android/repository/commandlinetools-mac-${var.android_cmdline_tools}_latest.zip",
      "unzip -q /tmp/clt.zip -d $ANDROID_HOME/cmdline-tools && mv $ANDROID_HOME/cmdline-tools/cmdline-tools $ANDROID_HOME/cmdline-tools/latest",
      "export JAVA_HOME=$(/usr/libexec/java_home -v 17)",
      "yes | $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --licenses > /dev/null",
      "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager 'platform-tools' 'platforms;android-36' 'build-tools;36.0.0' 'ndk;27.1.12297006' > /dev/null",
      "echo 'export ANDROID_HOME=$HOME/android-sdk' >> ~/.zprofile",
      "echo 'export JAVA_HOME=$(/usr/libexec/java_home -v 17)' >> ~/.zprofile",
      "echo 'export PATH=\"$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH\"' >> ~/.zprofile",
    ]
  }

  # ── Maestro CLI (E2E driver) ────────────────────────────────────────
  provisioner "shell" {
    inline = [
      "curl -fsSL https://get.maestro.mobile.dev | bash",
      "echo 'export PATH=\"$HOME/.maestro/bin:$PATH\"' >> ~/.zprofile",
    ]
  }

  # ── GitHub Actions runner binary (JIT-registered per job) ───────────
  provisioner "shell" {
    inline = [
      "mkdir -p ~/actions-runner && cd ~/actions-runner",
      "curl -fsSL -o runner.tar.gz https://github.com/actions/runner/releases/download/v${var.actions_runner_version}/actions-runner-osx-arm64-${var.actions_runner_version}.tar.gz",
      "tar xzf runner.tar.gz && rm runner.tar.gz",
    ]
  }

  # ── Prewarm: an iOS simulator matching the E2E device pin ───────────
  provisioner "shell" {
    inline = [
      "xcrun simctl list runtimes",
      "xcrun simctl create 'zukan-e2e' com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro || true",
    ]
  }
}
