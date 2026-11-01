# Build environment for the Moto S50 (XT2409-5) kernel project.
#
# SteamOS 3.5+ ships podman and distrobox.  On the Steam Deck (Konsole):
#   podman build -t s50-kernel -f Containerfile .
#   podman run --rm -it -v "$HOME/moto-kernel:/work:Z" -v "$PWD:/repo:Z" s50-kernel \
#       /repo/scripts/host/build-all.sh /work /work/backup-W1UI36H.39-25-11-4
# The container never needs USB/ADB access: flashing is done outside of it
# with Google platform-tools, and only by the user.
FROM docker.io/library/ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
RUN apt-get update && apt-get install -y --no-install-recommends \
      bc bison flex make git curl ca-certificates python3 python3-minimal \
      libssl-dev libelf-dev dwarves cpio lz4 kmod rsync file xz-utils \
      erofs-utils android-sdk-libsparse-utils openssl binutils \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /repo
