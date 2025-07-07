#!/bin/bash
set -e

# --- Configuration ---
# (This section is unchanged and correct)
export RUST_LOG="info,broker=debug,boundless_market=debug"
export RUST_BACKTRACE=1
export BOUNDLESS_MARKET_ADDRESS="0x26759dbB201aFbA361Bec78E097Aa3942B0b4AB8"
export SET_VERIFIER_ADDRESS="0x8C5a8b5cC272Fe2b74D18843CF9C3aCBc952a760"
export ORDER_STREAM_URL="https://base-mainnet.beboundless.xyz"
export POSTGRES_HOST="localhost"
export POSTGRES_DB="taskdb"
export POSTGRES_PORT="5432"
export POSTGRES_USER="worker"
export POSTGRES_PASS="password"
export DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASS}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
export REDIS_URL="redis://localhost:6379"
export MINIO_HOST="localhost"
export S3_URL="http://${MINIO_HOST}:9000"
export S3_BUCKET="workflow"
export MINIO_ROOT_USER="admin"
export MINIO_ROOT_PASS="password"
export S3_ACCESS_KEY=${MINIO_ROOT_USER}
export S3_SECRET_KEY=${MINIO_ROOT_PASS}

echo "================================================="
echo "====   BOUNDLESS PROVER ORCHESTRATION SCRIPT   ===="
echo "================================================="

# Part 1: System Checkup & Dynamic Resource Allocation
# (This section is unchanged and correct)
echo -e "\n==== [1/6] System Checkup & Resource Allocation ===="
nvidia-smi; GPU_COUNT=$(nvidia-smi -L | wc -l); VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n 1); TOTAL_CPU_THREADS=$(nproc); TOTAL_MEM_GB=$(free -g | awk '/^Mem:/{print $2}'); echo "INFO: Detected: $GPU_COUNT GPUs, $VRAM_MB VRAM, $TOTAL_CPU_THREADS CPU Threads, $TOTAL_MEM_GB GB RAM."; if [ "$VRAM_MB" -gt 38000 ]; then SEGMENT_SIZE=22; elif [ "$VRAM_MB" -gt 18000 ]; then SEGMENT_SIZE=21; elif [ "$VRAM_MB" -gt 14000 ]; then SEGMENT_SIZE=20; else SEGMENT_SIZE=19; fi; echo "INFO: Determined SEGMENT_SIZE: $SEGMENT_SIZE"; RESERVED_CPU=2 && RESERVED_MEM_GB=4; AVAILABLE_CPU=$((TOTAL_CPU_THREADS > RESERVED_CPU ? TOTAL_CPU_THREADS - RESERVED_CPU : 1)); AVAILABLE_MEM_GB=$((TOTAL_MEM_GB > RESERVED_MEM_GB ? TOTAL_MEM_GB - RESERVED_MEM_GB : 1)); CPU_PER_GPU=$((AVAILABLE_CPU / GPU_COUNT)); [ "$CPU_PER_GPU" -lt 1 ] && CPU_PER_GPU=1; MEM_PER_GPU=$((AVAILABLE_MEM_GB / GPU_COUNT)); [ "$MEM_PER_GPU" -lt 1 ] && MEM_PER_GPU=1; echo "INFO: Calculated per-agent resources -> CPUs: $CPU_PER_GPU, Memory: ${MEM_PER_GPU}G"

# Part 2: Start Background Dependencies
# (This section is unchanged and correct)
echo -e "\n==== [2/6] Starting Background Dependencies (Redis, Postgres, Minio) ===="
redis-server --daemonize yes; pg_ctlcluster 14 main start; sudo -u postgres psql -c "CREATE DATABASE ${POSTGRES_DB}" 2>/dev/null || true; sudo -u postgres psql -c "CREATE USER ${POSTGRES_USER} WITH PASSWORD '${POSTGRES_PASS}'" 2>/dev/null || true; sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO ${POSTGRES_USER}"; mkdir -p /minio-data; MINIO_ROOT_USER=${MINIO_ROOT_USER} MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASS} minio server /minio-data --console-address ":9001" &; echo "INFO: Waiting for services to initialize..." && sleep 15; mc alias set local ${S3_URL} ${S3_ACCESS_KEY} ${S3_SECRET_KEY}; mc mb local/${S3_BUCKET} > /dev/null 2>&1 || true; echo "INFO: Dependencies are running."

# Part 3: Run Bento Test Proof
echo -e "\n==== [3/6] Running Bento Test Proof (No Broker) ===="
echo "INFO: Verifying and starting Bento services for testing..."

# ADDED: Verification step for clearer error messages.
command -v bento_rest_api >/dev/null 2>&1 || { echo "❌ ERROR: bento_rest_api not found. Installation failed."; exit 1; }
command -v bento_agent >/dev/null 2>&1 || { echo "❌ ERROR: bento_agent not found. Installation failed."; exit 1; }

bento_rest_api --bind-addr 0.0.0.0:8081 &
bento_agent -t exec --segment-po2 ${SEGMENT_SIZE} &
bento_agent -t exec --segment-po2 ${SEGMENT_SIZE} &
bento_agent -t aux --monitor-requeue &
bento_agent -t snark &
for (( i=0; i<GPU_COUNT; i++ )); do bento_agent -t prove --gpu-id $i & done
echo "INFO: Waiting for Bento infrastructure to start..." && sleep 5

echo "INFO: Submitting test proof to Bento..."
if bento_cli -c 32 | tee /tmp/bento_test.log | grep -q "Job Done!"; then
    echo "✅ SUCCESS: Bento test proof completed successfully!"
else
    echo "❌ ERROR: Bento test proof failed. See logs below."
    cat /tmp/bento_test.log
    exit 1
fi
echo "INFO: Shutting down test agents..." && pkill -f bento_ || true && sleep 5

# Part 4: Auto-Staking Logic
# (This section is unchanged and correct)
echo -e "\n==== [4/6] Checking Stake and Depositing if Needed ===="
if [ -z "$PRIVATE_KEY" ] || [ -z "$RPC_URL" ]; then echo "INFO: PRIVATE_KEY or RPC_URL not set. Skipping stake check."; else STAKED_BALANCE=$(boundless account stake-balance | awk '{print $1}'); echo "INFO: Current staked balance: $STAKED_BALANCE"; if (( $(echo "$STAKED_BALANCE < 1.0" | bc -l) )); then STAKE_AMOUNT=${STAKE_IF_EMPTY:-100}; echo "INFO: Staked balance is less than 1.0. Attempting to deposit $STAKE_AMOUNT USDC..."; if boundless account deposit-stake "$STAKE_AMOUNT"; then echo "✅ Stake deposit successful."; else echo "⚠️ Stake deposit failed. Continuing..."; fi; else echo "INFO: Sufficient stake already exists. Skipping deposit."; fi; fi

# Part 5: Generate compose.yml (Logging Only)
# (This section is unchanged and correct)
echo -e "\n==== [5/6] Generating compose.yml for logging purposes ===="
echo "INFO: compose.yml generation is for visual confirmation only."; sleep 2

# Part 6: Run Full Prover Stack
echo -e "\n==== [6/6] Starting Full Prover Stack (Bento Agents + Broker) ===="
echo "INFO: Starting all Bento services for production..."
bento_rest_api --bind-addr 0.0.0.0:8081 &
bento_agent -t exec --segment-po2 ${SEGMENT_SIZE} &
bento_agent -t exec --segment-po2 ${SEGMENT_SIZE} &
bento_agent -t aux --monitor-requeue &
bento_agent -t snark &
for (( i=0; i<GPU_COUNT; i++ )); do bento_agent -t prove --gpu-id $i & done
echo "INFO: Waiting for Bento infrastructure to start..." && sleep 5

echo "INFO: All agents running. Starting the main Broker process in the foreground."
echo "----------------------------------------------------------------------"
boundless broker --db-url 'sqlite:///db/broker.db' --config-file /boundless/broker.toml --bento-api-url http://localhost:8081
