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
    # Scope: the two Consistent Character Creator 4.0 workflows —
    #   260713_MICKMUMPITZ_CCC_4-0_SMPL  (shipped in this image, set as the default)
    #   260713_MICKMUMPITZ_CCC_4-0_ADV   (not shipped; users load it manually and it
    #                                     runs with no extra downloads)
    # The Ideogram / Krea 2 / Wan 2.2 / dataset-tagger workflows are deliberately out of
    # scope — none of their models are fetched here.
    echo "Downloading models from Hugging Face..."
    MODELS_BASE="$COMFYUI_DIR/models"
    mkdir -p "$MODELS_BASE/diffusion_models" \
             "$MODELS_BASE/text_encoders" \
             "$MODELS_BASE/vae" \
             "$MODELS_BASE/loras" \
             "$MODELS_BASE/ultralytics/bbox" \
             "$MODELS_BASE/SEEDVR2"

    # filepath|url  — files are saved under the exact name the workflow's loader
    # nodes reference (some differ from the source repo's filename; the downloader renames).
    #
    # NOT DOWNLOADED — must be supplied manually (see TODO_MODELS.md):
    #   * flux-2-klein-9b-fp8.safetensors — gated behind black-forest-labs/FLUX.2-klein.
    #     Its non-gated dependencies ARE downloaded below, so both workflows only need
    #     the UNET dropped into models/diffusion_models.
    MODELS=(
        # ── Flux.2 Klein 9B — deps only (UNET itself is gated and omitted; see note above) ──
        # Both workflows generate through this model; SMPL uses nothing else.
        "$MODELS_BASE/loras/Flux2-Klein-9B-consistency-V2.safetensors|https://huggingface.co/dx8152/Flux2-Klein-9B-Consistency/resolve/main/Flux2-Klein-9B-consistency-V2.safetensors"
        "$MODELS_BASE/text_encoders/qwen_3_8b_fp8mixed.safetensors|https://huggingface.co/Comfy-Org/vae-text-encorder-for-flux-klein-9b/resolve/main/split_files/text_encoders/qwen_3_8b_fp8mixed.safetensors"
        "$MODELS_BASE/vae/flux2-vae.safetensors|https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/vae/flux2-vae.safetensors"
        # ── SeedVR2 upscaler — ADV upscale branch only (SeedVR2LoadDiTModel + LoadVAEModel) ──
        # ADV's default setup is the GGUF DiT + ema_vae_fp16; the fp16 DiT build is an
        # alternative the graph does not select, so it is not fetched.
        # The GGUF build lives in a different repo than the safetensors one.
        "$MODELS_BASE/SEEDVR2/seedvr2_ema_7b_sharp-Q4_K_M.gguf|https://huggingface.co/cmeka/SeedVR2-GGUF/resolve/main/seedvr2_ema_7b_sharp-Q4_K_M.gguf"
        "$MODELS_BASE/SEEDVR2/ema_vae_fp16.safetensors|https://huggingface.co/numz/SeedVR2_comfyUI/resolve/main/ema_vae_fp16.safetensors"
        # ── Face detector — ADV FaceDetailer branch only ──
        # UltralyticsDetectorProvider references it as "bbox/face_yolov8m.pt"; the bbox/
        # prefix is the local ComfyUI folder convention, not part of the repo path.
        "$MODELS_BASE/ultralytics/bbox/face_yolov8m.pt|https://huggingface.co/Bingsu/adetailer/resolve/main/face_yolov8m.pt"
    )

    # ── Fast, resumable, logged downloads ─────────────────────────────────────
    # Why this shape:
    #   * aria2c (multi-connection + resumable) is much faster and more reliable than
    #     a single wget stream against Hugging Face; installed best-effort if missing.
    #   * Only a few files download at once. Firing all of them at once floods HF with
    #     parallel connections that get throttled/dropped — that is what stalled an
    #     earlier boot at ~87 GB with disk to spare — and leaves no progress in the log.
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
