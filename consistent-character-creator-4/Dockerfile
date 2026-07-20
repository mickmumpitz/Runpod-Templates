FROM runpod/comfyui:1.4.0-cuda12.8

# ── Pin ComfyUI version (unshallow + checkout specific tag) ──────────────────
# Change COMFYUI_VERSION to update. Use a tag (e.g. v0.28.0) or commit hash.
ARG COMFYUI_VERSION=v0.28.0
RUN cd /opt/comfyui-baked && \
    git fetch --depth 1 origin tag "$COMFYUI_VERSION" && \
    git checkout "$COMFYUI_VERSION" && \
    pip install --no-cache-dir -r requirements.txt

# ── Bake custom nodes into /opt/comfyui-baked/custom_nodes ────────────────────
WORKDIR /opt/comfyui-baked/custom_nodes

# Scope: the two Consistent Character Creator 4.0 workflows — CCC_4-0_SMPL (shipped
# in ./workflows) and CCC_4-0_ADV (not shipped; users load it manually, so its nodes
# are baked in too and it runs without a Manager install).
#
# ComfyUI-KJNodes is already baked into the runpod/comfyui base image, so it is
# not cloned here (cloning would collide with the existing copy).
#
# Impact-Subpack must be cloned explicitly: since Impact-Pack v8.0 it is no
# longer auto-installed, and UltralyticsDetectorProvider (used by ADV's FaceDetailer)
# lives only in Subpack.
# was-node-suite-comfyui: the ltdrdata fork is the maintained continuation
# (WASasquatch retired the original); it is what the `was-ns` registry id maps to.
RUN git clone https://github.com/mickmumpitz/ComfyUI-Mickmumpitz-Nodes && \
    git clone https://github.com/liusida/ComfyUI-AutoCropFaces && \
    git clone https://github.com/capitan01R/ComfyUI-Flux2Klein-Enhancer && \
    git clone https://github.com/ltdrdata/ComfyUI-Impact-Pack && \
    git clone https://github.com/ltdrdata/ComfyUI-Impact-Subpack && \
    git clone https://github.com/ltdrdata/was-node-suite-comfyui && \
    git clone https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler && \
    git clone https://github.com/pythongosssss/ComfyUI-Custom-Scripts && \
    git clone https://github.com/yolain/ComfyUI-Easy-Use && \
    git clone https://github.com/rgthree/rgthree-comfy

# ── System libs needed by Impact-Pack / opencv ────────────────────────────────
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        libgl1 \
        libglx-mesa0 \
        libglib2.0-0 \
        aria2 && \
    rm -rf /var/lib/apt/lists/*

# ── Install all custom-node deps into system site-packages ────────────────────
RUN pip install --no-cache-dir \
    GitPython numpy pillow opencv-python ultralytics && \
    for req in /opt/comfyui-baked/custom_nodes/*/requirements.txt; do \
        [ -f "$req" ] && pip install --no-cache-dir -r "$req" || true; \
    done && \
    for inst in /opt/comfyui-baked/custom_nodes/*/install.py; do \
        [ -f "$inst" ] && python3 "$inst" || true; \
    done

# ── Fix: SeedVR2's flash_attn shim breaks WAS Node Suite (and SeedVR2 itself) ────
# SeedVR2's src/optimization/compatibility.py stubs `flash_attn` into sys.modules when the
# import fails, and gives the stub a real __spec__. transformers' is_flash_attn_2_available()
# then sees find_spec('flash_attn') succeed, so it stops short-circuiting and evaluates
# PACKAGE_DISTRIBUTION_MAPPING["flash_attn"] -> KeyError, because no such distribution is
# installed. Every node pack importing transformers/diffusers after SeedVR2 dies with it.
# The shim exists only to survive broken flash_attn DLLs, so keep the OSError case and let a
# plain absence stay absent. Applied after the pip layers above so their cache survives.
RUN python3 - <<'PY'
p = '/opt/comfyui-baked/custom_nodes/ComfyUI-SeedVR2_VideoUpscaler/src/optimization/compatibility.py'
s = open(p).read()
old = """    try:
        import flash_attn
    except (ImportError, OSError):"""
new = """    try:
        import flash_attn
    except ImportError:
        return
    except OSError:"""
assert old in s, 'SeedVR2 flash_attn shim changed upstream — re-check this patch'
open(p, 'w').write(s.replace(old, new, 1))
print('patched SeedVR2 flash_attn shim')
PY

# ── WAS Node Suite runtime config ────────────────────────────────────────────
# WAS merges any missing keys from its internal template into an existing config, so this
# minimal file only needs to override what we care about. Without ffmpeg_bin_path it warns
# and falls back to guessing; ffmpeg is at /usr/bin/ffmpeg in this image.
RUN printf '{\n    "ffmpeg_bin_path": "/usr/bin/ffmpeg"\n}\n' \
    > /opt/comfyui-baked/custom_nodes/was-node-suite-comfyui/was_suite_config.json

# WAS self-installs missing deps at import via `pip uninstall` WITHOUT -y, which blocks on a
# confirmation prompt that never comes on a pod. Deps are baked above, so switch it off.
ENV WAS_BLOCK_AUTO_INSTALL=true

# ── Build-time smoke test ────────────────────────────────────────────────────
# The failure above passed the build and only surfaced on a pod, because it needs SeedVR2 to
# be imported before WAS in one process. Reproduce that ordering here so a regression breaks
# the build instead of a user's pod. Importing WAS outright would need a GPU (comfy's
# model_management calls torch.cuda.current_device()), which the builder has no access to —
# so assert on the shim's effect and on the exact transformers import WAS dies at (line 2459).
RUN cd /opt/comfyui-baked && python3 -c "\
import importlib.util as iu; \
spec = iu.spec_from_file_location('c', './custom_nodes/ComfyUI-SeedVR2_VideoUpscaler/src/optimization/compatibility.py'); \
m = iu.module_from_spec(spec); spec.loader.exec_module(m); \
assert iu.find_spec('flash_attn') is None, 'SeedVR2 shim is poisoning sys.modules for flash_attn'; \
from transformers import BlipProcessor, BlipForConditionalGeneration, BlipForQuestionAnswering; \
print('smoke test passed: WAS transformers import survives the SeedVR2 shim')"

# Reset workdir so the container doesn't start inside custom_nodes
WORKDIR /

# ── Copy workflows + default args ────────────────────────────────────────────
COPY ./workflows /opt/import/workflows
COPY ./comfyui_args.txt /opt/import/comfyui_args.txt

# ── Copy start script ────────────────────────────────────────────────────────
COPY --chmod=755 ./start.sh /start.sh
