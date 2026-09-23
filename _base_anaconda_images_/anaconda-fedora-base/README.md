# anaconda-fedora-base

This is a **shared Anaconda installer environment for Fedora bootc payloads**, built on `quay.io/fedora/fedora-bootc:rawhide`. It is build infrastructure, not a deployable image: it is never installed on a device and never produces its own installable artifact.

---

## What it's for

When an app directory's `.buildconfig` requests `bootc-generic-iso` or `bootc-installer` as an `artifact_formats`, the main workflow needs an Anaconda-based installer environment to boot from. Rather than every app image building its own installer from scratch, they all share this one base:

1. This image is built once (see [`.buildconfig`](.buildconfig)) and published like any other image in the repository.
2. An app directory's own `installer/Containerfile` uses this image as its `FROM`, layering in only what differs per app: `installer/kickstart.ks` and `installer/iso.yaml`.
3. The result is used as the `--bootc-ref` (installer environment) passed to `image-builder`, paired with the app's own bootc image as `--bootc-installer-payload-ref`.

App directories select this base with `installer_base: anaconda-fedora-base` in their own `.buildconfig` (the repo-wide default is `anaconda-rhel10-base` unless overridden). See the [`installer_base`](../README.md#installer_base) section of the repository README for the full explanation.

---

## What's included

- `anaconda`, `anaconda-install-img-deps`, `anaconda-dracut`, `dracut-config-generic`, `dracut-network`, `net-tools`, `plymouth`, font packages (`default-fonts-core-sans`, `default-fonts-other-sans`, `google-noto-sans-cjk-fonts`), `fuse-overlayfs`, `xorrisofs`, `squashfs-tools`, plus the correct GRUB/shim and devname packages for the target architecture (`grub2-efi-x64-cdboot`/`grub2-pc-modules`/`shim-x64`/`biosdevname` on x86_64, `grub2-efi-aa64-cdboot`/`shim-aa64` on arm64).
- A `containers/storage.conf` set to the `overlay` driver with `fuse-overlayfs-snapshot` as the mount program.
- EFI boot files copied into `/boot/efi`.
- Anaconda wired up as the boot target instead of a normal login (an `install` user added, `default.target` → `anaconda.target`, `autovt@.service` → `anaconda-shell@.service`), with the initramfs rebuilt to include the `anaconda` dracut module.
- Pipewire allowed to run as root inside the installer environment (`ConditionUser=` overrides for `pipewire.service`/`pipewire.socket`).

---

## Notes

- No kickstart and no per-app configuration live here on purpose; per-app ISO details belong in each app's own `installer/` directory.
- `.buildconfig` sets `artifacts: false`, since this image must never try to build installable artifacts from itself, and `keep_version: true`.
- Built for both `linux/amd64` and `linux/arm64`.
- Tracks Fedora `rawhide`, so expect it to move faster and be less stable than the RHEL 9/10 installer bases.
- Rebuild this image only when Anaconda or the installer tooling itself needs to change; app teams building on top of it should not need to touch it.
