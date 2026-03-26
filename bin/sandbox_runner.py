"""OSS-CRS local sandbox: replace Docker image_run with subprocess execution.

Used in OSSCRS_INTEGRATION_MODE to avoid Docker-in-Docker.
Provides resource limits (memory, CPU time, file size) and timeout.

TODO: upgrade to chroot-based isolation for filesystem separation.
"""
import os
import time
import resource
import logging
import subprocess
from pathlib import Path

log = logging.getLogger("sandbox_runner")


def _preexec_resource_limits():
    """Set resource limits for the child process."""
    # 512 MB virtual memory
    resource.setrlimit(resource.RLIMIT_AS, (512 * 1024 * 1024, 512 * 1024 * 1024))
    # 120s CPU time (generous — timeout handles wall clock)
    resource.setrlimit(resource.RLIMIT_CPU, (120, 120))
    # 10 MB max file size
    resource.setrlimit(resource.RLIMIT_FSIZE, (10 * 1024 * 1024, 10 * 1024 * 1024))


def image_run_local_osscrs(
    artifacts_dir_work,
    artifacts_dir_out,
    cmd,
    timeout=None,
    extra_env=None,
    volumes=None,
    print_output=True,
):
    """Run a command locally instead of in a Docker container.

    Replaces OSSFuzzProject.image_run__local() for OSSCRS mode.
    Sets up /work and /out symlinks so commands using container paths work as-is.

    Args:
        artifacts_dir_work: Host path that maps to /work in the container.
        artifacts_dir_out: Host path that maps to /out in the container.
        cmd: Command to run (list of strings or single string).
        timeout: Wall-clock timeout in seconds.
        extra_env: Additional environment variables.
        volumes: Additional volume mappings {host_path: container_path}.
        print_output: Whether to print subprocess output.

    Returns:
        dict with RunImageResult-compatible fields.
    """
    from shellphish_crs_utils.models.crs_reports import RunImageResult

    artifacts_dir_work = Path(artifacts_dir_work)
    artifacts_dir_out = Path(artifacts_dir_out)

    # Ensure /work and /out point to the right places (container path compat)
    _setup_path_symlink("/work", artifacts_dir_work)
    _setup_path_symlink("/out", artifacts_dir_out)

    # Set up additional volume symlinks if provided
    if volumes:
        for host_path, container_path in volumes.items():
            _setup_path_symlink(container_path, Path(host_path))

    # Build the command
    if isinstance(cmd, str):
        cmd = [cmd]
    cmd = list(cmd)

    # Don't translate paths in command — symlinks handle /work and /out mapping.
    # Commands and scripts use container paths (e.g., /work/script.py) which
    # resolve correctly through the symlinks created above.
    translated_cmd = list(cmd)

    # Handle "reproduce <harness>" command — this script exists in base-runner
    # but not in component-base containers. Replace with direct harness execution.
    # Match the runner image environment (ASAN_OPTIONS, etc.) for consistent output format.
    is_harness_run = False
    if translated_cmd and translated_cmd[0] == "reproduce":
        harness_name = translated_cmd[1] if len(translated_cmd) > 1 else None
        if harness_name:
            harness_bin = artifacts_dir_out / harness_name
            testcase = extra_env.get("TESTCASE", "/work/pov_input") if extra_env else "/work/pov_input"
            if harness_bin.exists():
                translated_cmd = [str(harness_bin), str(testcase)]
                is_harness_run = True
                log.info(f"[sandbox_runner] reproduce → direct execution: {translated_cmd}")
            else:
                log.warning(f"[sandbox_runner] Harness binary not found: {harness_bin}")

    # Merge environment
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)

    # For harness execution, replicate base-runner container's full environment.
    # base-runner (ghcr.io/aixcc-finals/base-runner:v1.3.0) sets these in its image.
    # Without them, ASAN output format differs (e.g., missing DEDUP_TOKEN) and the
    # Shellphish sanitizer parser fails.
    if is_harness_run:
        env.setdefault("ASAN_OPTIONS",
            "alloc_dealloc_mismatch=0:allocator_may_return_null=1:"
            "allocator_release_to_os_interval_ms=500:check_malloc_usable_size=0:"
            "detect_container_overflow=1:detect_odr_violation=0:detect_leaks=1:"
            "detect_stack_use_after_return=1:fast_unwind_on_fatal=0:handle_abort=1:"
            "handle_segv=1:handle_sigill=1:max_uar_stack_size_log=16:print_scariness=1:"
            "quarantine_size_mb=10:strict_memcmp=1:strip_path_prefix=/workspace/:"
            "symbolize=1:use_sigaltstack=1:dedup_token_length=3")
        env.setdefault("MSAN_OPTIONS",
            "print_stats=1:strip_path_prefix=/workspace/:symbolize=1:dedup_token_length=3")
        env.setdefault("UBSAN_OPTIONS",
            "print_stacktrace=1:print_summary=1:silence_unsigned_overflow=1:"
            "strip_path_prefix=/workspace/:symbolize=1:dedup_token_length=3")
        env.setdefault("HWASAN_OPTIONS", "random_tags=0")
        env.setdefault("FUZZER_ARGS", "-rss_limit_mb=2560 -timeout=25")
        env.setdefault("OUT", str(artifacts_dir_out))
        env.setdefault("SRC", "/src")
        env.setdefault("WORK", str(artifacts_dir_work))
        # run_fuzzer does: PATH=$OUT:$PATH && cd $OUT
        env["PATH"] = f"{artifacts_dir_out}:{env.get('PATH', '')}"

    # Apply timeout wrapper if specified (matching Docker behavior)
    effective_timeout = timeout + 10 if timeout else 300

    time_start = time.time()

    # Only apply strict resource limits for sandbox scripts, not harness execution
    # (ASAN harnesses need much more virtual memory)
    preexec = None if is_harness_run else _preexec_resource_limits

    # cwd: harness runs from $OUT (run_fuzzer does cd $OUT), scripts run from /
    run_cwd = str(artifacts_dir_out) if is_harness_run else "/"

    try:
        result = subprocess.run(
            translated_cmd,
            timeout=effective_timeout,
            capture_output=True,
            env=env,
            cwd=run_cwd,
            preexec_fn=preexec,
        )
        exit_code = result.returncode
        stdout = result.stdout
        stderr = result.stderr
    except subprocess.TimeoutExpired as e:
        exit_code = 124  # Match timeout(1) exit code
        stdout = e.stdout or b""
        stderr = e.stderr or b""
    except Exception as e:
        log.error(f"[sandbox_runner] Execution failed: {e}")
        exit_code = 1
        stdout = b""
        stderr = str(e).encode()

    time_end = time.time()

    if print_output and stdout:
        try:
            print(stdout.decode(errors="replace"))
        except Exception:
            pass

    return RunImageResult(
        task_success=(exit_code == 0),
        run_exit_code=exit_code,
        time_scheduled=time_start,
        time_start=time_start,
        time_end=time_end,
        time_taken=time_end - time_start,
        stdout=stdout,
        stderr=stderr,
        container_id=None,
        container_name=None,
        out_dir=artifacts_dir_work.parent,
    )


def _setup_path_symlink(container_path, host_path):
    """Create a symlink from container_path to host_path if needed."""
    container_path = Path(container_path)
    host_path = Path(host_path)

    if container_path == host_path:
        return  # Already the same

    if container_path.is_symlink():
        if container_path.resolve() == host_path.resolve():
            return  # Already correct
        container_path.unlink()

    if container_path.exists():
        return  # Real directory exists, don't overwrite

    try:
        container_path.parent.mkdir(parents=True, exist_ok=True)
        container_path.symlink_to(host_path)
        log.debug(f"[sandbox_runner] Symlinked {container_path} -> {host_path}")
    except OSError as e:
        log.warning(f"[sandbox_runner] Could not symlink {container_path} -> {host_path}: {e}")
