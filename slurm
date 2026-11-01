#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/scripts/common.sh"

usage() {
    cat <<'HELP'
Usage: ./slurm [--cluster local|rohan|gondor|cpu] COMMAND [ARGUMENTS...]

  config                              Show effective profile defaults
  doctor                              Check Slurm connection, inventory, storage
  smoke [OPTIONS...]                  Submit a five-minute environment check
  submit NAME [OPTIONS...] [-- CMD...] Submit experiment (default: experiments/run.sh)
  interactive [OPTIONS...]            Open a shell in a new allocation
  status [JOB_ID]                     Queue and accounting (default: latest)
  logs [JOB_ID] [--once]              Follow stdout/stderr (default: latest)
  path [JOB_ID]                       Print the saved run directory
  attach [JOB_ID] [-- CMD...]         Shell/command in an existing running job
  cancel [JOB_ID]                     Cancel one job (default: latest)

Scheduling OPTIONS use --option=value, for example --time=04:00:00 --gres=gpu:2.
submit/interactive also accept --dry-run (prints commands, does not allocate).
Put all experiment arguments AFTER --. No shell evaluation is performed.
HELP
}

EXP_CLUSTER=${EXP_CLUSTER:-local}
if [[ "${1:-}" == --cluster ]]; then
    (( $# >= 2 )) || die 'Expected a cluster profile after --cluster.'
    EXP_CLUSTER=$2; shift 2
fi
action=${1:-help}; (( $# == 0 )) || shift
case "$action" in help|--help|-h) usage; exit 0 ;; esac
[[ "$EXP_CLUSTER" =~ ^[a-zA-Z0-9_-]+$ ]] || die 'Invalid cluster profile name.'
load_settings

submit() {
    local label=${1:-}; (( $# == 0 )) || shift
    [[ "$label" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die 'Supply a run name using letters, digits, dots, underscores, or dashes.'
    parse_options "$@"
    (( ${#command_args[@]} )) || command_args=(bash "$EXP_PROJECT_ROOT/experiments/run.sh")
    resource_options
    if [[ "$dry_run" == true ]]; then
        echo "Profile: $EXP_CLUSTER; run parent: $EXP_RUNS_DIR/$label"
        print_command sbatch "${resources[@]}" "${options[@]}" --job-name="$label" \
            --parsable --export=ALL --no-requeue --chdir="$EXP_PROJECT_ROOT" \
            '--output=<run>/logs/%j.out' '--error=<run>/logs/%j.err' \
            "$EXP_PROJECT_ROOT/batch/job.sbatch" '<run>'
        printf 'Experiment: '; print_command "${command_args[@]}"
        echo 'The real submission records settings and arguments in <run>; arrays use %A_%a logs.'
        return
    fi
    need sbatch
    mkdir -p "$EXP_RUNS_DIR/$label" "$EXP_CACHE_DIR" "$EXP_STATE_DIR/jobs"
    run_dir=$(mktemp -d "$EXP_RUNS_DIR/$label/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
    mkdir -p "$run_dir/logs"
    # A small, explicit snapshot avoids dumping the submitting environment.
    local variable
    for variable in EXP_PROJECT_ROOT EXP_CLUSTER EXP_RUNS_DIR EXP_CACHE_DIR EXP_PARTITION EXP_GRES EXP_CONSTRAINT EXP_CPUS EXP_MEM EXP_TIME EXP_ACCOUNT EXP_QOS EXP_MAIL_USER; do
        printf 'export %s=%q\n' "$variable" "${!variable}"
    done > "$run_dir/settings.sh"
    printf '%s\0' "${command_args[@]}" > "$run_dir/command.argv"
    print_command "${command_args[@]}" > "$run_dir/command.txt"
    if [[ -f "$EXP_PROJECT_ROOT/environment.local.sh" ]]; then
        cp "$EXP_PROJECT_ROOT/environment.local.sh" "$run_dir/environment.sh"
    else
        cp "$EXP_PROJECT_ROOT/environment.example.sh" "$run_dir/environment.sh"
    fi
    if command -v git >/dev/null 2>&1 && git -C "$EXP_PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$EXP_PROJECT_ROOT" rev-parse HEAD > "$run_dir/git-commit.txt" 2>/dev/null || true
        git -C "$EXP_PROJECT_ROOT" status --short > "$run_dir/git-status.txt"
    fi
    local pattern='%j' submitted
    [[ "$array" == false ]] || pattern='%A_%a'
    local invocation=(sbatch "${resources[@]}" "${options[@]}" --job-name="$label"
        --parsable --export=ALL --no-requeue --chdir="$EXP_PROJECT_ROOT"
        --output="$run_dir/logs/$pattern.out" --error="$run_dir/logs/$pattern.err"
        "$EXP_PROJECT_ROOT/batch/job.sbatch" "$run_dir")
    print_command "${invocation[@]}" > "$run_dir/submission.txt"
    printf '%s\n' "$array" > "$run_dir/is-array"
    if submitted=$("${invocation[@]}"); then :; else
        local status=$?
        echo "Submission failed (exit $status). Receipt: $run_dir. Check the queue before retrying if the connection failed." >&2
        return "$status"
    fi
    job_id=${submitted%%;*}
    [[ "$job_id" =~ ^[0-9]+$ ]] || die "Unexpected sbatch output: $submitted. Inspect the queue before retrying. Receipt: $run_dir"
    printf '%s\n' "$job_id" > "$run_dir/job-id"
    # Atomic registry writes keep concurrent submissions from mixing IDs.
    local record
    record=$(mktemp "$EXP_STATE_DIR/jobs/.record-XXXXXX")
    printf '%s\n' "$run_dir" > "$record"
    mv "$record" "$EXP_STATE_DIR/jobs/$job_id"
    record=$(mktemp "$EXP_STATE_DIR/.latest-XXXXXX")
    printf '%s\n' "$job_id" > "$record"
    mv "$record" "$EXP_STATE_DIR/latest"
    printf '%s\n' "$job_id"
    echo "Submitted $label ($EXP_CLUSTER). Run: $run_dir" >&2
}

case "$action" in
    config)
        (( $# == 0 )) || die 'config takes no arguments.'
        for variable in EXP_CLUSTER EXP_PROJECT_ROOT EXP_RUNS_DIR EXP_CACHE_DIR EXP_PARTITION EXP_GRES EXP_CONSTRAINT EXP_CPUS EXP_MEM EXP_TIME EXP_ACCOUNT EXP_QOS EXP_MAIL_USER; do
            printf '%s=%q\n' "$variable" "${!variable}"
        done ;;
    doctor)
        (( $# == 0 )) || die 'doctor takes no arguments.'
        for program in sbatch srun sinfo squeue scontrol; do need "$program"; done
        scontrol ping
        sinfo -N -o '%N %P %t %G %f'
        scontrol show partition "$EXP_PARTITION"
        squeue -u "$(id -un)" -o '%.18i %.12P %.9T %.10M %.40R'
        mkdir -p "$EXP_RUNS_DIR" "$EXP_CACHE_DIR"
        for directory in "$EXP_RUNS_DIR" "$EXP_CACHE_DIR"; do
            probe=$(mktemp "$directory/.write-check-XXXXXX")
            printf 'write check\n' > "$probe"
            rm "$probe"
        done
        df -h "$EXP_PROJECT_ROOT" "$EXP_RUNS_DIR" "$EXP_CACHE_DIR"
        echo 'Login-node checks passed. Run ./slurm smoke to check a compute node.' ;;
    submit) submit "$@" ;;
    smoke)
        parse_options "$@"
        (( ${#command_args[@]} == 0 )) || die 'smoke accepts resource options only.'
        smoke_options=("${options[@]}")
        [[ "$dry_run" == false ]] || smoke_options+=(--dry-run)
        submit smoke --time=00:05:00 --mem=4G "${smoke_options[@]}" -- bash "$EXP_PROJECT_ROOT/experiments/smoke.sh" ;;
    interactive)
        parse_options "$@"
        [[ "$array" == false && ${#command_args[@]} == 0 ]] || die 'interactive takes resource options only.'
        resource_options
        invocation=(srun "${resources[@]}" "${options[@]}" --export=ALL --chdir="$EXP_PROJECT_ROOT"
            --pty bash --rcfile "$EXP_PROJECT_ROOT/scripts/interactive.sh" -i)
        if [[ "$dry_run" == true ]]; then print_command "${invocation[@]}"; else need srun; exec "${invocation[@]}"; fi ;;
    path)
        (( $# <= 1 )) || die 'path accepts at most one job ID.'
        resolve_job "${1:-}"; resolve_run
        printf '%s\n' "$run_dir" ;;
    status|cancel)
        (( $# <= 1 )) || die "$action accepts at most one job ID."
        resolve_job "${1:-}"
        if [[ "$action" == cancel ]]; then need scancel; exec scancel "$job_id"; fi
        need squeue
        squeue -j "$job_id" -o '%.18i %.12P %.9T %.10M %.40R' || echo 'Queue query failed; checking accounting.' >&2
        if command -v sacct >/dev/null 2>&1; then
            sacct -j "$job_id" --format=JobID,JobName,State,Elapsed,MaxRSS,AllocTRES,ExitCode -P
        else
            echo 'sacct is unavailable; ask your site how to view completed jobs.' >&2
        fi ;;
    logs)
        follow=true; selected_job=''
        for argument in "$@"; do
            case "$argument" in
                --once) follow=false ;;
                *) [[ -z "$selected_job" ]] || die 'logs takes one job ID and optional --once.'; selected_job=$argument ;;
            esac
        done
        resolve_job "$selected_job"; resolve_run
        read -r array < "$run_dir/is-array"
        if [[ "$array" == true && "$job_id" != *_* ]]; then
            die "For an array, select a task: ./slurm --cluster $EXP_CLUSTER logs ${job_id}_0 (use your task index)."
        fi
        [[ "$array" == true || "$job_id" != *_* ]] || die 'This job is not an array.'
        if [[ "$follow" == true ]]; then
            echo 'Ctrl-C stops viewing. The job keeps running; pending jobs may not have logs yet.' >&2
            exec tail -n 60 -F -- "$run_dir/logs/$job_id.out" "$run_dir/logs/$job_id.err"
        fi
        exec tail -n 60 -- "$run_dir/logs/$job_id.out" "$run_dir/logs/$job_id.err" ;;
    attach)
        selected_job=''; command_args=()
        while (( $# )); do
            case "$1" in
                --) shift; (( $# )) || die 'Expected a command after --.'; command_args=("$@"); break ;;
                *) [[ -z "$selected_job" ]] || die 'attach takes one job ID and optional -- COMMAND.'; selected_job=$1 ;;
            esac
            shift
        done
        resolve_job "$selected_job"
        need squeue; need srun
        state=$(squeue --noheader --jobs="$job_id" --format=%T)
        [[ "$state" == RUNNING ]] || die "Job $job_id is ${state:-not in the active queue}; attach needs one RUNNING job/task."
        environment="$EXP_PROJECT_ROOT/environment.local.sh"
        if [[ -r "$EXP_STATE_DIR/jobs/${job_id%%_*}" ]]; then
            resolve_run; environment="$run_dir/environment.sh"
        fi
        exec srun --jobid="$job_id" --overlap --nodes=1 --ntasks=1 --cpus-per-task=1 \
            --export=ALL --chdir="$EXP_PROJECT_ROOT" --pty \
            bash "$EXP_PROJECT_ROOT/scripts/with-environment.sh" "$environment" "${command_args[@]}" ;;
    *) die "Unknown command: $action. Run ./slurm help." ;;
esac
