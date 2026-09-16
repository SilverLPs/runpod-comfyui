# Native TRELLIS.2 + Pixal3D on RunPod (Fresh PyTorch Image)

**Status:** September 16, 2026 · **Script:** `install_native_3d_runpod_pytorch.sh` · **ComfyUI:** pinned to `v0.36.0`.

This setup explicitly targets a **new, disposable/immutable RunPod instance**. It installs ComfyUI and the native TRELLIS.2/Pixal3D nodes once, then starts the web server. It does **not** migrate or back up an existing installation, install legacy custom nodes, or apply compatibility patches. Recreate the instance when switching to a new script version.

## 1. RunPod template

Use the official **PyTorch 2.8/CUDA 12.8.1 image** with Python 3.12:

```text
runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404
```

Choose an RTX 4090 or a GPU with a comparable amount of VRAM. At startup, the script checks the **versions that are actually installed**: Python 3.12, PyTorch 2.8.0, the CUDA 12.8 PyTorch build, cuDNN, and an accessible CUDA GPU. It does not silently modify an incorrectly labeled image.

Expose **HTTP port 8188** in the RunPod template. Also expose port 8888 if you need JupyterLab. Allow enough storage for the models: approximately 25–35 GB of free space in addition to the image. Model variants and download caches can increase this requirement. Generated files are written to `/workspace/ComfyUI/output/`.

ComfyUI 0.36.0 supports Python 3.10 or newer and does not require a newer PyTorch release in its `requirements.txt`. A Linux Python 3.12+ wheel is available for `comfy-kitchen==0.2.34`. A custom Docker image is therefore not required for native TRELLIS.2/Pixal3D support.

The complete setup was tested successfully on September 16, 2026, using the specified image and an RTX 4090. A fresh installation, all model downloads, ComfyUI startup, and both branches of the official workflow completed successfully. Pixal3D and TRELLIS.2 each produced a textured GLB file.

## 2. Installation

Add `install_native_3d_runpod_pytorch.sh` to your GitHub repository. Replace `YOUR-USER/YOUR-REPOSITORY` in the following example with the actual repository path:

```bash
cd /workspace
curl -fsSL \
  https://raw.githubusercontent.com/YOUR-USER/YOUR-REPOSITORY/main/install_native_3d_runpod_pytorch.sh \
  -o install_native_3d_runpod_pytorch.sh

# For versioned installations, preferably point the URL to a Git tag or a
# complete commit SHA instead of the main branch.
less install_native_3d_runpod_pytorch.sh
chmod +x install_native_3d_runpod_pytorch.sh
./install_native_3d_runpod_pytorch.sh
```

After installation, ComfyUI starts **in the foreground on port 8188 by default**. Open the RunPod HTTP proxy for port 8188. The process only remains active while the terminal session or its supervising process is running. To start it automatically on each fresh instance, integrate the same script into your startup mechanism.

If you use RunPod's official container startup script, its `/post_start.sh` hook runs after the Jupyter/SSH setup. A suitable `/post_start.sh` can download the versioned GitHub file to `/workspace` and run it with `exec bash /workspace/install_native_3d_runpod_pytorch.sh`. Verify that the selected template actually supports this hook because RunPod templates do not all use the same entrypoint. Alternatively, configure the script as the template's startup command if the template supports that option.

To install without starting the server immediately:

```bash
START_COMFYUI=0 ./install_native_3d_runpod_pytorch.sh

# Start it later:
cd /workspace/ComfyUI
./.venv/bin/python main.py --listen 0.0.0.0 --port 8188 --enable-cors-header
```

**Important:** The script intentionally rejects an existing `/workspace/ComfyUI` directory. Reset the pod or use a fresh instance when installing a new version.

## 3. Installed components

- ComfyUI `v0.36.0` from the official Git release. The script verifies the version against `pyproject.toml`.
- A virtual Python environment at `/workspace/ComfyUI/.venv`, created with `--system-site-packages` so it reuses the PyTorch installation provided by RunPod. The installed PyTorch packages are constrained for `pip`; the script does not install separate PyTorch/CUDA wheels.
- Dependencies from ComfyUI's `requirements.txt`, including SciPy and the corresponding ComfyUI frontend components.
- Native Comfy-Org models (**INT8** by default):

| Model/helper | Path below `/workspace/ComfyUI/models/` |
|---|---|
| TRELLIS.2 INT8 | `diffusion_models/trellis_2_int8_convrot.safetensors` |
| Pixal3D INT8 | `diffusion_models/pixal3d_int8_convrot.safetensors` |
| TRELLIS.2 DINOv3 | `clip_vision/dino_v3_vit_l.safetensors` |
| Pixal3D DINOv3 | `clip_vision/dino_v3_L_naf_fp32.safetensors` |
| Shape VAE | `vae/trellis_2_shape_vae_bf16.safetensors` |
| Texture VAE | `vae/trellis_2_texture_vae_bf16.safetensors` |
| BiRefNet (background removal) | `background_removal/birefnet.safetensors` |
| MoGe (geometry/camera) | `geometry_estimation/moge_2_vitl_normal_fp16.safetensors` |

The models are downloaded directly from public `Comfy-Org` repositories with `huggingface_hub.snapshot_download`. **No Hugging Face login is expected for these public repositories.** Set `INCLUDE_MULTIVIEW=1` to also download `diffusion_models/pixal3d_multiview_int8_convrot.safetensors`; this model requires a suitable multiview workflow.

The combined official workflow is loaded from template tag `v0.11.62`, which matches the pinned ComfyUI release, and is saved to two locations:

```text
/workspace/ComfyUI/user/native3d-examples/3d_pixal3d_trellis2_image_to_model.json
/workspace/ComfyUI/user/default/workflows/3d_pixal3d_trellis2_image_to_model.json
```

Drag the JSON file into the ComfyUI interface, select a test image, and start with the INT8 models. **A running UI and successful import checks do not replace a successful full 3D generation test.**

## 4. Options and reproducibility

```bash
# Install only Python/ComfyUI and skip the models for development:
SKIP_MODELS=1 START_COMFYUI=0 ./install_native_3d_runpod_pytorch.sh

# Also download the Pixal3D multiview model:
INCLUDE_MULTIVIEW=1 ./install_native_3d_runpod_pytorch.sh

# Use another ComfyUI destination that does not exist yet:
COMFY_ROOT=/workspace/ComfyUI-3D ./install_native_3d_runpod_pytorch.sh

# Use another explicit ComfyUI release after testing compatibility:
COMFY_REF=v0.36.0 ./install_native_3d_runpod_pytorch.sh
```

The ComfyUI version and workflow template are pinned. The exact model commit SHAs used during the download are recorded in `models/.native3d-model-revisions.json`. By default, the Hugging Face repositories are loaded from `main`. For **strictly reproducible** installations, pin the commit SHA of each of the four model repositories with environment variables:

```bash
HF_REV_TRELLIS=<COMMIT_SHA> \
HF_REV_PIXAL=<COMMIT_SHA> \
HF_REV_BIREFNET=<COMMIT_SHA> \
HF_REV_MOGE=<COMMIT_SHA> \
./install_native_3d_runpod_pytorch.sh
```

For a fully reproducible build, also pin the RunPod Docker image by **digest** instead of tag alone. The script does not install dynamically discovered GitHub custom nodes.

## 5. Limitations and troubleshooting

- **The PyTorch check fails:** The image label does not match the installed runtime, or the GPU/driver is not configured correctly. Check it inside the container with `python -c 'import torch; print(torch.__version__, torch.version.cuda, torch.cuda.is_available())'`. The script does not automatically replace PyTorch.
- **`comfy-kitchen` prints a CUDA 13 optimization warning:** The CUDA 12.8 image uses its eager fallback because the newest optimized kernels require CUDA 13. The tested INT8 Pixal3D and TRELLIS.2 workflows still complete successfully, but a matching future CUDA 13 image may be faster. Do not replace only PyTorch inside this image; switch the complete base image after testing it.
- **`pip` cannot find a compatible build:** The requirements of the selected ComfyUI release may have changed. On a fresh image, deliberately change the base image or ComfyUI release instead of blindly downgrading PyTorch.
- **A download fails:** Check the available disk space and access to Hugging Face. With the immutable-instance approach, reset the pod and retry.
- **Out of memory on a 24 GB GPU:** Start with INT8 and reduce the resolution and mesh post-processing settings. A complete PBR/remeshing workflow can require considerably more memory than model inference alone.
- **ComfyUI is not available in the browser:** Expose RunPod HTTP port 8188. The PyTorch container does not start ComfyUI automatically; this setup starts it only after installation finishes.

## Repository safety

This repository is intended to be public. Local instance metadata, environment files, credentials, private keys, generated output, downloaded model weights, caches, and editor-specific state are excluded by `.gitignore`. Review staged changes before every push and never add credentials with `git add --force`.

## Official sources

- [Native TRELLIS.2 and Pixal3D in ComfyUI](https://blog.comfy.org/p/trellis2-and-pixal3d-are-now-native)
- [ComfyUI v0.36.0](https://github.com/Comfy-Org/ComfyUI/releases/tag/v0.36.0)
- [ComfyUI v0.36.0 requirements](https://raw.githubusercontent.com/Comfy-Org/ComfyUI/v0.36.0/requirements.txt)
- [RunPod PyTorch 2.8/CUDA 12.8](https://www.runpod.io/articles/guides/pytorch-2-8-cuda-12-8)
- [RunPod PyTorch Docker tag](https://hub.docker.com/layers/runpod/pytorch/1.0.2-cu1281-torch280-ubuntu2404/images/sha256-4d1721e62b56d345c83b4fd6090664be6daf9312caab5b2e76f23d8231941851)
- [Official 3D workflow v0.11.62](https://raw.githubusercontent.com/Comfy-Org/workflow_templates/v0.11.62/templates/3d_pixal3d_trellis2_image_to_model.json)
- [TRELLIS.2 models](https://huggingface.co/Comfy-Org/TRELLIS.2) · [Pixal3D models](https://huggingface.co/Comfy-Org/Pixal3D) · [BiRefNet](https://huggingface.co/Comfy-Org/BiRefNet) · [MoGe](https://huggingface.co/Comfy-Org/MoGe)
