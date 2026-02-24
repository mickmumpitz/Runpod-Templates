# CUDA Version Detection Code (saved for future use)

This code was removed from all start.sh templates on 2026-02-24 in favor of always using cu128.
Can be re-added if we need dynamic CUDA version detection again.

```bash
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
```

## Note
- cu128 = CUDA 12.8, cu124 = CUDA 12.4, cu130 = CUDA 13.0
- If driver only supports CUDA 12.4, need cu124 wheels
- PyTorch wheel index URLs: `https://download.pytorch.org/whl/cu1XX`
