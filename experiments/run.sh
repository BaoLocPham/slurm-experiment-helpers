#!/usr/bin/env bash
# Replace this command with your train/evaluate/reproduce entrypoint.
set -euo pipefail
cd "${EXP_PROJECT_ROOT:?Run through ./slurm submit}"
seed=${SLURM_ARRAY_TASK_ID:-${EXP_SEED:-0}}
exec python3 experiments/example.py --seed "$seed" \
    --output "$EXP_RUN_DIR/results/${SLURM_JOB_ID:?}" "$@"
