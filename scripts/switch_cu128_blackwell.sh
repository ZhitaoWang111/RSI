#!/usr/bin/env bash
#
# Switch the ASPIRE LIBERO venv from the locked cu126 torch build to a cu128
# build that contains sm_120 (Blackwell) kernels.
#
# Why this is needed
# ------------------
# ASPIRE's uv.lock pins torch 2.12.1+cu126. That wheel ships kernels for
# sm_50..sm_90 and sm_100, but NOT sm_120. On a Blackwell workstation card
# (RTX 50-series, RTX PRO 5000) CUDA device enumeration succeeds --
# torch.cuda.is_available() returns True and the device name and capability
# report correctly -- but the first real kernel launch fails with:
#
#   CUDA error: no kernel image is available for execution on the device
#
# sm_100 is not a substitute: it is the datacenter Blackwell variant and CUDA
# binaries do not carry across the two.
#
# What this changes
# -----------------
#   torch          2.12.1+cu126  ->  2.11.0+cu128
#   torchvision    0.27.1+cu126  ->  0.26.0+cu128
#   triton         3.7.1         ->  3.6.0     (torch 2.11 pairing)
#   nvidia-*-cu12  12.6.x        ->  12.8.x    (via cuda-toolkit==12.8.1)
#
# Notes on the upgrade path:
#
#   * There is no 2.12.1+cu128. The cu128 branch tops out at 2.11.0, so this is
#     a version downgrade in exchange for usable GPU compute.
#
#   * uv cannot resolve against download.pytorch.org -- that index is not PEP
#     503 -- so the torch/torchvision wheels are fetched with curl and installed
#     from local files.
#
#   * The CUDA component upgrade is not optional. torch's reduction kernels are
#     JIT-compiled at runtime with nvrtc, and nvrtc 12.6 rejects `-arch=sm_120`
#     ("invalid value for --gpu-architecture"). Leaving the 12.6 components in
#     place produces a working `import torch` and a failing SAM3 inference.
#     Package versions do not track the CUDA version (cufft 11.3.x and curand
#     10.3.x are both 12.8 builds), so install the `cuda-toolkit` metapackage
#     and let it resolve the set.
#
# Usage:
#   bash scripts/switch_cu128_blackwell.sh
#   MIRROR=tuna bash scripts/switch_cu128_blackwell.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM_DIR="$REPO_ROOT/third_party/ASPIRE/aspire/sim"
VENV="$SIM_DIR/.venv-libero"
PY="$VENV/bin/python3"

TORCH_VER="2.11.0"
TV_VER="0.26.0"
TOOLKIT_VER="12.8.1"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

[ -x "$PY" ] || { echo "No venv at $VENV; run scripts/setup_aspire_env.sh first."; exit 1; }

case "${MIRROR:-aliyun}" in
  aliyun)
    PYPI_INDEX="https://mirrors.aliyun.com/pypi/simple"
    WHEEL_BASE="https://mirrors.aliyun.com/pytorch-wheels/cu128"
    ;;
  tuna)
    PYPI_INDEX="https://pypi.tuna.tsinghua.edu.cn/simple"
    WHEEL_BASE="https://mirrors.tuna.tsinghua.edu.cn/pytorch-wheels/cu128"
    ;;
  *)
    PYPI_INDEX="https://pypi.org/simple"
    WHEEL_BASE="https://download.pytorch.org/whl/cu128"
    ;;
esac

# --- Report the current state ------------------------------------------------
step "Current state"
"$PY" - <<'PY' || true
import torch
print(f"  torch       {torch.__version__}")
print(f"  cuda build  {torch.version.cuda}")
if torch.cuda.is_available():
    cap = torch.cuda.get_device_capability(0)
    print(f"  device      {torch.cuda.get_device_name(0)} (sm_{cap[0]}{cap[1]})")
    try:
        a = torch.randn(256, 256, device="cuda")
        (a @ a).sum().item()
        torch.cuda.synchronize()
        print("  GPU compute OK")
    except Exception as e:
        print(f"  GPU compute FAILS: {str(e)[:80]}")
PY

# --- Torch / torchvision -----------------------------------------------------
step "Installing torch ${TORCH_VER}+cu128 and torchvision ${TV_VER}+cu128"
CACHE="${UV_CACHE_DIR:-$HOME/.cache/uv}/wheel-downloads"
mkdir -p "$CACHE"

fetch_wheel() {
  local name="$1"   # e.g. torch-2.11.0+cu128-cp312-cp312-manylinux_2_28_x86_64.whl
  local out="$CACHE/$name"
  if [ -f "$out" ]; then
    echo "  cached: $name"
    return 0
  fi
  local encoded="${name//+/%2B}"
  echo "  fetching $name"
  curl -sSfL --retry 3 -o "$out" "$WHEEL_BASE/$encoded"
  echo "    $(du -h "$out" | cut -f1)"
}
PY_TAG="$(bash -c '"$1" -c "import sys; print(f\"cp{sys.version_info.major}{sys.version_info.minor}\")"' _ "$PY")"
PLAT="manylinux_2_28_x86_64"

TORCH_WHL="torch-${TORCH_VER}+cu128-${PY_TAG}-${PY_TAG}-${PLAT}.whl"
TV_WHL="torchvision-${TV_VER}+cu128-${PY_TAG}-${PY_TAG}-${PLAT}.whl"

fetch_wheel "$TORCH_WHL"
fetch_wheel "$TV_WHL"

uv pip install --python "$PY" --no-deps "$CACHE/$TORCH_WHL" "$CACHE/$TV_WHL"

# --- CUDA components ---------------------------------------------------------
# Required for nvrtc to accept sm_120 at runtime. See the header comment.
step "Installing CUDA ${TOOLKIT_VER} components"
uv pip install --python "$PY" \
  --index-url "$PYPI_INDEX" \
  --index-strategy unsafe-best-match \
  "cuda-toolkit[cublas,cudart,cufft,cufile,cupti,curand,cusolver,cusparse,nvjitlink,nvrtc,nvtx]==${TOOLKIT_VER}" \
  "cuda-bindings<13,>=12.9.4"

# --- Align triton to the torch pairing ---------------------------------------
step "Aligning triton to the torch ${TORCH_VER} pairing"
uv pip install --python "$PY" --index-url "$PYPI_INDEX" --index-strategy unsafe-best-match "triton==3.6.0"

# --- Verify ------------------------------------------------------------------
step "Verification"
"$PY" - <<'PY'
import torch, importlib.metadata as md

print(f"  torch        {torch.__version__}")
print(f"  cuda build   {torch.version.cuda}")
print(f"  triton       {md.version('triton')}")
for p in ("cuda-toolkit", "nvidia-cuda-nvrtc-cu12", "nvidia-cudnn-cu12", "nvidia-nccl-cu12"):
    try:
        print(f"  {p:<28} {md.version(p)}")
    except Exception:
        print(f"  {p:<28} MISSING")

cap = torch.cuda.get_device_capability(0)
print(f"  device       {torch.cuda.get_device_name(0)} (sm_{cap[0]}{cap[1]})")

a = torch.randn(1024, 1024, device="cuda")
c = a @ a
torch.cuda.synchronize()
print(f"  fp32 matmul  OK (finite={torch.isfinite(c).all().item()})")

x = torch.randn(1, 3, 64, 64, device="cuda")
conv = torch.nn.Conv2d(3, 8, 3, padding=1).cuda()
print(f"  conv2d       OK {tuple(conv(x).shape)}")

# Exercises the nvrtc reduction JIT path that fails with 12.6 components.
print(f"  reduction    OK {float(torch.randn(4, 1000, device='cuda').sum()):.1f}")
PY

cat <<'EOF'

[done] venv now runs on sm_120.

  Caveat: `uv sync --frozen` will reinstall the locked cu126 build and undo
  this. Re-run this script after any sync, or bump the lock (see README).
EOF
