# Slurm experiment helpers

A starting template for reproductions, training runs, and evaluations on a Slurm cluster. Configure storage and your environment once, then use `./slurm` to submit, monitor, inspect, and cancel experiments.

Inspired by the cluster profiles, submission wrapper, shared caches, logs, and attach commands in `/home/s226684402/self-evol/reproduce/agent0`. The experiment itself is a replaceable entrypoint; no Agent0 code or dependencies are required.

## Start here

Run these commands from this repository on your cluster's **login node**:

```bash
cp cluster.example.sh cluster.local.sh
cp environment.example.sh environment.local.sh

# Edit storage, partition, GPU request, and account/QoS as needed.
nano cluster.local.sh
# Point at your existing venv/Conda environment or site modules.
nano environment.local.sh

./slurm config
./slurm doctor
./slurm smoke
./slurm status
./slurm logs
```

`logs` follows both output files; Ctrl-C stops viewing. Once the smoke job succeeds, submit the included dependency-free example:

```bash
./slurm submit baseline
./slurm status
./slurm logs
./slurm path                     # Where this submission's results and records live
```

Requires Bash 4.4+ and the site's Slurm client commands. The example and smoke check also require Python 3. There is no package installation for the helpers. Install and pin your experiment's dependencies separately, following your site's policy.

## Everyday commands

| Task | Command |
| --- | --- |
| Submit the project entrypoint | `./slurm submit baseline` |
| Submit any command | `./slurm submit train -- python3 -u train.py --seed 0` |
| Override runtime and RAM | `./slurm submit train --time=08:00:00 --mem=64G -- python3 -u train.py` |
| Preview without submitting or creating files | `./slurm submit train --dry-run -- python3 train.py` |
| Queue a job after job 12345 ends | `./slurm submit next --continue-after 12345` |
| List your active jobs and their dependencies | `./slurm queue` |
| Inspect one queued job's dependency | `./slurm queue 12346` |
| Check latest job, including completed jobs | `./slurm status` |
| Check a specific job | `./slurm status 12345` |
| Follow latest logs | `./slurm logs` |
| Read logs once | `./slurm logs 12345 --once` |
| Find outputs | `./slurm path 12345` |
| Open a new interactive allocation | `./slurm interactive --time=00:30:00 --mem=8G` |
| Open a shell inside a running job | `./slurm attach 12345` |
| Inspect GPU usage inside that job | `./slurm attach 12345 -- watch -n 2 nvidia-smi` |
| Cancel latest job | `./slurm cancel` |
| Cancel one specific job | `./slurm cancel 12345` |

With no ID, `status`, `logs`, `path`, `attach`, and `cancel` use the last successfully submitted job **for the selected profile**. `queue` lists all your active jobs on the cluster you are logged into, including jobs submitted outside this template. Use explicit IDs when several experiments are active. A new submission with the same name creates a new run directory.

Scheduling options go **before** `--`; your experiment command and all its arguments go **after** `--`. Use `--option=value` for scheduling settings. Arguments are passed literally, preserving spaces and shell characters. For a pipeline, explicitly invoke a shell, for example `-- bash -c 'python3 prepare.py && python3 train.py'`.

Supported scheduling overrides: `--partition`, `--gres`, `--constraint`, `--cpus-per-task`, `--mem`, `--time`, `--account`, `--qos`, `--array`, `--dependency`, `--reservation`, `--exclude`, and `--nodelist`. The wrapper manages job names, log paths, working directories, exports, and launch topology.

Submission prints just the job ID to stdout, so dependencies are straightforward:

```bash
TRAIN=$(./slurm submit train -- python3 -u train.py --seed 0)
EVAL=$(./slurm submit evaluate --dependency=afterok:"$TRAIN" -- python3 -u evaluate.py)
./slurm status "$EVAL"
```

Pass the checkpoint/output path required by your own programs; the dependency only controls when evaluation can start. If training fails, an `afterok` dependent job cannot run successfully; inspect or cancel it.

## Queue a job after another job

Adapted from Agent0's `575dc8a` update, `--continue-after JOB_ID` submits a new job immediately with `--dependency=afterany:JOB_ID`. It becomes eligible after that job ends, including failure, timeout, or cancellation:

```bash
# Replace 12345 with the existing job's ID. Uses experiments/run.sh by default.
NEXT=$(./slurm --cluster rohan submit next --continue-after 12345 --time=24:00:00)
./slurm --cluster rohan queue "$NEXT"
./slurm --cluster rohan status "$NEXT"
./slurm --cluster rohan logs "$NEXT"
```

`--continue-after=12345` works too. Use one positive numeric job ID, and choose either this shortcut or `--dependency`, not both. For multiple predecessors or a particular array task, use `--dependency` directly.

This queues a separate allocation with its own logs and run record. It does not extend the predecessor's runtime or reserve its GPUs. A 24-hour request must fit your site's partition and QoS limits. Once the dependency clears, normal resource availability and priority still apply. The latest saved job becomes the new submission; use `logs 12345` to keep following the predecessor.

The shortcut controls scheduling. **Resume requires your application's own checkpoint arguments.** Agent0 can automatically append `--resume` and `--run-dir` because it has one known training entrypoint. This template accepts arbitrary commands, so it leaves their arguments unchanged; the included example starts a fresh calculation.

For a predecessor submitted through the same profile and checkout, the new job receives `EXP_PREVIOUS_RUN_DIR`, captured from that job's record at submission. For a project whose `train.py` writes to `$EXP_RUN_DIR/checkpoints` and accepts `--resume --checkpoint-dir`, use:

```bash
./slurm --cluster rohan submit continue-training \
    --continue-after 12345 --time=24:00:00 -- bash -c \
    'exec python3 -u train.py --resume --checkpoint-dir "${EXP_PREVIOUS_RUN_DIR:?No saved predecessor run}/checkpoints"'
```

Adapt those arguments to your program. `EXP_PREDECESSOR_JOB_ID` contains the predecessor's ID. Jobs submitted outside the template can also be predecessors; without a local record, `EXP_PREVIOUS_RUN_DIR` is empty, so pass an explicit checkpoint path. For a chain of resumptions, pass the same persistent application checkpoint directory to every job, even though their submission records are separate. Inspect failures before queuing work that will resume them: `afterany` does not establish checkpoint validity or training success.

Choose the dependency that matches your intent:

| Dependency | When the next job becomes eligible |
| --- | --- |
| `--continue-after 12345` / `--dependency=afterany:12345` | After the predecessor terminates, regardless of result |
| `--dependency=afterok:12345` | After successful completion; useful for train → evaluate |
| `--dependency=afterany:12345:12346` | After both predecessors terminate |
| `--dependency=after:12345` | After the predecessor starts or is cancelled; does not wait for completion |

Dependencies are set by `sbatch`; `squeue` displays them. `./slurm queue` and `./slurm status JOB_ID` show pending reasons and the remaining dependency in the final column. A pending continuation commonly shows `Dependency` and `afterany:12345`. You can inspect the same information directly:

```bash
squeue -u "$USER" -o '%.18i %.24j %.9T %.40R %E'
```

`DependencyNeverSatisfied` means a required dependency cannot succeed, such as `afterok` after a failed job. Inspect the predecessor and cancel or deliberately replace the dependent job. New jobs have no log files until they start.

## Use your experiment

For a quick run, supply your existing command after `--`. For a project you run repeatedly, edit [experiments/run.sh](experiments/run.sh) once:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$EXP_PROJECT_ROOT"
exec python3 -u train.py \
    --seed "${SLURM_ARRAY_TASK_ID:-0}" \
    --output-dir "$EXP_RUN_DIR/results/$SLURM_JOB_ID" "$@"
```

Then your regular command is simply:

```bash
./slurm submit baseline
```

The helpers provide `EXP_PROJECT_ROOT`, `EXP_RUN_DIR`, `EXP_CACHE_DIR`, and Slurm's normal environment variables inside jobs. Each submission's run directory exists before the job starts. Use a task-specific results directory for arrays, as above.

With `--continue-after`, `EXP_PREDECESSOR_JOB_ID` and `EXP_PREVIOUS_RUN_DIR` link to the predecessor as described above; both are empty on ordinary submissions.

To keep an installation/download step off the login node, submit its script too:

```bash
./slurm --cluster cpu submit setup --time=01:00:00 -- bash scripts/setup-project.sh
```

Create that project-specific script yourself. Network access and GPU requirements for installation vary by cluster.

## Rohan, Gondor, and CPU jobs

The default profile is `local`, using `cluster.local.sh`. Named profiles load the same local settings first, then override the scheduling values defined in `clusters/NAME.sh`. Storage, environment, account, and QoS remain your local choices. Command-line scheduling overrides apply last.

```bash
# Rohan: example feature gpu-32G, one V100 by default
./slurm --cluster rohan smoke
./slurm --cluster rohan submit baseline --time=08:00:00
./slurm --cluster rohan logs

# Gondor: A100 by default; H100/H200 use gpu-large in the example profile
./slurm --cluster gondor submit baseline
EXP_GPU=h100 ./slurm --cluster gondor submit baseline
./slurm --cluster gondor status

# CPU-only: no GPU GRES or GPU constraint is requested
./slurm --cluster cpu submit preprocess -- python3 prepare_data.py
./slurm --cluster cpu logs
```

These GPU types, partitions, and feature names were taken from `agent0`; they are **examples to verify with `./slurm doctor`**, not a live cluster inventory. Change `EXP_CPU_PARTITION` for sites whose CPU partition is not named `cpu`.

Always select the same profile when using its saved job IDs. You can also set `export EXP_CLUSTER=rohan` in your terminal to make it the default. A profile selects resource settings on the cluster you are already logged into; it does not SSH to another machine.

For another cluster, add `clusters/mycluster.sh` with assignments such as `EXP_PARTITION=...` and use `./slurm --cluster mycluster ...`.

## Multiple GPUs and seed sweeps

Each job requests **one node and one Slurm task**. Reserving GPUs does not automatically launch distributed training. For two local workers, run your framework's launcher:

```bash
./slurm --cluster rohan submit train \
    --gres=gpu:v100:2 --cpus-per-task=4 --mem=64G \
    -- torchrun --standalone --nproc_per_node=2 train.py --seed 0
```

Multi-node/MPI launch layouts require extending the wrapper. Match model size, GPU VRAM, host RAM, and worker count to your experiment; Agent0's two-GPU/256G requests are not imposed on other projects.

For seeds 0–4, with at most two tasks running concurrently:

```bash
SWEEP=$(./slurm submit seeds --array=0-4%2)
./slurm status "$SWEEP"
./slurm logs "${SWEEP}_0"          # One task's output
./slurm attach "${SWEEP}_0"        # Only while that task is RUNNING
./slurm cancel "$SWEEP"            # Cancels the whole array
```

The included `experiments/run.sh` maps `SLURM_ARRAY_TASK_ID` to `--seed`. A custom command must do its own mapping, for example:

```bash
./slurm submit seeds --array=0-4%2 -- bash -c \
    'python3 train.py --seed "$SLURM_ARRAY_TASK_ID" --output-dir "$EXP_RUN_DIR/results/$SLURM_JOB_ID"'
```

Each array task requests the full configured resources. Arrays use `PARENT_TASK.out/.err` log names; supply a task ID to `logs`.

## Configuration and saved records

| Setting | Purpose / default |
| --- | --- |
| `EXP_STORAGE` | Shared storage root: `/scratch/$USER/experiments` |
| `EXP_RUNS_DIR` | Run records and artifacts: `$EXP_STORAGE/runs/<project-directory-name>` |
| `EXP_CACHE_DIR` | Reusable framework/package caches: `$EXP_STORAGE/cache` |
| `EXP_PARTITION`, `EXP_GRES`, `EXP_CONSTRAINT` | Partition, GPU request, optional feature |
| `EXP_CPUS`, `EXP_MEM`, `EXP_TIME` | 4 CPUs, 16G host RAM, 1-hour runtime |
| `EXP_ACCOUNT`, `EXP_QOS` | Site-specific billing and queue settings; empty by default |
| `EXP_MAIL_USER` | Optional recipient for END/FAIL mail; empty disables mail |

The project, environment, data, and run directories must be visible at the same paths from login and compute nodes. Change the scratch default if your site uses another location. Caches default to shared storage unless `HF_HOME`, `PIP_CACHE_DIR`, `UV_CACHE_DIR`, `TORCH_HOME`, or `TRITON_CACHE_DIR` are already set. Triton defaults to a separate directory per job.

Every submitted job gets a record like:

```text
<EXP_RUNS_DIR>/baseline/<UTC-time>-<unique-suffix>/
  job-id                     # Assigned job ID
  command.txt, command.argv   # Readable command and exact NUL-separated arguments
  submission.txt             # Exact sbatch command, including scheduling overrides
  settings.sh                # Profile defaults, shared paths, predecessor ID/run if supplied
  environment.sh             # Copy of your environment activation script
  git-commit.txt             # When the project is a Git checkout
  git-status.txt             # Whether the checkout had local changes
  is-array
  logs/<JOB_ID>.out, .err     # Arrays: <PARENT>_<TASK>.out, .err
  exit-code-<JOB_ID>.txt      # Written when the batch shell exits normally
  results/                   # Written by the included example
```

Use `RUN_DIR=$(./slurm path)` to locate the latest run. `.slurm/<profile>/` is a local index of job IDs to run directories. Local settings, the index, and the default in-repository `runs/` directory are ignored by Git.

The command and environment activation script are copied at submission. Source code, datasets, installed packages, and checkpoints are **not copied or frozen**. A queued job reads the project files when it starts. Keep code and dependencies fixed for pending/running jobs; commit the code and pin dependencies for reproducible results. Keep secrets out of scripts and command arguments, which are saved in the run record.

## Reuse for a new reproduction

Copy the template into a fresh project directory, excluding Git history and local run state:

```bash
mkdir -p ~/reproductions/my-experiment
rsync -a --exclude='.git/' --exclude='.slurm/' --exclude='runs/' \
    --exclude='cluster.local.sh' --exclude='environment.local.sh' \
    /home/s226684402/templates/slurm-experiment-helpers/ \
    ~/reproductions/my-experiment/
cd ~/reproductions/my-experiment
```

Repeat the two configuration-file copies from “Start here,” add your experiment code, and edit `experiments/run.sh`. The shared cache can be reused across projects; the default run path separates projects by directory name. Set `EXP_RUNS_DIR` explicitly if two projects share a directory name.

The files you usually edit are only:

| File | What belongs there |
| --- | --- |
| `cluster.local.sh` | Your cluster resources and storage paths |
| `environment.local.sh` | Module/venv/Conda activation |
| `experiments/run.sh` | The actual experiment command |
| `experiments/smoke.sh` | Optional framework imports and tiny model checks |

## If a job does not run

| Symptom | First check |
| --- | --- |
| `PENDING` | `./slurm status ID` shows the reason: resources, priority, dependency, or account/QoS limits |
| `Dependency` | `./slurm queue ID` shows the predecessor; inspect it with `./slurm status PREVIOUS_ID` |
| `DependencyNeverSatisfied` | Inspect failed predecessors; cancel or replace the dependent job intentionally |
| Invalid GRES, partition, or constraint | `./slurm doctor`; compare the profile with `sinfo -N -o '%N %P %G %f'` |
| Logs do not exist yet | A pending job has not started; use `status`. `logs --once` requires existing files |
| `OUT_OF_MEMORY` | Inspect logs and `MaxRSS`; host RAM (`--mem`) is separate from GPU VRAM |
| `TIMEOUT` | Increase `--time` within site limits and resume from an application checkpoint |
| Python/package not found | Fix `environment.local.sh` and rerun `smoke`; login-shell activation alone is insufficient |
| `attach` is refused | The job/task must be RUNNING; overlapping steps may also be restricted by site policy |
| No saved job/receipt | Use the same profile and checkout used for submission |
| Submission connection failed | Check `squeue -u "$USER"` before retrying; the controller may have accepted it |

`sbatch` returns after submission; runtime limits start after allocation and do not cap queue waiting. `./slurm status` combines `squeue` with `sacct` because completed jobs leave the queue. Accounting may be delayed or unavailable at your site; an empty record is not proof of success. `MaxRSS` is typically reported on step rows.

Leaving `attach` ends that inspection step; the batch job continues. Leaving `interactive` ends its allocation. Use `cancel` to stop a batch job.

The batch wrapper preserves the application exit code and disables automatic requeue. Checkpointing, graceful walltime handling, and `--resume` belong to your experiment code. To resume, explicitly submit your program with its checkpoint argument; this creates a new submission record. Hard termination can prevent an exit-code file from being written, so Slurm accounting remains the authority on job state.

Command references: [sbatch dependencies](https://slurm.schedmd.com/sbatch.html#OPT_dependency), [squeue](https://slurm.schedmd.com/squeue.html), [srun](https://slurm.schedmd.com/srun.html), [sacct](https://slurm.schedmd.com/sacct.html).

## Local verification

```bash
python3 -m unittest discover -s tests -v
```

Tests use fake Slurm commands and temporary directories; they do not submit jobs. They exercise submission, continuations and dependency inspection, exact arguments, environment snapshots, arrays, profiles, logs, attach, and failure exit codes. Real cluster scheduling, modules, and GPU compatibility require the compute-node smoke check on your site.
