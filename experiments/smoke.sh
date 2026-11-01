#!/usr/bin/env bash
set -euo pipefail
hostname
python3 --version
printf 'Python: %s\n' "$(command -v python3)"
printf 'CUDA_VISIBLE_DEVICES=%s\n' "${CUDA_VISIBLE_DEVICES:-<unset>}"
if [[ -n "${SLURM_JOB_GPUS:-}" || "${SLURM_GPUS_ON_NODE:-0}" != 0 || -n "$EXP_GRES" ]]; then
    nvidia-smi
fi
probe=$(mktemp "$EXP_RUN_DIR/.compute-write-XXXXXX")
printf 'compute write check\n' > "$probe"
rm "$probe"
echo 'Compute-node smoke check passed. Add framework imports and a tiny model step for your project.'
