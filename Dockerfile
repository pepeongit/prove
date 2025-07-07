# Use Ubuntu 22.04 as the base image.
FROM ubuntu:22.04

# Set environment variables to prevent interactive prompts.
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# Set the system PATH to include cargo and risc0 bin directories.
ENV PATH="/root/.risc0/bin:/root/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# STEP 1: Install base OS and system dependencies.
# Added 'llvm-dev' for more robust Rust compilation dependencies.
RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    sudo ca-certificates redis-server postgresql wget psmisc \
    curl iptables build-essential git lz4 jq make gcc nano automake autoconf \
    tmux htop nvme-cli libgbm1 pkg-config libssl-dev tar clang bsdmainutils ncdu \
    unzip libleveldb-dev libclang-dev ninja-build nvidia-utils-535 llvm-dev && \
    rm -rf /var/lib/apt/lists/*

# Download and install Minio Server and Client
RUN wget https://dl.minio.io/server/minio/release/linux-amd64/minio -O /usr/local/bin/minio && \
    chmod +x /usr/local/bin/minio
RUN wget https://dl.minio.io/client/mc/release/linux-amd64/mc -O /usr/local/bin/mc && \
    chmod +x /usr/local/bin/mc

# STEP 2: Install slow language toolchains (cached layer).
# CORRECTED: Clone the risc0 repo and install from path for robustness.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && \
    rustup update && \
    curl -L https://risczero.com/install | bash && \
    rzup install rust && \
    cargo install cargo-risczero && \
    cargo install just && \
    \
    # Clone the risc0 repository explicitly for path-based installation
    git clone https://github.com/risc0/risc0.git /risc0_temp && \
    cd /risc0_temp && \
    git checkout release-2.1 && \
    \
    # Install each bento component from its path within the cloned repo
    cargo install --locked --path crates/bento-cli && \
    cargo install --locked --path crates/bento-agent && \
    cargo install --locked --path crates/bento-rest-api && \
    \
    cd / && \
    rm -rf /risc0_temp && \
    cargo install --locked boundless-cli

# --- CACHE BOUNDARY ---

# STEP 3: Clone the application source code.
RUN git clone https://github.com/boundless-xyz/boundless.git /boundless
WORKDIR /boundless
RUN git checkout release-0.11

# STEP 4: Copy the main orchestration script.
COPY startup.sh /startup.sh
RUN chmod +x /startup.sh

# Set the entrypoint for the container.
ENTRYPOINT ["/startup.sh"]
