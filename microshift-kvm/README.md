# microshift-kvm bootc image

This image includes Microshift and libvirt to run virtual machines and it contains several custom scripts to show a management worflow example.

---

## Features

This image includes:

- **Flightctl agent** - Enables management of the device through **Red Hat Edge Manager**.

- **MicroShift** - Fully integrated with dynamic configuration.

- **VM Management with Libvirt** - Pre-configured libvirt environment with `qemu:///system` as the default URI for managing virtual machines.

- **Systemd VM Template** - Includes `libvirt-vm@.service` template unit for managing VM lifecycle. This template monitors VM status and automatically restarts VMs if they are powered off outside of systemd control (e.g., not via `systemctl stop`).

- **Embedded Fedora VM** - A small Fedora VM is pre-embedded in the image. The VM disk is downloaded on first boot using the `get-files.sh` script, and a corresponding systemd unit is automatically created.

- **Dynamic File Retrieval** - The `get-files.sh` script (located in `/usr/local/bin`) downloads files from HTTP sources or container registries, with configuration managed via `/etc/get-files.yaml`.

- **First Boot Automation** - The `first-boot.sh` script (in `/usr/local/bin`) runs on initial device boot and performs:
  - Hostname configuration based on MAC address using `set-hostname-from-mac.sh`
  - MicroShift configuration with device-specific settings (IP) via `create-microshift-dynamic-conf.sh`
  - File downloads using `get-files.sh`
  - Libvirt and associated systemd unit configuration for VMs

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

- Resources will depend on the VMs that you want to run. The embedded Fedora VM has 2 cores and 2 GB of memory so a safe minimum (without additional VMs) will be 4 cores and 4 GB of memory and 50GB disk
- Network connectivity for downloading VM disks and container images

---

## Pre-Build Configuration

### 1. Red Hat Edge Manager Config

You should include your specific Red Hat Edge Manager config file under `/etc/flightctl/config.yaml` before building your image to enable fully automated onboarding. 

If you don't want to rebuild the image, you can change the built-in file with one containing your values after installing the device as a post-boot action. This will automatically trigger the flightctl-agent restart thanks to the hook-files.sh monitoring script.

---

## Post-Boot Configuration

After the device boots, you can customize the following components:

### VMs

Using the `hook-files.sh` monitoring capability, you can configure any VM by placing VM definitions in `/etc/libvirt/qemu`. If you remove a VM definition file the VM will be removed from the system (it takes some time to complete after the file removal). 

**NOTE:** The embedded VM takes some time to be created on the first boot since the disk file must be downloaded.

VMs can use [cloud-init scripts but those must be contained in ISOs](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/configuring_and_managing_cloud-init_for_rhel/creating-a-virtual-machine-with-cloud-init). In order to simplify the process the `hook-files.sh` will create the iso with the cloud-init files automatically when you place them in `/etc/libvirt/cloud-init/files/<name>`. The embedded VM is using the cloud-init files that you find in `/etc/libvirt/cloud-init/files/test-vm` (password is `redhat`).

**Important**: Remember to download the VM disk files as well. You can automate this by adding appropriate configuration entries in `/etc/get-files.yaml` to use the `get-files.sh` script automatically.

### MicroShift

Place your OpenShift pull secret at:

```text
/etc/crio/openshift-pull-secret
```

The MicroShift systemd unit will be automatically restarted by the `hook-files.sh` script when this file is updated.

### Flightctl / Red Hat Edge Manager

The image includes an embedded configuration for zero-touch provisioning with enrollment. You can modify this configuration after installation, and the `hook-files.sh` script will automatically restart the flightctl-agent to apply the changes.


