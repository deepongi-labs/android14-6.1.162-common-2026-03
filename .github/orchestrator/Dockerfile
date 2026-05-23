FROM ubuntu:22.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies for GitHub Actions runner and kernel builds
RUN apt-get update && apt-get install -y \
    curl \
    git \
    jq \
    build-essential \
    libssl-dev \
    libffi-dev \
    python3 \
    python3-pip \
    ccache \
    bc \
    bison \
    flex \
    libelf-dev \
    libncurses-dev \
    autoconf \
    dwarves \
    libtool \
    gawk \
    wget \
    cpio \
    unzip \
    rsync \
    && rm -rf /var/lib/apt/lists/*

# Create runner user
RUN useradd -m -s /bin/bash runner && \
    usermod -aG sudo runner && \
    echo "runner ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Set up runner directory
WORKDIR /home/runner
RUN mkdir -p /home/runner/actions-runner && \
    chown -R runner:runner /home/runner

# Download and extract GitHub Actions runner
ARG RUNNER_VERSION=2.319.1
RUN curl -o actions-runner-linux-x64.tar.gz -L \
    https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz && \
    tar xzf actions-runner-linux-x64.tar.gz -C /home/runner/actions-runner && \
    rm actions-runner-linux-x64.tar.gz && \
    chown -R runner:runner /home/runner/actions-runner

# Install runner dependencies
RUN cd /home/runner/actions-runner && \
    ./bin/installdependencies.sh

# Create work directory
RUN mkdir -p /work && chown -R runner:runner /work

# Switch to runner user
USER runner

# Set up ccache
ENV PATH="/usr/lib/ccache:${PATH}"
ENV CCACHE_DIR="/mnt/ccache/.ccache"

# Create entrypoint script
COPY --chown=runner:runner entrypoint.sh /home/runner/entrypoint.sh
RUN chmod +x /home/runner/entrypoint.sh

WORKDIR /home/runner/actions-runner

ENTRYPOINT ["/home/runner/entrypoint.sh"]
