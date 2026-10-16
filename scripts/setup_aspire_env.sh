#!/usr/bin/env bash
#
# Build the ASPIRE LIBERO environment and run the credential-free smoke test.
#
# Verified on:
#   - Ubuntu 24.04 + CUDA 12.8 + RTX 5070 Ti  (local workstation, EGL)
#   - Ubuntu 22.04 + CUDA 12.8 + RTX PRO 5000 (Aliyun DSW container, OSMesa)
#
# Prereq: scripts/setup_third_party.sh and scripts/apply_patches.sh have run.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM_DIR="$REPO_ROOT/third_party/ASPIRE/aspire/sim"
VENV="$SIM_DIR/.venv-libero"

export CUDA_HOME="${CUDA_HOME:-/usr/local/cuda-12.8}"
export PATH="$CUDA_HOME/bin:$PATH"
# Blackwell is sm_120. Override for other archs (8.9 Ada, 9.0 Hopper).
export TORCH_CUDA_ARCH_LIST="${TORCH_CUDA_ARCH_LIST:-12.0}"
export TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD=1

# Build-time dependencies (e.g. egl-probe's cmake) are resolved live and do not
# come from uv.lock, so they need the default index pointed at a mirror too.
# Set MIRROR=tuna (or any host) to switch; set MIRROR= to use upstream PyPI.
MIRROR="${MIRROR:-aliyun}"
case "$MIRROR" in
  aliyun) MIRROR_INDEX="https://mirrors.aliyun.com/pypi/simple/" ;;
  tuna)   MIRROR_INDEX="https://pypi.tuna.tsinghua.edu.cn/simple/" ;;
  "")     MIRROR_INDEX="" ;;
  *)      MIRROR_INDEX="https://$MIRROR/simple/" ;;
esac
if [ -n "$MIRROR_INDEX" ]; then
  export UV_DEFAULT_INDEX="$MIRROR_INDEX"
  export UV_INDEX_STRATEGY=unsafe-best-match
fi

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

# --- Preflight ---------------------------------------------------------------
step "Preflight"
[ -d "$SIM_DIR" ] || { echo "ASPIRE not found at $SIM_DIR; run scripts/setup_third_party.sh"; exit 1; }

if [ ! -x "$CUDA_HOME/bin/nvcc" ]; then
  echo "ERROR: no nvcc at $CUDA_HOME/bin/nvcc"
  echo "cuRobo v0.7.8 compiles a torch CUDAExtension and needs a system toolkit,"
  echo "not just a driver. Install it, e.g.:"
  echo "  sudo apt-get install -y cuda-toolkit-12-8"
  echo "Do NOT install the 'cuda' or 'cuda-drivers' meta-packages: they try to"
  echo "replace the installed GPU driver."
  exit 1
fi
echo "nvcc: $("$CUDA_HOME/bin/nvcc" --version | tail -1)"
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader || true

command -v uv >/dev/null 2>&1 || { echo "uv not found; install: curl -LsSf https://astral.sh/uv/install.sh | sh"; exit 1; }
[ -n "$MIRROR_INDEX" ] && echo "mirror: $MIRROR_INDEX"

# --- Virtualenv --------------------------------------------------------------
step "Creating .venv-libero (Python 3.12)"
cd "$SIM_DIR"
[ -d "$VENV" ] || uv venv .venv-libero --python 3.12

# --- Dependencies ------------------------------------------------------------
# --frozen installs exactly what uv.lock specifies without re-validating it
# against the working tree. --locked fails here because the cuRobo patch
# changes that package's metadata.
step "uv sync --frozen (libero + dev extras)"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
uv sync --frozen --active --extra libero --extra dev

# --- Repair partially removed nvidia libraries -------------------------------
# uv sync can leave an nvidia-*-cu12 package with its dist-info present but its
# .so files gone, which surfaces as e.g. "libcudnn.so.9: cannot open shared
# object file" on `import torch`.
step "Checking nvidia-*-cu12 shared objects"
SP="$VENV/lib/python3.12/site-packages"
TO_REPAIR=()
for distinfo in "$SP"/nvidia_*_cu12-*.dist-info; do
  [ -e "$distinfo" ] || continue
  base="$(basename "$distinfo" .dist-info)"   # nvidia_cudnn_cu12-9.10.2.21
  mod="${base%%-[0-9]*}"                      # nvidia_cudnn_cu12
  ver="${base#"$mod"-}"                       # 9.10.2.21
  short="${mod#nvidia_}"                      # cudnn_cu12
  short="${short%_cu12}"                      # cudnn
  dir="$SP/nvidia/$short"
  if [ ! -d "$dir" ] || [ -z "$(find "$dir" -name '*.so*' -print -quit 2>/dev/null)" ]; then
    pypi_name="${mod//_/-}"                   # nvidia-cudnn-cu12
    TO_REPAIR+=("$pypi_name==$ver")
    echo "  needs repair: $pypi_name==$ver"
  fi
done

if [ ${#TO_REPAIR[@]} -gt 0 ]; then
  step "Reinstalling ${#TO_REPAIR[@]} damaged package(s)"
  uv pip install --python "$VENV/bin/python3" \
    --index-url https://download.pytorch.org/whl/cu126 \
    --extra-index-url https://pypi.org/simple \
    --index-strategy unsafe-best-match \
    --force-reinstall --no-deps "${TO_REPAIR[@]}"
else
  echo "  all present"
fi

# --- Offscreen rendering backend ---------------------------------------------
# MuJoCo needs a headless GL backend. EGL uses the GPU and is faster, but many
# containers ship without the EGL vendor config or /dev/dri, in which case EGL
# fails with "Cannot initialize a EGL device display". OSMesa is a pure CPU
# software rasterizer and works nearly everywhere, at the cost of speed.
step "Selecting offscreen rendering backend"

egl_works() {
  MUJOCO_GL=egl "$VENV/bin/python3" - <<'PY' >/dev/null 2>&1
import mujoco
m = mujoco.MjModel.from_xml_string(
    '<mujoco><visual><global offwidth="64" offheight="64"/></visual><worldbody>'
    '<light pos="0 0 3"/><geom type="box" size=".3 .3 .3"/></worldbody></mujoco>')
d = mujoco.MjData(m); mujoco.mj_forward(m, d)
mujoco.Renderer(m, 64, 64).render()
PY
}

osmesa_works() {
  MUJOCO_GL=osmesa "$VENV/bin/python3" - <<'PY' >/dev/null 2>&1
import mujoco
m = mujoco.MjModel.from_xml_string(
    '<mujoco><visual><global offwidth="64" offheight="64"/></visual><worldbody>'
    '<light pos="0 0 3"/><geom type="box" size=".3 .3 .3"/></worldbody></mujoco>')
d = mujoco.MjData(m); mujoco.mj_forward(m, d)
mujoco.Renderer(m, 64, 64).render()
PY
}

if [ -n "${MUJOCO_GL:-}" ] && [ "${MUJOCO_GL}" != "egl" ]; then
  echo "  respecting caller-provided MUJOCO_GL=$MUJOCO_GL"
elif egl_works; then
  export MUJOCO_GL=egl
  echo "  EGL works — using GPU rendering"
else
  echo "  EGL unavailable (common in containers without /dev/dri or the glvnd"
  echo "  vendor config). Falling back to OSMesa software rendering."
  if ! ldconfig -p 2>/dev/null | grep -q libOSMesa; then
    echo "  installing libosmesa6"
    apt-get install -y -q libosmesa6 >/dev/null 2>&1 || sudo apt-get install -y -q libosmesa6 >/dev/null 2>&1 || {
      echo "  ERROR: could not install libosmesa6; install it manually and re-run."
      exit 1
    }
  fi
  if osmesa_works; then
    export MUJOCO_GL=osmesa
    echo "  OSMesa works — using software rendering (slower than EGL)"
  else
    echo "  ERROR: neither EGL nor OSMesa could render. Headless MuJoCo will not work."
    exit 1
  fi
fi

# --- LIBERO config -----------------------------------------------------------
# Importing libero for the first time prompts interactively for a dataset path
# and writes ~/.libero/config.yaml. Pre-seed it so non-interactive runs work.
step "Seeding ~/.libero/config.yaml"
if [ -f "$HOME/.libero/config.yaml" ]; then
  echo "  already exists"
else
  echo "N" | "$VENV/bin/python3" -c "import sys; sys.path.insert(0, '$SIM_DIR/cap/third_party/LIBERO-PRO'); import libero" >/dev/null
  echo "  created"
fi

# --- Smoke test --------------------------------------------------------------
step "Smoke test (LIBERO-10, 10 zero-action steps, no credentials)"
echo "  MUJOCO_GL=$MUJOCO_GL"
ASPIRE_INTEGRATION_REAL=1 "$VENV/bin/python" -m pytest tests/test_libero.py -q

cat <<EOF

[done] ASPIRE LIBERO environment is up.
       Rendering backend: $MUJOCO_GL
       Next: MUJOCO_GL=$MUJOCO_GL scripts/libero_interactive_repl.sh
EOF
