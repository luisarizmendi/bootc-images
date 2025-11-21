# Image  bootc-microshift-luks-tpm

This repository contains a **Bootc image** designed for secure and automated edge deployments with Red Hat Edge Manager. The image includes several pre-configured components and scripts to simplify device onboarding, network configuration, and management.

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

- **Disk Encryption**  
  The root disk is encrypted with **LUKS**, and encryption keys are securely stored in the **TPM**.  

  **IMPORTANT: Requires a TPM** on the device.

- **IDM Integration & Network Setup**  
  A script is provided to:
  - Join the device to an **IDM (Identity Management) domain**.
  - Configure **802.1X authentication** for the network.
  - Prepare the device to use **Certmonger** for automatic renewal of 802.1X certificates.


---

## Extracting Installable Artifacts (ISO)

The GitHub Actions workflow creates two types of outputs:

1. **Bootc container image**: [ghcr.io/luisarizmendi/bootc-microshift-luks-tpm:{label}](https://github.com/luisarizmendi/bootc-images/pkgs/container/bootc-microshift-luks-tpm)
2. **Artifact container image**: [ghcr.io/luisarizmendi/bootc-microshift-luks-tpm-anaconda-iso:{label}](https://github.com/luisarizmendi/bootc-images/pkgs/container/bootc-microshift-luks-tpm-anaconda-iso)

To extract installable artifacts (ISOs, disk images, etc.) from the artifact container images:

```bash
# Example: Extract an anaconda-iso artifact
mkdir artifacts
podman create --name temp-container ghcr.io/luisarizmendi/bootc-microshift-luks-tpm-anaconda-iso:v1-amd64
podman cp temp-container:/ ./artifacts/

# The installable files will be in ./artifacts/
ls -la artifacts/bootiso/
```


---

## Device requirements

- At least 2 cores and 2 GB of memory and 20GB disk, best 4 cores, 4 GB of memory and 50GB disk.
- Requires a TPM on the device.

---

## Pre-Build Configuration

### 1. Red Hat Edge Manager Config

You should include your specific Red Hat Edge Manager config file under `/etc/flightctl/config.yaml` before building your image to enable fully automated onboarding. 

If you don't want to rebuild the image, you can change the built-in file with one containing your values after installing the device as a post-boot action. This will automatically trigger the flightctl-agent restart thanks to the hook-files.sh monitoring script.



### 2. IDM CA Certificate
   Add your IDM CA certificate to the trusted store:  
   ```text
   /etc/pki/ca-trust/source/anchors/ca.crt
   ```

   You can also do it as a post-boot step since the `/etc/pki/ca-trust/source/anchors/ca.crt` file is being monitored by the `file-monitor` systemd unit.


---

## Post-Boot Configuration

After the device boots, you can customize the following components:

### MicroShift

Place your OpenShift pull secret at:

```text
/etc/crio/openshift-pull-secret
```

The MicroShift systemd unit will be automatically restarted by the `hook-files.sh` script when this file is updated.


### DNS Configuration 

If your demo environment does not have a DNS entry for the IDM, update `/etc/hosts` to resolve the IDM server.

### IDM Variables for 802.1X

Configure your IDM-specific variables in: 

```text
/etc/sysconfig/setup-8021x-cert
```

### Flightctl / Red Hat Edge Manager

The image includes an embedded configuration for zero-touch provisioning with enrollment. You can modify this configuration after installation, and the `hook-files.sh` script will automatically restart the flightctl-agent to apply the changes.


> These steps can be completed **manually** or via **Red Hat Edge Manager**.

---

## Notes

- TPM is mandatory for LUKS key storage.
- Monitoring actions will only be triggered after the initial post-boot configuration is completed.
- The system is designed for edge/demo environments and integrates tightly with Red Hat tools.
- Installable artifact (ISO) will create demo user in the device: admin/redhat.