#!/bin/bash
set -e  # Exit the script if any statement returns a non-true return value

COMFYUI_DIR="/workspace/runpod-slim/ComfyUI"
VENV_DIR="$COMFYUI_DIR/.venv"
# export VENV_DIR
FILEBROWSER_CONFIG="/root/.config/filebrowser/config.json"
DB_FILE="/workspace/runpod-slim/filebrowser.db"
CUSTOM_REQS_INSTALLED="$COMFYUI_DIR/.custom_reqs_installed"

# ---------------------------------------------------------------------------- #
#                          Function Definitions                                  #
# ---------------------------------------------------------------------------- #

# Setup SSH with optional key or random password
setup_ssh() {
    mkdir -p ~/.ssh
    
    # Generate host keys if they don't exist
    for type in rsa dsa ecdsa ed25519; do
        if [ ! -f "/etc/ssh/ssh_host_${type}_key" ]; then
            ssh-keygen -t ${type} -f "/etc/ssh/ssh_host_${type}_key" -q -N ''
            echo "${type^^} key fingerprint:"
            ssh-keygen -lf "/etc/ssh/ssh_host_${type}_key.pub"
        fi
    done

    # If PUBLIC_KEY is provided, use it
    if [[ $PUBLIC_KEY ]]; then
        echo "$PUBLIC_KEY" >> ~/.ssh/authorized_keys
        chmod 700 -R ~/.ssh
    else
        # Generate random password if no public key
        RANDOM_PASS=$(openssl rand -base64 12)
        echo "root:${RANDOM_PASS}" | chpasswd
        echo "Generated random SSH password for root: ${RANDOM_PASS}"
    fi

    # Configure SSH to preserve environment variables
    echo "PermitUserEnvironment yes" >> /etc/ssh/sshd_config

    # Start SSH service
    /usr/sbin/sshd
}

# Export environment variables
export_env_vars() {
    echo "Exporting environment variables..."
    
    # Create environment files
    ENV_FILE="/etc/environment"
    PAM_ENV_FILE="/etc/security/pam_env.conf"
    SSH_ENV_DIR="/root/.ssh/environment"
    
    # Backup original files
    cp "$ENV_FILE" "${ENV_FILE}.bak" 2>/dev/null || true
    cp "$PAM_ENV_FILE" "${PAM_ENV_FILE}.bak" 2>/dev/null || true
    
    # Clear files
    > "$ENV_FILE"
    > "$PAM_ENV_FILE"
    mkdir -p /root/.ssh
    > "$SSH_ENV_DIR"
    
    # Export to multiple locations for maximum compatibility
    printenv | grep -E '^RUNPOD_|^PATH=|^_=|^CUDA|^LD_LIBRARY_PATH|^PYTHONPATH' | while read -r line; do
        # Get variable name and value
        name=$(echo "$line" | cut -d= -f1)
        value=$(echo "$line" | cut -d= -f2-)
        
        # Add to /etc/environment (system-wide)
        echo "$name=\"$value\"" >> "$ENV_FILE"
        
        # Add to PAM environment
        echo "$name DEFAULT=\"$value\"" >> "$PAM_ENV_FILE"
        
        # Add to SSH environment file
        echo "$name=\"$value\"" >> "$SSH_ENV_DIR"
        
        # Add to current shell
        echo "export $name=\"$value\"" >> /etc/rp_environment
    done
    
    # Add sourcing to shell startup files
    echo 'source /etc/rp_environment' >> ~/.bashrc
    echo 'source /etc/rp_environment' >> /etc/bash.bashrc
    
    # Set permissions
    chmod 644 "$ENV_FILE" "$PAM_ENV_FILE"
    chmod 600 "$SSH_ENV_DIR"
}

# Start Jupyter Lab server for remote access
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

# Setup environment
setup_ssh
export_env_vars

# Initialize FileBrowser if not already done
if [ ! -f "$DB_FILE" ]; then
    echo "Initializing FileBrowser..."
    filebrowser config init
    filebrowser config set --address 0.0.0.0
    filebrowser config set --port 8080
    filebrowser config set --root /workspace
    filebrowser config set --auth.method=json
    filebrowser users add admin adminadmin12 --perm.admin
else
    echo "Using existing FileBrowser configuration..."
fi

# Start FileBrowser
echo "Starting FileBrowser on port 8080..."
nohup filebrowser &> /filebrowser.log &

start_jupyter

# Create default comfyui_args.txt if it doesn't exist
ARGS_FILE="/workspace/runpod-slim/comfyui_args.txt"
if [ ! -f "$ARGS_FILE" ]; then
    echo "# Add your custom ComfyUI arguments here (one per line)" > "$ARGS_FILE"
    echo "Created empty ComfyUI arguments file at $ARGS_FILE"
fi

# Setup ComfyUI if needed
if [ ! -d "$COMFYUI_DIR" ] || [ ! -d "$VENV_DIR" ]; then
    echo "First time setup: Installing ComfyUI and dependencies..."
    
    # Clone ComfyUI if not present
    if [ ! -d "$COMFYUI_DIR" ]; then
        cd /workspace/runpod-slim
        git clone https://github.com/comfyanonymous/ComfyUI.git
    fi
    
    # Install ComfyUI-Manager if not present
    if [ ! -d "$COMFYUI_DIR/custom_nodes/ComfyUI-Manager" ]; then
        echo "Installing ComfyUI-Manager..."
        mkdir -p "$COMFYUI_DIR/custom_nodes"
        cd "$COMFYUI_DIR/custom_nodes"
        git clone https://github.com/ltdrdata/ComfyUI-Manager.git
    fi

    # Install additional custom nodes
    CUSTOM_NODES=(
        "https://github.com/ltdrdata/ComfyUI-Impact-Pack"
        "https://github.com/pythongosssss/ComfyUI-Custom-Scripts"
        "https://github.com/rgthree/rgthree-comfy"
        "https://github.com/kijai/ComfyUI-KJNodes"
        "https://github.com/kijai/ComfyUI-Florence2"
        "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
        "https://github.com/cubiq/ComfyUI_essentials"
        "https://github.com/Fannovel16/comfyui_controlnet_aux"
        "https://github.com/ltdrdata/was-node-suite-comfyui"
        "https://github.com/yolain/ComfyUI-Easy-Use"
        "https://github.com/kijai/ComfyUI-WanVideoWrapper"
        "https://github.com/lquesada/ComfyUI-Inpaint-CropAndStitch"
        "https://github.com/PozzettiAndrea/ComfyUI-SAM3"
        "https://github.com/kijai/ComfyUI-segment-anything-2"
        "https://github.com/calcuis/gguf"
    )

    for repo in "${CUSTOM_NODES[@]}"; do
        repo_name=$(basename "$repo")
        if [ ! -d "$COMFYUI_DIR/custom_nodes/$repo_name" ]; then
            echo "Installing $repo_name..."
            cd "$COMFYUI_DIR/custom_nodes"
            git clone "$repo"
        fi
    done

    # Copy pre-saved custom_nodes
#    if [ -d "/opt/import/custom_nodes" ]; then
#        echo "Copying custom nodes..."
#        cp -r /opt/import/custom_nodes/* /workspace/runpod-slim/ComfyUI/custom_nodes/
#    fi    

    # Copy workflows
    if [ -d "/opt/import/workflows" ]; then
        echo "Copying workflows..."
        mkdir -p /workspace/runpod-slim/ComfyUI/user/default/workflows
        cp -r /opt/import/workflows/* /workspace/runpod-slim/ComfyUI/user/default/workflows/
    fi

    # # Copy pre-saved models
    # if [ -d "/opt/import/models" ]; then
    #     echo "Copying models..."
    #     cp -r /opt/import/models/* /workspace/runpod-slim/ComfyUI/models/
    # fi   
    
    # Download models from Hugging Face
    echo "Downloading models from Hugging Face..."
    
    # Define base model path
    MODELS_BASE="/workspace/runpod-slim/ComfyUI/models"
    
    # Create model directories if they don't exist
    mkdir -p "$MODELS_BASE/diffusion_models/"
    mkdir -p "$MODELS_BASE/checkpoints/"
    mkdir -p "$MODELS_BASE/text_encoders/"
    mkdir -p "$MODELS_BASE/model_patches/"
    mkdir -p "$MODELS_BASE/clip_vision/"
    mkdir -p "$MODELS_BASE/vae"
    mkdir -p "$MODELS_BASE/loras/"
    mkdir -p "$MODELS_BASE/upscale_models/"
    mkdir -p "$MODELS_BASE/sam3/"
    
    # Define models to download: "local_path|url"
    MODELS=(
        "$MODELS_BASE/diffusion_models/Qwen-Image-Edit-2509-Q5_1.gguf|https://huggingface.co/QuantStack/Qwen-Image-Edit-2509-GGUF/resolve/main/Qwen-Image-Edit-2509-Q5_1.gguf"
        "$MODELS_BASE/loras/Qwen-Image-Edit-2509-Lightning-4steps-V1.0-fp32.safetensors|https://huggingface.co/lightx2v/Qwen-Image-Lightning/resolve/main/Qwen-Image-Edit-2509/Qwen-Image-Edit-2509-Lightning-4steps-V1.0-fp32.safetensors"
        "$MODELS_BASE/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors|https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors"
        "$MODELS_BASE/vae/qwen_image_vae.safetensors|https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors"
        "$MODELS_BASE/diffusion_models/Wan2_2-I2V-A14B-HIGH_fp8_e4m3fn_scaled_KJ.safetensors|https://huggingface.co/Kijai/WanVideo_comfy_fp8_scaled/resolve/main/I2V/Wan2_2-I2V-A14B-HIGH_fp8_e4m3fn_scaled_KJ.safetensors"
        "$MODELS_BASE/diffusion_models/Wan2_2-I2V-A14B-LOW_fp8_e4m3fn_scaled_KJ.safetensors|https://huggingface.co/Kijai/WanVideo_comfy_fp8_scaled/resolve/main/I2V/Wan2_2-I2V-A14B-LOW_fp8_e4m3fn_scaled_KJ.safetensors"
        "$MODELS_BASE/loras/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors|https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors"
        "$MODELS_BASE/text_encoders/umt5-xxl-enc-bf16.safetensors|https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-bf16.safetensors"
        "$MODELS_BASE/vae/Wan2_1_VAE_bf16.safetensors|https://huggingface.co/Kijai/WanVideo_comfy/resolve/346ea0b6848edd2aa7e34d0444b2b05ebc7bd97a/Wan2_1_VAE_bf16.safetensors"
    )

    # Download each model if it doesn't exist
    for model in "${MODELS[@]}"; do
        IFS='|' read -r filepath url <<< "$model"
        if [ ! -f "$filepath" ]; then
            echo "Downloading $(basename "$filepath")..."
            wget -O "$filepath" "$url"
        fi
    done

    # Create and setup virtual environment if not present
    if [ ! -d "$VENV_DIR" ]; then
        cd $COMFYUI_DIR
        python3.12 -m venv $VENV_DIR
        source $VENV_DIR/bin/activate
        
        # Use pip first to install uv
        pip install -U pip
        pip install uv
        
        # Configure uv to use copy instead of hardlinks
        export UV_LINK_MODE=copy
        
        # Detect CUDA version and install matching PyTorch
        if command -v nvidia-smi &> /dev/null; then
            CUDA_VERSION=$(nvidia-smi | grep -oP 'CUDA Version: \K[0-9]+\.[0-9]+')
            CUDA_MAJOR=$(echo "$CUDA_VERSION" | cut -d. -f1)
            CUDA_MINOR=$(echo "$CUDA_VERSION" | cut -d. -f2)
            echo "Detected CUDA version: $CUDA_VERSION"
        else
            echo "nvidia-smi not found, defaulting to CUDA 12.8"
            CUDA_MAJOR=12
            CUDA_MINOR=8
        fi

        if [ "$CUDA_MAJOR" -ge 13 ]; then
            echo "Installing PyTorch for CUDA 13.0..."
            TORCH_INDEX="https://download.pytorch.org/whl/cu130"
        else
            echo "Installing PyTorch for CUDA 12.8..."
            TORCH_INDEX="https://download.pytorch.org/whl/cu128"
        fi
        uv pip install torch torchvision torchaudio --index-url "$TORCH_INDEX"
        uv pip install --no-cache -r requirements.txt
        
        # Install dependencies for custom nodes
        echo "Installing/updating dependencies for custom nodes..."
        uv pip install --no-cache GitPython numpy pillow opencv-python  # Common dependencies

        # Install dependencies for all custom nodes
        cd "$COMFYUI_DIR/custom_nodes"
        for node_dir in */; do
            if [ -d "$node_dir" ]; then
                echo "Checking dependencies for $node_dir..."
                cd "$COMFYUI_DIR/custom_nodes/$node_dir"

                # Check for requirements.txt
                if [ -f "requirements.txt" ]; then
                    echo "Installing requirements.txt for $node_dir"
                    uv pip install --no-cache -r requirements.txt
                fi

                # Check for install.py
                if [ -f "install.py" ]; then
                    echo "Running install.py for $node_dir"
                    python install.py
                fi

                # Check for setup.py
                if [ -f "setup.py" ]; then
                    echo "Running setup.py for $node_dir"
                    uv pip install --no-cache -e .
                fi
            fi
        done
    fi
else
    # Just activate the existing venv
    source $VENV_DIR/bin/activate
    
    # Always install/update dependencies for custom nodes
    echo "Installing/updating dependencies for custom nodes..."
    uv pip install --no-cache GitPython numpy pillow  # Common dependencies

    # Install dependencies for all custom nodes
    cd "$COMFYUI_DIR/custom_nodes"
    for node_dir in */; do
        if [ -d "$node_dir" ]; then
            echo "Checking dependencies for $node_dir..."
            cd "$COMFYUI_DIR/custom_nodes/$node_dir"

            # Check for requirements.txt
            if [ -f "requirements.txt" ]; then
                echo "Installing requirements.txt for $node_dir"
                uv pip install --no-cache -r requirements.txt
            fi

            # Check for install.py
            if [ -f "install.py" ]; then
                echo "Running install.py for $node_dir"
                python install.py
            fi

            # Check for setup.py
            if [ -f "setup.py" ]; then
                echo "Running setup.py for $node_dir"
                uv pip install --no-cache -e .
            fi
        fi
    done
fi

# Installing custom requirements (one-time installation)
if [ ! -f "$CUSTOM_REQS_INSTALLED" ]; then
    echo "Installing custom node requirements..."
    source $VENV_DIR/bin/activate
    pip install -r /workspace/runpod-slim/ComfyUI/custom_nodes/ComfyUI-Florence2/requirements.txt
    pip install -r /workspace/runpod-slim/ComfyUI/custom_nodes/ComfyUI-Impact-Pack/requirements.txt
    pip install -r /workspace/runpod-slim/ComfyUI/custom_nodes/was-node-suite-comfyui/requirements.txt
    pip install -r /workspace/runpod-slim/ComfyUI/custom_nodes/comfyui_controlnet_aux/requirements.txt
    pip install -r /workspace/runpod-slim/ComfyUI/custom_nodes/ComfyUI-WanVideoWrapper/requirements.txt
    pip install -r /workspace/runpod-slim/ComfyUI/custom_nodes/ComfyUI-SAM3/requirements.txt
    touch "$CUSTOM_REQS_INSTALLED"
    echo "Custom node requirements installed successfully"
else
    echo "Custom node requirements already installed, skipping..."
fi

# Start ComfyUI with custom arguments if provided
cd $COMFYUI_DIR
FIXED_ARGS="--listen 0.0.0.0 --port 8188"
if [ -s "$ARGS_FILE" ]; then
    # File exists and is not empty, combine fixed args with custom args
    CUSTOM_ARGS=$(grep -v '^#' "$ARGS_FILE" | tr '\n' ' ')
    if [ ! -z "$CUSTOM_ARGS" ]; then
        echo "Starting ComfyUI with additional arguments: $CUSTOM_ARGS"
        nohup python main.py $FIXED_ARGS $CUSTOM_ARGS &> /workspace/runpod-slim/comfyui.log &
    else
        echo "Starting ComfyUI with default arguments"
        nohup python main.py $FIXED_ARGS &> /workspace/runpod-slim/comfyui.log &
    fi
else
    # File is empty, use only fixed args
    echo "Starting ComfyUI with default arguments"
    nohup python main.py $FIXED_ARGS &> /workspace/runpod-slim/comfyui.log &
fi

# Tail the log file
tail -f /workspace/runpod-slim/comfyui.log
