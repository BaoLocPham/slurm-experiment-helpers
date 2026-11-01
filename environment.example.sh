# Copy to environment.local.sh and enable ONE setup method for your project.
# Sourced inside batch jobs, interactive shells, and attached commands.
# Available: EXP_PROJECT_ROOT, EXP_RUN_DIR (batch jobs only), EXP_CACHE_DIR.
# Use environment variables for credentials; do not write secrets here.

# Python virtual environment on shared storage:
# source /scratch/your-user/envs/my-project/bin/activate

# Conda from an existing installation:
# source "$HOME/miniconda3/etc/profile.d/conda.sh"
# conda activate /scratch/your-user/envs/my-project

# Site modules, then Conda (edit names for your cluster):
# source /etc/profile.d/modules.sh
# module load Anaconda3/2024.02
# source "$(conda info --base)/etc/profile.d/conda.sh"
# conda activate /scratch/your-user/envs/my-project

export PYTHONUNBUFFERED=1
