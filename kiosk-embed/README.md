# kiosk-embed bootc image

This image is the same **GNOME kiosk** setup as the [`kiosk`](../kiosk) image, but with its application container image **embedded directly in the bootc image** instead of being pulled from a registry at runtime. This lets the device run fully offline from first boot, with no network dependency to start the kiosk app.

---

## Features

This image includes:

- **GNOME Kiosk session** - `gnome-kiosk`, `gdm` and `gnome-kiosk-script-session` are installed, and GDM is set to auto-login as the `kiosk` user straight into the kiosk session (`/etc/gdm/custom.conf`). Screen lock, idle delay and the screensaver are disabled so the display stays on.

- **Embedded application container** - The app container image (a demo point-of-sale app, `quay.io/luisarizmendi/tailwind-pos:latest`) is pulled and saved into `/usr/lib/containers/storage` at **build time**, together with a manifest of image-to-directory mappings (`image-list.txt`). No registry access is needed on the device to get the app image.

- **First-boot image copy** - The `copy-embedded-images.service` unit runs once, early in boot (`Before=multi-user.target`), and copies each embedded image from that build-time directory into the live `containers-storage` so Podman can run it. The service then disables itself so it never runs again. **This copy step is what drives the higher memory requirement below.**

- **Embedded app as a Quadlet** - `pos.container` (in `/usr/share/containers/systemd`) defines the app as a systemd-managed Podman container, publishing it on port `8080`, and it `Requires=copy-embedded-images.service` so it only starts once the image is available locally.

- **Firefox in kiosk mode** - The `gnome-kiosk-script` waits until `http://localhost:8080` responds, then launches Firefox with `--kiosk` pointed at the local app, filling the screen with no browser chrome.

- **Flightctl agent** - Enables management of the device through **Red Hat Edge Manager**.

- **Dynamic File Retrieval** - The `get-files.sh` script (located in `/usr/local/bin`) downloads files from HTTP sources or container registries, with configuration managed via `/etc/get-files/config.yaml`.

- **First Boot Automation** - The `first-boot.sh` script (in `/usr/local/bin`) runs on initial device boot and performs:
  - Hostname configuration based on MAC address using `set-hostname-from-mac.sh`
  - File downloads using `get-files.sh`
  - Optional SELinux module install for Cockpit if `/tmp/my-cockpit.te` is present

- **Hook-Based File Monitoring** - The `hook-files.sh` script (in `/usr/local/bin`) monitors files and directories, triggering actions configured in `/usr/lib/flightctl/hooks.d/afterupdating`. Uses the same configuration files as the flightctl-agent, ensuring compatibility with Red Hat Edge Manager. The script automatically disables itself once the device is enrolled to avoid conflicts with Red Hat Edge Manager's native hook feature.

---

## Extracting Installable Artifacts (ISO)

The GitHub Actions workflow creates two types of outputs:

1. **Bootc container image**: [ghcr.io/luisarizmendi/bootc-kiosk-embed:{label}](https://github.com/luisarizmendi/bootc-images/pkgs/container/bootc-kiosk-embed)
2. **Artifact container image**: [ghcr.io/luisarizmendi/bootc-kiosk-embed-bootc-generic-iso:{label}](https://github.com/luisarizmendi/bootc-images/pkgs/container/bootc-kiosk-embed-bootc-generic-iso)

To extract installable artifacts (ISOs, disk images, etc.) from the artifact container images:

```bash
# Example: Extract a bootc-generic-iso artifact
mkdir artifacts
podman create --name temp-container ghcr.io/luisarizmendi/bootc-kiosk-embed-bootc-generic-iso:v1-amd64
podman cp temp-container:/ ./artifacts/

# The installable files will be in ./artifacts/
ls -la artifacts/bootiso/
```

---

## Device Requirements

- **8 GB of memory.** Unlike the plain `kiosk` image, `copy-embedded-images.service` copies the embedded application image into container storage in memory on first boot, which needs noticeably more RAM than the base kiosk workload.
- 2 cores and 20GB disk is enough otherwise.

---

## Pre-Build Configuration

### 1. Red Hat Edge Manager Config

You should include your specific Red Hat Edge Manager config file under `/etc/flightctl/config.yaml` before building your image to enable fully automated onboarding:

```bash
flightctl login --username=<your_user> --password=<your_password> --insecure-skip-tls-verify https://<rhem_api_server_url>

flightctl certificate request --signer=enrollment --expiration=365d --output=embedded > config.yaml
```

If you don't want to rebuild the image, you can change the built-in file with one containing your values after installing the device as a post-boot action. This will automatically trigger the flightctl-agent restart thanks to the hook-files.sh monitoring script.

### 2. Embedded application image

To embed a different application, change the `IMAGES` build argument in the Containerfile (a space-separated list of image references) before building. Each listed image is pulled and stored under `/usr/lib/containers/storage` at build time, ready to be copied into place on first boot.

---

## Post-Boot Configuration

After the device boots, you can customize the following components:

### Flightctl / Red Hat Edge Manager

The image includes an embedded configuration for zero-touch provisioning with enrollment. You can modify this configuration after installation, and the `hook-files.sh` script will automatically restart the flightctl-agent to apply the changes.

---

## Notes

- Installable artifact (ISO) will create demo user in the device: admin/redhat.
- The embedded app only becomes reachable on `localhost:8080` after `copy-embedded-images.service` finishes on first boot; the kiosk script waits for it automatically.
- The `kiosk` user is auto-logged in on every boot; there is no login screen in normal operation.
