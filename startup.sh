#!/bin/bash
set -e

# ==============================================================================
# ==                  BOUNDLESS PROVER LAUNCH SCRIPT                          ==
# ==============================================================================
# This script configures and launches the full Boundless proving stack within
# a single container, designed for environments like Clore.ai where Docker-in-Docker
# is not available.

# --- [1/6] SCRIPT CONFIGURATION ---
echo "==== [1/6] Reading Environment Configuration ===="

# Read execution mode from environment variable.
# - 'config_only': (Default) Set up the environment and wait for inspection.
# - 'bento_test': Configure and run a test proof with Bento.
# - 'broker': Configure, deposit stake (if PRIVATE_KEY is set), and run the full broker.
export BOUNDLESS_MODE="${BOUNDLESS_MODE:-config_only}"

# Read secrets and configuration from environment variables.
export PRIVATE_KEY="${PRIVATE_KEY}"
export RPC_URL="${RPC_URL:-https://mainnet.base.org}"
export STAKE_AMOUNT="${STAKE_AMOUNT:-10}" # Default stake amount in USDC

# Set high-level logging. Use 'trace' for maximum verbosity.
export RUST_LOG="${RUST_LOG:-info,bento=debug,risc0_bento=debug}"
export RUST_BACKTRACE=1

# Hardcoded addresses and URLs for Base Mainnet
MARKET_CONTRACT="0x26759dbB201aFbA361Bec78E097Aa3942B0b4AB8"
STAKE_TOKEN_CONTRACT="0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" # USDC on Base
ORDER_STREAM_URL="https://base-mainnet.beboundless.xyz"

# Define data and log directories
DATA_DIR="/data"
LOG_DIR="/var/log/boundless"
mkdir -p "$DATA_DIR" "$LOG_DIR"
touch "$LOG_DIR/boundless.log"


# --- [2/6] SYSTEM CHECKUP ---
echo ""
echo "==== [2/6] Performing System Checkup ===="

if ! command -v nvidia-smi &> /dev/null; then
    echo "ERROR: nvidia-smi command not found. Please ensure NVIDIA drivers are accessible."
    exit 1
fi
nvidia-smi

GPU_COUNT=$(nvidia-smi -L | wc -l)
VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n 1)
CPU_THREADS=$(nproc)
TOTAL_MEM_GB=$(free -g | awk '/^Mem:/{print $2}')

echo "INFO: Detected System Resources:"
echo "  - GPU Count: $GPU_COUNT"
echo "  - VRAM per GPU (MB): $VRAM_MB"
echo "  - Total CPU Threads: $CPU_THREADS"
echo "  - Total System Memory (GB): $TOTAL_MEM_GB"


# --- [3/6] DYNAMIC RESOURCE ALLOCATION ---
echo ""
echo "==== [3/6] Calculating Dynamic Resource Allocation ===="

# Determine SEGMENT_SIZE based on GPU VRAM
if [ "$VRAM_MB" -gt 38000 ]; then SEGMENT_SIZE=22
elif [ "$VRAM_MB" -gt 18000 ]; then SEGMENT_SIZE=21
elif [ "$VRAM_MB" -gt 14000 ]; then SEGMENT_SIZE=20
else SEGMENT_SIZE=19
fi
echo "INFO: Determined SEGMENT_SIZE: $SEGMENT_SIZE"

# Reserve resources for OS and core services (in threads and GB)
RESERVED_CPU=4
RESERVED_MEM=8
echo "INFO: Reserving ${RESERVED_CPU} CPU threads and ${RESERVED_MEM}GB RAM for OS and core services."

# Calculate available resources for prover/executor agents
AVAIL_CPU=$((CPU_THREADS - RESERVED_CPU))
AVAIL_MEM=$((TOTAL_MEM_GB - RESERVED_MEM))
NUM_EXEC_AGENTS=2 # As per original compose file
# Total number of agents that will share the available resources
AGENT_COUNT=$((GPU_COUNT + NUM_EXEC_AGENTS))

# Calculate resources per agent, ensuring we don't allocate zero
CPU_PER_AGENT=$((AVAIL_CPU / AGENT_COUNT > 0 ? AVAIL_CPU / AGENT_COUNT : 1))
MEM_PER_AGENT_G=$((AVAIL_MEM / AGENT_COUNT > 0 ? AVAIL_MEM / AGENT_COUNT : 1))
MEM_PER_AGENT_M=$((MEM_PER_AGENT_G * 1024))

echo "INFO: Distributing available resources to $AGENT_COUNT agents:"
echo "  - CPUs per Agent: $CPU_PER_AGENT"
echo "  - Memory per Agent: ${MEM_PER_AGENT_G}G"


# --- [4/6] GENERATE CONFIGURATION FILES ---
echo ""
echo "==== [4/6] Generating Configuration Files ===="

# Generate broker.toml for the broker process
cat << EOF > /boundless/broker.toml
[market]
rpc_url = "${RPC_URL}"
chain_id = 8453 # Base Mainnet
market_contract = "${MARKET_CONTRACT}"
private_key = "${PRIVATE_KEY}"

[prover]
bento_api_url = "http://127.0.0.1:8081"

[orders]
order_stream_url = "${ORDER_STREAM_URL}"
EOF
echo "INFO: Generated broker.toml"

# --- [5/6] SERVICE LAUNCHER ---
echo ""
echo "==== [5/6] Starting Services for Mode: $BOUNDLESS_MODE ===="

# Function to start all Bento services in the background
start_bento_services() {
    echo "INFO: Starting Bento services..."

    # Start REST API
    /boundless/target/release/rest_api --bind-addr 0.0.0.0:8081 >> "$LOG_DIR/rest_api.log" 2>&1 &
    echo "  - Started REST API"

    # Start AUX Agent
    /boundless/target/release/agent -t aux --monitor-requeue >> "$LOG_DIR/aux_agent.log" 2>&1 &
    echo "  - Started AUX Agent"

    # Start SNARK Agent
    /boundless/target/release/agent -t snark >> "$LOG_DIR/snark_agent.log" 2>&1 &
    echo "  - Started SNARK Agent"
    
    # Start EXEC Agents
    for i in $(seq 0 $((NUM_EXEC_AGENTS - 1))); do
        /boundless/target/release/agent -t exec --segment-po2 ${SEGMENT_SIZE} >> "$LOG_DIR/exec_agent${i}.log" 2>&1 &
        echo "  - Started EXEC Agent ${i}"
    done
    
    # Start GPU PROVE Agents, one per GPU
    for i in $(seq 0 $((GPU_COUNT - 1))); do
        export NVIDIA_VISIBLE_DEVICES=${i}
        /boundless/target/release/agent -t prove >> "$LOG_DIR/gpu_prove_agent${i}.log" 2>&1 &
        echo "  - Started GPU PROVE Agent ${i} for GPU ${i}"
    done
    
    unset NVIDIA_VISIBLE_DEVICES
    echo "INFO: All Bento services launched. Waiting for them to initialize..."
    sleep 20 # Give services time to start up
}

# --- [6/6] EXECUTION LOGIC ---
echo ""
echo "==== [6/6] Executing Main Logic ===="

cd /boundless

case "$BOUNDLESS_MODE" in
  bento_test)
    echo "INFO: Entering 'bento_test' mode."
    start_bento_services
    
    echo "INFO: Running bento_cli test proof..."
    bento_cli -c 32
    echo "INFO: Test proof command finished. Check logs for 'Job Done!'."
    
    echo "INFO: Tailing logs. Press Ctrl+C to exit."
    tail -n 100 -f "$LOG_DIR"/*.log
    ;;

  broker)
    echo "INFO: Entering 'broker' mode."
    start_bento_services
    
    if [[ -n "$PRIVATE_KEY" ]]; then
        echo "INFO: PRIVATE_KEY is set. Attempting to deposit stake..."
        boundless account deposit-stake "$STAKE_AMOUNT" --rpc-url "$RPC_URL" --stake-token "$STAKE_TOKEN_CONTRACT" || echo "WARN: Staking failed. Check your configuration and balance. Continuing..."
        echo "INFO: Current stake balance:"
        boundless account stake-balance --rpc-url "$RPC_URL" --market-contract "$MARKET_CONTRACT"
    else
        echo "WARN: PRIVATE_KEY not set. Skipping stake deposit. Broker will run without being able to accept jobs."
    fi
    
    echo "INFO: Starting the main broker process..."
    /boundless/target/release/broker --config-file /boundless/broker.toml >> "$LOG_DIR/broker.log" 2>&1 &
    
    echo "INFO: Full stack is running. Tailing logs. Press Ctrl+C to exit."
    tail -n 100 -f "$LOG_DIR"/*.log
    ;;

  *)
    echo "INFO: Mode is 'config_only'. Configuration is complete."
    echo "INFO: The system is ready for inspection. The container will remain running."
    echo "INFO: Set BOUNDLESS_MODE to 'bento_test' or 'broker' to run the prover."
    tail -f /dev/null
    ;;
esac

exit 0
