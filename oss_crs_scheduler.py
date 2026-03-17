#!/usr/bin/env python3
"""
Simple resource scheduler for Shellphish CRS on OSS-CRS.

Single-machine deployment: takes available CPU cores, splits them among
active fuzzer components based on a fixed ratio, writes core assignments
into the compose file's additional_env, then delegates to oss-crs CLI.

The compose file is modified in-place (additional_env updated) so that
prepare/build-target/run all use the same compose and thus the same workdir.

Usage:
    python3 oss_crs_scheduler.py --cpus 4-15 --language c \
        --compose-file /project/oss-crs/example/crs-shellphish/compose.yaml \
        run --fuzz-proj-path ... --target-harness ...
"""

import argparse
import os
import subprocess
import sys

import yaml


def parse_cpuset(cpuset_str: str) -> list[int]:
    """Parse cpuset string like '4-15' or '4,5,6,7' into sorted list of core numbers."""
    cores = set()
    for part in cpuset_str.split(","):
        part = part.strip()
        if "-" in part:
            start, end = part.split("-", 1)
            cores.update(range(int(start), int(end) + 1))
        else:
            cores.add(int(part))
    return sorted(cores)


def cores_to_str(cores: list[int]) -> str:
    """Convert list of core numbers to comma-separated string."""
    return ",".join(str(c) for c in cores)


def cpuset_range_str(cores: list[int]) -> str:
    """Convert list to cpuset range string for compose.yaml (e.g. '4-15')."""
    if not cores:
        return ""
    return f"{cores[0]}-{cores[-1]}" if len(cores) > 1 else str(cores[0])


# Component definitions per language
COMPONENTS = {
    "c": {
        "aflpp": {"env_var": "AFLPP_CPUS", "ratio": 1},
        "libfuzzer": {"env_var": "LIBFUZZER_CPUS", "ratio": 1},
    },
    "c++": {
        "aflpp": {"env_var": "AFLPP_CPUS", "ratio": 1},
        "libfuzzer": {"env_var": "LIBFUZZER_CPUS", "ratio": 1},
    },
    # "jvm": {
    #     "jazzer": {"env_var": "JAZZER_CPUS", "ratio": 1},
    # },
}

SUPPORTED_LANGUAGES = set(COMPONENTS.keys())


def allocate_cores(cores: list[int], language: str) -> dict[str, list[int]]:
    """Split cores among components based on fixed ratio."""
    components = COMPONENTS[language]
    total_ratio = sum(c["ratio"] for c in components.values())
    n = len(cores)

    allocation = {}
    offset = 0
    items = list(components.items())
    for i, (name, config) in enumerate(items):
        if i == len(items) - 1:
            share = cores[offset:]
        else:
            share_size = max(1, n * config["ratio"] // total_ratio)
            share = cores[offset:offset + share_size]
            offset += share_size
        allocation[name] = share

    return allocation


def update_compose(compose_path: str, cores: list[int], language: str):
    """Update compose file in-place with core assignments in additional_env."""
    with open(compose_path) as f:
        compose = yaml.safe_load(f)

    allocation = allocate_cores(cores, language)

    # Find the CRS entry
    crs_key = None
    for key in compose:
        if key not in ("run_env", "docker_registry", "oss_crs_infra"):
            crs_key = key
            break

    if crs_key is None:
        print("Error: no CRS entry found in compose file", file=sys.stderr)
        sys.exit(1)

    # Update cpuset and additional_env
    compose[crs_key]["cpuset"] = cpuset_range_str(cores)
    additional_env = compose[crs_key].get("additional_env", {})
    for name, assigned_cores in allocation.items():
        env_var = COMPONENTS[language][name]["env_var"]
        additional_env[env_var] = cores_to_str(assigned_cores)
    compose[crs_key]["additional_env"] = additional_env

    with open(compose_path, "w") as f:
        yaml.dump(compose, f, default_flow_style=False)


def main():
    parser = argparse.ArgumentParser(
        description="Shellphish CRS resource scheduler for OSS-CRS"
    )
    parser.add_argument(
        "--cpus", required=True,
        help="Available CPU cores (e.g., '4-15' or '4,5,6,7,8,9')"
    )
    parser.add_argument(
        "--language", required=True, choices=sorted(SUPPORTED_LANGUAGES),
        help="Target language"
    )
    parser.add_argument(
        "--compose-file", required=True,
        help="Path to CRS compose file (will be updated in-place)"
    )
    parser.add_argument(
        "command", choices=["prepare", "build-target", "run"],
        help="OSS-CRS command to run"
    )
    parser.add_argument(
        "extra_args", nargs=argparse.REMAINDER,
        help="Additional arguments passed to oss-crs CLI"
    )

    args = parser.parse_args()

    # Parse cores
    cores = parse_cpuset(args.cpus)
    if len(cores) < 2:
        print(f"Error: need at least 2 cores, got {len(cores)}", file=sys.stderr)
        sys.exit(1)

    # Check language
    if args.language not in SUPPORTED_LANGUAGES:
        print(f"Error: unsupported language '{args.language}'. "
              f"Supported: {sorted(SUPPORTED_LANGUAGES)}", file=sys.stderr)
        sys.exit(1)

    # Allocate and display
    allocation = allocate_cores(cores, args.language)
    print(f"=== Shellphish CRS Scheduler ===")
    print(f"Language: {args.language}")
    print(f"Total cores: {len(cores)} ({cores_to_str(cores)})")
    for name, assigned_cores in allocation.items():
        env_var = COMPONENTS[args.language][name]["env_var"]
        print(f"  {name}: {len(assigned_cores)} cores ({cores_to_str(assigned_cores)}) -> {env_var}")
    print(f"================================")

    # Update compose file with core assignments
    update_compose(args.compose_file, cores, args.language)

    # Run oss-crs command
    cmd = [
        "uv", "run", "oss-crs", args.command,
        "--compose-file", args.compose_file,
    ] + args.extra_args

    print(f"Running: {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd="/project/oss-crs")
    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
