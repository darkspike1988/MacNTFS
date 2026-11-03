FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ntfs-3g sleuthkit python3 attr fuse3 util-linux ca-certificates \
    && rm -rf /var/lib/apt/lists/*
