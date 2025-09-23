# syntax=docker/dockerfile:1
ARG alpine_version=3.22.1
ARG S6_OVERLAY_VERSION=3.2.1.0
# Define the build version argument. Default to 'release' for local builds.
# Possible values: stable, release, pre-release, latest, develop
ARG BUILD_VERSION=release

###### LIBRESPOT START ######
# Build stage for librespot
FROM docker.io/alpine:${alpine_version} AS librespot
# Declare ARG inside the stage
ARG TARGETPLATFORM
ARG BUILD_VERSION

RUN apk add --no-cache \
    git \
    curl \
    libgcc \
    gcc \
    musl-dev \
    pkgconf

# Clone librespot and checkout the version based on BUILD_VERSION
RUN git clone https://github.com/librespot-org/librespot \
    && cd librespot \
    && echo ">>> Checking out librespot source for BUILD_VERSION: ${BUILD_VERSION}" \
    && case ${BUILD_VERSION} in \
        stable) \
            git checkout 0e5531ff5483dc57fc7557325ceec13b2e486732 ;; \
        release) \
            LATEST_STABLE_TAG=$(git tag --sort=-taggerdate | grep -vE 'alpha|beta|rc|-' | head -n 1) \
            && git checkout ${LATEST_STABLE_TAG} ;; \
        pre-release) \
            LATEST_TAG=$(git tag --sort=-taggerdate | head -n 1) \
            && git checkout ${LATEST_TAG} ;; \
        latest) \
            git checkout master ;; \
        develop) \
            git checkout dev ;; \
       *) echo >&2 "!!! ERROR: Unsupported BUILD_VERSION: '${BUILD_VERSION}' for librespot" && exit 1 ;; \
    esac \
    && echo ">>> Using librespot version: $(git describe --always --tags)"

WORKDIR /librespot

# Setup rust toolchain
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal --default-toolchain nightly

# Install the source code for the standard library
RUN rustup component add rust-src --toolchain nightly

# Size optimizations from https://github.com/johnthagen/min-sized-rust
# Strip debug symbols, build a static binary, optimize for size, enable thin LTO, abort on panic
ENV RUSTFLAGS="-C strip=symbols -C target-feature=+crt-static -C opt-level=z -C embed-bitcode=true -C lto=thin -C panic=abort"
# Use the new "sparse" protocol which speeds up the cargo index update massively
# https://blog.rust-lang.org/inside-rust/2023/01/30/cargo-sparse-protocol.html
ENV CARGO_REGISTRIES_CRATES_IO_PROTOCOL="sparse"
# Disable incremental compilation
ENV CARGO_INCREMENTAL=0

# Build the binary
# Determine Rust target dynamically based on TARGETPLATFORM
RUN echo ">>> DEBUG Librespot Stage: Received TARGETPLATFORM='${TARGETPLATFORM}'" \
    && export TARGETARCH=$(echo ${TARGETPLATFORM} | cut -d / -f2) \
    && echo ">>> DEBUG: Derived TARGETARCH='${TARGETARCH}'" \
    && case ${TARGETARCH} in \
    amd64)  RUST_TARGET=x86_64-unknown-linux-musl ;; \
    arm64)  RUST_TARGET=aarch64-unknown-linux-musl ;; \
    arm/v7) RUST_TARGET=armv7-unknown-linux-musleabihf ;; \
    *) echo >&2 "!!! ERROR: Unsupported architecture: '${TARGETARCH}' (derived from TARGETPLATFORM: '${TARGETPLATFORM}')" && exit 1 ;; \
    esac \
    && echo "Building librespot for ${RUST_TARGET} (TARGETPLATFORM: ${TARGETPLATFORM})" \
    && cargo +nightly build \
    -Z build-std=std,panic_abort \
    -Z build-std-features="optimize_for_size,panic_immediate_abort" \
    --release --no-default-features --features "with-avahi rustls-tls-webpki-roots" -j $(nproc) \
    --target ${RUST_TARGET} \
    # Copy artifact to a fixed location for easier final copy
    && mkdir -p /app/bin \
    && cp target/${RUST_TARGET}/release/librespot /app/bin/

###### LIBRESPOT END ######

###### SNAPSERVER BUNDLE START ######
# Build stage for snapserver and its dependencies
FROM docker.io/alpine:${alpine_version} AS snapserver
ARG BUILD_VERSION

### ALSA STATIC ###
# Disable ALSA static build as of https://github.com/alsa-project/alsa-lib/pull/459 static build on musl is broken
# RUN apk add --no-cache \
#     automake \
#     autoconf \
#     build-base \
#     bash \
#     git \
#     libtool \
#     linux-headers \
#     m4
#
# Clone and check out the version based on BUILD_VERSION
# RUN git clone https://github.com/alsa-project/alsa-lib.git /alsa-lib \
#    && cd /alsa-lib \
#    && echo ">>> Checking out alsa-lib source for BUILD_VERSION: ${BUILD_VERSION}" \
#    && case ${BUILD_VERSION} in \
#        *) \
#            git checkout master ;; \
#    esac \
#    && echo ">>> Using alsa-lib version: $(git describe --always --tags)"
# WORKDIR /alsa-lib
# RUN libtoolize --force --copy --automake \
#    && aclocal \
#    && autoheader \
#    && automake --foreign --copy --add-missing \
#    && autoconf \
#    && ./configure --enable-shared=no --enable-static=yes CFLAGS="-ffunction-sections -fdata-sections" \
#    && make -j $(( $(nproc) -1 )) \
#    && make install
### ALSA STATIC END ###

WORKDIR /

### SOXR ###
RUN apk add --no-cache \
    build-base \
    cmake \
    git

# Clone and check out the version based on BUILD_VERSION
RUN git clone https://github.com/chirlu/soxr.git /soxr \
    && cd /soxr \
    && git checkout master
WORKDIR /soxr
RUN mkdir build \
    && cd build \
    && cmake -Wno-dev   -DCMAKE_BUILD_TYPE=Release \
                        -DBUILD_SHARED_LIBS=OFF \
                        -DWITH_OPENMP=OFF \
                        -DBUILD_TESTS=OFF \
                        -DCMAKE_C_FLAGS="-ffunction-sections -fdata-sections" .. \
    && make -j $(( $(nproc) -1 )) \
    && make install
### SOXR END ###

WORKDIR /

### LIBEXPAT STATIC ###
RUN apk add --no-cache \
    build-base \
    bash \
    cmake \
    git

# Clone and check out the version based on BUILD_VERSION
RUN git clone https://github.com/libexpat/libexpat.git /libexpat \
    && cd /libexpat \
    && git checkout master
WORKDIR /libexpat/expat
RUN mkdir build \
    && cd build \
    && cmake    -DCMAKE_BUILD_TYPE=Release \
                -DBUILD_SHARED_LIBS=OFF \
                -DEXPAT_BUILD_TESTS=OFF \
                -DCMAKE_C_FLAGS="-ffunction-sections -fdata-sections" .. \
    && make -j $(( $(nproc) -1 )) \
    && make install
### LIBEXPAT STATIC END ###

WORKDIR /

### LIBOPUS STATIC ###
RUN apk add --no-cache \
    build-base \
    cmake \
    git

# Clone and check out the version based on BUILD_VERSION
# Github mirror of: https://gitlab.xiph.org/xiph/opus.git (more reliable)
RUN git clone https://github.com/xiph/opus.git /opus \
    && cd /opus \
    && git checkout main
WORKDIR /opus
RUN mkdir build \
    && cd build \
    && cmake    -DOPUS_BUILD_PROGRAMS=OFF \
                -DOPUS_BUILD_TESTING=OFF \
                -DOPUS_BUILD_SHARED_LIBRARY=OFF \
                -DCMAKE_C_FLAGS="-ffunction-sections -fdata-sections" .. \
    && make -j $(( $(nproc) -1 )) \
    && make install
### LIBOPUS STATIC END ###

WORKDIR /

### FLAC STATIC ###
RUN apk add --no-cache \
    build-base \
    cmake \
    git \
    pkgconfig

# Clone and check out the version based on BUILD_VERSION
RUN git clone https://github.com/xiph/flac.git /flac \
    && cd /flac \
    && git checkout master
RUN git clone https://github.com/xiph/ogg /flac/ogg \
    && cd /flac/ogg \
    && git checkout main
WORKDIR /flac
RUN mkdir build \
    && cd build \
    && cmake    -DBUILD_EXAMPLES=OFF \
                -DBUILD_TESTING=OFF \
                -DBUILD_DOCS=OFF \
                -DINSTALL_MANPAGES=OFF \
                -DCMAKE_CXX_FLAGS="-ffunction-sections -fdata-sections" .. \
    && make \
    && make install
### FLAC STATIC END ###

WORKDIR /

### LIBVORBIS STATIC ###

# NOTE: libvorbis requires libogg (which is built as part of the flac build)
RUN apk add --no-cache \
    build-base \
    cmake \
    git

# Clone and check out the version based on BUILD_VERSION
# Github mirror of: https://gitlab.xiph.org/xiph/vorbis.git (more reliable)
RUN git clone https://github.com/xiph/vorbis.git /vorbis \
    && cd /vorbis \
    && git checkout main
WORKDIR /vorbis
RUN mkdir build \
    && cd build \
    && cmake -DCMAKE_CXX_FLAGS="-ffunction-sections -fdata-sections" .. \
    && make -j $(( $(nproc) -1 )) \
    && make install
### LIBVORBIS STATIC END ###

WORKDIR /

### SNAPSERVER ###
RUN apk add --no-cache \
    alsa-lib-dev \
    avahi-dev \
    bash \
    build-base \
    boost-dev \
    cmake \
    git \
    npm \
    openssl-dev

# Clone and check out the version based on BUILD_VERSION
RUN git clone https://github.com/badaix/snapcast.git /snapcast \
    && cd snapcast \
    && echo ">>> Checking out snapcast source for BUILD_VERSION: ${BUILD_VERSION}" \
    && case ${BUILD_VERSION} in \
        stable) \
            git checkout 37984c16a101945fe2b52da9c98dbe8073b2a57b ;; \
        release) \
            LATEST_STABLE_TAG=$(git tag --sort=-taggerdate | grep -vE 'alpha|beta|rc|-' | head -n 1) \
            && git checkout ${LATEST_STABLE_TAG} ;; \
        pre-release) \
            LATEST_TAG=$(git tag --sort=-taggerdate | head -n 1) \
            && git checkout ${LATEST_TAG} ;; \
        latest) \
            git checkout master ;; \
        develop) \
            git checkout develop ;; \
       *) echo >&2 "!!! ERROR: Unsupported BUILD_VERSION: '${BUILD_VERSION}' for snapcast" && exit 1 ;; \
    esac \
    && echo ">>> Using snapcast version: $(git describe --always --tags)"
WORKDIR /snapcast
RUN cmake -S . -B build \
    -DBUILD_CLIENT=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_CXX_FLAGS="-s -ffunction-sections -fdata-sections -static-libgcc -static-libstdc++ -Wl,--gc-sections " \
    && cmake --build build -j $(( $(nproc) -1 )) --verbose
WORKDIR /

# Gather all shared libaries necessary to run the executable
RUN mkdir /snapserver-libs \
    && ldd /snapcast/bin/snapserver | grep "=> /" | awk '{print $3}' | xargs -I '{}' cp --dereference '{}' /snapserver-libs/
### SNAPSERVER END ###

### SNAPWEB ###
# Clone and check out the version based on BUILD_VERSION
RUN git clone https://github.com/badaix/snapweb.git \
    && cd snapweb \
    && echo ">>> Checking out snapweb source for BUILD_VERSION: ${BUILD_VERSION}" \
    && case ${BUILD_VERSION} in \
        stable) \
            git checkout f899725fd5b3f103da6c5c53420e6755b4524104 ;; \
        release) \
            LATEST_STABLE_TAG=$(git tag --sort=-taggerdate | grep -vE 'alpha|beta|rc|-' | head -n 1) \
            && git checkout ${LATEST_STABLE_TAG} ;; \
        pre-release) \
            LATEST_TAG=$(git tag --sort=-taggerdate | head -n 1) \
            && git checkout ${LATEST_TAG} ;; \
        latest) \
            git checkout master ;; \
        develop) \
            git checkout develop ;; \
       *) echo >&2 "!!! ERROR: Unsupported BUILD_VERSION: '${BUILD_VERSION}' for snapweb" && exit 1 ;; \
    esac \
    && echo ">>> Using snapweb version: $(git describe --always --tags)"
WORKDIR /snapweb
ENV GENERATE_SOURCEMAP="false"
RUN npm install -g npm@latest \
    && npm ci \
    && npm run build
WORKDIR /
### SNAPWEB END ###
###### SNAPSERVER BUNDLE END ######

###### SHAIRPORT BUNDLE START ######
# Build stage for shairport-sync and its dependencies
FROM docker.io/alpine:${alpine_version} AS shairport
ARG BUILD_VERSION

RUN apk add --no-cache \
    alpine-sdk \
    pkgconf \
    alsa-lib-dev \
    autoconf \
    automake \
    avahi-dev \
    dbus \
    ffmpeg-dev \
    git \
    libtool \
    libplist-dev \
    libplist-util \
    libsodium-dev \
    libgcrypt-dev \
    libconfig-dev \
    openssl-dev \
    popt-dev \
    soxr-dev \
    xxd \
    # Only Necessary for build from 'master'
    libdaemon-dev \
    xmltoman \
    # Necessary for 'development' build, which uses Pipewire
    build-base \
    libsndfile-dev \
    pipewire-dev \
    mosquitto-dev \
    pulseaudio-dev


### NQPTP ###
# Clone and check out the version based on BUILD_VERSION
RUN git clone https://github.com/mikebrady/nqptp \
    && cd nqptp \
    && echo ">>> Checking out nqptp source for BUILD_VERSION: ${BUILD_VERSION}" \
    && case ${BUILD_VERSION} in \
        stable) \
            git checkout c82f64ffd02d88a4961953b50ec392090032592c ;; \
        develop) \
            git checkout development ;; \
        *) \
            git checkout main ;; \
    esac \
    && echo ">>> Using nqptp version: $(git describe --always --tags)"
WORKDIR /nqptp
RUN autoreconf -i \
    && ./configure \
    && make -j $(( $(nproc) -1 ))
WORKDIR /
### NQPTP END ###

### ALAC ###
# Clone and check out the version based on BUILD_VERSION
RUN git clone https://github.com/mikebrady/alac \
    && cd alac \
    && echo ">>> Checking out alac source for BUILD_VERSION: ${BUILD_VERSION}" \
    && case ${BUILD_VERSION} in \
        stable) \
            git checkout 1832544d27d01335d823d639b176d1cae25ecfd4 ;; \
        *) \
            git checkout master ;; \
    esac \
    && echo ">>> Using alac version: $(git describe --always --tags)"
WORKDIR /alac
RUN autoreconf -i \
    && ./configure \
    && make -j $(( $(nproc) -1 )) \
    && make install
WORKDIR /
### ALAC END ###

### SPS ###
# Clone and check out the version based on BUILD_VERSION
RUN git clone https://github.com/mikebrady/shairport-sync.git /shairport \
    && cd /shairport \
    && echo ">>> Checking out shairport-sync source for BUILD_VERSION: ${BUILD_VERSION}" \
    && case ${BUILD_VERSION} in \
        stable) \
            git checkout a56d090fef1ad7e1aa58121f05faa5816cc2fee6 ;; \
        release) \
            LATEST_STABLE_TAG=$(git tag --sort=-taggerdate | grep -vE 'alpha|beta|rc|-' | head -n 1) \
            && git checkout ${LATEST_STABLE_TAG} ;; \
        pre-release) \
            LATEST_TAG=$(git tag --sort=-taggerdate | head -n 1) \
            && git checkout ${LATEST_TAG} ;; \
        latest) \
            git checkout master ;; \
        develop) \
            git checkout development ;; \
       *) echo >&2 "!!! ERROR: Unsupported BUILD_VERSION: '${BUILD_VERSION}' for shairport-sync" && exit 1 ;; \
    esac \
    && echo ">>> Using shairport-sync version: $(git describe --always --tags)"
WORKDIR /shairport/build
RUN autoreconf -i ../ \
    && ../configure --sysconfdir=/etc \
                    --with-soxr \
                    --with-avahi \
                    --with-ssl=openssl \
                    --with-airplay-2 \
                    --with-stdout \
                    --with-metadata \
                    --with-apple-alac \
    && DESTDIR=install make -j $(( $(nproc) -1 )) install

WORKDIR /

# Gather all shared libaries necessary to run the executable
RUN mkdir /shairport-libs \
    && ldd /shairport/build/install/usr/local/bin/shairport-sync | grep "=> /" | awk '{print $3}' | xargs -I '{}' cp --dereference '{}' /shairport-libs/
### SPS END ###
###### SHAIRPORT BUNDLE END ######

###### BASE START ######
# Intermediate stage for common libraries and s6 setup
FROM docker.io/alpine:${alpine_version} AS base
# Declare ARGs needed within this stage
ARG TARGETARCH
ARG S6_OVERLAY_VERSION

RUN apk add --no-cache \
    avahi \
    dbus \
    fdupes
# Copy all necessary libaries into one directory
COPY --from=snapserver /snapserver-libs/ /tmp-libs/
COPY --from=shairport /shairport-libs/ /tmp-libs/
# Remove duplicates
RUN fdupes -rdN /tmp-libs/

# Install s6-overlay dynamically based on TARGETARCH
RUN apk add --no-cache --virtual .fetch-deps curl \
    && echo ">>> DEBUG Base Stage: TARGETARCH='${TARGETARCH}'" \
    && case ${TARGETARCH} in \
    amd64)  S6_ARCH=x86_64 ;; \
    arm64)  S6_ARCH=aarch64 ;; \
    arm/v7) S6_ARCH=armhf ;; \
    *) echo >&2 "!!! ERROR Base Stage: Unsupported architecture for S6: '${TARGETARCH}'" && exit 1 ;; \
    esac \
    && echo "Downloading S6 overlay for arch ${S6_ARCH}" \
    && curl -o /tmp/s6-overlay-noarch.tar.xz -L https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz \
    && curl -o /tmp/s6-overlay-arch.tar.xz -L https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz \
    && tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz \
    && tar -C / -Jxpf /tmp/s6-overlay-arch.tar.xz \
    && apk del .fetch-deps \
    && rm -rf /tmp/*
###### BASE END ######

###### MAIN BASE START ######
# Intermediate stage with common runtime components for both final images
FROM docker.io/alpine:${alpine_version} AS main-base

ENV S6_CMD_WAIT_FOR_SERVICES=1
ENV S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0

# Install common runtime dependencies (excluding Python)
RUN apk add --no-cache \
    avahi \
    dbus \
    # Add any other common runtime packages here if needed
    && rm -rf /var/cache/apk/*

# Copy extracted s6-overlay components and shared libs from base stage
COPY --from=base /command /command/
COPY --from=base /package/ /package/
COPY --from=base /etc/s6-overlay/ /etc/s6-overlay/
COPY --from=base init /init
COPY --from=base /tmp-libs/ /usr/lib/

# Copy core application binaries from their respective build stages
COPY --from=librespot /app/bin/librespot /usr/local/bin/
COPY --from=snapserver /snapcast/bin/snapserver /usr/local/bin/
COPY --from=snapserver /snapweb/dist /usr/share/snapserver/snapweb
COPY --from=shairport /shairport/build/install/usr/local/bin/shairport-sync /usr/local/bin/
COPY --from=shairport /nqptp/nqptp /usr/local/bin/

# Copy common S6 service definitions
COPY ./s6-overlay/s6-rc.d /etc/s6-overlay/s6-rc.d

# Common runtime setup
RUN mkdir -p /var/run/dbus/
# Ensure common startup script is executable (adjust path if needed)
RUN chmod +x /etc/s6-overlay/s6-rc.d/01-startup/script.sh

###### MAIN BASE END ######


###### SLIM FINAL STAGE ######
# Final stage for the "slim" image (without Python/Plugins)
FROM main-base AS slim

# No Python installation or plugin copy here

# Final image setup
WORKDIR /
ENTRYPOINT ["/init"]
###### SLIM FINAL STAGE END ######


###### FULL FINAL STAGE (DEFAULT) ######
# Final stage for the "full" image (with Python/Plugins)
# This is the default target if --target is not specified during build
FROM main-base AS full

# Add Python-specific dependencies
RUN echo "@testing https://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories \
    && apk add --no-cache \
    # Install python dependencies for control scripts
    python3 \
    py3-pip \
    py3-gobject3 \
    py3-mpd2@testing \
    #py3-mpd2 \
    py3-musicbrainzngs \
    py3-websocket-client \
    py3-requests \
    # Clean apk cache after adding packages
    && rm -rf /var/cache/apk/* \
    # Optional: Remove the testing repository if no longer needed
    && sed -i '/@testing/d' /etc/apk/repositories

# Optional: Copy Snapcast Plugins
COPY --from=snapserver /snapcast/server/etc/plug-ins /usr/share/snapserver/plug-ins

# Final image setup
WORKDIR /
ENTRYPOINT ["/init"]
###### FULL FINAL STAGE END ######