#!/usr/bin/env bash
# Resource requests come from ./slurm; submit through that wrapper.
set -euo pipefail
export EXP_RUN_DIR=${1:?Expected a run receipt directory}
source "$EXP_RUN_DIR/settings.sh"
cd "$EXP_PROJECT_ROOT"
source "$EXP_PROJECT_ROOT/scripts/cache-env.sh"
task_id=${SLURM_JOB_ID:?This entrypoint requires a Slurm allocation}
if [[ -n "${SLURM_ARRAY_TASK_ID:-}" ]]; then
    task_id="${SLURM_ARRAY_JOB_ID}_${SLURM_ARRAY_TASK_ID}"
fi
trap 'status=$?; printf "%s\n" "$status" > "$EXP_RUN_DIR/exit-code-$task_id.txt"' EXIT
source "$EXP_RUN_DIR/environment.sh"
command_args=()
while IFS= read -r -d '' argument; do command_args+=("$argument"); done < "$EXP_RUN_DIR/command.argv"
(( ${#command_args[@]} )) || { echo 'Empty experiment command.' >&2; exit 2; }
printf 'Job: %s | Host: %s | Started: %s\n' "$task_id" "$(hostname)" "$(date -u +%FT%TZ)"
printf 'Run: %s\n' "$EXP_RUN_DIR"
printf 'Command: '; printf '%q ' "${command_args[@]}"; printf '\n'
# Keep the application exit code; do not hide failures behind tee or auto-retry.
srun --nodes=1 --ntasks=1 --cpus-per-task="${SLURM_CPUS_PER_TASK:-$EXP_CPUS}" \
    --export=ALL --kill-on-bad-exit=1 "${command_args[@]}"
