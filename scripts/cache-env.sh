# Cache defaults shared by batch and interactive environments.
export HF_HOME="${HF_HOME:-$EXP_CACHE_DIR/huggingface}"
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-$EXP_CACHE_DIR/pip}"
export UV_CACHE_DIR="${UV_CACHE_DIR:-$EXP_CACHE_DIR/uv}"
export TORCH_HOME="${TORCH_HOME:-$EXP_CACHE_DIR/torch}"
# Avoid concurrent compiler writes across jobs and array tasks.
export TRITON_CACHE_DIR="${TRITON_CACHE_DIR:-$EXP_CACHE_DIR/triton/${SLURM_JOB_ID:-interactive}}"
export PYTHONUNBUFFERED=1
