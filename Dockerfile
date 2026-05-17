FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Kernel build dependencies + clang/llvm toolchain + cross toolchains for arm64 + 32-bit compat.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bc \
    bison \
    build-essential \
    ca-certificates \
    ccache \
    cpio \
    curl \
    device-tree-compiler \
    dwarves \
    file \
    flex \
    git \
    kmod \
    lz4 \
    libelf-dev \
    libncurses-dev \
    libssl-dev \
    llvm-17 \
    lld-17 \
    clang-17 \
    make \
    openssl \
    pahole \
    perl \
    pkg-config \
    python3 \
    python3-distutils \
    rsync \
    unzip \
    xz-utils \
    zip \
    zlib1g-dev \
    gcc-aarch64-linux-gnu \
    binutils-aarch64-linux-gnu \
    gcc-arm-linux-gnueabihf \
    binutils-arm-linux-gnueabihf \
  && rm -rf /var/lib/apt/lists/*

# Default envs that match the repo workflow's intent (can be overridden at runtime).
ENV ARCH=arm64
ENV LLVM=1
ENV LLVM_IAS=1
ENV CROSS_COMPILE=aarch64-linux-gnu-
ENV CROSS_COMPILE_COMPAT=arm-linux-gnueabihf-

# Make ccache useful by default when you mount a volume to /ccache.
ENV CCACHE_DIR=/ccache
ENV CCACHE_BASEDIR=/work
ENV CCACHE_NOHASHDIR=true
ENV CCACHE_COMPILERCHECK=content

# Non-root build user.
RUN useradd -m -u 1000 builder \
  && mkdir -p /work /ccache \
  && chown -R builder:builder /work /ccache

USER builder
WORKDIR /work

CMD ["/bin/bash"]

