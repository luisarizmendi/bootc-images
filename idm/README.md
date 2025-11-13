# Image bootc-idm

This repository contains a **Bootc image** prepared to deploy an **Identity Management (IdM) server** easily and consistently across edge or lab environments.

---

## Features

This image includes:

- **IdM Installation Script**  
  Automates the setup of an **Identity Management (IdM)** server after boot, based on user-provided configuration variables.

---

## Extracting Installable Artifacts (ISO)

The GitHub Actions workflow creates two types of outputs:

1. **Bootc container image**: [ghcr.io/luisarizmendi/bootc-idm:{label}](https://github.com/luisarizmendi/bootc-images/pkgs/container/bootc-idm)
2. **Artifact container image**: [ghcr.io/luisarizmendi/bootc-idm-anaconda-iso:{label}](https://github.com/luisarizmendi/bootc-images/pkgs/container/bootc-idm-anaconda-iso)

To extract installable artifacts (ISOs, disk images, etc.) from the artifact container images:

```bash
# Example: Extract an anaconda-iso artifact
mkdir artifacts
podman create --name temp-container ghcr.io/luisarizmendi/bootc-idm-anaconda-iso:v1-amd64
podman cp temp-container:/ ./artifacts/

# The installable files will be in ./artifacts/
ls -la artifacts/bootiso/
```

---

## Device Requirements

- **Minimum:** 2 cores, 4 GB of memory and 20GB disk.

---

## Post-Boot Configuration

After the device boots, you must define the variables required for the IdM installation (install will be triggered automatically after some time):

1. **IdM Configuration Variables**  
   Set your IdM-specific parameters in:  

   ```text
   /etc/sysconfig/idm-server-install
  ```

---

## Notes

- Installable artifact (ISO) will create demo user in the device: admin/redhat.
- The IdM installation process may take several minutes.

  When the installation is complete, a marker file is created at:  

  ```text
  /var/lib/idm-server-install.done
  ```




