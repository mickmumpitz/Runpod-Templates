FROM runpod/comfyui:1.4.0-cuda12.8

# ── Pin ComfyUI version (unshallow + checkout specific tag) ──────────────────
# Change COMFYUI_VERSION to update. Use a tag (e.g. v0.33.4) or commit hash.
ARG COMFYUI_VERSION=v0.33.4
RUN cd /opt/comfyui-baked && \
    git fetch --depth 1 origin tag "$COMFYUI_VERSION" && \
    git checkout "$COMFYUI_VERSION" && \
    pip install --no-cache-dir -r requirements.txt

# ── Bake custom nodes into /opt/comfyui-baked/custom_nodes ────────────────────
WORKDIR /opt/comfyui-baked/custom_nodes

# Scope: the 3DGS Dataset Generator workflows —
#   Krea2-360Pano-Creator      (default; Krea 2 + 360 ERP LoRAs, text→pano / image→pano)
#   3DGS-Dataset-Creator SMPL  (Wan 2.1 I2V camera-plot fly-through dataset)
#   3DGS-Dataset-Creator ADV   (premium; NOT shipped in ./workflows — members load it
#                               manually, so its extra node + model are baked in too)
#
# ComfyUI-SplatKit           — all SplatKit_* nodes (the pano→dataset pipeline core, A/B switch)
# ComfyUI-Mickmumpitz-Nodes  — Erp* / Pano* nodes, Bundle / UnbundleByName / ResolutionPicker (needs >=1.5.6)
# ComfyUI-Krea2-Ostris-Edit  — Krea2OstrisEditModelPatch + TextEncodeKrea2OstrisEdit (image→pano edit)
# ComfyUI_essentials         — ImageCASharpening+ (CAS pre-sharpen)
# ComfyUI_UltimateSDUpscale  — UltimateSDUpscaleNoUpscale (Krea refine tiling)
# ComfyUI-GGUF               — UnetLoaderGGUF (Wan I2V GGUF alternative for <=16GB VRAM)
# ComfyUI_preview360panorama — PanoramaViewerNode (360 viewer on the final pano)
# ComfyUI-RMBG               — SAM3Segment (ADV workflow only; sam3.pt fetched in start.sh)
#
# ComfyUI-KJNodes is already baked into the runpod/comfyui base image, so it is
# not cloned here (cloning would collide with the existing copy).
RUN git clone https://github.com/mickmumpitz/ComfyUI-SplatKit && \
    git clone https://github.com/mickmumpitz/ComfyUI-Mickmumpitz-Nodes && \
    git clone https://github.com/ostris/ComfyUI-Krea2-Ostris-Edit && \
    git clone https://github.com/cubiq/ComfyUI_essentials && \
    git clone https://github.com/ssitu/ComfyUI_UltimateSDUpscale && \
    git clone https://github.com/city96/ComfyUI-GGUF && \
    git clone https://github.com/ProGamerGov/ComfyUI_preview360panorama && \
    git clone https://github.com/1038lab/ComfyUI-RMBG

# ── System libs needed by opencv / SplatKit rendering ─────────────────────────
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        libgl1 \
        libglx-mesa0 \
        libglib2.0-0 \
        aria2 && \
    rm -rf /var/lib/apt/lists/*

# ── Install all custom-node deps into system site-packages ────────────────────
RUN pip install --no-cache-dir \
    GitPython numpy pillow opencv-python && \
    for req in /opt/comfyui-baked/custom_nodes/*/requirements.txt; do \
        [ -f "$req" ] && pip install --no-cache-dir -r "$req" || true; \
    done && \
    for inst in /opt/comfyui-baked/custom_nodes/*/install.py; do \
        [ -f "$inst" ] && python3 "$inst" || true; \
    done

# ── Pre-install ninja + CUDA dev headers (needed for SageAttention build) ────
# SageAttention is compiled from source on first boot (needs a GPU); the base
# image has nvcc but not all CUDA dev headers (cusparse.h, cusolverDn.h, etc.).
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        libcusparse-dev-12-8 \
        libcublas-dev-12-8 \
        libcusolver-dev-12-8 && \
    rm -rf /var/lib/apt/lists/* && \
    pip install --no-cache-dir ninja

# Reset workdir so the container doesn't start inside custom_nodes
WORKDIR /

# ── Copy workflows + default args ────────────────────────────────────────────
COPY ./workflows /opt/import/workflows
COPY ./comfyui_args.txt /opt/import/comfyui_args.txt

# ── Copy start script ────────────────────────────────────────────────────────
COPY --chmod=755 ./start.sh /start.sh
