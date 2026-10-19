#!/usr/bin/env bash
#
# Drop into an interactive REPL with the LIBERO environment and the full CaP
# tool namespace loaded. No LLM and no credentials required -- this is the
# fastest way to inspect ASPIRE's per-primitive trace mechanism by hand.
#
# Requires: scripts/setup_aspire_env.sh has completed successfully.
#
# Note: functions that need perception (e.g. segment_sam3_text_prompt) will
# require SAM3 weights (gated on Hugging Face) and the perception servers.
# Env construction, observation, and robot state work without them.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM_DIR="$REPO_ROOT/Submodule/ASPIRE/aspire/sim"
VENV="$SIM_DIR/.venv-libero"

SUITE="${SUITE:-libero_goal_swap}"
TASK="${TASK:-put_the_bowl_on_the_stove}"
TRIAL="${TRIAL:-51}"
CONFIG="${CONFIG:-env_configs/libero/franka_libero_traced.yaml}"

export ASPIRE_ROOT="$SIM_DIR"
export ASPIRE_INTEGRATION_REAL=1
# EGL is faster but needs a GPU-capable headless GL stack (/dev/dri + glvnd
# vendor config); many containers lack it and need OSMesa instead.
# setup_aspire_env.sh reports which one it settled on. Override with e.g.
#   MUJOCO_GL=osmesa scripts/libero_interactive_repl.sh
export MUJOCO_GL="${MUJOCO_GL:-egl}"
export TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD=1
export PYTHONPATH="$REPO_ROOT/Submodule/ASPIRE"

echo "suite=$SUITE task=$TASK trial=$TRIAL"
echo "At the REPL, try:"
echo "  obs = get_observation()"
echo "  rgb = obs['agentview']['images']['rgb']"
echo "  print(rgb.shape)"
echo
echo "Ground-truth simulator APIs (sim.data.*, env.handle.env.*) are FORBIDDEN"
echo "in fix code -- see aspire/sim/CLAUDE.md. They invalidate benchmark results."
echo

cd "$SIM_DIR"
exec "$VENV/bin/python3" scripts/libero/replay_trial.py \
  --args.suite "$SUITE" \
  --args.task "$TASK" \
  --args.trial "$TRIAL" \
  --args.interactive \
  --args.no-record-video \
  --args.config "$CONFIG"
