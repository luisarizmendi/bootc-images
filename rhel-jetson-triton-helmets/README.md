# rhel-jetson-triton-helmets bootc image

This image builds on [`rhel-jetson`](../rhel-jetson) to run a **helmet/PPE compliance detection** application on an NVIDIA Jetson device, using the **NVIDIA Triton Inference Server** for GPU inference instead of a standalone TensorRT process. It watches a camera feed and flags people who are not wearing a helmet.

---

## Features

This image includes:

- **Triton Inference Server** - `triton-inference-gpu.container` (Quadlet) runs `nvcr.io/nvidia/tritonserver:25.03-py3-igpu`, serving models from `/etc/models` (mounted from the model volume copied in at build time) on ports `8000`/`8001`, with `AddDevice=nvidia.com/gpu=all` for GPU access.

- **Helmet detection model** - Pulled at build time from `quay.io/luisarizmendi/modelcar-hardhat` and copied into `/etc/models` for Triton to load.

- **Webcam stream manager** - `hardhat-webcam.container` reads the USB camera, sends frames to Triton via gRPC (`TRITON_SERVER_URL=localhost:8001`) for the `hardhat` model, and classifies detections as `helmet`, `no_helmet` or `hat`.

- **Alerting service** - `hardhat-action.container` polls the current detections and alert endpoints and raises alerts when non-compliant PPE is detected.

- **Web dashboard** - `hardhat-dashboard-backend.container` and `hardhat-dashboard-frontend.container` expose a backend API and a frontend UI so detections and alerts can be viewed from a browser.

- **Hostname from MAC address** - `mac-hostname.service` runs `set-hostname-from-mac.sh` at boot, pinned to the `enP8p1s0` interface.

- **Wi-Fi and Ethernet NetworkManager profiles** - Pre-provisioned connection profiles under `/etc/NetworkManager/system-connections`; the Wi-Fi SSID and password are injected at build time from the `WIFI_SSID` and `WIFI_PASSWORD` build secrets.

All application containers are defined as Podman Quadlets under `/etc/containers/systemd` and run with `Network=host`, so they come up automatically as systemd services on boot.

---

## Extracting Installable Artifacts (ISO)

The GitHub Actions workflow creates two types of outputs:

1. **Bootc container image**: [ghcr.io/luisarizmendi/bootc-rhel-jetson-triton-helmets:{label}](https://github.com/luisarizmendi/bootc-images/pkgs/container/bootc-rhel-jetson-triton-helmets)
2. **Artifact container image**: [ghcr.io/luisarizmendi/bootc-rhel-jetson-triton-helmets-bootc-generic-iso:{label}](https://github.com/luisarizmendi/bootc-images/pkgs/container/bootc-rhel-jetson-triton-helmets-bootc-generic-iso)

To extract installable artifacts (ISOs, disk images, etc.) from the artifact container images:

```bash
# Example: Extract a bootc-generic-iso artifact
mkdir artifacts
podman create --name temp-container ghcr.io/luisarizmendi/bootc-rhel-jetson-triton-helmets-bootc-generic-iso:v1-arm64
podman cp temp-container:/ ./artifacts/

# The installable files will be in ./artifacts/
ls -la artifacts/bootiso/
```

---

## Device Requirements

- Built and tested for **NVIDIA Jetson Orin Nano** class hardware, `arm64` only, with a USB camera attached.
- Running Triton alongside the webcam, dashboard and action services is heavier than the plain [`rhel-jetson-object-detection`](../rhel-jetson-object-detection) image; give the device as much memory as your Jetson module allows (8 GB modules are recommended).

---

## Pre-Build Configuration

### Wi-Fi credentials

Supply the `WIFI_SSID` and `WIFI_PASSWORD` build-time secrets so they can be baked into `/etc/NetworkManager/system-connections/wifi.nmconnection`. See the repository-level README for how to wire up build secrets.

---

## Notes

- The application images (`object-detection-action`, `object-detection-dashboard-backend`, `object-detection-dashboard-frontend`, `object-detection-stream-manager`) are pulled from `quay.io/luisarizmendi` at runtime and set to `AutoUpdate=registry`, so they update automatically when a new `prod`/`grpc` tag is published.
- Installable artifact (ISO) will create demo user in the device: admin/redhat.
