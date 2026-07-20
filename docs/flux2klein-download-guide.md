### Fast manual download via terminal

For a fast download of the gated 9B model, pull it straight onto the pod with your Hugging Face credentials instead of through the browser:

1. **Accept the license** for FLUX.2 Klein 9B on its [model page](https://huggingface.co/black-forest-labs/FLUX.2-klein-9b-fp8) first.
2. **Create an access token:** on huggingface.co click your profile → **Settings** → **Access Tokens** → **Create new token**.
3. **Open the terminal** in JupyterLab on RunPod and run the commands below.

Log in with your token (paste it when prompted):
```
hf auth login
```
Then download the model straight into the diffusion-models folder:
```
export HF_HUB_DISABLE_XET=1
hf download black-forest-labs/FLUX.2-klein-9b-fp8 flux-2-klein-9b-fp8.safetensors \
    --local-dir /workspace/runpod-slim/ComfyUI/models/diffusion_models/
```

---

## Free 4B alternative (no Hugging Face account needed)

The gated 9B UNET is the only model that is not auto-downloaded. If you don't have access, switch this workflow to the **free FLUX.2 Klein 4B** model instead - both files below are already downloaded for you on first boot:

| File | Put it in |
|------|-----------|
| `flux-2-klein-4b-fp8.safetensors` | `models/diffusion_models/` |
| `qwen_3_4b_fp4_flux2.safetensors` | `models/text_encoders/` |

**To switch to 4B:**
1. In **UNETLoader**, choose `flux-2-klein-4b-fp8.safetensors` instead of the 9B file.
2. In **CLIPLoader**, choose `qwen_3_4b_fp4_flux2.safetensors` instead of `qwen_3_8b_fp8mixed.safetensors`.
3. **Bypass the consistency `LoraLoaderModelOnly`** - it is 9B-only and has no 4B equivalent.
4. Leave the VAELoader on `flux2-vae.safetensors` - it works for both 4B and 9B.

*(This mirrors the free 4B setup included in the LTX Movie Builder template.)*
