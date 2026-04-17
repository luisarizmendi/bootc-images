# rhel-jetson-object-detection bootc ima

This image embeds the following application:

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
