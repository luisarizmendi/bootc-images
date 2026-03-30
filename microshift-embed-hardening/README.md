# microshift bootc image

This image includes Microshift and it contains several custom scripts to show a management worflow example.

---

## Features

This image includes:

- **Flightctl agent** - Enables management of the device through **Red Hat Edge Manager**.

- **MicroShift** - Fully integrated with dynamic configuration.

- **Dynamic File Retrieval** - The `get-files.sh` script (located in `/usr/local/bin`) downloads files from HTTP sources or container registries, with configuration managed via `/etc/get-files.yaml`.

- **First Boot Automation** - The `first-boot.sh` script (in `/usr/local/bin`) runs on initial device boot and performs:
  - Hostname configuration based on MAC address using `set-hostname-from-mac.sh`
  - MicroShift configuration with device-specific settings (IP) via `create-microshift-dynamic-conf.sh`
  - File downloads using `get-files.sh`

- **Hook-Based File Monitoring** - The `hook-files.sh` script (in `/usr/local/bin`) monitors files and directories, triggering actions configured in `/usr/lib/flightctl/hooks.d/afterupdating`. Uses the same configuration files as the flightctl-agent, ensuring compatibility with Red Hat Edge Manager. The script automatically disables itself once the device is enrolled to avoid conflicts with Red Hat Edge Manager's native hook feature.

---

## Extracting Installable Artifacts (ISO)

The GitHub Actions workflow creates two types of outputs:

1. **Bootc container image**: [ghcr.io/luisarizmendi/bootc-microshift-kvm:{label}](https://github.com/luisarizmendi/bootc-images/pkgs/container/bootc-microshift-kvm)
2. **Artifact container image**: [ghcr.io/luisarizmendi/bootc-microshift-kvm-anaconda-iso:{label}](https://github.com/luisarizmendi/bootc-images/pkgs/container/bootc-microshift-kvm-anaconda-iso)

To extract installable artifacts (ISOs, disk images, etc.) from the artifact container images:

```bash
# Example: Extract an anaconda-iso artifact
mkdir artifacts
podman create --name temp-container ghcr.io/luisarizmendi/bootc-microshift-kvm-anaconda-iso:v1-amd64
podman cp temp-container:/ ./artifacts/

# The installable files will be in ./artifacts/
ls -la artifacts/bootiso/
```

---

## Device Requirements

- Resources will depend on the applications that you want to run, but you can start with 2 cores and 3 GB of memory and 50GB disk
- Network connectivity for downloading VM disks and container images

---

## Pre-Build Configuration

### 1. Red Hat Edge Manager Config

You should include your specific Red Hat Edge Manager config file under `/etc/flightctl/config.yaml` before building your image to enable fully automated onboarding.:

```bash
flightctl login --username=<your_user> --password=<your_password> --insecure-skip-tls-verify https://<rhem_api_server_url>

flightctl certificate request --signer=enrollment --expiration=365d --output=embedded > config.yaml
```


If you don't want to rebuild the image, you can change the built-in file with one containing your values after installing the device as a post-boot action. This will automatically trigger the flightctl-agent restart thanks to the hook-files.sh monitoring script.

---

## Post-Boot Configuration

After the device boots, you can customize the following components:

### MicroShift

Place your OpenShift pull secret at:

```text
/etc/crio/openshift-pull-secret
```

The MicroShift systemd unit will be automatically restarted by the `hook-files.sh` script when this file is updated.

### Flightctl / Red Hat Edge Manager

The image includes an embedded configuration for zero-touch provisioning with enrollment. You can modify this configuration after installation, and the `hook-files.sh` script will automatically restart the flightctl-agent to apply the changes.


