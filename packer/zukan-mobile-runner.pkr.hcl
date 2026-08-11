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
  type = string
  # Calendar versioning, YYYY.MM.N, N reset each month. Bump on EVERY template
  # change (including a base_image bump) — the version is the fleet's audit
  # trail. Passed on the command line: ./build.sh 2026.07.3
  #
  # What the fleet is actually running lives in the agent plist's BASE_IMAGE
  # (runner/com.zukan.mobile-runner-agent.plist) — bump that in the same PR, or
  # hosts keep cloning the old image and the change never lands.
  description = "Version tag for the output image (e.g. 2026.07.3). Bump on every template change."
}

variable "base_image" {
  type = string
  # A macOS base image with NO Xcode. We install Xcode ourselves (see
  # xcode_version / xcode_xip below) rather than taking a prebuilt
  # macos-<os>-xcode:<tag> image.
  #
  # WHY WE BUILD OUR OWN (ZUK-2131, 2026-07-28) — this is the load-bearing
  # comment; read it before "simplifying" back to a combined image:
  #
  #   The build failures that drove this decision were:
  #     Tahoe   + Xcode 26.5  → BUILD FAILED
  #     Tahoe   + Xcode 26.6  → BUILD SUCCEEDED
  #     Sequoia + Xcode 26.6  → BUILD FAILED
  #
  #   CAVEAT (2026-07-28): those rows are an UNCONTROLLED comparison and the
  #   "Sequoia is the variable" reading was WRONG. The real defect was a UUID
  #   collision in the generated Pods.xcodeproj — CocoaPods restarts its UUID
  #   counter mid-install, and when the project's object count is an exact
  #   multiple of 100 the clerk-ios XCRemoteSwiftPackageReference is handed the
  #   root PBXProject's UUID:
  #     "The project 'Pods' is damaged"
  #     -[XCRemoteSwiftPackageReference _setSavedArchiveVersion:] unrecognized selector
  #     → "no such module 'Expo'" → ** BUILD FAILED **
  #   It is fixed in apps/mobile/plugins/withPodsUuidCollisionGuard.js, and it
  #   was reproduced on a developer Mac with this exact toolchain. Any two
  #   images differing in anything can land on opposite sides of that boundary,
  #   which is what the table above actually recorded. See docs/mobile-cicd.md
  #   § "Root cause: a UUID collision with the root project object".
  #
  #   Tahoe + 26.6 therefore stays as a deliberate, current pin — NOT as a
  #   measured requirement. Xcode 26.5 is genuinely too old; macOS Tahoe is a
  #   choice. Do not re-derive a toolchain theory from a red build again.
  #
  #   cirruslabs publishes no macos-tahoe-xcode:26.6 — the combination we need
  #   has no prebuilt image, and its absence is what blocked iOS E2E for days.
  #   Installing Xcode ourselves DECOUPLES US FROM THEIR PUBLISHING CADENCE:
  #   macOS comes from the -base image, Xcode from a .xip we control, and
  #   neither can strand the other again.
  default = "ghcr.io/cirruslabs/macos-tahoe-base:latest"
}

variable "xcode_version" {
  type = string
  # Hard floor 26.6 — asserted by the first provisioner, so a wrong xip fails
  # the build in seconds instead of surfacing as an `eas build --local` error
  # in CI a day later.
  default = "26.6"
}

variable "xcode_xip" {
  type = string
  # MANUAL PREREQUISITE. Apple requires a developer account to download Xcode,
  # so the .xip cannot be fetched by this template — stage it on the build host
  # first (it is NOT in git; it is ~2.2 GB):
  #
  #   brew install xcodes
  #   xcodes download 26.6            # prompts for Apple ID + 2FA; needs a TTY
  #   mkdir -p ~/XcodesCache
  #   mv ~/Downloads/Xcode-26.6.0+*.xip ~/XcodesCache/Xcode_26.6.xip
  #
  # Keep the file after a build — a rebuild needs it again.
  default = "~/XcodesCache/Xcode_26.6.xip"
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
  # The -base image ships a SMALLER disk than the prebuilt -xcode images did,
  # and Xcode alone unpacks to ~40 GB, so grow it. Tart can only GROW a disk,
  # never shrink it (a smaller value errors: "new disk size … should be larger
  # than the current disk size"), so this may only ever go up. Clones are APFS
  # copy-on-write, so each ephemeral VM still consumes only its write-delta.
  disk_size_gb = 140
  headless     = true
  ssh_username = "admin" # cirruslabs image default
  ssh_password = "admin"
  ssh_timeout  = "120s"
}

build {
  sources = ["source.tart-cli.zukan_mobile_runner"]

  # ── Xcode, from a .xip we control (NOT from the base image) ─────────
  # Upload first: everything downstream needs a working xcodebuild.
  provisioner "file" {
    source      = pathexpand(var.xcode_xip)
    destination = "/Users/admin/Downloads/Xcode.xip"
  }

  provisioner "shell" {
    inline = [
      "source ~/.zprofile || true",
      "brew install --quiet xcodes",
      # --empty-trash + the explicit rm keep peak disk down; the expanded app
      # and the 2.2 GB archive would otherwise coexist on a 140 GB disk.
      "sudo xcodes install ${var.xcode_version} --experimental-unxip --path /Users/admin/Downloads/Xcode.xip --select --empty-trash",
      # Park it at a versioned path so multiple Xcodes can coexist later, and
      # so `xcode_path` in fastlane logs names the version outright.
      "APP_DIR=$(dirname $(dirname \"$(xcodes select -p)\"))",
      "sudo mv \"$APP_DIR\" /Applications/Xcode_${var.xcode_version}.app",
      "sudo xcode-select -s /Applications/Xcode_${var.xcode_version}.app",
      "sudo xcodebuild -license accept",
      # The modern Xcode .xip carries no simulator runtime — it is a separate
      # unauthenticated download. Without this the prewarm below cannot create
      # a device, which is exactly the failure we want surfaced here.
      "xcodebuild -downloadPlatform iOS",
      "sudo xcodebuild -runFirstLaunch",
      "rm -f /Users/admin/Downloads/Xcode.xip",
      "df -h /",
    ]
  }

  # ── Guard: assert the installed Xcode clears the floor ──────────────
  # Immediately after the install, so a wrong xip fails in seconds instead of
  # after an hour of brew installs — and so it fails HERE rather than as a
  # cryptic `eas build --local` error in CI a day later. 26.6 is a hard floor
  # and macOS must be Tahoe (26.x); see base_image for the measured matrix.
  provisioner "shell" {
    inline = [
      "sw_vers",
      "xcodebuild -version",
      "XCODE_VER=$(xcodebuild -version | awk 'NR==1{print $2}')",
      "[ \"$(printf '%s\\n26.6\\n' \"$XCODE_VER\" | sort -V | head -1)\" = '26.6' ] || { echo \"FATAL: Xcode $XCODE_VER is below the 26.6 floor (ZUK-2131). xcode_xip=${var.xcode_xip}\"; exit 1; }",
      # Tahoe is a deliberate pin, not a measured requirement — the Sequoia
      # failure it was derived from turned out to be a Pods UUID collision, not
      # a macOS issue (ZUK-2131; see base_image). Kept so the fleet stays on one
      # known-good OS, and so an accidental base-image downgrade fails here.
      "OS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)",
      "[ \"$OS_MAJOR\" -ge 26 ] || { echo \"FATAL: macOS $OS_MAJOR is not Tahoe (26+). Sequoia + Xcode 26.6 was measured to FAIL the app build (ZUK-2131). base_image=${var.base_image}\"; exit 1; }",
      "echo \"OK: macOS $(sw_vers -productVersion) + Xcode $XCODE_VER clear the ZUK-2131 floor\"",
    ]
  }

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
  # mobile-e2e.yml greps this exact device NAME for a UDID, so an image
  # without it is a broken image. NO `|| true` here (ZUK-2131): the base image
  # supplies both the device type and the runtime, so a base-image change can
  # remove either — and a silently absent simulator surfaces a day later as an
  # empty-UDID error in CI instead of a failed image build. The runtime echo is
  # the record of what actually shipped; read it before trusting a new image.
  provisioner "shell" {
    inline = [
      "xcrun simctl list runtimes",
      "xcrun simctl create 'zukan-e2e' com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
      "xcrun simctl list devices available | grep 'zukan-e2e'",
    ]
  }
}
