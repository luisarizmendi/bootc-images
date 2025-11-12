# Image bootc-idm

This repository contains a **Bootc image** prepared to deploy an **Identity Management (IdM) server** easily and consistently across edge or lab environments.

---

## Features

This image includes:

- **IdM Installation Script**  
  Automates the setup of an **Identity Management (IdM)** server after boot, based on user-provided configuration variables.

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



---

## Notes

- **The IdM installation process may take several minutes.**  

  When the installation is complete, a marker file is created at:  

  ```text
  /var/lib/idm-server-install.done
  ```
