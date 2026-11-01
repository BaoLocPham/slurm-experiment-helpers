#!/usr/bin/env bash
# Internal helpers; source from the ./slurm command.
die() { echo "Error: $*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing $1; run this command on a cluster login node."; }
print_command() { printf '%q ' "$@"; printf '\n'; }

load_settings() {
    EXP_PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
    if [[ -f "$EXP_PROJECT_ROOT/cluster.local.sh" ]]; then
        source "$EXP_PROJECT_ROOT/cluster.local.sh"
    fi
    if [[ "$EXP_CLUSTER" != local ]]; then
        [[ "$EXP_CLUSTER" =~ ^[a-zA-Z0-9_-]+$ ]] || die 'Invalid cluster profile name.'
        [[ -r "$EXP_PROJECT_ROOT/clusters/$EXP_CLUSTER.sh" ]] || die "Unknown profile: $EXP_CLUSTER"
        source "$EXP_PROJECT_ROOT/clusters/$EXP_CLUSTER.sh"
    fi
    EXP_STORAGE=${EXP_STORAGE:-/scratch/$USER/experiments}
    EXP_RUNS_DIR=${EXP_RUNS_DIR:-$EXP_STORAGE/runs/$(basename "$EXP_PROJECT_ROOT")}
    EXP_CACHE_DIR=${EXP_CACHE_DIR:-$EXP_STORAGE/cache}
    EXP_PARTITION=${EXP_PARTITION:-gpu}
    EXP_GRES=${EXP_GRES-gpu:1}
    EXP_CONSTRAINT=${EXP_CONSTRAINT-}
    EXP_CPUS=${EXP_CPUS:-4}
    EXP_MEM=${EXP_MEM:-16G}
    EXP_TIME=${EXP_TIME:-01:00:00}
    EXP_ACCOUNT=${EXP_ACCOUNT-}
    EXP_QOS=${EXP_QOS-}
    EXP_MAIL_USER=${EXP_MAIL_USER-}
    [[ "$EXP_RUNS_DIR" == /* && "$EXP_CACHE_DIR" == /* ]] || die 'Run and cache paths must be absolute.'
    EXP_STATE_DIR="$EXP_PROJECT_ROOT/.slurm/$EXP_CLUSTER"
    export EXP_CLUSTER EXP_PROJECT_ROOT
}

# One node, one Slurm task. torchrun/accelerate may spawn local GPU workers.
resource_options() {
    resources=(--partition="$EXP_PARTITION" --nodes=1 --ntasks=1
        --cpus-per-task="$EXP_CPUS" --mem="$EXP_MEM" --time="$EXP_TIME")
    [[ -z "$EXP_GRES" ]] || resources+=(--gres="$EXP_GRES")
    [[ -z "$EXP_CONSTRAINT" ]] || resources+=(--constraint="$EXP_CONSTRAINT")
    [[ -z "$EXP_ACCOUNT" ]] || resources+=(--account="$EXP_ACCOUNT")
    [[ -z "$EXP_QOS" ]] || resources+=(--qos="$EXP_QOS")
    [[ -z "$EXP_MAIL_USER" ]] || resources+=(--mail-user="$EXP_MAIL_USER" --mail-type=END,FAIL)
    return 0
}

# Accept scheduling overrides in unambiguous --option=value form. Keep paths,
# launch topology, and receipt handling under the wrapper's control.
parse_options() {
    options=(); command_args=(); array=false; dry_run=false
    while (( $# )); do
        case "$1" in
            --) shift; (( $# )) || die 'Expected a command after --.'; command_args=("$@"); break ;;
            --dry-run) dry_run=true ;;
            --array=*) array=true; options+=("$1") ;;
            --time=*|--mem=*|--cpus-per-task=*|--gres=*|--constraint=*|--partition=*|--account=*|--qos=*|--dependency=*|--reservation=*|--exclude=*|--nodelist=*) options+=("$1") ;;
            *) die "Unsupported option: $1. Use --option=value; put the experiment command after --. See ./slurm help." ;;
        esac
        shift
    done
}

resolve_job() {
    job_id=${1:-}
    if [[ -z "$job_id" ]]; then
        [[ -r "$EXP_STATE_DIR/latest" ]] || die "No saved job for $EXP_CLUSTER; supply a job ID."
        read -r job_id < "$EXP_STATE_DIR/latest"
    fi
    [[ "$job_id" =~ ^[0-9]+(_[0-9]+)?$ ]] || die 'Expected a job ID such as 12345 or 12345_0.'
}

resolve_run() {
    local record="$EXP_STATE_DIR/jobs/${job_id%%_*}"
    [[ -r "$record" ]] || die "No local receipt for $job_id in profile $EXP_CLUSTER. Use the same profile as submission."
    read -r run_dir < "$record"
    [[ -d "$run_dir" ]] || die "Run directory is unavailable: $run_dir"
}

load_session_environment() {
    if [[ -n "${EXP_RUN_DIR:-}" && -r "$EXP_RUN_DIR/settings.sh" ]]; then
        source "$EXP_RUN_DIR/settings.sh"
    else
        EXP_CLUSTER=${EXP_CLUSTER:-local}
        load_settings
    fi
    export EXP_CACHE_DIR EXP_PROJECT_ROOT EXP_CLUSTER
    source "$EXP_PROJECT_ROOT/scripts/cache-env.sh"
    local environment=${EXP_ENVIRONMENT_SCRIPT:-$EXP_PROJECT_ROOT/environment.local.sh}
    [[ ! -f "$environment" ]] || source "$environment"
    return 0
}
