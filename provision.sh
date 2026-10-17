#!/bin/bash
# LoRA Dataset Studio on Vast.ai - provisioning script for the vastai/comfy image.
#
# Vast's boot runs this once per new container (PROVISIONING_SCRIPT), as root, while
# /.provisioning exists - ComfyUI and the services registered here wait for it.
# Everything heavy lives on the persistent volume mounted at $WORKSPACE, so a new
# instance on the same volume only re-checks what is already there:
#
#   $WORKSPACE/ComfyUI               ComfyUI (copied there by the image itself)
#   $WORKSPACE/lora-dataset-studio   the studio checkout + its .venv
#   $WORKSPACE/lds-data              datasets, database, config.json, .env (API keys)
#   $WORKSPACE/ai-toolkit            ostris ai-toolkit + its .venv (training, JoyCaption)
#   $WORKSPACE/.lds                  this kit: Python builds, uv cache, Ollama, secrets
#
# Safe to re-run: every step checks before it installs.
set -Eeuo pipefail

# ---- settings: each can be overridden with an env var in the Vast template ---------
WORKSPACE=${WORKSPACE:-/workspace}
LDS_REPO=${LDS_REPO:-https://github.com/perfectgf/lora-dataset-studio.git}
LDS_REF=${LDS_REF:-v2}
AITK_REPO=${AITK_REPO:-https://github.com/ostris/ai-toolkit.git}
AITK_REF=${AITK_REF:-main}
LDS_INSTALL_AITK=${LDS_INSTALL_AITK:-1}
LDS_INSTALL_OLLAMA=${LDS_INSTALL_OLLAMA:-1}
OLLAMA_VERSION=${OLLAMA_VERSION:-v0.40.6}
# torch for the studio's own venv (scoring, face similarity, video helpers). Same
# version as ai-toolkit's manager pins, so uv can hardlink one copy for both venvs.
LDS_TORCH_VERSION=${LDS_TORCH_VERSION:-2.13.0}
LDS_TORCHVISION_VERSION=${LDS_TORCHVISION_VERSION:-0.28.0}
LDS_TORCH_BACKEND=${LDS_TORCH_BACKEND:-auto}   # auto | cu126 | cu129 | cu130 | cpu
LDS_AITK_CPU=${LDS_AITK_CPU:-0}                # 1 = allow ai-toolkit without a GPU (CI only)

KIT=$WORKSPACE/.lds
LDS_DIR=$WORKSPACE/lora-dataset-studio
LDS_DATA=$WORKSPACE/lds-data
AITK_DIR=$WORKSPACE/ai-toolkit
COMFY_DIR=$WORKSPACE/ComfyUI
OLLAMA_DIR=$KIT/ollama
LDS_INTERNAL_PORT=15050   # the studio listens here, on loopback only
LDS_EXTERNAL_PORT=5050    # Caddy serves it here, behind Vast's login
PORTAL_NAME="LoRA Dataset Studio"
ENV_FILE=/etc/lds-vast.env

# Keep uv's Python builds and cache on the volume. The image points both at the
# container disk (/.uv/...), which a new instance does not have - venvs built on
# those interpreters would break on the next instance.
export UV_PYTHON_INSTALL_DIR=$KIT/python
export UV_CACHE_DIR=$KIT/uv-cache
export UV_LINK_MODE=hardlink
unset UV_NO_CACHE VIRTUAL_ENV PYTHONPATH PYTHONHOME CONDA_PREFIX || true

log()  { echo "[lds-vast] $(date '+%H:%M:%S') $*"; }
warn() { echo "[lds-vast] $(date '+%H:%M:%S') WARNING: $*" >&2; }
die()  { echo "[lds-vast] $(date '+%H:%M:%S') ERROR: $*" >&2; exit 1; }
trap 'die "failed at line $LINENO: $BASH_COMMAND"' ERR

stamp_ok()  { [[ -f "$KIT/stamps/$1" && "$(cat "$KIT/stamps/$1")" == "$2" ]]; }
stamp_set() { mkdir -p "$KIT/stamps"; printf '%s' "$2" > "$KIT/stamps/$1"; }

retry() {  # retry <attempts> <cmd...> - network steps on rented hosts do flake
    local n=$1 i=1; shift
    until "$@"; do
        (( i >= n )) && return 1
        warn "attempt $i/$n failed: $* - retrying in $((i * 10))s"
        sleep $((i * 10)); i=$((i + 1))
    done
}

# ---- 0. preconditions ---------------------------------------------------------------
preflight() {
    [[ $EUID -eq 0 ]] || die "must run as root (Vast's provisioner does)"
    mkdir -p "$KIT" "$LDS_DATA"
    [[ -w "$WORKSPACE" ]] || die "$WORKSPACE is not writable"
    command -v uv >/dev/null || die "uv not found - this script expects a vastai/* image"
    command -v git >/dev/null || die "git not found"
    [[ -d "$COMFY_DIR" ]] || warn "$COMFY_DIR is missing - is this the vastai/comfy image?"
    if ! mountpoint -q "$WORKSPACE"; then
        warn "$WORKSPACE is not a separate volume: everything installed here is lost when the instance is destroyed"
    fi
    local free_gb
    free_gb=$(df -BG --output=avail "$WORKSPACE" | tail -1 | tr -dc '0-9')
    log "free space on $WORKSPACE: ${free_gb} GB"
    (( free_gb >= 60 )) || warn "less than 60 GB free on $WORKSPACE - models and training need far more (200 GB recommended)"
}

# ---- 1. system packages (container disk: reinstalled on every new instance) --------
system_packages() {
    local want=() pkg
    command -v zstd >/dev/null || want+=(zstd)
    dpkg -s libgl1 >/dev/null 2>&1 || want+=(libgl1)
    if ! dpkg -s libglib2.0-0t64 >/dev/null 2>&1 && ! dpkg -s libglib2.0-0 >/dev/null 2>&1; then
        want+=(glib)
    fi
    (( ${#want[@]} )) || return 0
    log "installing system packages: ${want[*]}"
    retry 3 apt-get update -qq
    for pkg in "${want[@]}"; do
        if [[ $pkg == glib ]]; then
            # renamed in the Ubuntu 24.04 time_t transition
            apt-get install -y -qq --no-install-recommends libglib2.0-0t64 \
                || apt-get install -y -qq --no-install-recommends libglib2.0-0
        else
            apt-get install -y -qq --no-install-recommends "$pkg"
        fi
    done
}

# ---- 2. secrets ----------------------------------------------------------------------
secrets() {
    mkdir -p "$KIT/secrets"; chmod 700 "$KIT/secrets"
    local token_file=$KIT/secrets/plugin-admin-token
    if [[ ! -s $token_file ]]; then
        # The studio sits behind Caddy, so every request carries X-Forwarded-For and the
        # Plugins page refuses installs without this operator token (>= 32 chars).
        (umask 077; openssl rand -hex 32 > "$token_file")
        log "generated the plugin admin token (show it with: lds-token)"
    fi
    touch "$LDS_DATA/.env"; chmod 600 "$LDS_DATA/.env"
}

# ---- 3. LoRA Dataset Studio ----------------------------------------------------------
torch_backend() {
    [[ $LDS_TORCH_BACKEND != auto ]] && { echo "$LDS_TORCH_BACKEND"; return; }
    command -v nvidia-smi >/dev/null || { echo cpu; return; }
    local cuda
    cuda=$(nvidia-smi 2>/dev/null | sed -nE 's/.*CUDA Version: ([0-9]+)\.([0-9]+).*/\1\2/p' | head -1 || true)
    [[ -n $cuda ]] || { echo cpu; return; }
    # torch 2.13 ships cu126/cu129/cu130 wheels; RTX 50xx needs cu129 or newer
    if (( cuda >= 130 )); then echo cu130
    elif (( cuda >= 129 )); then echo cu129
    else echo cu126
    fi
}

install_lds() {
    if [[ ! -d $LDS_DIR/.git ]]; then
        log "cloning LoRA Dataset Studio ($LDS_REF)"
        rm -rf "$LDS_DIR"
        # blob:none keeps the full history for the in-app updater without
        # downloading every old screenshot up front.
        retry 3 git clone --filter=blob:none --branch "$LDS_REF" "$LDS_REPO" "$LDS_DIR"
    else
        # Updates come from the app itself (Settings -> Update & restart); never reset
        # a checkout the user may have moved forward.
        log "studio checkout present: $(git -C "$LDS_DIR" rev-parse --abbrev-ref HEAD)@$(git -C "$LDS_DIR" rev-parse --short HEAD)"
    fi
    git config --global --add safe.directory "$LDS_DIR" 2>/dev/null || true

    local py=$LDS_DIR/.venv/bin/python
    if ! "$py" -c 'import flask' >/dev/null 2>&1; then
        log "creating the studio venv (Python 3.12)"
        rm -rf "$LDS_DIR/.venv"
        retry 3 uv python install 3.12
        uv venv --python 3.12 --managed-python "$LDS_DIR/.venv"
        rm -f "$KIT/stamps/lds-deps"
    fi
    lds_deps
}

# The same install as the repo's Dockerfile.gpu, into a venv that lives on the volume.
lds_deps() {
    local py=$LDS_DIR/.venv/bin/python req=$LDS_DIR/backend/requirements.txt
    local ml=$LDS_DIR/backend/requirements-ml.txt backend key
    backend=$(torch_backend)
    key="$(cat "$req" "$ml" | sha256sum | cut -c1-16)-$LDS_TORCH_VERSION-$backend"
    if stamp_ok lds-deps "$key"; then
        log "studio dependencies up to date ($backend)"
        return
    fi
    log "installing studio dependencies (torch $LDS_TORCH_VERSION, $backend) - several minutes on first boot"
    local tb=(--torch-backend "$backend")
    retry 3 uv pip install --python "$py" -r "$req"
    retry 3 uv pip install --python "$py" "${tb[@]}" \
        "torch==$LDS_TORCH_VERSION" "torchvision==$LDS_TORCHVISION_VERSION" -c "$ml"
    # Pin what is now installed so no later step can swap torch for another build.
    local pins=$KIT/lds-torch-pins.txt
    "$py" -c 'import torch, torchvision; print(f"torch=={torch.__version__}\ntorchvision=={torchvision.__version__}")' > "$pins"
    # simple-lama-inpainting pins pillow<10, which has no cp312 wheel: install the
    # rest binary-only, then LaMa itself without its dependencies (as Dockerfile.gpu).
    local lama
    lama=$(grep '^simple-lama-inpainting' "$ml" || true)
    grep -v '^simple-lama-inpainting' "$ml" > "$KIT/requirements-ml.nolama.txt"
    retry 3 uv pip install --python "$py" "${tb[@]}" --only-binary :all: \
        -r "$KIT/requirements-ml.nolama.txt" -c "$pins"
    [[ -z $lama ]] || retry 3 uv pip install --python "$py" --no-deps "$lama"
    # Bank scoring (CLIP + NSFW classifier); -c keeps numpy under insightface's ceiling.
    retry 3 uv pip install --python "$py" "${tb[@]}" \
        open_clip_torch transformers timm safetensors huggingface_hub -c "$ml" -c "$pins"
    "$py" -c 'import flask, torch, insightface, cv2, open_clip; print("studio venv ok, torch", torch.__version__, "cuda", torch.cuda.is_available())'
    stamp_set lds-deps "$key"
}

# ---- 4. ai-toolkit (training + JoyCaption) -------------------------------------------
install_aitk() {
    [[ $LDS_INSTALL_AITK == 1 ]] || { log "skipping ai-toolkit (LDS_INSTALL_AITK=$LDS_INSTALL_AITK)"; return; }
    if [[ ! -d $AITK_DIR/.git ]]; then
        log "cloning ai-toolkit ($AITK_REF)"
        rm -rf "$AITK_DIR"
        retry 3 git clone "$AITK_REPO" "$AITK_DIR"
        git -C "$AITK_DIR" checkout -q "$AITK_REF"
    fi
    git config --global --add safe.directory "$AITK_DIR" 2>/dev/null || true

    local py=$AITK_DIR/.venv/bin/python check='import torch, transformers, accelerate, bitsandbytes, safetensors'
    if "$py" -c "$check" >/dev/null 2>&1 && stamp_ok aitk "$(git -C "$AITK_DIR" rev-parse HEAD)"; then
        log "ai-toolkit environment up to date"
        return
    fi
    if [[ -e $AITK_DIR/.venv ]] && ! "$py" -c 'import sys' >/dev/null 2>&1; then
        warn "ai-toolkit venv is broken (interpreter missing) - rebuilding it"
        rm -rf "$AITK_DIR/.venv"
    fi
    # ai-toolkit's own manager picks the torch build for this driver and installs
    # everything inside the checkout. --cpu is only for CI hosts without a GPU.
    local args=(install)
    [[ -x $py ]] && args=(sync)
    if [[ $LDS_AITK_CPU == 1 ]]; then args+=(--cpu); fi
    local sys_py=/usr/bin/python3
    [[ -x $sys_py ]] || sys_py=$(command -v python3)
    log "installing ai-toolkit environment - several minutes on first boot"
    (cd "$AITK_DIR" && retry 2 "$sys_py" -m manager "${args[@]}")
    "$py" -c "$check; print('ai-toolkit venv ok, torch', torch.__version__, 'cuda', torch.cuda.is_available())"
    stamp_set aitk "$(git -C "$AITK_DIR" rev-parse HEAD)"
}

# ---- 5. Ollama (captioning helpers, framing, head-crop) ------------------------------
install_ollama() {
    [[ $LDS_INSTALL_OLLAMA == 1 ]] || { log "skipping Ollama (LDS_INSTALL_OLLAMA=$LDS_INSTALL_OLLAMA)"; return; }
    if [[ -x $OLLAMA_DIR/bin/ollama ]] && stamp_ok ollama "$OLLAMA_VERSION"; then
        log "Ollama $OLLAMA_VERSION present"
        return
    fi
    log "installing Ollama $OLLAMA_VERSION"
    local url="https://github.com/ollama/ollama/releases/download/$OLLAMA_VERSION/ollama-linux-amd64.tar.zst"
    local tmp=$KIT/tmp-ollama
    rm -rf "$tmp"; mkdir -p "$tmp"
    retry 3 curl -fL --retry 3 -o "$tmp/ollama.tar.zst" "$url"
    tar --use-compress-program=unzstd -xf "$tmp/ollama.tar.zst" -C "$tmp"
    rm -rf "$OLLAMA_DIR.new"; mkdir -p "$OLLAMA_DIR.new"
    mv "$tmp/bin" "$tmp/lib" "$OLLAMA_DIR.new/"
    rm -rf "${OLLAMA_DIR:?}/bin" "${OLLAMA_DIR:?}/lib"
    mkdir -p "$OLLAMA_DIR/models"
    mv "$OLLAMA_DIR.new/bin" "$OLLAMA_DIR.new/lib" "$OLLAMA_DIR/"
    rm -rf "$tmp" "$OLLAMA_DIR.new"
    "$OLLAMA_DIR/bin/ollama" --version || true
    stamp_set ollama "$OLLAMA_VERSION"
}

# ---- 6. studio config: point it at this box (only fills what the user has not set) --
seed_config() {
    log "seeding $LDS_DATA/config.json"
    "$LDS_DIR/.venv/bin/python" - "$LDS_DATA/config.json" <<PY
import json, os, sys, tempfile
path = sys.argv[1]
cfg = {}
if os.path.exists(path):
    try:
        with open(path, encoding='utf-8') as f:
            cfg = json.load(f)
    except ValueError:
        os.replace(path, path + '.broken')
        print('config.json was unreadable - kept as config.json.broken')
if not isinstance(cfg, dict):
    cfg = {}

def seed(dotted, value, replace=()):
    *parents, leaf = dotted.split('.')
    node = cfg
    for key in parents:
        if not isinstance(node.get(key), dict):
            node[key] = {}
        node = node[key]
    if node.get(leaf) in (None, '') or node.get(leaf) in replace:
        node[leaf] = value
        print(f'  {dotted} = {value}')

seed('comfyui.api_url', 'http://127.0.0.1:18188',
     replace=('http://127.0.0.1:8188', 'http://localhost:8188'))
seed('comfyui.base_dir', '$COMFY_DIR')
seed('ollama.url', 'http://127.0.0.1:11434')
if '$LDS_INSTALL_AITK' == '1':
    seed('aitoolkit.dir', '$AITK_DIR')
    seed('aitoolkit.python', '$AITK_DIR/.venv/bin/python')
    seed('aitoolkit.hf_home', '$WORKSPACE/.hf_home')

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix='.config.')
with os.fdopen(fd, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
os.replace(tmp, path)
PY
}

# ---- 7. ComfyUI custom node dependencies --------------------------------------------
# /venv/main is on the container disk, so packages the nodes on the volume need are
# gone on a new instance. Reinstall them (torch lines stripped, never swap torch).
comfy_node_deps() {
    [[ -d $COMFY_DIR/custom_nodes && -x /venv/main/bin/python ]] || return 0
    local req pins=$KIT/comfy-torch-pins.txt
    /venv/main/bin/python -c 'import torch, torchvision; print(f"torch=={torch.__version__}\ntorchvision=={torchvision.__version__}")' > "$pins" 2>/dev/null || : > "$pins"
    for req in "$COMFY_DIR"/custom_nodes/*/requirements.txt; do
        [[ -f $req ]] || continue
        grep -vE '^\s*(torch|torchvision|torchaudio|torchcodec)([[:space:]]|[<>=!~]|$)' "$req" > "$KIT/node-req.txt" || true
        [[ -s $KIT/node-req.txt ]] || continue
        log "node requirements: $(basename "$(dirname "$req")")"
        uv pip install --python /venv/main/bin/python -q -r "$KIT/node-req.txt" -c "$pins" \
            || warn "could not install requirements of $(dirname "$req") - that node pack may not load"
    done
    rm -f "$KIT/node-req.txt"
}

# ---- 8. services ---------------------------------------------------------------------
write_env_file() {
    cat > "$ENV_FILE" <<EOF
# Written by provision.sh - read by the lds and ollama supervisor scripts.
WORKSPACE=$WORKSPACE
LDS_KIT=$KIT
LDS_DIR=$LDS_DIR
LDS_DATA_DIR=$LDS_DATA
LDS_CONFIG=$LDS_DATA/config.json
LDS_ENV=$LDS_DATA/.env
LDS_HOST=127.0.0.1
LDS_PORT=$LDS_INTERNAL_PORT
LDS_AUTO_PORT=0
LDS_BIND_MANAGED=1
LDS_RESTART_MODE=supervisor
LDS_NO_REEXEC=1
LDS_PLUGIN_ADMIN_TOKEN=$(cat "$KIT/secrets/plugin-admin-token")
HF_HOME=$WORKSPACE/.hf_home
UV_PYTHON_INSTALL_DIR=$UV_PYTHON_INSTALL_DIR
UV_CACHE_DIR=$UV_CACHE_DIR
UV_LINK_MODE=$UV_LINK_MODE
OLLAMA_DIR=$OLLAMA_DIR
EOF
    chmod 600 "$ENV_FILE"
}

write_services() {
    cat > /opt/supervisor-scripts/lds.sh <<'EOF'
#!/bin/bash
utils=/opt/supervisor-scripts/utils
. "${utils}/logging.sh"
. "${utils}/cleanup_generic.sh"
. "${utils}/environment.sh"

while [ -f /.provisioning ]; do
    echo "$PROC_NAME waits for instance provisioning to finish (/.provisioning present)"
    sleep 5
done

set -a; . /etc/lds-vast.env; set +a
unset VIRTUAL_ENV PYTHONPATH PYTHONHOME UV_NO_CACHE
cd "$LDS_DIR"
# An in-app update may have changed requirements.txt; supervisor-mode restarts do not
# reinstall it themselves.
uv pip install --python .venv/bin/python -q -r backend/requirements.txt \
    || echo "WARNING: could not sync backend/requirements.txt"
.venv/bin/python backend/run.py 2>&1
EOF

    cat > /opt/supervisor-scripts/lds-ollama.sh <<'EOF'
#!/bin/bash
utils=/opt/supervisor-scripts/utils
. "${utils}/logging.sh"
. "${utils}/cleanup_generic.sh"
. "${utils}/environment.sh"

while [ -f /.provisioning ]; do
    echo "$PROC_NAME waits for instance provisioning to finish (/.provisioning present)"
    sleep 5
done

set -a; . /etc/lds-vast.env; set +a
export OLLAMA_HOST=127.0.0.1:11434
export OLLAMA_MODELS="$OLLAMA_DIR/models"
"$OLLAMA_DIR/bin/ollama" serve 2>&1
EOF
    chmod 755 /opt/supervisor-scripts/lds.sh /opt/supervisor-scripts/lds-ollama.sh

    local name
    for name in lds lds-ollama; do
        [[ $name == lds-ollama && $LDS_INSTALL_OLLAMA != 1 ]] && { rm -f /etc/supervisor/conf.d/lds-ollama.conf; continue; }
        cat > "/etc/supervisor/conf.d/$name.conf" <<EOF
[program:$name]
environment=PROC_NAME="%(program_name)s"
command=/opt/supervisor-scripts/$name.sh
autostart=true
autorestart=true
startsecs=10
startretries=20
stopasgroup=true
killasgroup=true
stopsignal=TERM
stopwaitsecs=30
stdout_logfile=/dev/stdout
redirect_stderr=true
stdout_events_enabled=true
stdout_logfile_maxbytes=0
stdout_logfile_backups=0
EOF
    done
    { supervisorctl reread >/dev/null && supervisorctl update; } || warn "supervisorctl update failed"
}

# The studio needs an entry in the Instance Portal: that is what makes Caddy serve
# port $LDS_EXTERNAL_PORT (with Vast's login) in front of the loopback-only app. The
# template's PORTAL_CONFIG should carry it; add it here if it does not.
ensure_portal_entry() {
    local yaml=/etc/portal.yaml py=/opt/portal-aio/venv/bin/python
    [[ -s $yaml && -x $py ]] || { warn "no /etc/portal.yaml - cannot check the portal entry"; return 0; }
    grep -q "$PORTAL_NAME" "$yaml" && return 0
    warn "PORTAL_CONFIG has no '$PORTAL_NAME' entry - adding it to $yaml"
    "$py" - "$yaml" "$PORTAL_NAME" "$LDS_EXTERNAL_PORT" "$LDS_INTERNAL_PORT" <<'PY'
import os, sys, tempfile, yaml
path, name, ext, internal = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
with open(path) as f:
    data = yaml.safe_load(f) or {}
apps = data.setdefault('applications', {})
apps[name] = {'hostname': 'localhost', 'external_port': ext, 'internal_port': internal,
              'open_path': '/', 'name': name}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd, 'w') as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)
os.chmod(tmp, 0o644)
os.replace(tmp, path)
PY
    supervisorctl restart caddy >/dev/null 2>&1 || true
    supervisorctl restart instance_portal tunnel_manager >/dev/null 2>&1 || true
    if [[ -z ${VAST_TCP_PORT_5050:-} ]]; then
        warn "port $LDS_EXTERNAL_PORT is not published (-p $LDS_EXTERNAL_PORT:$LDS_EXTERNAL_PORT missing in the template): use the Cloudflare link from the Instance Portal"
    fi
}

# ---- 9. helper commands --------------------------------------------------------------
write_helpers() {
    mkdir -p "$KIT/bin"
    cp -f "$0" "$KIT/provision.sh" 2>/dev/null || true

    cat > "$KIT/bin/lds-status" <<'EOF'
#!/bin/bash
# Short health report of the studio, ComfyUI and Ollama.
set -a; . /etc/lds-vast.env; set +a
supervisorctl status lds lds-ollama comfyui 2>/dev/null
printf '\nstudio  : '; curl -s -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:$LDS_PORT/" || echo down
printf 'ComfyUI : '; curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18188/system_stats || echo down
printf 'Ollama  : '; curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:11434/api/version || echo down
printf 'studio  @ %s\n' "$(git -C "$LDS_DIR" log -1 --format='%h %cs %s' 2>/dev/null)"
echo; df -h "$WORKSPACE" | tail -1 | awk '{print "volume  : " $3 " used, " $4 " free of " $2}'
# The studio sends deleted files to the OS trash, which for the volume is here:
[[ -d $WORKSPACE/.Trash-0 ]] && echo "trash   : $(du -sh "$WORKSPACE/.Trash-0" 2>/dev/null | cut -f1) in $WORKSPACE/.Trash-0 (empty it with: rm -rf $WORKSPACE/.Trash-0/*)"
command -v nvidia-smi >/dev/null && nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader
EOF

    cat > "$KIT/bin/lds-token" <<'EOF'
#!/bin/bash
# The operator token the studio's Plugins page asks for before installing plugins.
cat "$(. /etc/lds-vast.env; echo "$LDS_KIT")/secrets/plugin-admin-token"
EOF

    cat > "$KIT/bin/lds-restart" <<'EOF'
#!/bin/bash
supervisorctl restart lds
EOF

    cat > "$KIT/bin/comfy-restart" <<'EOF'
#!/bin/bash
# Run after the studio's Setup installed ComfyUI node packs: installs their Python
# requirements into ComfyUI's venv, then restarts ComfyUI so it registers them.
set -euo pipefail
set -a; . /etc/lds-vast.env; set +a
pins=$(mktemp)
/venv/main/bin/python -c 'import torch, torchvision; print(f"torch=={torch.__version__}\ntorchvision=={torchvision.__version__}")' > "$pins"
for req in "$WORKSPACE"/ComfyUI/custom_nodes/*/requirements.txt; do
    [[ -f $req ]] || continue
    filtered=$(mktemp)
    grep -vE '^\s*(torch|torchvision|torchaudio|torchcodec)([[:space:]]|[<>=!~]|$)' "$req" > "$filtered" || true
    if [[ -s $filtered ]]; then
        echo "requirements: $(basename "$(dirname "$req")")"
        uv pip install --python /venv/main/bin/python -q -r "$filtered" -c "$pins" || echo "  (failed - see above)"
    fi
    rm -f "$filtered"
done
rm -f "$pins"
supervisorctl restart comfyui
EOF

    cat > "$KIT/bin/lds-reprovision" <<'EOF'
#!/bin/bash
# Re-run the whole provisioning (safe: every step checks before it installs).
set -a; . /etc/lds-vast.env; set +a
exec bash "$LDS_KIT/provision.sh" "$@"
EOF

    chmod 755 "$KIT/bin/"*
    ln -sf "$KIT/bin/"* /usr/local/bin/
}

summary() {
    log "--------------------------------------------------------------------"
    log "LoRA Dataset Studio is provisioned."
    log "  open it from the Instance Portal ('Open' on the instance card) -> '$PORTAL_NAME'"
    log "  studio   : $LDS_DIR ($(git -C "$LDS_DIR" rev-parse --short HEAD))"
    log "  data     : $LDS_DATA"
    [[ $LDS_INSTALL_AITK == 1 ]] && log "  training : $AITK_DIR ($(git -C "$AITK_DIR" rev-parse --short HEAD))"
    [[ $LDS_INSTALL_OLLAMA == 1 ]] && log "  ollama   : $OLLAMA_VERSION, models in $OLLAMA_DIR/models"
    log "  helpers  : lds-status, lds-token, lds-restart, comfy-restart, lds-reprovision"
    log "--------------------------------------------------------------------"
}

main() {
    exec 9>"$WORKSPACE/.lds-provision.lock"
    flock -n 9 || die "another provisioning run holds $WORKSPACE/.lds-provision.lock"
    local started=$SECONDS
    log "provisioning LoRA Dataset Studio into $WORKSPACE"
    preflight
    system_packages
    secrets
    install_lds
    install_aitk
    install_ollama
    seed_config
    comfy_node_deps
    write_env_file
    write_helpers
    write_services
    ensure_portal_entry
    summary
    log "done in $(( (SECONDS - started) / 60 )) min $(( (SECONDS - started) % 60 )) s"
}

main "$@"
