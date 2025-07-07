# Use Ubuntu 22.04 as the base image.
FROM ubuntu:22.04

# Set environment variables to prevent interactive prompts.
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# Set the system PATH to include cargo, risc0, and local binaries.
ENV PATH="/root/.risc0/bin:/root/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# STEP 1: Install base OS, system dependencies, and required services.
# This layer is very stable and will be cached.
RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    # Existing dependencies
    ca-certificates curl iptables build-essential git wget lz4 jq make gcc nano automake autoconf \
    tmux htop nvme-cli libgbm1 pkg-config libssl-dev tar clang bsdmainutils ncdu \
    unzip libleveldb-dev libclang-dev ninja-build nvidia-utils-535 \
    # Added services
    postgresql postgresql-contrib redis-server && \
    rm -rf /var/lib/apt/lists/*

# Install Minio server and client binaries
RUN wget -q https://dl.min.io/server/minio/release/linux-amd64/minio -O /usr/local/bin/minio && \
    wget -q https://dl.min.io/client/mc/release/linux-amd64/mc -O /usr/local/bin/mc && \
    chmod +x /usr/local/bin/minio /usr/local/bin/mc

# STEP 2: Install slow language toolchains and binaries.
# THIS IS THE SLOW STEP and will be cached after the first successful build.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && \
    rustup update && \
    curl -L https://risczero.com/install | bash && \
    rzup install rust && \
    cargo install cargo-risczero && \
    cargo install just && \
    cargo install --locked boundless-cli

# --- CACHE BOUNDARY ---
# Almost everything above this line will be cached on subsequent builds.
# ---

# STEP 3: Clone the application source code and build binaries.
# This step clones the Boundless repo and builds the agent, API, and broker binaries
# which were previously in separate Docker images.
RUN git clone https://github.com/boundless-xyz/boundless.git /boundless
WORKDIR /boundless
RUN git checkout release-0.11
# Build all release binaries for the project
RUN cargo build --workspace --release --bins

# STEP 4: Copy local files and set permissions.
# This is the most frequently changed part.
COPY startup.sh /startup.sh
RUN chmod +x /startup.sh

# Expose ports for informational purposes. Clore handles the actual port forwarding.
EXPOSE 8081 9000 9001 5432 6379

# Set the entrypoint for the container. The startup script will manage all processes.
ENTRYPOINT ["/startup.sh"]
