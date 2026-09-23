# anaconda-rhel9-base

This is a **shared Anaconda installer environment for RHEL 9 bootc payloads**. It is build infrastructure, not a deployable image: it is never installed on a device and never produces its own installable artifact.

---

## What it's for

When an app directory's `.buildconfig` requests `bootc-generic-iso` or `bootc-installer` as an `artifact_formats`, the main workflow needs an Anaconda-based installer environment to boot from. Rather than every app image building its own installer from scratch, they all share this one base:

1. This image is built once (see [`.buildconfig`](.buildconfig)) and published like any other image in the repository.
2. An app directory's own `installer/Containerfile` uses this image as its `FROM`, layering in only what differs per app: `installer/kickstart.ks` and `installer/iso.yaml`.
3. The result is used as the `--bootc-ref` (installer environment) passed to `image-builder`, paired with the app's own bootc image as `--bootc-installer-payload-ref`.

App directories select this base with `installer_base: anaconda-rhel9-base` in their own `.buildconfig` (the repo-wide default is `anaconda-rhel10-base` unless overridden). See the [`installer_base`](../README.md#installer_base) section of the repository README for the full explanation.

---

## What's included

- `anaconda`, `anaconda-install-env-deps`, `anaconda-dracut`, `dracut-config-generic`, `dracut-network`, `lorax-templates-rhel`, `python3-mako`, `grub2-common`, `audit`, `xorriso`, `squashfs-tools`, `fuse-overlayfs`, plus the correct GRUB/shim and devname packages for the target architecture (`grub2-efi-x64-cdboot`/`shim-x64`/`biosdevname` on x86_64, `grub2-efi-aa64-cdboot`/`shim-aa64` on arm64).
- A `dnf reinstall` pass for the GRUB/shim packages, needed because the base `rhel-bootc` image ships them as "installed" in the RPM database but bootc's image compose step strips their actual `/boot/efi` payload; a plain `dnf install` would then be a no-op.
- A build-time check that the expected `shim*.efi`, `mm*.efi` and `gcd*.efi` files actually landed under `/boot/efi/EFI/redhat/`, failing the build early with a clear error (including which RPM should own the missing file) if they didn't.
- Anaconda wired up as the boot target instead of a normal login (`default.target` → `anaconda.target`, `autovt@.service` → `anaconda-shell@.service`), with the initramfs rebuilt to include the `anaconda` dracut module. The kernel version is read from `/usr/lib/modules` rather than `kernel-install list --json`, since that subcommand isn't supported on RHEL 9's older `kernel-install`.

---

## Notes

- No kickstart and no per-app configuration live here on purpose; per-app ISO details belong in each app's own `installer/` directory.
- `.buildconfig` sets `artifacts: false`, since this image must never try to build installable artifacts from itself, and `keep_version: true`.
- Built for both `linux/amd64` and `linux/arm64`.
- Kept as a separate image from `anaconda-rhel10-base` on purpose: Anaconda and dracut versions aren't guaranteed compatible across RHEL major versions, so the two installer environments are not shared.
- Rebuild this image only when Anaconda or the installer tooling itself needs to change; app teams building on top of it should not need to touch it.
