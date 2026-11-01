# Copy to cluster.local.sh. This file is sourced by Bash; keep it quiet.
# All paths must be visible at the SAME location on login and compute nodes.
EXP_STORAGE="${EXP_STORAGE:-/scratch/$USER/experiments}"
EXP_RUNS_DIR="${EXP_RUNS_DIR:-$EXP_STORAGE/runs/$(basename "$EXP_PROJECT_ROOT")}"
EXP_CACHE_DIR="${EXP_CACHE_DIR:-$EXP_STORAGE/cache}"

EXP_PARTITION="${EXP_PARTITION:-gpu}"
EXP_GRES="${EXP_GRES-gpu:1}"          # Empty string for CPU-only jobs.
EXP_CONSTRAINT="${EXP_CONSTRAINT-}"  # Optional site-specific GPU feature.
EXP_CPUS="${EXP_CPUS:-4}"
EXP_MEM="${EXP_MEM:-16G}"            # Host RAM, not GPU VRAM.
EXP_TIME="${EXP_TIME:-01:00:00}"
EXP_ACCOUNT="${EXP_ACCOUNT-}"
EXP_QOS="${EXP_QOS-}"
EXP_MAIL_USER="${EXP_MAIL_USER-}"    # Empty disables mail.
