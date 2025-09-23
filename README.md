# librespot-shairport-snapserver

Alpine-based Docker image for running the **snapserver** part of [snapcast](https://github.com/badaix/snapcast) with [**librespot**](https://github.com/librespot-org/librespot) (Spotify Connect) and [**shairport-sync**](https://github.com/mikebrady/shairport-sync) (AirPlay 2) as audio sources.

This project provides a flexible, multi-arch, and automatically updated image that compiles all components from source to ensure up-to-date features and maximum compatibility.

> **Note:** The corresponding Docker image for running `snapclient` can be found here:  
> [yubiuser/snapclient-docker](https://github.com/yubiuser/snapclient-docker)

---

## Features

- **Multi-Arch Support:** Images are built for `linux/amd64` and `linux/arm64`. Docker will automatically pull the correct architecture.
- **Full & Slim Variants:** Choose between a full-featured image with Python tools or a minimal `slim` image for reduced size.
- **Multiple Stability Channels:** Tags are provided for stable releases, pre-releases, and development branches.
- **Automated Builds:** The images are automatically built and updated by GitHub Actions based on upstream changes and new releases.
- **All-in-One:** Combines Snapcast server, Spotify Connect, and AirPlay 2 support into a single, easy-to-use image.

---

## Available Docker Tags

All images are published to the [GitHub Container Registry (GHCR)](https://github.com/jojo141185/librespot-shairport-snapserver/pkgs/container/librespot-shairport-snapserver).

Each version is available in two variants:
- **Full (default):** Includes all components plus a full Python environment with useful dependencies.
- **Slim (suffixed with `-slim`):** Includes all core components but **excludes** Python and related tools for a smaller footprint.

| Tag(s) | Description | Source Code Version |
| :--- | :--- | :--- |
| `stable`, `stable-slim` | **Recommended for most users.** A highly reproducible build from specific, tested commit hashes of the main components. Provides the greatest stability. | Pinned commit hashes |
| `release`, `release-slim` | Tracks the latest official release tag (excluding pre-releases) from the main components. | Latest release tags |
| `pre-release`, `pre-release-slim` | Tracks the absolute latest chronological tag from the main components, including alphas, betas, and release candidates. | Latest pre-release tags |
| `latest`, `latest-slim` | **Bleeding-edge builds.** A stable version built from the latest official releases of the main components or their `master` branches. Updated weekly and on new releases. | Latest stable releases |
| `develop`, `develop-slim` | **Bleeding-edge dev builds.** Built from the `HEAD` of the `development` branches of the main components. Contains the newest features but may be unstable. Updated weekly. | `develop` branches |
| `vX.Y.Z`, `vX.Y.Z-slim` | **Immutable, stable releases.** These tags correspond to a specific Git tag of this repository and provide a fixed, non-changing version of the image. | Git Tag `vX.Y.Z` |

---

## Usage Examples

### Using Docker Run

For most users, the `stable` or `release` tag is the best choice.

```bash
docker pull ghcr.io/jojo141185/librespot-shairport-snapserver:stable
docker run -d --rm --net host \
  -v ./snapserver.conf:/etc/snapserver.conf \
  --name snapserver ghcr.io/jojo141185/librespot-shairport-snapserver:stable
```

### Using with docker-compose

```yml
services:
  snapcast:
    image: ghcr.io/jojo141185/librespot-shairport-snapserver:stable
    # Or use a slim version:
    # image: ghcr.io/jojo141185/librespot-shairport-snapserver:stable-slim
    # Or a specific version for stability:
    # image: ghcr.io/jojo141185/librespot-shairport-snapserver:v1.2.3
    container_name: snapcast
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./snapserver.conf:/etc/snapserver.conf
      # Example FIFO mapping if needed for other sources
      # - /tmp/snapfifo:/tmp/snapfifo
```

> Replace `./snapserver.conf` with the path to your actual Snapserver config file.

---

## Building Locally

You can build the image locally using `docker build`. The build process is controlled by the `BUILD_VERSION` argument to select which source code versions to compile.

### Build Arguments
- **`BUILD_VERSION`**: Controls the build strategy. Default is `release`.
  - `stable`: Builds from the hardcoded commit hashes (recommended).
  - `release`: Builds from the latest stable tags of the main components.
  - `pre-release`: Builds from the absolute latest tags (including alphas/betas).
  - `latest`: Builds from the `master`/`main` branches.
  - `develop`: Builds from the `development` branches.

### Build Examples

```bash
# Build the recommended 'stable' version
docker build \
  --build-arg BUILD_VERSION=stable \
  -t my-snapserver:local-stable -f ./alpine.dockerfile .

# Build the 'slim' image from the development branches
docker build \
  --target slim \
  --build-arg BUILD_VERSION=develop \
  -t my-snapserver:slim-dev -f ./alpine.dockerfile .
```

---

## Notes

- Based on Alpine 3.22; final image size is ~200 MB (full version); ~120 MB (slim version).
- All CMake builds use `-j $(( $(nproc) - 1 ))` to leave one CPU core free for normal operation.
- Uses [s6-overlay](https://github.com/just-containers/s6-overlay) as an `init` system for robust service management.
- Services are launched with proper dependencies (e.g., waiting for `dbus` and `avahi` before starting).
- Adjust `snapserver.conf` as needed. Note that AirPlay 2 uses additional ports starting from 7000.
- The [Snapweb](https://github.com/badaix/snapweb) UI is included and available at `http://<snapserver-host>:1780`.
