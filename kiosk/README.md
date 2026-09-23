# kiosk bootc image

This image turns a device into a **GNOME kiosk** running RHEL bootc: it boots straight into a full-screen browser session showing a single web app, with no desktop or login prompt visible to the end user.

---

## Features

This image includes:

- **GNOME Kiosk session** - `gnome-kiosk`, `gdm` and `gnome-kiosk-script-session` are installed, and GDM is set to auto-login as the `kiosk` user straight into the kiosk session (`/etc/gdm/custom.conf`). Screen lock, idle delay and the screensaver are disabled so the display stays on.

- **Firefox in kiosk mode** - The `gnome-kiosk-script` (`/var/home/kiosk/.local/bin/gnome-kiosk-script`) waits until the target URL responds, then launches Firefox with `--kiosk` so it fills the screen with no browser chrome. The default script points at a demo HTML5 page; edit this file (or replace it via `get-files.sh`, see below) to point at your own application.

- **Flightctl agent** - Enables management of the device through **Red Hat Edge Manager**.

- **Dynamic File Retrieval** - The `get-files.sh` script (located in `/usr/local/bin`) downloads files from HTTP sources or container registries, with configuration managed via `/etc/get-files/config.yaml`.

- **First Boot Automation** - The `first-boot.sh` script (in `/usr/local/bin`) runs on initial device boot and performs:
  - Hostname configuration based on MAC address using `set-hostname-from-mac.sh`
  - File downloads using `get-files.sh`
  - Optional SELinux module install for Cockpit if `/tmp/my-cockpit.te` is present

- **Hook-Based File Monitoring** - The `hook-files.sh` script (in `/usr/local/bin`) monitors files and directories, triggering actions configured in `/usr/lib/flightctl/hooks.d/afterupdating`. Uses the same configuration files as the flightctl-agent, ensuring compatibility with Red Hat Edge Manager. Restarting GDM (to pick up a new kiosk script or config) and restarting the flightctl-agent (to pick up a new config) are both wired up this way. The script automatically disables itself once the device is enrolled to avoid conflicts with Red Hat Edge Manager's native hook feature.

---

## Extracting Installable Artifacts (ISO)

The GitHub Actions workflow creates two types of outputs:

1. **Bootc container image**: [ghcr.io/luisarizmendi/bootc-kiosk:{label}](https://github.com/luisarizmendi/bootc-images/pkgs/container/bootc-kiosk)
2. **Artifact container image**: [ghcr.io/luisarizmendi/bootc-kiosk-bootc-generic-iso:{label}](https://github.com/luisarizmendi/bootc-images/pkgs/container/bootc-kiosk-bootc-generic-iso)

To extract installable artifacts (ISOs, disk images, etc.) from the artifact container images:

```bash
# Example: Extract a bootc-generic-iso artifact
mkdir artifacts
podman create --name temp-container ghcr.io/luisarizmendi/bootc-kiosk-bootc-generic-iso:v1-amd64
podman cp temp-container:/ ./artifacts/

# The installable files will be in ./artifacts/
ls -la artifacts/bootiso/
```

---

## Device Requirements

- 2 cores, 2 GB of memory and 20GB disk is enough.

---

## Pre-Build Configuration

### 1. Red Hat Edge Manager Config

You should include your specific Red Hat Edge Manager config file under `/etc/flightctl/config.yaml` before building your image to enable fully automated onboarding:

```bash
flightctl login --username=<your_user> --password=<your_password> --insecure-skip-tls-verify https://<rhem_api_server_url>

flightctl certificate request --signer=enrollment --expiration=365d --output=embedded > config.yaml
```

If you don't want to rebuild the image, you can change the built-in file with one containing your values after installing the device as a post-boot action. This will automatically trigger the flightctl-agent restart thanks to the hook-files.sh monitoring script.

---

## Post-Boot Configuration

After the device boots, you can customize the following components:

### Kiosk application

Edit `/var/home/kiosk/.local/bin/gnome-kiosk-script` to change the URL that Firefox opens in kiosk mode. The `hook-files.sh` script will automatically restart GDM (and therefore the kiosk session) when this file changes.

### Flightctl / Red Hat Edge Manager

The image includes an embedded configuration for zero-touch provisioning with enrollment. You can modify this configuration after installation, and the `hook-files.sh` script will automatically restart the flightctl-agent to apply the changes.

---

## Notes

- Installable artifact (ISO) will create demo user in the device: admin/redhat.
- The `kiosk` user is auto-logged in on every boot; there is no login screen in normal operation.
