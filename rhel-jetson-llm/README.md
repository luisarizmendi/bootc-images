# rhel-jetson bootc image

This is a **base RHEL bootc image for NVIDIA Jetson (Tegra) devices**, prepared for GPU-accelerated workloads through NVIDIA's Container Device Interface (CDI). It ships no application by default; it exists as the common `FROM` base for the Jetson application images in this repository (for example [`rhel-jetson-object-detection`](../rhel-jetson-object-detection) and [`rhel-jetson-triton-helmets`](../rhel-jetson-triton-helmets)), and can also be used directly as a plain Jetson bootc image.

---

## Features

This image includes:

- **NVIDIA Jetpack components** - Installed from `quay.io/luisarizmendi/rhel-nvidia-jetson-rpms`, matched to the pinned RHEL bootc base tag.

- **NVIDIA Container Toolkit + CDI** - `nvidia-container-toolkit` and `netavark` are installed, and a `nvidia-cdi.service` systemd unit regenerates `/etc/cdi/nvidia.yaml` at boot so containers can request the GPU with `AddDevice=nvidia.com/gpu=all`.

- **Jetson boot tuning** - `nvfancontrol`, `nvpmodel` and `nvpower` services are masked (they can cause a kernel panic on this platform), the conflicting upstream `host1x` kernel module is removed, the initrd is regenerated, the correct serial console (`ttyTCU0`) is set via kernel arguments, and the `bootc-generic-growpart` service is patched to grow the root partition even though it runs on bare metal (not a VM).

- **i2c-dev kernel module** - Loaded at boot, required by tools such as `jetson_stats`.

---

## Extracting Installable Artifacts (ISO)

The GitHub Actions workflow creates two types of outputs:

1. **Bootc container image**: [ghcr.io/luisarizmendi/bootc-rhel-jetson:{label}](https://github.com/luisarizmendi/bootc-images/pkgs/container/bootc-rhel-jetson)
2. **Artifact container image**: [ghcr.io/luisarizmendi/bootc-rhel-jetson-bootc-generic-iso:{label}](https://github.com/luisarizmendi/bootc-images/pkgs/container/bootc-rhel-jetson-bootc-generic-iso)

To extract installable artifacts (ISOs, disk images, etc.) from the artifact container images:

```bash
# Example: Extract a bootc-generic-iso artifact
mkdir artifacts
podman create --name temp-container ghcr.io/luisarizmendi/bootc-rhel-jetson-bootc-generic-iso:v1-arm64
podman cp temp-container:/ ./artifacts/

# The installable files will be in ./artifacts/
ls -la artifacts/bootiso/
```

---

## Device Requirements

- Built and tested for **NVIDIA Jetson Orin Nano** class hardware, `arm64` only.
- The exact RHEL bootc base tag in the Containerfile must match a version the NVIDIA Jetpack RPMs are published for; check `quay.io/luisarizmendi/rhel-nvidia-jetson-rpms` before changing the pinned tag.

---

## Notes

- This image has no `files/` directory and applies no user-facing customization on its own; it is meant to be extended with `FROM ghcr.io/luisarizmendi/bootc-rhel-jetson:latest` by an application-specific image.
- Installable artifact (ISO) will create demo user in the device: admin/redhat.
