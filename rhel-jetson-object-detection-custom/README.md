# rhel-jetson-object-detection bootc image

This image embeds the following application embedded that us running as rootless containers using quadlets:

https://github.com/luisarizmendi/object-detection-custom

It is prepared to be used in a Jetson Orin Nano.


---

## Extracting Installable Artifacts (ISO)

The GitHub Actions workflow creates two types of outputs:

1. **Bootc container image**: [ghcr.io/luisarizmendi/bootc-rhel-jetson-object-detection:{label}](https://github.com/luisarizmendi/bootc-images/pkgs/container/bootc-rhel-jetson-object-detection)
2. **Artifact container image**: [ghcr.io/luisarizmendi/bootc-rhel-jetson-object-detection-anaconda-iso:{label}](https://github.com/luisarizmendi/bootc-images/pkgs/container/bootc-rhel-jetson-object-detection-anaconda-iso)

To extract installable artifacts (ISOs, disk images, etc.) from the artifact container images:

```bash
# Example: Extract an anaconda-iso artifact
mkdir artifacts
podman create --name temp-container ghcr.io/luisarizmendi/bootc-rhel-jetson-object-detection-anaconda-iso:v1-arm64
podman cp temp-container:/ ./artifacts/

# The installable files will be in ./artifacts/
ls -la artifacts/bootiso/
```


---

## Startup and Initialization Times

The application may take a few minutes to start on the first boot, as the embedded images need to be initialized for the user. On an NVIDIA Jetson Orin Nano with 8 GB of memory (zero-touch provisioning, i.e., not pressing `Enter` in the GRUB menu):
  - **System installation**: ~11 minutes from power-on (up to the second time the fan spins up).
  - **Image availability**: ~1.5 additional minutes for the image to appear on port 8080.
  - **Inference service readiness**: ~1 more minute for the inference service to become available.

After installation and the first boot:
  - **Device boot time**: ~15 seconds.
  - **Application startup time and Inference service readiness**: ~30 seconds after boot.


> NOTE: Depending on your USB Camera, sometimes the camera initalization could fail. Application will show the embedded video until the camera is ready.

---

## Important Note

If inference is not working, first try removing the `model.engine` file under `/home/detector/models/` and restart the inference container. This will generate a new file for your hardware (it may take some time—check the container logs).