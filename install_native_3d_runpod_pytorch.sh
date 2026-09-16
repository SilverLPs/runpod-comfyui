#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# Native TRELLIS.2 + Pixal3D on a FRESH RunPod PyTorch image (one-shot setup)
# =============================================================================
# Suggested base image:
#   runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04
# Verified ComfyUI release for this script: v0.36.0 (2026-09-16).
# Official native implementation: https://blog.comfy.org/p/trellis2-and-pixal3d-are-now-native
#
# IMPORTANT: This script assumes a fresh, disposable pod. It deliberately DOES
# NOT migrate or remove existing ComfyUI installations. It fails when COMFY_ROOT
# already exists. No SimpleTrellis2, hand-built CUDA wheels or compatibility
# patches are installed. The RunPod image supplies torch / CUDA / cuDNN.
#
# Options:
#   COMFY_ROOT=/workspace/ComfyUI     # destination; must not exist
#   COMFY_REF=v0.36.0                 # immutable ComfyUI release tag
#   BASE_PYTHON=python                # Python interpreter in RunPod image
#   START_COMFYUI=1                   # launch server after setup (default)
#   SKIP_MODELS=1                     # development only: skip model downloads
#   INCLUDE_MULTIVIEW=1              # additionally download Pixal3D MV INT8
#   PORT=8188                         # HTTP port; expose it in RunPod template
#   HF_REV_TRELLIS=main               # optional model repo revision pins
#   HF_REV_PIXAL=main
#   HF_REV_BIREFNET=main
#   HF_REV_MOGE=main
#
# Security: inspect this script before running code from your GitHub repository;
# do not pipe an unreviewed remote shell script directly into bash.
# =============================================================================

COMFY_ROOT="${COMFY_ROOT:-/workspace/ComfyUI}"
COMFY_REF="${COMFY_REF:-v0.36.0}"
BASE_PYTHON="${BASE_PYTHON:-python}"
START_COMFYUI="${START_COMFYUI:-1}"
SKIP_MODELS="${SKIP_MODELS:-0}"
INCLUDE_MULTIVIEW="${INCLUDE_MULTIVIEW:-0}"
PORT="${PORT:-8188}"
HF_REV_TRELLIS="${HF_REV_TRELLIS:-main}"
HF_REV_PIXAL="${HF_REV_PIXAL:-main}"
HF_REV_BIREFNET="${HF_REV_BIREFNET:-main}"
HF_REV_MOGE="${HF_REV_MOGE:-main}"

VENV="$COMFY_ROOT/.venv"
PYTHON="$VENV/bin/python"
WORKFLOW_REL='3d_pixal3d_trellis2_image_to_model.json'
WORKFLOW_URL='https://raw.githubusercontent.com/Comfy-Org/workflow_templates/v0.11.62/templates/3d_pixal3d_trellis2_image_to_model.json'

log()  { printf '\n[native-3d] %s\n' "$*"; }
warn() { printf '\n[native-3d WARNING] %s\n' "$*" >&2; }
die()  { printf '\n[native-3d ERROR] %s\n' "$*" >&2; exit 1; }
on_error() {
    local result="$?"
    printf '\n[native-3d ERROR] Exit %s on line %s. This is a disposable setup; reset the pod and inspect the error above.\n' \
        "$result" "$1" >&2
    exit "$result"
}
trap 'on_error "$LINENO"' ERR

[[ "$COMFY_REF" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'COMFY_REF must be a release tag, e.g. v0.36.0.'
[[ "$START_COMFYUI" =~ ^[01]$ && "$SKIP_MODELS" =~ ^[01]$ && "$INCLUDE_MULTIVIEW" =~ ^[01]$ ]] \
    || die 'START_COMFYUI, SKIP_MODELS and INCLUDE_MULTIVIEW must be 0 or 1.'
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die 'PORT must be between 1 and 65535.'
[[ ! -e "$COMFY_ROOT" && ! -L "$COMFY_ROOT" ]] || die "Destination already exists: $COMFY_ROOT. Reset this immutable pod or choose a fresh COMFY_ROOT."
command -v "$BASE_PYTHON" >/dev/null || die "Base Python not found: $BASE_PYTHON"

# RunPod's PyTorch image is PYTHON 3.11. Do NOT reuse paths/venvs from the
# official RunPod ComfyUI image (which used Python 3.12 + .venv-cu128).
log 'Checking actual RunPod Python, PyTorch, CUDA and cuDNN (not the image label)'
"$BASE_PYTHON" - <<'PY'
import sys
import torch
assert sys.version_info[:2] == (3, 11), (
    f"Expected Python 3.11 on the specified RunPod image; found {sys.version.split()[0]}"
)
assert torch.__version__.split('+', 1)[0] == '2.8.0', (
    f"Expected torch 2.8.0 but found {torch.__version__}; some RunPod tags historically shipped another build."
)
assert torch.version.cuda and torch.version.cuda.startswith('12.8'), (
    f"Expected CUDA 12.8 torch build; found {torch.version.cuda}"
)
assert torch.cuda.is_available(), 'No CUDA GPU is visible. Check RunPod GPU/driver configuration.'
assert torch.backends.cudnn.version() is not None, 'cuDNN is missing.'
print('Python:', sys.version.split()[0])
print('PyTorch:', torch.__version__)
print('CUDA:', torch.version.cuda)
print('cuDNN:', torch.backends.cudnn.version())
print('GPU:', torch.cuda.get_device_name(0))
PY

if (( EUID != 0 )); then
    die 'The fresh-image setup installs Ubuntu system packages. Run it as root (the default in RunPod PyTorch images).'
fi

log 'Installing essential Linux system packages for Git, OpenGL and 3D processing'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    git curl ca-certificates libgl1 libopengl0 libegl1 libglib2.0-0 libgomp1

# ComfyUI v0.36.0 requires Python >=3.10, NOT Python 3.12.  Its requirements
# list torch without requiring a newer build, and native 3D avoids separate
# native CUDA extension wheels. Use RunPod's installed PyTorch in the venv.
log "Cloning immutable ComfyUI release $COMFY_REF"
mkdir -p "$(dirname "$COMFY_ROOT")"
git clone --depth 1 --branch "$COMFY_REF" \
    https://github.com/Comfy-Org/ComfyUI.git "$COMFY_ROOT"

# Strict version guard, so a renamed/moved git tag cannot silently change the
# installed core. Python script reads the version from pyproject.toml.
"$BASE_PYTHON" - "$COMFY_ROOT/pyproject.toml" "$COMFY_REF" <<'PY'
import pathlib, sys, tomllib
actual = tomllib.loads(pathlib.Path(sys.argv[1]).read_text())['project']['version']
expected = sys.argv[2].removeprefix('v')
assert actual == expected, f'ComfyUI checkout version {actual}, expected {expected}'
print('ComfyUI version:', actual)
PY

log 'Creating isolated ComfyUI venv with access to the image-provided PyTorch'
"$BASE_PYTHON" -m venv --system-site-packages "$VENV" || die \
    'Cannot create venv. Check whether the selected image has python3.11-venv / ensurepip.'
"$PYTHON" -m pip --version >/dev/null || die 'pip is not available in the ComfyUI venv.'

# Pin the *installed* Torch family in pip resolution. Otherwise a future
# transitive requirement may overwrite the preinstalled CUDA build. Using
# --system-site-packages avoids re-downloading its multi-GB CUDA libraries.
log 'Locking RunPod Torch packages and installing ComfyUI dependencies'
CONSTRAINTS="$COMFY_ROOT/.runpod-torch-constraints.txt"
"$BASE_PYTHON" - "$CONSTRAINTS" <<'PY'
import importlib.metadata as md
import pathlib, sys
constraints = []
for name in ('torch', 'torchvision', 'torchaudio'):
    try:
        version = md.version(name)
    except md.PackageNotFoundError:
        if name == 'torch':
            raise SystemExit('The base image has no PyTorch installed.')
    else:
        constraints.append(f'{name}=={version}')
pathlib.Path(sys.argv[1]).write_text('\n'.join(constraints) + '\n')
print('PyTorch constraints:', ', '.join(constraints))
PY
unset PIP_CONSTRAINT || true
"$PYTHON" -m pip install --constraint "$CONSTRAINTS" \
    -r "$COMFY_ROOT/requirements.txt" \
    'huggingface_hub>=0.34,<2'

# Confirm that pip did not overlay the base image's Torch. Check origin as well
# as version: a separately installed torch could pass a simple version check.
BASE_TORCH_FILE="$("$BASE_PYTHON" -c 'import torch; print(torch.__file__)')"
export BASE_TORCH_FILE
"$PYTHON" - <<'PY'
import os, pathlib
import torch, scipy, safetensors
import comfy_kitchen
import comfy_aimdo
assert torch.__version__.split('+', 1)[0] == '2.8.0', torch.__version__
assert torch.version.cuda and torch.version.cuda.startswith('12.8'), torch.version.cuda
assert torch.cuda.is_available()
assert pathlib.Path(torch.__file__).resolve() == pathlib.Path(os.environ['BASE_TORCH_FILE']).resolve(), (
    'pip installed another Torch into the venv; expected to reuse RunPod base Torch.'
)
print('ComfyUI environment OK:', torch.__version__, 'CUDA', torch.version.cuda, 'SciPy', scipy.__version__)
PY

# Fail clearly if a release no longer bundles the native 3D implementation.
log 'Checking native TRELLIS.2 / Pixal3D source nodes'
grep -Rqs 'Trellis2ShapeStage' "$COMFY_ROOT/comfy_extras" \
    || die 'Native Trellis2ShapeStage not found in ComfyUI core.'
grep -Rqs 'Pixal3D' "$COMFY_ROOT/comfy_extras" "$COMFY_ROOT/comfy" \
    || die 'Native Pixal3D source not found in ComfyUI core.'

# Download the fixed-version official template, not a potentially changing
# workflow from the default branch. The template models match the filenames
# below. It is normal for the template's sample input image to need replacing.
log 'Downloading official combined TRELLIS.2 / Pixal3D example workflow'
mkdir -p "$COMFY_ROOT/user/default/workflows" "$COMFY_ROOT/user/native3d-examples"
WORKFLOW="$COMFY_ROOT/user/native3d-examples/$WORKFLOW_REL"
curl --fail --location --show-error --retry 3 "$WORKFLOW_URL" -o "$WORKFLOW"
"$PYTHON" - "$WORKFLOW" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
wf = json.loads(p.read_text())
types = {node.get('type') for node in wf.get('nodes', [])}
assert 'Trellis2ShapeStage' in types, 'Downloaded file is not the intended native 3D workflow.'
print('Verified workflow:', p)
PY
# Normal ComfyUI user workflow directory, for convenient browser discovery.
cp "$WORKFLOW" "$COMFY_ROOT/user/default/workflows/$WORKFLOW_REL"

if [[ "$SKIP_MODELS" == 1 ]]; then
    warn 'SKIP_MODELS=1: the UI can start, but 3D generation needs the model downloads.'
else
    # snapshot_download() keeps the original repository directory layout when
    # local_dir=.../models. We download only explicitly needed INT8 weights,
    # shared VAEs and helpers. No gated BRIA model or old Microsoft checkpoints.
    log 'Downloading Comfy-Org INT8 TRELLIS.2 + Pixal3D and public helper models'
    export COMFY_MODEL_DIR="$COMFY_ROOT/models"
    export HF_REV_TRELLIS HF_REV_PIXAL HF_REV_BIREFNET HF_REV_MOGE INCLUDE_MULTIVIEW
    "$PYTHON" - <<'PY'
import json
import os
from pathlib import Path
from huggingface_hub import HfApi, snapshot_download

root = Path(os.environ['COMFY_MODEL_DIR'])
root.mkdir(parents=True, exist_ok=True)

jobs = [
    ('Comfy-Org/TRELLIS.2', os.environ['HF_REV_TRELLIS'], [
        'diffusion_models/trellis_2_int8_convrot.safetensors',
        'clip_vision/dino_v3_vit_l.safetensors',
        'vae/trellis_2_shape_vae_bf16.safetensors',
        'vae/trellis_2_texture_vae_bf16.safetensors',
    ]),
    ('Comfy-Org/Pixal3D', os.environ['HF_REV_PIXAL'], [
        'diffusion_models/pixal3d_int8_convrot.safetensors',
        'clip_vision/dino_v3_L_naf_fp32.safetensors',
    ]),
    ('Comfy-Org/BiRefNet', os.environ['HF_REV_BIREFNET'], [
        'background_removal/birefnet.safetensors',
    ]),
    ('Comfy-Org/MoGe', os.environ['HF_REV_MOGE'], [
        'geometry_estimation/moge_2_vitl_normal_fp16.safetensors',
    ]),
]
if os.environ['INCLUDE_MULTIVIEW'] == '1':
    jobs[1][2].append('diffusion_models/pixal3d_multiview_int8_convrot.safetensors')

resolved = {}
api = HfApi()
for repo, revision, paths in jobs:
    # Resolve moving names such as "main" once. Record the exact commit to make
    # this one-shot install auditable even if the upstream model later changes.
    sha = api.model_info(repo_id=repo, revision=revision).sha
    print(f'[native-3d] {repo}@{revision} -> {sha}: {len(paths)} file(s)', flush=True)
    snapshot_download(
        repo_id=repo,
        revision=sha,
        allow_patterns=paths,
        local_dir=str(root),
        max_workers=4,
    )
    for rel in paths:
        file = root / rel
        # Reject absent/empty files and Git LFS pointer placeholders; these
        # checkpoints are much larger than 1 MB.
        assert file.is_file() and file.stat().st_size > 1_000_000, (
            f'Model missing or incomplete: {file}'
        )
        print(f'  OK: {rel} ({file.stat().st_size / 1e9:.2f} GB)', flush=True)
    resolved[repo] = {'requested_revision': revision, 'commit': sha, 'files': paths}

manifest = root / '.native3d-model-revisions.json'
manifest.write_text(json.dumps(resolved, indent=2, ensure_ascii=False) + '\n')
print(f'[native-3d] Exact model revisions saved: {manifest}', flush=True)
PY
fi

log 'Setup complete: native ComfyUI + TRELLIS.2 + Pixal3D'
log "ComfyUI root: $COMFY_ROOT"
log "Workflow: $WORKFLOW"
log 'Use the INT8 diffusion models first on an RTX 4090 (24 GB VRAM).'

# The RunPod PyTorch image does NOT have a built-in ComfyUI service. By default
# run it in the foreground so an image startup command or /post_start.sh can
# supervise the process. START_COMFYUI=0 leaves only an installed filesystem.
if [[ "$START_COMFYUI" == 1 ]]; then
    log "Starting ComfyUI on 0.0.0.0:$PORT (RunPod template must expose HTTP port $PORT)"
    cd "$COMFY_ROOT"
    exec "$PYTHON" main.py --listen 0.0.0.0 --port "$PORT" --enable-cors-header
else
    log "Start manually: cd '$COMFY_ROOT' && '$PYTHON' main.py --listen 0.0.0.0 --port '$PORT' --enable-cors-header"
fi
