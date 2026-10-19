#!/usr/bin/env bash
#
# Clone the upstream RSI repos at pinned commits and initialize ASPIRE's
# submodules. Everything lands in Submodule/ (gitignored).
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THIRD_PARTY="$REPO_ROOT/Submodule"
mkdir -p "$THIRD_PARTY"

# --- Upstream repos (commits verified 2026-10-16, EmbodiedEvo 2026-10-19) ----
ASPIRE_COMMIT="f4c8939aab0af9b97690c561bd80e282940f7886"
ENPIRE_COMMIT="99ee90acf65b5b18957c8382ad580db999528be3"
DREAMRSI_COMMIT="4149ea9181ab1db80f85717ffda2c9f0f130e85b"
EMBODIEDEVO_COMMIT="470278c478bdb5e4b6f17dde1ea0393761f230f0"

clone_pinned() {
  local name="$1" url="$2" commit="$3"
  local dest="$THIRD_PARTY/$name"
  if [ -d "$dest/.git" ]; then
    echo "[=] $name: already present"
  else
    echo "[+] $name: cloning $url"
    git clone --quiet "$url" "$dest"
  fi
  git -C "$dest" fetch --quiet --all --tags
  git -C "$dest" checkout --quiet "$commit"
  echo "    -> $name @ $(git -C "$dest" rev-parse --short HEAD)"
}

clone_pinned ASPIRE      https://github.com/NVlabs/ASPIRE.git          "$ASPIRE_COMMIT"
clone_pinned ENPIRE      https://github.com/NVlabs/ENPIRE.git          "$ENPIRE_COMMIT"
clone_pinned Dream-RSI   https://github.com/zhengkid/Dream-RSI.git     "$DREAMRSI_COMMIT"
clone_pinned EmbodiedEvo https://github.com/Einsia/EmbodiedEvo.git     "$EMBODIEDEVO_COMMIT"

# --- ASPIRE submodules -------------------------------------------------------
# All 7 are required. `uv` evaluates every workspace member during resolution,
# so a single missing submodule makes *every* uv command in the repo fail --
# including ones unrelated to that dependency, and `--no-install-package`
# does not help.
echo "[+] ASPIRE: initializing submodules"
git -C "$THIRD_PARTY/ASPIRE" submodule update --init --recursive --depth 1 --jobs 4

# Re-pin explicitly. `--depth 1` alone can leave a submodule sitting on its
# default-branch tip rather than the pinned commit (observed for
# libero_dependencies/robosuite, which landed on cb173eb instead of a498b08).
pin_submodule() {
  local rel="$1" pin="$2"
  local sub="$THIRD_PARTY/ASPIRE/$rel"
  [ -e "$sub/.git" ] || { echo "    [!] missing: $rel"; return 0; }
  git -C "$sub" fetch --quiet --depth 1 origin "$pin" 2>/dev/null || true
  git -C "$sub" checkout --quiet "$pin" 2>/dev/null || true
  echo "    -> $(basename "$rel") @ $(git -C "$sub" rev-parse --short HEAD)"
}

pin_submodule aspire/sim/cap/third_party/LIBERO-PRO                      47aaa8038930bcdc84ab9ea2867e2ffc8039ab4a
pin_submodule aspire/sim/cap/third_party/b1k                            272ec5ca9936453c4a8fd335c4dfba61245e33ca
pin_submodule aspire/sim/cap/third_party/contact_graspnet_pytorch       2d71da4e50a04aa353352d1cae99f20f7022145b
pin_submodule aspire/sim/cap/third_party/curobo                         d64c4b005459db10c5dd867d8b30a87d5bda9bdb
pin_submodule aspire/sim/cap/third_party/libero_dependencies/robosuite  a498b087d4bc5a3981e3d27030d09bc537a537f3
pin_submodule aspire/sim/cap/third_party/robosuite                      97292732ed909ac3ae116579fb768607034a4dbd
pin_submodule aspire/sim/cap/third_party/sam3                           6fe87d64a5beb9084923d7a9e002741178635b09

# --- ENPIRE submodule --------------------------------------------------------
echo "[+] ENPIRE: initializing submodules"
git -C "$THIRD_PARTY/ENPIRE" submodule update --init --recursive --depth 1

cat <<'EOF'

[!] Licensing note
    ASPIRE's `b1k` submodule contains Pixar USD assets whose bundled license
    prohibits redistribution without Pixar's written authorization. Other
    pinned dependencies (SAM 3, cuRobo, Contact-GraspNet) carry custom
    licenses. Do not re-publish Submodule/ or any recursive copy of it.
    See Submodule/ASPIRE/NOTICE and LICENSES/evidence/SUBMODULE_AUDIT.md.

[done] third_party ready
EOF
