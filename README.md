# Bootc Images

This directory contains bootc images and a GitHub Actions workflow (`.github/workflows/build.yml`) that builds **bootc images** for multiple platforms and creates **installable artifacts** (ISOs, disk images, etc.). It is based on [this one](https://github.com/redhat-cop/redhat-image-mode-actions/blob/main/.github/workflows/build_rhel_bootc.yml)

The images and artifacts are pushed to the **GitHub Container Registry (GHCR)** by default, but can be configured to push to any container registry.

This workflow uses a **subscribed UBI container** approach, which eliminates the need to handle Red Hat subscriptions within your Containerfile. The subscription is managed at the workflow level, making your Containerfile cleaner and more secure.

Store your images in designated folders within the repository's root directory. The workflow will automatically rebuild images whenever changes are detected in those folders.



---

## How the Workflow Works

1. **Setup**
   - Reads input parameters or defaults
   - Detects changed directories with Containerfiles
   - Generates build matrices for images and artifacts
   - Checks existing artifacts to avoid redundant builds

2. **Build Images**
   - Runs in a subscribed UBI9 container with container tools installed
   - Registers with Red Hat using credentials or activation keys
   - Uses `buildah` to build multi-platform bootc images
   - Creates semantic version tags (v1, v2, v3, etc.)
   - Automatically unregisters subscription when complete

3. **Build Artifacts** (Optional)
   - Uses `bootc-image-builder` to create installable artifacts
   - Supports custom artifact configuration via optional `config.toml` files
   - Packages artifacts into container images for easy distribution
   - Supports multiple formats and platforms simultaneously

4. **Multi-Platform Manifest**
   - Creates unified multi-arch container image manifests
   - Supports both x86_64 and ARM64 architectures

5. **Push**
   - Pushes container images and artifact images to the configured registry


---

## Configuration Summary

### Required Secrets (Minimum Setup)
Choose one authentication method:

**Username/Password:**
- `RH_USERNAME`: Your Red Hat username
- `RH_PASSWORD`: Your Red Hat password

**OR Organization/Activation Key:**
- `RHT_ORGID`: Your Red Hat organization ID  
- `RHT_ACT_KEY`: Your Red Hat activation key

### Optional Configuration

**Repository Variables:**
- `DEST_REGISTRY_HOST`: Destination registry (default: `ghcr.io`)
- `DEST_REGISTRY_USER`: Registry username (default: repository owner)

**Repository Secrets:**
- `DEST_REGISTRY_PASSWORD`: Registry password (default: GitHub token)
- `SOURCE_REGISTRY_USER`: Source registry username override
- `SOURCE_REGISTRY_PASSWORD`: Source registry password override

**Optional Parameters:**
- `BASE_PATH`: Path where the image definitions are located in the repo (defaults to "/")
- `IMAGE_PREFIX`: Prefix that will be included in the container image names (defaults to "bootc")

---

## Repository Setup

If you want to create your own GitHub repository for building bootc images follow this steps:

### 1. Create your GitHub repo

Once it is created place the `.github/workflows/build.yml` at the root of your repository:

```
.github/workflows/build.yml
```

If it's placed elsewhere, GitHub Actions will **not** detect it.

Then create directories at the root level with your different images. Example directory structure:

**Note:** More information about the `.buildconfig ` in a section below.

```
my-arm64-only-image/
├── Containerfile
├── config.toml           
├── .buildconfig          
└── other-files...

my-image-with-artifacts/
├── Containerfile
├── .buildconfig          

my-minimal-image/
├── Containerfile         
└── other-files...
```

Alternatively you can also fork this repository and remove the directories with the images.

### 2. Enable Required Workflow Permissions

To allow the workflow to read repository contents and push packages:

1. Go to **Repository Settings** → **Actions** → **General**.
2. Scroll to **Workflow permissions**.
3. Select:
   - ✅ **Read repository contents and packages permissions**
4. Click **Save**.

### 3. Configure Red Hat Credentials

The workflow supports two authentication methods with Red Hat:

#### Option 1: Username/Password (Default)
1. Go to **Repository Settings** → **Secrets and variables** → **Actions**.
2. Add the following **Repository secrets**:
   - `RH_USERNAME`: Your Red Hat username
   - `RH_PASSWORD`: Your Red Hat password

#### Option 2: Organization ID/Activation Key (Optional)
If you prefer to use activation keys:
1. Add these **Repository secrets** instead:
   - `RHT_ORGID`: Your Red Hat organization ID
   - `RHT_ACT_KEY`: Your Red Hat activation key

The workflow will automatically detect which method to use based on available secrets.

### 4. (Optional) Configure Custom Registry Settings

By default, images are pushed to GitHub Container Registry (GHCR). To use a different registry:

1. Go to **Repository Settings** → **Secrets and variables** → **Actions**.
2. Under **Variables**, add any of:
   - `DEST_REGISTRY_HOST`: Custom registry hostname (default: `ghcr.io`)
   - `DEST_REGISTRY_USER`: Custom registry username (default: `github.repository_owner`)
3. Under **Secrets**, add:
   - `DEST_REGISTRY_PASSWORD`: Custom registry password (default: `GITHUB_TOKEN`)

### 5. (Optional) Override Source Registry Credentials

If you need different credentials for pulling from registry.redhat.io:

1. Add these **Repository secrets**:
   - `SOURCE_REGISTRY_USER`: Registry username (defaults to `RH_USERNAME`)
   - `SOURCE_REGISTRY_PASSWORD`: Registry password (defaults to `RH_PASSWORD`)


### 6. (Optional) Override other paremeters

1. Go to **Repository Settings** → **Secrets and variables** → **Actions**.
2. Under **Variables**, add any of these that you want to override:
   - `BASE_PATH`: Path where the image definitions are located in the repo (defaults to "/")
   - `IMAGE_PREFIX`: Prefix that will be included in the container image names (defaults to "bootc")

---

## Finding Your Images and Artifacts

Built images and artifacts are available in your repository's **Packages** section:

```
https://github.com/{username}/{repository}/pkgs/container/{image-name}
```

### Image Naming Convention

- **Bootc Images**: `ghcr.io/{owner}/bootc-{directory}:latest`
- **Artifact Images**: `ghcr.io/{owner}/bootc-{directory}-{format}:latest`
- **Version Tags**: All images also have `vN` tags (v1, v2, v3, etc.)

### Example Package Names

If your directory is named `myimage`:
- Bootc image: `ghcr.io/myorg/bootc-myimage:latest`
- ISO artifact: `ghcr.io/myorg/bootc-myimage-anaconda-iso:latest`
- QCOW2 artifact: `ghcr.io/myorg/bootc-myimage-qcow2:latest`


### Available Artifact Formats

The workflow can create the following installable formats:
- `anaconda-iso` - Anaconda installer ISO
- `qcow2` - QEMU disk image
- `vmdk` - VMware disk image  
- `raw` - Raw disk image
- `ami` - Amazon Machine Image
- `vhd` - Hyper-V disk image
- `gce` - Google Compute Engine image

---

### Extracting Installable Artifacts

The workflow creates two types of outputs:

1. **Bootc container images**: `ghcr.io/{owner}/bootc-{directory}:latest`
2. **Artifact container images**: `ghcr.io/{owner}/bootc-{directory}-{format}:{label}` (when artifacts are built)

Note: Check in the **Packages** section in the repo the available images.

To extract installable artifacts (ISOs, disk images, etc.) from the artifact container images:

```bash
# Example: Extract an anaconda-iso artifact
mkdir artifacts
podman create --name temp-container ghcr.io/{owner}/bootc-{directory}-{format}:{label}
podman cp temp-container:/ ./artifacts/
podman rm temp-container
podman rmi ghcr.io/{owner}/bootc-{directory}-{format}:{label}

# The installable files will be in ./artifacts/
ls -la artifacts/
```



---

## Architecture and Artifact Configuration

### .buildconfig File Options

You can control build behavior by adding a `.buildconfig` file to any image directory:

```yaml
# Restrict platforms (default: linux/amd64,linux/arm64)
platforms: linux/arm64

# Control artifact creation
artifacts: true|false|auto    # default: auto (create if none exist)

# Specify artifact formats (default: anaconda-iso)
artifact_formats: anaconda-iso,qcow2,vmdk

# Reuse the same version tag instead of incrementing (default: false)
keep_version: false

# Map GitHub secret names to Buildah secret IDs for use in Containerfile RUN --mount=type=secret
# Format: GITHUB_SECRET_NAME:buildah-secret-id  (comma-separated for multiple)
secrets: MY_SECRET:path/to/secret
```

---

#### `platforms`

Restricts which architectures the image (and its artifacts) are built for.

```yaml
# Build only for ARM64
platforms: linux/arm64
```
```yaml
# Build only for AMD64
platforms: linux/amd64
```
```yaml
# Build for both (same as omitting this option)
platforms: linux/amd64,linux/arm64
```

---

#### `artifacts`

Controls whether installable artifacts (e.g. ISO, qcow2) are created from the image.

```yaml
# Always create artifacts on every build
artifacts: true

# Never create artifacts
artifacts: false

# Create artifacts only if none exist yet in the registry (default)
artifacts: auto
```

When `artifacts: true` or `artifacts: auto`, you can specify which formats to build:

```yaml
artifacts: true
artifact_formats: anaconda-iso,qcow2
```

Supported formats: `anaconda-iso`, `qcow2`, `vmdk`, `raw`, `ami`, `vhd`, `gce`

---

#### `keep_version`

By default, each build increments the version tag (`v1` → `v2` → `v3`...).
Set `keep_version: true` to always overwrite the current version instead of creating a new one.
Useful for images that are frequently rebuilt but don't need a full version history.

```yaml
keep_version: true
```

---

#### `secrets`

Maps GitHub repository secret names to Buildah secret IDs, so they can be consumed
in your `Containerfile` via `RUN --mount=type=secret,id=<secret-id>`.

Format: `GITHUB_SECRET_NAME:buildah-secret-id`, comma-separated for multiple secrets.

```yaml
# Single secret
secrets: MY_GITLAB_TOKEN:myrepo_secret

# Multiple secrets
secrets: MY_GITLAB_TOKEN:myrepo_secret,ANOTHER_SECRET:other
```

Then reference them in your `Containerfile`:

```dockerfile
RUN --mount=type=secret,id=myrepo/TOKEN \
    cat /run/secrets/myrepo/TOKEN
```

The GitHub secret name (left of `:`) is the name as set in **Settings → Secrets → Actions**
in your repository. The secret ID (right of `:`) is the path used inside the container at
`/run/secrets/<secret-id>`. To add a new secret, create it in GitHub and reference it in
`.buildconfig` — no changes to the workflow file are needed.

```

### config.toml File for Artifact Customization

You can customize installable artifacts by adding an optional `config.toml` file to any image directory. This file will be passed to `bootc-image-builder` to configure the artifact creation process.

The `config.toml` file supports various configuration options such as:
- User accounts and SSH keys
- Filesystem customizations
- Network configuration
- Package installation/removal
- System services configuration
- And other bootc-image-builder options

**Important**: The `config.toml` file is completely optional. If it doesn't exist, artifacts will be created with default settings.


Here's an example `config.toml` file that creates a user account with sudo access:

```toml
[[customizations.user]]
name = "admin"
password = "redhat"
groups = ["wheel"]
```

Or the same file but with the password encripted with `openssl passwd -6 "redhat"`

```toml
[[customizations.user]]
name = "admin"
password = "$6$/7rTITXmb1xpkB52$1L6xl53aTMayMIqhdxh6VxLGguy2CUxxf50oqcJGElUgcyx/8nTIEBKtvP6erLtwwLS5B6ZyCEDkrZMGC8ydN/"
groups = ["wheel"]
```

For more configuration options, consult the bootc-image-builder documentation.






---

## Manual Workflow Triggers

You can manually trigger builds with custom parameters:

1. Go to **Actions** → **Build bootc images**
2. Click **Run workflow**
3. Configure:
   - **Platforms**: `linux/amd64,linux/arm64` (or subset)
   - **Formats**: `anaconda-iso,qcow2,vmdk` (or subset)

## Important Notes About GitHub Runner Limitations

This workflow uses GitHub's free hosted runners, which have limited disk space.

When creating installable artifacts, especially larger formats like `raw` disk images, you may encounter disk space limitations that cause the workflow to fail.

### Solutions for Disk Space Issues

If you experience disk space failures during artifact creation, consider these alternatives:

1. **Create artifacts externally**: Use the generated bootc images from this workflow to create installable artifacts on your own system with more disk space. You might find useful the [RHEL and non-RHEL examples in this repository](https://github.com/luisarizmendi/bootc-build-scenarios).

2. **Use self-hosted runners**: Set up your own GitHub Actions runners with more disk space and configure the workflow to use them.

3. **Upgrade to larger GitHub runners**: GitHub offers larger runners with more disk space as part of their paid plans. You can configure the workflow to use these by updating the runner specifications in the build matrix.