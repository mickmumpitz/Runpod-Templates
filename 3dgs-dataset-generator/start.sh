#!/bin/bash
set -e  # Exit the script if any statement returns a non-true return value

COMFYUI_DIR="/workspace/runpod-slim/ComfyUI"
VENV_DIR="$COMFYUI_DIR/.venv-cu128"
DB_FILE="/workspace/runpod-slim/filebrowser.db"

# ---------------------------------------------------------------------------- #
#                          Function Definitions                                  #
# ---------------------------------------------------------------------------- #

# Setup SSH with optional key or random password
setup_ssh() {
    mkdir -p ~/.ssh

    if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
        ssh-keygen -A -q
    fi

    if [[ $PUBLIC_KEY ]]; then
        echo "$PUBLIC_KEY" >> ~/.ssh/authorized_keys
        chmod 700 -R ~/.ssh
    else
        RANDOM_PASS=$(openssl rand -base64 12)
        echo "root:${RANDOM_PASS}" | chpasswd
        echo "Generated random SSH password for root: ${RANDOM_PASS}"
    fi

    echo "PermitUserEnvironment yes" >> /etc/ssh/sshd_config
    /usr/sbin/sshd
}

# Export environment variables for SSH sessions
export_env_vars() {
    echo "Exporting environment variables..."

    ENV_FILE="/etc/environment"
    PAM_ENV_FILE="/etc/security/pam_env.conf"
    SSH_ENV_DIR="/root/.ssh/environment"

    cp "$ENV_FILE" "${ENV_FILE}.bak" 2>/dev/null || true
    cp "$PAM_ENV_FILE" "${PAM_ENV_FILE}.bak" 2>/dev/null || true

    > "$ENV_FILE"
    > "$PAM_ENV_FILE"
    mkdir -p /root/.ssh
    > "$SSH_ENV_DIR"

    printenv | grep -E '^RUNPOD_|^PATH=|^_=|^CUDA|^LD_LIBRARY_PATH|^PYTHONPATH' | while read -r line; do
        name=$(echo "$line" | cut -d= -f1)
        value=$(echo "$line" | cut -d= -f2-)

        echo "$name=\"$value\"" >> "$ENV_FILE"
        echo "$name DEFAULT=\"$value\"" >> "$PAM_ENV_FILE"
        echo "$name=\"$value\"" >> "$SSH_ENV_DIR"
        echo "export $name=\"$value\"" >> /etc/rp_environment
    done

    echo 'source /etc/rp_environment' >> ~/.bashrc
    echo 'source /etc/rp_environment' >> /etc/bash.bashrc

    chmod 644 "$ENV_FILE" "$PAM_ENV_FILE"
    chmod 600 "$SSH_ENV_DIR"
}

# Start Jupyter Lab server
start_jupyter() {
    mkdir -p /workspace
    echo "Starting Jupyter Lab on port 8888..."
    nohup jupyter lab \
        --allow-root \
        --no-browser \
        --port=8888 \
        --ip=0.0.0.0 \
        --FileContentsManager.delete_to_trash=False \
        --FileContentsManager.preferred_dir=/workspace \
        --ServerApp.root_dir=/workspace \
        --ServerApp.terminado_settings='{"shell_command":["/bin/bash"]}' \
        --IdentityProvider.token="${JUPYTER_PASSWORD:-}" \
        --ServerApp.allow_origin=* &> /jupyter.log &
    echo "Jupyter Lab started"
}

# ---------------------------------------------------------------------------- #
#                               Main Program                                     #
# ---------------------------------------------------------------------------- #

# Ensure workspace directory exists before anything touches it
mkdir -p /workspace/runpod-slim

setup_ssh
export_env_vars

# Initialize FileBrowser if not already done
if [ ! -f "$DB_FILE" ]; then
    echo "Initializing FileBrowser..."
    filebrowser config init --database "$DB_FILE"
    filebrowser config set --database "$DB_FILE" --address 0.0.0.0
    filebrowser config set --database "$DB_FILE" --port 8080
    filebrowser config set --database "$DB_FILE" --root /workspace
    filebrowser config set --database "$DB_FILE" --auth.method=json
    filebrowser users add admin adminadmin12 --perm.admin --database "$DB_FILE"
else
    echo "Using existing FileBrowser configuration..."
fi

echo "Starting FileBrowser on port 8080..."
nohup filebrowser --database "$DB_FILE" &> /filebrowser.log &

start_jupyter

# Create default comfyui_args.txt if it doesn't exist
ARGS_FILE="/workspace/runpod-slim/comfyui_args.txt"
if [ ! -f "$ARGS_FILE" ]; then
    if [ -f "/opt/import/comfyui_args.txt" ]; then
        cp /opt/import/comfyui_args.txt "$ARGS_FILE"
        echo "Copied default ComfyUI arguments file"
    else
        echo "# Add your custom ComfyUI arguments here (one per line)" > "$ARGS_FILE"
        echo "Created empty ComfyUI arguments file at $ARGS_FILE"
    fi
fi

# ── Setup ComfyUI (first boot or missing venv) ───────────────────────────────
if [ ! -d "$COMFYUI_DIR" ] || [ ! -d "$VENV_DIR" ]; then
    echo "First time setup: Copying baked ComfyUI to workspace..."

    if [ ! -d "$COMFYUI_DIR" ]; then
        cp -r /opt/comfyui-baked "$COMFYUI_DIR"
        echo "ComfyUI copied to workspace"
    fi

    # Copy workflows
    if [ -d "/opt/import/workflows" ]; then
        echo "Copying workflows..."
        mkdir -p "$COMFYUI_DIR/user/default/workflows"
        cp -r /opt/import/workflows/* "$COMFYUI_DIR/user/default/workflows/"

        DEFAULT_WF=$(ls /opt/import/workflows/*.json 2>/dev/null | head -1)
        if [ -n "$DEFAULT_WF" ]; then
            mkdir -p "$COMFYUI_DIR/web/templates"
            cp "$DEFAULT_WF" "$COMFYUI_DIR/web/templates/default.json"
            echo "Default workflow set to: $(basename "$DEFAULT_WF")"
        fi
    fi

    # Download models from Hugging Face
    # Scope: the 3DGS Dataset Generator workflows —
    #   Krea2-360Pano-Creator      (default; Krea 2 + 360 ERP LoRAs, text→pano / image→pano)
    #   3DGS-Dataset-Creator SMPL  (Wan 2.1 I2V camera-plot fly-through dataset)
    #   3DGS-Dataset-Creator ADV   (premium; not shipped, but its sam3.pt is fetched so it
    #                               runs out-of-the-box once a member loads the workflow)
    echo "Downloading models from Hugging Face..."
    MODELS_BASE="$COMFYUI_DIR/models"
    mkdir -p "$MODELS_BASE/diffusion_models" \
             "$MODELS_BASE/unet" \
             "$MODELS_BASE/text_encoders" \
             "$MODELS_BASE/vae" \
             "$MODELS_BASE/clip_vision" \
             "$MODELS_BASE/loras" \
             "$MODELS_BASE/upscale_models" \
             "$MODELS_BASE/sam3"

    # filepath|url  — files are saved under the exact name (and subfolder) the
    # workflow's loader nodes reference. Download URLs come from the workflows'
    # own "Model download links" cards.
    MODELS=(
        # ── Pano creator: Krea 2 base + 360 ERP LoRAs ──────────────────────────
        "$MODELS_BASE/diffusion_models/krea2_turbo_fp8_scaled.safetensors|https://huggingface.co/Comfy-Org/Krea-2/resolve/main/diffusion_models/krea2_turbo_fp8_scaled.safetensors"
        "$MODELS_BASE/text_encoders/qwen3vl_4b_fp8_scaled.safetensors|https://huggingface.co/Comfy-Org/Krea-2/resolve/main/text_encoders/qwen3vl_4b_fp8_scaled.safetensors"
        "$MODELS_BASE/loras/krea2_t2i_360_erp_lora_v1.safetensors|https://huggingface.co/mickmumpitz/Krea2-360-ERP-LoRAs/resolve/main/krea2_t2i_360_erp_lora_v1.safetensors"
        "$MODELS_BASE/loras/krea2_oedit_360_erp_outpaint_lora_v1.safetensors|https://huggingface.co/mickmumpitz/Krea2-360-ERP-LoRAs/resolve/main/krea2_oedit_360_erp_outpaint_lora_v1.safetensors"
        "$MODELS_BASE/upscale_models/RealESRGAN_x2.pth|https://huggingface.co/ai-forever/Real-ESRGAN/resolve/main/RealESRGAN_x2.pth"
        # ── Dataset creator: Wan 2.1 I2V 720p fly-through ──────────────────────
        "$MODELS_BASE/diffusion_models/Wan2_1-I2V-14B-720P_fp8_e4m3fn.safetensors|https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1-I2V-14B-720P_fp8_e4m3fn.safetensors"
        # GGUF alternative for <=16GB VRAM (UnetLoaderGGUF reads from /unet)
        "$MODELS_BASE/unet/wan2.1-i2v-14b-720p-Q4_K_M.gguf|https://huggingface.co/city96/Wan2.1-I2V-14B-720P-gguf/resolve/main/wan2.1-i2v-14b-720p-Q4_K_M.gguf"
        "$MODELS_BASE/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors|https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"
        "$MODELS_BASE/clip_vision/clip_vision_h.safetensors|https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors"
        "$MODELS_BASE/loras/pano_video_gen_720p_comfy.safetensors|https://huggingface.co/mickmumpitz/Wan2.1-Pano360-LoRA/resolve/main/pano_video_gen_720p_comfy.safetensors"
        "$MODELS_BASE/loras/lightx2v_T2V_14B_cfg_step_distill_v2_lora_rank64_bf16.safetensors|https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Lightx2v/lightx2v_T2V_14B_cfg_step_distill_v2_lora_rank64_bf16.safetensors"
        "$MODELS_BASE/upscale_models/4x-UltraSharp.pth|https://huggingface.co/Kim2091/UltraSharp/resolve/main/4x-UltraSharp.pth"
        # ── Shared: Wan 2.1 VAE (both workflows) ───────────────────────────────
        "$MODELS_BASE/vae/wan_2.1_vae.safetensors|https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors"
        # ── ADV (premium) workflow only: SAM3 segmenter (ComfyUI-RMBG SAM3Segment) ──
        "$MODELS_BASE/sam3/sam3.pt|https://huggingface.co/1038lab/sam3/resolve/main/sam3.pt"
    )

    # ── Fast, resumable, logged downloads ─────────────────────────────────────
    # Why this shape:
    #   * aria2c (multi-connection + resumable) is much faster and more reliable than
    #     a single wget stream against Hugging Face; installed best-effort if missing.
    #   * Only a few files download at once. Firing all of them at once floods HF with
    #     parallel connections that get throttled/dropped, and leaves no progress in the log.
    #   * Every file resumes (-c / --continue), so re-running this pod finishes a
    #     partial file instead of skipping it. Each file logs start, done, and size.
    #   * A heartbeat prints the growing models-dir size so the boot never looks frozen.

    # Best-effort: pull in aria2 if it isn't already on the image (one-time, first boot)
    if ! command -v aria2c >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1 && \
            apt-get install -y -qq --no-install-recommends aria2 >/dev/null 2>&1 || true
    fi

    MIN_BYTES=1048576          # smaller than this => treat as a failed/partial stub
    FAIL_LOG="$(mktemp)"

    download_model() {
        local filepath="$1" url="$2"
        local name dir rc size
        name="$(basename "$filepath")"
        dir="$(dirname "$filepath")"
        if command -v aria2c >/dev/null 2>&1; then
            if aria2c -c -x8 -s8 -k1M --max-tries=5 --retry-wait=10 \
                      --console-log-level=error --summary-interval=0 \
                      -d "$dir" -o "$name" "$url" >/dev/null 2>&1; then rc=0; else rc=$?; fi
        else
            if wget -q --continue --tries=5 --timeout=60 --waitretry=10 \
                    -O "$filepath" "$url"; then rc=0; else rc=$?; fi
        fi
        size=$(stat -c%s "$filepath" 2>/dev/null || echo 0)
        if [ "$rc" -eq 0 ] && [ "$size" -ge "$MIN_BYTES" ]; then
            echo "  done: $name ($(numfmt --to=iec "$size" 2>/dev/null || echo "${size}B"))"
        else
            echo "  FAILED: $name (rc=$rc, ${size}B)"
            echo "$name" >> "$FAIL_LOG"
        fi
    }

    # Heartbeat: print total downloaded size every 30s so the quiet phase shows progress
    ( while true; do
          sleep 30
          echo "  ...downloading — models dir now $(du -sh "$MODELS_BASE" 2>/dev/null | cut -f1)"
      done ) &
    HEARTBEAT_PID=$!

    MAX_PARALLEL=3
    DL_PIDS=()
    for model in "${MODELS[@]}"; do
        IFS='|' read -r filepath url <<< "$model"
        # Throttle: keep at most MAX_PARALLEL downloads running (+1 for the heartbeat)
        while [ "$(jobs -rp | wc -l)" -ge "$((MAX_PARALLEL + 1))" ]; do
            wait -n 2>/dev/null || true
        done
        echo "Downloading $(basename "$filepath")..."
        download_model "$filepath" "$url" &
        DL_PIDS+=($!)
    done

    # Wait only for the download jobs, then stop the heartbeat
    for pid in "${DL_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    kill "$HEARTBEAT_PID" 2>/dev/null || true

    if [ -s "$FAIL_LOG" ]; then
        echo "WARNING: the following model download(s) failed or are incomplete:"
        sed 's/^/    - /' "$FAIL_LOG"
        echo "Restart the container to resume them — downloads continue where they left off."
    else
        echo "All model downloads completed ($(du -sh "$MODELS_BASE" 2>/dev/null | cut -f1) total)."
    fi
    rm -f "$FAIL_LOG"

    # Create venv with system site-packages (torch, numpy, etc. pre-installed in image)
    if [ ! -d "$VENV_DIR" ]; then
        cd "$COMFYUI_DIR"
        python3.12 -m venv --system-site-packages "$VENV_DIR"
        source "$VENV_DIR/bin/activate"
        python -m ensurepip
        echo "ComfyUI ready — all dependencies pre-installed in image"
    fi
else
    source "$VENV_DIR/bin/activate"
    echo "Using existing ComfyUI installation"
fi

# ── Build SageAttention on first boot (requires GPU) ─────────────────────────
SAGE_FAILED_MARKER="/workspace/.sage_build_failed"
if ! python -c "import sageattention" 2>/dev/null && [ ! -f "$SAGE_FAILED_MARKER" ]; then
    echo "Building SageAttention from source..."
    GPU_COMPUTE_CAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1)
    echo "Detected GPU compute capability: $GPU_COMPUTE_CAP"

    # Build v2 from source in a subshell to isolate env changes (CUDA_HOME, PATH, cwd)
    # Always include 8.0: SageAttention's _qattn_sm80 base extension needs sm80
    # gencode even on newer GPUs (its CUDA sources use SM80 intrinsics)
    (
        if [ "$GPU_COMPUTE_CAP" = "8.0" ]; then
            export TORCH_CUDA_ARCH_LIST="8.0"
        else
            export TORCH_CUDA_ARCH_LIST="8.0;$GPU_COMPUTE_CAP"
        fi
        export CUDA_HOME=/usr/local/cuda-12.8
        export PATH=$CUDA_HOME/bin:$PATH
        cd /tmp
        rm -rf SageAttention
        git clone https://github.com/thu-ml/SageAttention.git
        cd SageAttention
        EXT_PARALLEL=4 NVCC_APPEND_FLAGS="--threads 8" MAX_JOBS=32 python setup.py install
    )
    SAGE_BUILD_RC=$?
    rm -rf /tmp/SageAttention
    if [ $SAGE_BUILD_RC -ne 0 ]; then
        echo "WARNING: SageAttention source build failed."
    else
        echo "SageAttention built from source"
    fi

    # Verify the install actually works
    if ! python -c "import sageattention" 2>/dev/null; then
        echo "WARNING: SageAttention is not importable. Continuing without it."
        touch "$SAGE_FAILED_MARKER"
    else
        echo "SageAttention verified working"
    fi
else
    echo "SageAttention already installed (or build previously failed), skipping..."
fi

# Warm up pip so ComfyUI-Manager's 5s timeout check doesn't fail on cold start
python -m pip --version > /dev/null 2>&1

# ── Start ComfyUI — keep container alive if it crashes ────────────────────────
cd "$COMFYUI_DIR"
FIXED_ARGS="--listen 0.0.0.0 --port 8188"
if [ -s "$ARGS_FILE" ]; then
    CUSTOM_ARGS=$(grep -v '^#' "$ARGS_FILE" | tr '\n' ' ')
    if [ ! -z "$CUSTOM_ARGS" ]; then
        FIXED_ARGS="$FIXED_ARGS $CUSTOM_ARGS"
    fi
fi

# Auto-add --use-sage-attention if sageattention is available and not already in args
if python -c "import sageattention" 2>/dev/null; then
    case "$FIXED_ARGS" in
        *--use-sage-attention*) ;;
        *) FIXED_ARGS="$FIXED_ARGS --use-sage-attention" ;;
    esac
else
    # Strip --use-sage-attention if present but package unavailable
    FIXED_ARGS=$(echo "$FIXED_ARGS" | sed 's/--use-sage-attention//g' | tr -s ' ')
fi

echo "Starting ComfyUI with args: $FIXED_ARGS"
python main.py $FIXED_ARGS &
COMFY_PID=$!
trap "kill $COMFY_PID 2>/dev/null" SIGTERM SIGINT
wait $COMFY_PID || true

echo "============================================="
echo "  ComfyUI crashed — check the logs above."
echo "  SSH and JupyterLab are still available."
echo "  To restart after fixing:"
echo "    cd $COMFYUI_DIR && source .venv-cu128/bin/activate"
echo "    python main.py $FIXED_ARGS"
echo "============================================="

sleep infinity
