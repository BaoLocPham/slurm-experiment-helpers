# Bash --rcfile for newly allocated and attached interactive shells.
# Avoid sourcing .bashrc: it can reactivate an unrelated Python environment.
export EXP_PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$EXP_PROJECT_ROOT/scripts/common.sh"
load_session_environment
PS1="(slurm ${SLURM_JOB_ID:-?}) \u@\h:\w\\$ "
