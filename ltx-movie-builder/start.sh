#!/bin/bash
set -e  # Exit the script if any statement returns a non-true return value

COMFYUI_DIR="/workspace/runpod-slim/ComfyUI"
VENV_DIR="$COMFYUI_DIR/.venv-cu128"
OLD_VENV_DIR="$COMFYUI_DIR/.venv"
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

# ── Migrate old CUDA 12.4 venv to cu128 ──────────────────────────────────────
if [ -d "$OLD_VENV_DIR" ] && [ ! -d "$VENV_DIR" ]; then
    NODE_COUNT=$(find "$COMFYUI_DIR/custom_nodes" -maxdepth 2 -name "requirements.txt" 2>/dev/null | wc -l)
    echo "============================================="
    echo "  CUDA 12.4 -> 12.8 migration"
    echo "  Reinstalling deps for $NODE_COUNT custom nodes"
    echo "  This may take several minutes"
    echo "============================================="
    mv "$OLD_VENV_DIR" "${OLD_VENV_DIR}.bak"
    cd "$COMFYUI_DIR"
    python3.12 -m venv --system-site-packages "$VENV_DIR"
    source "$VENV_DIR/bin/activate"
    python -m ensurepip
    # Skip nodes baked into the image — their deps are in system site-packages
    BAKED_NODES="ComfyUI-Manager ComfyUI-KJNodes Civicomfy ComfyUI-RunpodDirect rgthree-comfy ComfyUI-VideoHelperSuite ComfyUI-Easy-Use ComfyUI-Mickmumpitz-Nodes RES4LYF ComfyUI-AutoCropFaces ComfyUI-Olm-DragCrop"
    CURRENT=0
    INSTALLED=0
    for req in "$COMFYUI_DIR"/custom_nodes/*/requirements.txt; do
        if [ -f "$req" ]; then
            NODE_NAME=$(basename "$(dirname "$req")")
            case " $BAKED_NODES " in
                *" $NODE_NAME "*) continue ;;
            esac
            CURRENT=$((CURRENT + 1))
            echo "[$CURRENT] $NODE_NAME"
            pip install -r "$req" 2>&1 | grep -E "^(Successfully|ERROR)" || true
            INSTALLED=$((INSTALLED + 1))
        fi
    done
    echo "Upgrading ComfyUI requirements..."
    pip install --upgrade -r "$COMFYUI_DIR/requirements.txt" 2>&1 | grep -E "^(Successfully|ERROR)" || true
    echo "Migration complete — $INSTALLED user nodes processed (${NODE_COUNT} total, baked nodes skipped)"
    echo "Old venv backed up at ${OLD_VENV_DIR}.bak — delete it to free space:"
    echo "  rm -rf ${OLD_VENV_DIR}.bak"
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
    echo "Downloading models from Hugging Face..."
    MODELS_BASE="$COMFYUI_DIR/models"
    mkdir -p "$MODELS_BASE/diffusion_models" \
             "$MODELS_BASE/text_encoders" \
             "$MODELS_BASE/vae" \
             "$MODELS_BASE/loras" \
             "$MODELS_BASE/latent_upscale_models"

    # Note: flux-2-klein-9b-fp8.safetensors is intentionally NOT downloaded here.
    MODELS=(
        "$MODELS_BASE/loras/Flux2-Klein-9B-consistency-V2.safetensors|https://huggingface.co/dx8152/Flux2-Klein-9B-Consistency/resolve/main/Flux2-Klein-9B-consistency-V2.safetensors"
        "$MODELS_BASE/loras/flux-2-klein-9B-360-erp-outpaint-lora_V1.safetensors|https://huggingface.co/nomadoor/flux-2-klein-9B-360-erp-outpaint-lora/resolve/main/flux-2-klein-9B-360-erp-outpaint-lora_V1.safetensors"
        "$MODELS_BASE/text_encoders/qwen_3_8b_fp8mixed.safetensors|https://huggingface.co/Comfy-Org/vae-text-encorder-for-flux-klein-9b/resolve/main/split_files/text_encoders/qwen_3_8b_fp8mixed.safetensors"
        "$MODELS_BASE/vae/flux2-vae.safetensors|https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/vae/flux2-vae.safetensors"
        "$MODELS_BASE/diffusion_models/ltx-2.3-22b-dev_transformer_only_fp8_scaled.safetensors|https://huggingface.co/Kijai/LTX2.3_comfy/resolve/main/diffusion_models/ltx-2.3-22b-dev_transformer_only_fp8_scaled.safetensors"
        "$MODELS_BASE/loras/ltx-2.3-22b-distilled-lora-384-1.1.safetensors|https://huggingface.co/Lightricks/LTX-2.3/resolve/main/ltx-2.3-22b-distilled-lora-384-1.1.safetensors"
        "$MODELS_BASE/loras/ltx-2.3-id-lora-talkvid-3k.safetensors|https://huggingface.co/Comfy-Org/ltx-2.3/resolve/main/split_files/loras/ltx-2.3-id-lora-talkvid-3k.safetensors"
        "$MODELS_BASE/loras/ltx-2.3-id-lora-celebvhq-3k.safetensors|https://huggingface.co/Comfy-Org/ltx-2.3/resolve/main/split_files/loras/ltx-2.3-id-lora-celebvhq-3k.safetensors"
        "$MODELS_BASE/vae/LTX23_video_vae_bf16.safetensors|https://huggingface.co/Kijai/LTX2.3_comfy/resolve/main/vae/LTX23_video_vae_bf16.safetensors"
        "$MODELS_BASE/vae/LTX23_audio_vae_bf16.safetensors|https://huggingface.co/Kijai/LTX2.3_comfy/resolve/main/vae/LTX23_audio_vae_bf16.safetensors"
        "$MODELS_BASE/latent_upscale_models/ltx-2.3-spatial-upscaler-x2-1.1.safetensors|https://huggingface.co/Lightricks/LTX-2.3/resolve/main/ltx-2.3-spatial-upscaler-x2-1.1.safetensors"
        "$MODELS_BASE/text_encoders/gemma_3_12B_it_fp8_scaled.safetensors|https://huggingface.co/Comfy-Org/ltx-2/resolve/main/split_files/text_encoders/gemma_3_12B_it_fp8_scaled.safetensors"
        "$MODELS_BASE/text_encoders/ltx-2.3_text_projection_bf16.safetensors|https://huggingface.co/Kijai/LTX2.3_comfy/resolve/main/text_encoders/ltx-2.3_text_projection_bf16.safetensors"
    )

    DL_PIDS=()
    for model in "${MODELS[@]}"; do
        IFS='|' read -r filepath url <<< "$model"
        if [ ! -f "$filepath" ]; then
            echo "Downloading $(basename "$filepath")..."
            wget -q -O "$filepath" "$url" &
            DL_PIDS+=($!)
        fi
    done
    DL_FAILED=0
    for pid in "${DL_PIDS[@]}"; do
        if ! wait "$pid"; then
            DL_FAILED=1
        fi
    done
    if [ "$DL_FAILED" -ne 0 ]; then
        echo "WARNING: Some model downloads failed. Check logs above."
    else
        echo "All model downloads completed."
    fi

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
# SageAttention is not used in this template — block disabled.
# SAGE_FAILED_MARKER="/workspace/.sage_build_failed"
# if ! python -c "import sageattention" 2>/dev/null && [ ! -f "$SAGE_FAILED_MARKER" ]; then
#     echo "Building SageAttention from source..."
#     GPU_COMPUTE_CAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1)
#     echo "Detected GPU compute capability: $GPU_COMPUTE_CAP"
#
#     # Build v2 from source in a subshell to isolate env changes (CUDA_HOME, PATH, cwd)
#     # Always include 8.0: SageAttention's _qattn_sm80 base extension needs sm80
#     # gencode even on newer GPUs (its CUDA sources use SM80 intrinsics)
#     (
#         if [ "$GPU_COMPUTE_CAP" = "8.0" ]; then
#             export TORCH_CUDA_ARCH_LIST="8.0"
#         else
#             export TORCH_CUDA_ARCH_LIST="8.0;$GPU_COMPUTE_CAP"
#         fi
#         export CUDA_HOME=/usr/local/cuda-12.8
#         export PATH=$CUDA_HOME/bin:$PATH
#         cd /tmp
#         rm -rf SageAttention
#         git clone https://github.com/thu-ml/SageAttention.git
#         cd SageAttention
#         EXT_PARALLEL=4 NVCC_APPEND_FLAGS="--threads 8" MAX_JOBS=32 python setup.py install
#     )
#     SAGE_BUILD_RC=$?
#     rm -rf /tmp/SageAttention
#     if [ $SAGE_BUILD_RC -ne 0 ]; then
#         echo "WARNING: SageAttention source build failed."
#     else
#         echo "SageAttention built from source"
#     fi
#
#     # Verify the install actually works
#     if ! python -c "import sageattention" 2>/dev/null; then
#         echo "WARNING: SageAttention is not importable. Continuing without it."
#         touch "$SAGE_FAILED_MARKER"
#     else
#         echo "SageAttention verified working"
#     fi
# else
#     echo "SageAttention already installed (or build previously failed), skipping..."
# fi

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
# SageAttention is not used in this template — block disabled.
# if python -c "import sageattention" 2>/dev/null; then
#     case "$FIXED_ARGS" in
#         *--use-sage-attention*) ;;
#         *) FIXED_ARGS="$FIXED_ARGS --use-sage-attention" ;;
#     esac
# else
#     # Strip --use-sage-attention if present but package unavailable
#     FIXED_ARGS=$(echo "$FIXED_ARGS" | sed 's/--use-sage-attention//g' | tr -s ' ')
# fi

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
