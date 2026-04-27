FROM runpod/comfyui:1.4.0-cuda12.8

# ── Pin ComfyUI version (unshallow + checkout specific tag) ──────────────────
# Change COMFYUI_VERSION to update. Use a tag (e.g. v0.17.2) or commit hash.
ARG COMFYUI_VERSION=v0.19.3
RUN cd /opt/comfyui-baked && \
    git fetch --depth 1 origin tag "$COMFYUI_VERSION" && \
    git checkout "$COMFYUI_VERSION" && \
    pip install --no-cache-dir -r requirements.txt

# ── Bake custom nodes into /opt/comfyui-baked/custom_nodes ────────────────────
WORKDIR /opt/comfyui-baked/custom_nodes

RUN git clone https://github.com/rgthree/rgthree-comfy && \
    git clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite && \
    git clone https://github.com/yolain/ComfyUI-Easy-Use && \
    git clone https://github.com/mickmumpitz/ComfyUI-Mickmumpitz-Nodes && \
    git clone https://github.com/ClownsharkBatwing/RES4LYF && \
    git clone https://github.com/liusida/ComfyUI-AutoCropFaces && \
    git clone https://github.com/o-l-l-i/ComfyUI-Olm-DragCrop

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
# The base image has nvcc but not all CUDA dev headers (cusparse.h, cusolverDn.h, etc.)
# SageAttention is not used in this template — keep this commented out unless re-enabled.
# RUN apt-get update && \
#     apt-get install -y --no-install-recommends \
#         libcusparse-dev-12-8 \
#         libcublas-dev-12-8 \
#         libcusolver-dev-12-8 && \
#     rm -rf /var/lib/apt/lists/* && \
#     pip install --no-cache-dir ninja

# Reset workdir so the container doesn't start inside custom_nodes
WORKDIR /

# ── Copy workflows + default args ────────────────────────────────────────────
COPY ./workflows /opt/import/workflows
COPY ./comfyui_args.txt /opt/import/comfyui_args.txt

# ── Copy start script ────────────────────────────────────────────────────────
COPY --chmod=755 ./start.sh /start.sh
