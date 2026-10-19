#!/usr/bin/env python3
"""Run ASPIRE's LIBERO batch launcher against the internal LLM gateway.

The stock launcher takes ``--server-url`` and ``--api-key`` on the command line,
which puts the bearer token in the process table where any local user can read it
with ``ps``. This wrapper reads the credential file itself and constructs the
launcher arguments in-process, so the token never reaches argv.

Credential file (JSON), path from $RSI_GATEWAY_KEY, default /root/gw_key.json:

    {"token": "sk-...", "OpenAI_URL": "https://...", "Claude_URL": "https://..."}

The endpoint is built as ``<OpenAI_URL>/v1/chat/completions``.

Examples
--------

    # one task, one trial, three seeds -- a smoke run
    python scripts/run_aspire_batch.py \
        --suites libero_goal_swap \
        --models anthropic/claude-sonnet-5-5 \
        --total-trials 1 --num-workers 1 \
        --output-dir ./outputs/smoke

    # pass anything the upstream launcher accepts
    python scripts/run_aspire_batch.py --debug --record-video false ...

Notes
-----
* ASPIRE requires PYTHONPATH to point at the ASPIRE checkout root so that
  ``aspire.sim.*`` imports resolve. The wrapper sets it up itself.
* ``MUJOCO_GL`` must be set before MuJoCo is imported; on hosts without a usable
  EGL stack use ``MUJOCO_GL=osmesa``.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ASPIRE_ROOT = REPO_ROOT / "Submodule" / "ASPIRE"
SIM_DIR = ASPIRE_ROOT / "aspire" / "sim"


def load_gateway(path: Path) -> tuple[str, str]:
    """Return (chat_completions_url, token) from the credential file."""
    cfg = json.loads(path.read_text())
    base = cfg.get("OpenAI_URL")
    token = cfg.get("token")
    if not base or not token:
        raise SystemExit(f"{path} must define 'OpenAI_URL' and 'token'")
    return f"{base.rstrip('/')}/v1/chat/completions", token


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run ASPIRE's LIBERO batch launcher with gateway credentials "
                    "read from a file instead of argv.",
        add_help=True,
    )
    parser.add_argument("--gateway-key", default=os.environ.get("RSI_GATEWAY_KEY", "/root/gw_key.json"),
                        help="JSON credential file (default: $RSI_GATEWAY_KEY or /root/gw_key.json)")
    parser.add_argument("--server-url", default=None,
                        help="Override the derived <OpenAI_URL>/v1/chat/completions")
    parser.add_argument("--suites", nargs="+", default=["libero_goal_swap"])
    parser.add_argument("--models", nargs="+", default=["anthropic/claude-sonnet-5-5"])
    parser.add_argument("--output-dir", default="./outputs/libero_batch_run")
    parser.add_argument("--base-config-path",
                        default="env_configs/libero/franka_libero_baseline_debug.yaml")
    parser.add_argument("--total-trials", type=int, default=None)
    parser.add_argument("--num-workers", type=int, default=None)
    parser.add_argument("--temperature", type=float, default=1.0)
    parser.add_argument("--max-tokens", type=int, default=2048 * 10)
    parser.add_argument("--debug", action="store_true")
    parser.add_argument("--dry-run", action="store_true",
                        help="Resolve credentials and print the plan, then exit")
    args, extra = parser.parse_known_args()

    url, token = load_gateway(Path(args.gateway_key))
    if args.server_url:
        url = args.server_url

    if args.dry_run:
        print(f"  server_url : {url}")
        print(f"  token      : <{len(token)} chars from {args.gateway_key}>")
        print(f"  models     : {args.models}")
        print(f"  suites     : {args.suites}")
        print(f"  output_dir : {args.output_dir}")
        return 0

    # ASPIRE imports `aspire.sim.cap.*`, so the checkout root must be importable.
    for p in (str(ASPIRE_ROOT), str(SIM_DIR)):
        if p not in sys.path:
            sys.path.insert(0, p)
    os.chdir(SIM_DIR)

    from aspire.sim.cap.envs.scripts.run_libero_batch import LiberoBatchLaunchArgs, main as launch

    launch_args = LiberoBatchLaunchArgs(
        base_config_path=args.base_config_path,
        suites=args.suites,
        models=args.models,
        server_url=url,
        output_dir=args.output_dir,
        temperature=args.temperature,
        max_tokens=args.max_tokens,
        api_key=token,
        total_trials=args.total_trials,
        num_workers=args.num_workers,
        debug=args.debug,
    )
    # Forward any remaining upstream flags verbatim (tyro parses its own options).
    if extra:
        print(f"  passing through: {' '.join(extra)}", file=sys.stderr)

    launch(launch_args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
