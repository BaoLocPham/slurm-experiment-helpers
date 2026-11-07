"""Exercise the CLI and batch entrypoint without a Slurm installation."""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MOCK = r'''#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["MOCK_CALLS"], "a") as stream:
    stream.write(json.dumps([name, args]) + "\n")
if name == "sbatch":
    if os.environ.get("MOCK_SUBMIT_FAIL"):
        sys.exit(7)
    print(os.environ.get("MOCK_JOB_ID", "12345") + ";test-cluster")
elif name == "srun":
    # All helpers use --option=value except --pty, --overlap.
    while args and args[0].startswith("--"):
        args.pop(0)
    sys.exit(subprocess.run(args).returncode)
elif name == "squeue":
    state = os.environ.get("MOCK_JOB_STATE", "RUNNING")
    if "--format=%T" in args:
        print(state)
    else:
        dependency = os.environ.get("MOCK_JOB_DEPENDENCY", "(null)")
        print("JOBID NAME STATE REASON DEPENDENCY")
        print(f"12346 next {state} Dependency {dependency}")
elif name == "sacct":
    print("JobID|State|ExitCode\n12345|COMPLETED|0:0")
'''


class WorkflowTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="slurm-template-test-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.project = self.base / "project with spaces"
        shutil.copytree(
            ROOT,
            self.project,
            ignore=shutil.ignore_patterns(".git", ".slurm", "__pycache__", "cluster.local.sh", "environment.local.sh"),
        )
        self.storage = self.base / "shared storage"
        self.bin = self.base / "bin"
        self.bin.mkdir()
        for name in ("sbatch", "srun", "squeue", "sacct", "scancel", "scontrol", "sinfo", "sacctmgr"):
            script = self.bin / name
            script.write_text(MOCK)
            script.chmod(0o755)
        self.calls_path = self.base / "calls.jsonl"
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("EXP_", "SLURM_", "SBATCH_", "MOCK_"))}
        self.env.update(
            PATH=f"{self.bin}:{os.environ['PATH']}",
            EXP_STORAGE=str(self.storage),
            MOCK_CALLS=str(self.calls_path),
        )

    def cli(self, *args, ok=True, env=None):
        result = subprocess.run(
            [str(self.project / "slurm"), *args],
            cwd=self.base,  # Commands work outside the project directory, too.
            env={**self.env, **(env or {})},
            text=True,
            capture_output=True,
            timeout=15,
        )
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def calls(self, name):
        if not self.calls_path.exists():
            return []
        return [args for tool, args in map(json.loads, self.calls_path.read_text().splitlines()) if tool == name]

    def run_dir(self, *prefix):
        return Path(self.cli(*prefix, "path").stdout.strip())

    def batch(self, run, **updates):
        return subprocess.run(
            ["bash", str(self.project / "batch/job.sbatch"), str(run)],
            cwd=self.base,
            env={**self.env, "SLURM_JOB_ID": "12345", **updates},
            text=True,
            capture_output=True,
            timeout=15,
        )

    def test_dry_run_needs_no_slurm_or_writable_storage(self):
        result = self.cli("submit", "preview", "--dry-run", "--time=02:00:00", "--", "python3", "train.py", "--seed", "4")
        self.assertIn("--time=02:00:00", result.stdout)
        self.assertFalse(self.storage.exists())
        self.assertFalse((self.project / ".slurm").exists())
        self.assertEqual(self.calls("sbatch"), [])

    def test_submit_records_exact_arguments_and_runs_example(self):
        result = self.cli("submit", "baseline", "--cpus-per-task=6")
        self.assertEqual(result.stdout, "12345\n")
        run = self.run_dir()
        self.assertTrue((run / "command.argv").exists())
        args = self.calls("sbatch")[0]
        self.assertIn(f"--chdir={self.project}", args)
        self.assertIn(f"--output={run}/logs/%j.out", args)
        result = self.batch(run, SLURM_CPUS_PER_TASK="6")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--cpus-per-task=6", self.calls("srun")[-1])
        metrics = json.loads((run / "results/12345/metrics.json").read_text())
        self.assertEqual(metrics["seed"], 0)
        self.assertEqual((run / "exit-code-12345.txt").read_text(), "0\n")

    def test_environment_is_snapshotted_and_arguments_are_literal(self):
        activation = self.project / "environment.local.sh"
        activation.write_text("export TEST_SNAPSHOT=before\n")
        marker = self.base / "must-not-exist"
        literal = f"space ; $(touch '{marker}') `touch '{marker}'`"
        code = "import json, os, sys; print(json.dumps([os.environ['TEST_SNAPSHOT'], sys.argv[1]]))"
        self.cli("submit", "literal", "--", "python3", "-c", code, literal)
        run = self.run_dir()
        activation.write_text("export TEST_SNAPSHOT=after\n")
        result = self.batch(run)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(json.dumps(["before", literal]), result.stdout)
        self.assertFalse(marker.exists())

    def test_application_failure_is_not_hidden(self):
        self.cli("submit", "failure", "--", "bash", "-c", "exit 42")
        run = self.run_dir()
        result = self.batch(run)
        self.assertEqual(result.returncode, 42)
        self.assertEqual((run / "exit-code-12345.txt").read_text(), "42\n")

    def test_failed_submission_preserves_previous_latest(self):
        self.cli("submit", "good")
        run = self.run_dir()
        result = self.cli("submit", "bad", ok=False, env={"MOCK_SUBMIT_FAIL": "1"})
        self.assertEqual(result.returncode, 7)
        self.assertEqual(self.run_dir(), run)
        self.assertIn("Check the queue before retrying", result.stderr)

    def test_run_name_reuse_does_not_overwrite(self):
        self.cli("submit", "same-name")
        first = self.run_dir()
        self.cli("submit", "same-name", env={"MOCK_JOB_ID": "12346"})
        second = self.run_dir()
        self.assertNotEqual(first, second)
        self.assertEqual(Path(self.cli("path", "12345").stdout.strip()), first)

    def test_continuation_preserves_command_and_captures_predecessor_on_both_clusters(self):
        code = "import json, os, sys; print(json.dumps([os.environ['EXP_PREDECESSOR_JOB_ID'], os.environ['EXP_PREVIOUS_RUN_DIR'], sys.argv[1:]]))"
        for profile in ("rohan", "gondor"):
            with self.subTest(profile=profile):
                prefix = ("--cluster", profile)
                self.cli(*prefix, "submit", "train")
                previous = self.run_dir(*prefix)
                command = ["python3", "-c", code, "--resume", "--checkpoint-dir", str(previous / "checkpoints")]
                result = self.cli(*prefix, "submit", "continue-train", "--continue-after", "12345", "--time=24:00:00", "--", *command, env={"MOCK_JOB_ID": "12346"})
                self.assertEqual(result.stdout, "12346\n")
                run = self.run_dir(*prefix)
                self.assertNotEqual(run, previous)
                args = self.calls("sbatch")[-1]
                self.assertIn("--dependency=afterany:12345", args)
                self.assertEqual([a for a in args if a.startswith("--time=")][-1], "--time=24:00:00")
                self.assertEqual((run / "command.argv").read_bytes().split(b"\0")[:-1], [arg.encode() for arg in command])
                # A later registry edit must not redirect the queued job's checkpoint lookup.
                record = self.project / ".slurm" / profile / "jobs/12345"
                record.write_text(str(run) + "\n")
                result = self.batch(run, SLURM_JOB_ID="12346")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(json.dumps(["12345", str(previous), command[3:]]), result.stdout)

    def test_external_predecessor_accepts_equals_form_without_adding_resume_arguments(self):
        self.cli("submit", "external", "--continue-after=98765")
        run = self.run_dir()
        self.assertIn("--dependency=afterany:98765", self.calls("sbatch")[-1])
        command = (run / "command.argv").read_bytes().split(b"\0")[:-1]
        self.assertEqual(command, [b"bash", str(self.project / "experiments/run.sh").encode()])
        result = self.batch(run)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("export EXP_PREDECESSOR_JOB_ID=98765\n", (run / "settings.sh").read_text())
        self.assertIn("export EXP_PREVIOUS_RUN_DIR=''\n", (run / "settings.sh").read_text())

    def test_continuation_dry_run_does_not_submit_or_create_state(self):
        result = self.cli("submit", "next", "--continue-after=12345", "--dry-run")
        self.assertIn("--dependency=afterany:12345", result.stdout)
        self.assertFalse(self.storage.exists())
        self.assertFalse((self.project / ".slurm").exists())
        self.assertEqual(self.calls("sbatch"), [])

    def test_invalid_or_conflicting_continuations_never_submit(self):
        cases = (
            ("submit", "next", "--continue-after"),
            ("submit", "next", "--continue-after="),
            ("submit", "next", "--continue-after", "0"),
            ("submit", "next", "--continue-after", "-1"),
            ("submit", "next", "--continue-after", "12345_0"),
            ("submit", "next", "--continue-after", "not-a-job"),
            ("submit", "next", "--continue-after", "--dry-run"),
            ("submit", "next", "--continue-after=12345", "--continue-after", "12346"),
            ("submit", "next", "--continue-after=12345", "--dependency=afterok:12346"),
            ("submit", "next", "--dependency=afterok:12346", "--continue-after", "12345"),
            ("smoke", "--continue-after=12345"),
            ("interactive", "--continue-after=12345"),
        )
        for args in cases:
            with self.subTest(args=args):
                self.assertEqual(self.cli(*args, ok=False).returncode, 2)
        self.assertEqual(self.calls("sbatch"), [])
        self.assertEqual(self.calls("srun"), [])
        self.assertFalse(self.storage.exists())

    def test_continuation_rejects_unavailable_recorded_run_before_submission(self):
        self.cli("submit", "train")
        previous = self.run_dir()
        shutil.rmtree(previous)
        result = self.cli("submit", "next", "--continue-after=12345", ok=False)
        self.assertIn("Predecessor run directory is unavailable", result.stderr)
        self.assertEqual(len(self.calls("sbatch")), 1)
        self.assertEqual((self.project / ".slurm/local/latest").read_text(), "12345\n")

    def test_raw_dependency_and_ordinary_submission_clear_inherited_predecessor_metadata(self):
        code = "import json, os; print(json.dumps([os.environ['EXP_PREDECESSOR_JOB_ID'], os.environ['EXP_PREVIOUS_RUN_DIR']]))"
        self.cli("submit", "evaluate", "--dependency=afterok:12344", "--", "python3", "-c", code,
                 env={"EXP_PREDECESSOR_JOB_ID": "stale", "EXP_PREVIOUS_RUN_DIR": "/stale/run"})
        self.assertIn("--dependency=afterok:12344", self.calls("sbatch")[-1])
        result = self.batch(self.run_dir())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(json.dumps(["", ""]), result.stdout)

    def test_queue_and_status_show_dependencies_for_external_jobs(self):
        env = {"MOCK_JOB_STATE": "PENDING", "MOCK_JOB_DEPENDENCY": "afterany:12345"}
        result = self.cli("queue", env=env)
        self.assertIn("afterany:12345", result.stdout)
        self.assertTrue(any(arg.startswith("--user=") for arg in self.calls("squeue")[-1]))
        self.assertTrue(any("%E" in arg for arg in self.calls("squeue")[-1]))
        result = self.cli("queue", "12346", env=env)
        self.assertIn("afterany:12345", result.stdout)
        self.assertIn("--jobs=12346", self.calls("squeue")[-1])
        self.assertEqual(self.calls("sacct"), [])
        self.assertFalse((self.project / ".slurm").exists())
        result = self.cli("status", "12346", env=env)
        self.assertIn("afterany:12345", result.stdout)
        self.assertIn("%E", self.calls("squeue")[-1][-1])

    def test_cpu_profile_clears_gpu_resources_and_named_profile_wins(self):
        (self.project / "cluster.local.sh").write_text("EXP_PARTITION=stale\nEXP_CONSTRAINT=stale\nEXP_GRES=gpu:8\nEXP_ACCOUNT=research\n")
        self.cli("--cluster", "cpu", "submit", "cpu")
        args = self.calls("sbatch")[-1]
        self.assertIn("--partition=cpu", args)
        self.assertIn("--account=research", args)
        self.assertFalse(any(arg.startswith(("--gres=", "--constraint=")) for arg in args))
        self.cli("--cluster", "rohan", "submit", "gpu", "--gres=gpu:v100:2")
        args = self.calls("sbatch")[-1]
        self.assertIn("--partition=gpu", args)
        self.assertIn("--constraint=gpu-32G", args)
        self.assertEqual([a for a in args if a.startswith("--gres=")][-1], "--gres=gpu:v100:2")

    def test_gondor_gpu_selection_and_profile_job_index(self):
        self.cli("--cluster", "gondor", "submit", "gpu", env={"EXP_GPU": "h100"})
        args = self.calls("sbatch")[-1]
        self.assertIn("--partition=gpu-large", args)
        self.assertIn("--gres=gpu:h100:1", args)
        self.cli("path", ok=False)  # Default local profile has no job yet.
        self.assertTrue(self.run_dir("--cluster", "gondor").exists())

    def test_array_seed_exit_record_and_logs(self):
        self.cli("submit", "seeds", "--array=0-4%2")
        run = self.run_dir()
        self.assertIn(f"--output={run}/logs/%A_%a.out", self.calls("sbatch")[-1])
        result = self.batch(run, SLURM_JOB_ID="12348", SLURM_ARRAY_JOB_ID="12345", SLURM_ARRAY_TASK_ID="3")
        self.assertEqual(result.returncode, 0, result.stderr)
        metrics = json.loads((run / "results/12348/metrics.json").read_text())
        self.assertEqual(metrics["seed"], 3)
        self.assertTrue((run / "exit-code-12345_3.txt").exists())
        (run / "logs/12345_3.out").write_text("task output\n")
        (run / "logs/12345_3.err").touch()
        self.assertIn("task output", self.cli("logs", "12345_3", "--once").stdout)
        self.assertIn("select a task", self.cli("logs", "--once", ok=False).stderr)

    def test_logs_status_and_cancel_use_saved_job(self):
        self.cli("submit", "baseline")
        run = self.run_dir()
        (run / "logs/12345.out").write_text("hello from experiment\n")
        (run / "logs/12345.err").write_text("diagnostic\n")
        self.assertIn("hello from experiment", self.cli("logs", "--once").stdout)
        self.assertIn("COMPLETED", self.cli("status").stdout)
        self.cli("cancel")
        self.assertEqual(self.calls("scancel"), [["12345"]])

    def test_limits_inspects_associations_qos_and_partition_without_submission(self):
        result = self.cli("--cluster", "gondor", "limits")
        self.assertIn("not unlimited access", result.stdout)
        self.assertEqual(len(self.calls("sacctmgr")), 2)
        self.assertIn("qos", self.calls("sacctmgr")[-1])
        self.assertIn("gpu", self.calls("scontrol")[-1])
        self.assertEqual(self.calls("sbatch"), [])
        self.assertFalse((self.project / ".slurm").exists())

    def test_missing_logs_once_reports_pending_guidance(self):
        self.cli("submit", "pending")
        result = self.cli("logs", "--once", ok=False)
        self.assertIn("omit --once to wait", result.stderr)
        self.assertNotIn("cannot open", result.stderr)

    def test_status_includes_requested_memory_and_qos_override_is_forwarded(self):
        self.cli("--cluster", "gondor", "submit", "train", "--qos=batch-short", "--mem=256G", "--time=24:00:00")
        args = self.calls("sbatch")[-1]
        for option in ("--qos=batch-short", "--mem=256G", "--time=24:00:00"):
            self.assertIn(option, args)
        self.cli("--cluster", "gondor", "status")
        self.assertIn("ReqMem", self.calls("sacct")[-1][-2])

    def test_attach_uses_snapshot_and_requires_running(self):
        activation = self.project / "environment.local.sh"
        activation.write_text("export TEST_SNAPSHOT=original\n")
        self.cli("submit", "baseline")
        activation.write_text("export TEST_SNAPSHOT=modified\n")
        result = self.cli("attach", "--", "python3", "-c", "import os; print(os.environ['TEST_SNAPSHOT'])")
        self.assertEqual(result.stdout, "original\n")
        self.assertIn("--overlap", self.calls("srun")[-1])
        result = self.cli("attach", "--", "true", ok=False, env={"MOCK_JOB_STATE": "PENDING"})
        self.assertIn("RUNNING", result.stderr)

    def test_interactive_initializes_selected_profile(self):
        # Execute the actual rcfile without a terminal to verify environment setup.
        code = f'source "{self.project}/scripts/interactive.sh"; printf "%s" "$EXP_PARTITION"'
        result = subprocess.run(["bash", "-c", code], env={**self.env, "EXP_CLUSTER": "cpu"}, text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "cpu")
        preview = self.cli("--cluster", "gondor", "interactive", "--dry-run")
        self.assertIn("--pty", preview.stdout)
        self.assertIn("--gres=gpu:a100:1", preview.stdout)

    def test_cpu_smoke_does_not_need_gpu_tools(self):
        self.cli("--cluster", "cpu", "smoke")
        run = self.run_dir("--cluster", "cpu")
        result = self.batch(run)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Compute-node smoke check passed", result.stdout)
        self.assertIn("--time=00:05:00", self.calls("sbatch")[-1])

    def test_invalid_arguments_cannot_change_managed_paths_or_cancel_all(self):
        for args in (
            ("submit", "../escape"),
            ("submit", "bad", "--output=/tmp/override"),
            ("submit", "bad", "--nodes=2"),
            ("submit", "bad", "--time", "02:00:00"),
            ("submit", "bad", "--"),
            ("cancel", "--all"),
            ("--cluster", "../../escape", "config"),
            ("smoke", "--", "arbitrary-command"),
        ):
            with self.subTest(args=args):
                self.cli(*args, ok=False)
        self.assertEqual(self.calls("sbatch"), [])
        self.assertEqual(self.calls("scancel"), [])


if __name__ == "__main__":
    unittest.main()
