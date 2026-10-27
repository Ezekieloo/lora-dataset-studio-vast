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
# On every start of the container the studio also updates itself to its author's
# latest version (LDS_AUTO_UPDATE) and downloads, through its own Setup installer,
# whatever models that version lists and the volume is still missing (LDS_MODELS).
#
# Safe to re-run: every step checks before it installs.
#   provision.sh          full provisioning (what Vast runs)
#   provision.sh deps     only re-sync the studio's Python dependencies
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
# Which models to fetch automatically on every start (only what is missing):
#   all       generation engines (Klein, Krea 2 Edit) + their ComfyUI nodes, the Ollama
#             vision model, quality tools, and every Test Studio family
#   generate  the same without the Test Studio families
#   none      nothing - use the studio's Setup screen by hand
#   a,b,c     an explicit list of the studio's Setup action names
LDS_MODELS=${LDS_MODELS:-all}
LDS_AUTO_UPDATE=${LDS_AUTO_UPDATE:-1}          # 1 = git pull the studio on every container start

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
LDS_MODELS=$LDS_MODELS
LDS_AUTO_UPDATE=$LDS_AUTO_UPDATE
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

# Follow the author's latest version once per container start, not on the in-app
# restarts in between (/dev/shm is emptied whenever the container stops).
# A Patreon members release (lds-patreon install) sits ahead of the public branch:
# the fast-forward-only pull keeps it until the public branch contains it.
if [[ ${LDS_AUTO_UPDATE:-1} == 1 && ! -f /dev/shm/lds-auto-updated ]]; then
    touch /dev/shm/lds-auto-updated
    before=$(git rev-parse --short HEAD)
    members=
    marker=$(git rev-parse -q --verify 'refs/lds/patreon/installed^{commit}' 2>/dev/null) \
        && git merge-base --is-ancestor "$marker" HEAD 2>/dev/null && members=1
    if [[ -n $(git status --porcelain --untracked-files=no 2>/dev/null) ]]; then
        echo "auto-update skipped: the studio checkout has local changes"
    elif branch=$(git symbolic-ref --short -q HEAD) && pull=$(timeout 300 git pull -q --ff-only origin "$branch" 2>&1); then
        after=$(git rev-parse --short HEAD)
        if [[ $before == "$after" ]]; then echo "studio is up to date ($after)"
        else echo "studio updated $before -> $after"; fi
    elif [[ -n $members ]]; then
        echo "studio is on the Patreon members release ($before) - newer members releases: lds-patreon install"
    else
        [[ -n ${pull:-} ]] && echo "$pull"
        echo "WARNING: auto-update failed - starting the installed version ($before)"
    fi
fi

# Python dependencies of the version about to start: an update (automatic or the
# in-app one) may have changed them, and supervisor-mode restarts do not reinstall
# them themselves. Fast when nothing changed.
bash "$LDS_KIT/provision.sh" deps || echo "WARNING: could not sync the studio's Python dependencies"
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

    cat > /opt/supervisor-scripts/lds-models.sh <<'EOF'
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
"$LDS_DIR/.venv/bin/python" "$LDS_KIT/lib/lds_models.py" 2>&1
EOF
    chmod 755 /opt/supervisor-scripts/lds.sh /opt/supervisor-scripts/lds-ollama.sh /opt/supervisor-scripts/lds-models.sh

    local name restart startsecs
    for name in lds lds-ollama lds-models; do
        [[ $name == lds-ollama && $LDS_INSTALL_OLLAMA != 1 ]] && { rm -f /etc/supervisor/conf.d/lds-ollama.conf; continue; }
        # lds-models is a one-shot job per container start; the other two are services.
        restart=true; startsecs=10
        [[ $name == lds-models ]] && { restart=false; startsecs=0; }
        cat > "/etc/supervisor/conf.d/$name.conf" <<EOF
[program:$name]
environment=PROC_NAME="%(program_name)s"
command=/opt/supervisor-scripts/$name.sh
autostart=true
autorestart=$restart
startsecs=$startsecs
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
    local yaml=/etc/portal.yaml py=/opt/portal-aio/venv/bin/python port_var=VAST_TCP_PORT_$LDS_EXTERNAL_PORT
    # Caddy only serves ports Vast actually published, and the Cloudflare link goes
    # through that same Caddy port - without it the studio is unreachable.
    if [[ -z ${!port_var:-} ]]; then
        warn "port $LDS_EXTERNAL_PORT is not published: add '-p $LDS_EXTERNAL_PORT:$LDS_EXTERNAL_PORT' to the template's Docker options, otherwise the studio cannot be opened"
    fi
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
}

# ---- 9. helper commands --------------------------------------------------------------
write_helpers() {
    mkdir -p "$KIT/bin"
    cp -f "$0" "$KIT/provision.sh" 2>/dev/null || true

    cat > "$KIT/bin/lds-status" <<'EOF'
#!/bin/bash
# Short health report of the studio, ComfyUI and Ollama.
set -a; . /etc/lds-vast.env; set +a
supervisorctl status lds lds-ollama lds-models comfyui 2>/dev/null
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

    cat > "$KIT/bin/lds-models" <<'EOF'
#!/bin/bash
# Download the missing models now: lds-models [all|generate|action,action,...]
set -a; . /etc/lds-vast.env; set +a
exec "$LDS_DIR/.venv/bin/python" "$LDS_KIT/lib/lds_models.py" "$@"
EOF

    mkdir -p "$KIT/lib"
    cat > "$KIT/lib/lds_models.py" <<'PY'
"""Download the models LoRA Dataset Studio lists in its own Setup screen.

Runs once per container start (supervisor program lds-models) and asks the studio's
own installer - the same Setup API its buttons use - for whatever is still missing.
The list therefore follows the installed studio version: when its author changes or
adds a model, the next start fetches it. Files already on the volume are skipped by
the studio itself.

    lds-models [all|generate|none|action,action,...]      default: $LDS_MODELS
    lds-models plan                                        what "all" would fetch, changes nothing
"""
import http.cookiejar
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = 'http://127.0.0.1:%s' % os.environ.get('LDS_PORT', '15050')
ACTIVE = {'queued', 'running'}
NODE_PACKS = {'krea_nodes', 'lanpaint_nodes', 'krea_sampler_nodes'}
# Quality tools Setup offers outside "Install everything". bank_scoring stays out on
# purpose: the studio venv already scores on the GPU, and that Setup action would
# move scoring into a CPU-only environment.
QUALITY_TOOLS = ('watermark_detect', 'bank_siglip2')

_opener = urllib.request.build_opener(
    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
_csrf = None
_dry_run = False


def log(msg):
    print('[lds-models] %s %s' % (time.strftime('%H:%M:%S'), msg), flush=True)


def call(method, path, body=None, timeout=60):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(API + path, data=data, method=method)
    if data is not None:
        req.add_header('Content-Type', 'application/json')
    if _csrf and method != 'GET':
        req.add_header('X-CSRFToken', _csrf)
    try:
        with _opener.open(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read() or b'null')
    except urllib.error.HTTPError as exc:
        try:
            return exc.code, json.loads(exc.read() or b'null')
        except ValueError:
            return exc.code, None
    except (urllib.error.URLError, OSError, ValueError) as exc:
        return None, {'error': str(exc)}


def wait_for(url, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=5):
                return True
        except Exception:
            time.sleep(5)
    return False


def error_of(code, body):
    return (body or {}).get('error') or 'HTTP %s' % code


def start(action, started):
    if _dry_run:
        started.append(action)
        return
    code, body = call('POST', '/api/setup/install/' + action, {})
    if code in (200, 409):          # 409 = already running: wait for it as well
        started.append(action)
    else:
        log('cannot start %s: %s' % (action, error_of(code, body)))


def queue_everything(mode, started):
    if mode not in ('all', 'generate'):
        for action in filter(None, (a.strip() for a in mode.split(','))):
            start(action, started)
        return

    # 1. the studio's own "Install everything": Klein, the Ollama vision model and
    #    whichever core extras its probes report missing
    if _dry_run:
        code, body = call('GET', '/api/setup/install-all/plan')
    else:
        code, body = call('POST', '/api/setup/install-all', {})
    if code == 200:
        started.extend(body.get('plan') or [])
    else:
        log('install-all refused: %s' % error_of(code, body))

    # 2. the second engine, Krea 2 Edit (nodes + weights), which "everything" skips
    code, body = call('GET', '/api/setup/install-group/krea/plan')
    if code == 200 and body.get('plan') and _dry_run:
        started.extend(body['plan'])
    elif code == 200 and body.get('plan'):
        code, body = call('POST', '/api/setup/install-group/krea', {})
        if code == 200:
            started.extend(body.get('plan') or [])
        else:
            log('Krea 2 Edit refused: %s' % error_of(code, body))

    # 3. node packs and quality tools the probes report missing
    _, caps = call('GET', '/api/capabilities')
    caps = caps or {}
    comfy = caps.get('comfyui') or {}
    for pack in ('lanpaint_nodes', 'krea_sampler_nodes'):
        if not comfy.get(pack + '_installed'):
            start(pack, started)
    for tool in QUALITY_TOOLS:
        if not caps.get(tool):
            start(tool, started)


def queue_test_studio(started):
    """Every Test Studio family the studio knows, missing files only.

    Queued as a second wave, after the engines: some of these files share their
    name and folder with an engine's file (Anima's VAE is the same
    vae/qwen_image_vae.safetensors as Krea 2 Edit's), and two downloads writing one
    file at once break each other. For the same reason no two actions in this
    wave may target the same file name."""
    code, body = call('GET', '/api/comfy/trained-image-models', timeout=180)
    if code != 200:
        log('could not list the Test Studio models: %s' % error_of(code, body))
    names = set()
    for family in (body or {}).get('families') or []:
        files = {d.get('action'): d.get('filename') for d in family.get('downloads') or []}
        for action in family.get('install_actions') or []:
            name = files.get(action)
            if name and name in names:
                log('%s: %s is already queued by another family' % (action, name))
                continue
            names.add(name)
            start(action, started)


def describe(state):
    progress = state.get('progress') or {}
    if progress.get('pct') is not None:
        return '%s %d%% of %.1f GB' % (state.get('state'), progress['pct'],
                                       (progress.get('total') or 0) / 1e9)
    return state.get('state') or '?'


def restart_comfyui():
    log('new ComfyUI nodes - installing their requirements and restarting ComfyUI')
    subprocess.call([os.path.join(os.environ.get('LDS_KIT', '/workspace/.lds'), 'bin', 'comfy-restart')])


def wait_until_done(actions, hours=10):
    deadline = time.time() + hours * 3600
    last_report = 0
    seen = {}
    packs = [a for a in actions if a in NODE_PACKS]
    restarted = not packs
    while True:
        _, body = call('GET', '/api/setup/install-all/status?actions=' + ','.join(actions))
        statuses = (body or {}).get('statuses') or {}
        busy = [a for a in actions if (statuses.get(a) or {}).get('state') in ACTIVE]
        for action in actions:
            state = (statuses.get(action) or {}).get('state')
            if state != seen.get(action) and state not in ACTIVE:
                log('%s: %s' % (action, state))
            seen[action] = state
        # Node packs take seconds, the weights can take an hour: restart ComfyUI as
        # soon as the packs are in, so the engines do not wait for every download.
        if not restarted and not any(a in busy for a in packs):
            restarted = True
            if any((statuses.get(a) or {}).get('state') == 'success' for a in packs):
                restart_comfyui()
        if not busy or time.time() > deadline:
            return statuses
        if time.time() - last_report > 120:
            last_report = time.time()
            log('still downloading: ' + ', '.join(
                '%s (%s)' % (a, describe(statuses.get(a) or {})) for a in busy))
        time.sleep(15)


def main():
    global _csrf, _dry_run
    mode = (sys.argv[1] if len(sys.argv) > 1 else os.environ.get('LDS_MODELS') or 'all').strip()
    if mode.lower() == 'none':
        log('LDS_MODELS=none - nothing to download automatically')
        return 0
    if mode.lower() == 'plan':
        _dry_run, mode = True, 'all'
    mode = mode.lower() if mode.lower() in ('all', 'generate') else mode
    if _dry_run:
        started = []
        queue_everything(mode, started)
        queue_test_studio(started)
        log('"all" would fetch %d item(s): %s' % (len(started), ', '.join(started) or 'nothing'))
        return 0
    if not wait_for(API + '/api/health', 1800):
        log('the studio did not start - no models downloaded')
        return 1
    # The Ollama model pull needs Ollama, the node packs and downloads a ComfyUI tree.
    wait_for('http://127.0.0.1:11434/api/version', 180)
    wait_for('http://127.0.0.1:18188/system_stats', 900)
    code, body = call('GET', '/api/csrf-token')
    if code != 200:
        log('no CSRF token from the studio: %s' % error_of(code, body))
        return 1
    _csrf = body['csrf_token']

    actions, statuses = [], {}
    waves = [queue_everything] + ([queue_test_studio] if mode == 'all' else [])
    for wave in waves:
        started = []
        if wave is queue_everything:
            wave(mode, started)
        else:
            wave(started)
        batch = [a for a in dict.fromkeys(started) if a not in actions]
        if not batch:
            continue
        log('downloading/installing %d item(s): %s' % (len(batch), ', '.join(batch)))
        statuses.update(wait_until_done(batch))
        actions.extend(batch)
    if not actions:
        log('every model the studio lists for "%s" is already on the volume' % mode)
        return 0

    failed = []
    for action in actions:
        state = statuses.get(action) or {}
        if state.get('state') != 'success':
            failed.append(action)
            for line in (state.get('log') or [])[-4:]:
                log('  %s | %s' % (action, line))
    if failed:
        log('not installed: %s' % ', '.join(failed))
        joined = ' '.join(' '.join((statuses.get(a) or {}).get('log') or []) for a in failed).lower()
        if 'civitai' in joined:
            log('hint: add your Civitai API key in the studio (Settings), then run lds-models or restart the instance')
        if 'huggingface' in joined or ' 401' in joined or ' 403' in joined:
            log('hint: gated model - accept its licence on Hugging Face and add your HF token in the studio Settings')
        return 1
    log('all models are ready')
    return 0


if __name__ == '__main__':
    sys.exit(main())
PY

    cat > "$KIT/bin/lds-patreon" <<'EOF'
#!/bin/bash
# Patreon members version of the studio: lds-patreon [status|install]
set -a; . /etc/lds-vast.env; set +a
exec "$LDS_DIR/.venv/bin/python" "$LDS_KIT/lib/lds_patreon.py" "$@"
EOF

    cat > "$KIT/lib/lds_patreon.py" <<'PY'
"""Install the Patreon members version of LoRA Dataset Studio from the terminal.

The studio's own button (Settings > Maintenance > Updates) does not send the plugin
admin token, and the studio requires that token from every browser that reaches it
through this host's login proxy - so the button is refused here. This asks the same
studio API, with the token, from inside the instance.

    lds-patreon            membership and members release status
    lds-patreon install    install the members release; the studio then restarts

Exit codes: 0 done or up to date, 1 the studio refused (reason printed), 2 the studio
could not be asked (down, token or CSRF refused).
"""
import http.cookiejar
import json
import os
import sys
import time
import urllib.error
import urllib.request

API = 'http://127.0.0.1:%s' % os.environ.get('LDS_PORT', '15050')
ADMIN = os.environ.get('LDS_PLUGIN_ADMIN_TOKEN', '')
CONNECT = ('Connect Patreon first: in the studio open Plugins, unlock it with the token from '
           'lds-token, press Connect Patreon and enter the code the Patreon page shows.')

_opener = urllib.request.build_opener(
    urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))


def log(msg):
    print('[lds-patreon] %s' % msg, flush=True)


def call(method, path, csrf=None, timeout=60):
    req = urllib.request.Request(API + path, method=method, data=b'{}' if method == 'POST' else None)
    req.add_header('X-LDS-Plugin-Admin', ADMIN)
    if method == 'POST':
        req.add_header('Content-Type', 'application/json')
        req.add_header('X-CSRFToken', csrf or '')
    try:
        with _opener.open(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read() or b'null')
    except urllib.error.HTTPError as exc:
        try:
            return exc.code, json.loads(exc.read() or b'null')
        except ValueError:
            return exc.code, None
    except (urllib.error.URLError, OSError, ValueError) as exc:
        return None, {'error': str(exc)}


def reason(body):
    if isinstance(body, dict):
        return body.get('reason') or body.get('error') or body.get('message') or json.dumps(body)[:300]
    return str(body)


def status():
    """The studio's Patreon channel answer, or None after printing why not."""
    code, body = call('GET', '/api/update/patreon?force=1', timeout=120)
    if code is None:
        log('the studio does not answer on %s: %s' % (API, reason(body)))
        return None
    if code != 200 or not isinstance(body, dict):
        log('the studio refused the status request (HTTP %s): %s' % (code, reason(body)))
        return None
    if not body.get('can_manage'):
        log('the studio refused the plugin admin token - is LDS_PLUGIN_ADMIN_TOKEN in /etc/lds-vast.env?')
        return None
    return body


def report(s):
    patreon = (s.get('access') or {}).get('patreon') or {}
    release = s.get('release') or {}
    channel = 'members' if s.get('on_channel') else 'public'
    log('studio     : %s (%s version)' % (s.get('current'), channel))
    if s.get('status') != 'ready':
        log('channel    : %s - %s' % (s.get('status'), s.get('message') or 'no details'))
        return
    if not patreon.get('linked'):
        log('membership : Patreon is not connected to this studio')
    else:
        log('membership : %s%s' % (patreon.get('status'), ', tier ' + patreon['tier'] if patreon.get('tier') else ''))
    log('members    : %s' % (release.get('version') or 'no members release published yet'))
    if s.get('restart_required'):
        log('state      : installed, waiting for a restart (lds-restart)')
    elif not s.get('update_available'):
        log('state      : up to date')
    elif s.get('blocked_reason'):
        log('state      : blocked - %s' % s['blocked_reason'])
    elif not s.get('entitled'):
        log('state      : available to active members - ' + CONNECT)
    else:
        log('state      : ready - run: lds-patreon install')


def wait_for_restart(old_version):
    """The old process exits; supervisor starts the new one, after syncing its
    Python dependencies when the release changed them."""
    deadline = time.time() + 30
    while time.time() < deadline and call('GET', '/api/health', timeout=5)[0] == 200:
        time.sleep(1)
    log('the studio is restarting (new dependencies, if any, install first) ...')
    deadline = time.time() + 1800
    while time.time() < deadline:
        if call('GET', '/api/health', timeout=5)[0] == 200:
            s = status()
            if s:
                log('the studio is back: %s -> %s' % (old_version, s.get('current')))
                report(s)
                return 0
            return 2
        time.sleep(10)
    log('the studio did not come back within 30 minutes - see: supervisorctl tail lds')
    return 2


def install():
    s = status()
    if s is None:
        return 2
    report(s)
    if s.get('status') == 'ready' and not s.get('update_available') and not s.get('restart_required'):
        return 0
    code, body = call('GET', '/api/csrf-token')
    if code != 200 or not isinstance(body, dict):
        log('no CSRF token from the studio (HTTP %s): %s' % (code, reason(body)))
        return 2
    log('installing the members release (download, verify, fast-forward) ...')
    # The studio decides: membership, running work, a checkout it cannot fast-forward.
    code, body = call('POST', '/api/update/patreon/apply', csrf=body['csrf_token'], timeout=1800)
    if code in (400, 403) or code is None:
        log('the studio refused the request itself (HTTP %s): %s' % (code, reason(body)))
        return 2
    body = body if isinstance(body, dict) else {}
    if code != 200:
        log('not installed: %s' % reason(body))
        refusal = body.get('code')
        if refusal == 'patreon_required':
            log(CONNECT)
        elif refusal == 'update_blocked':
            log('wait for the running work to finish (lds-status, supervisorctl tail -f lds-models), then retry')
        return 1
    if body.get('restarting'):
        return wait_for_restart(s.get('current'))
    if body.get('restart_required'):
        log('installed - restart the studio to finish: lds-restart')
        return 0
    log(reason(body) if body.get('reason') else 'already installed')
    return 0


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else 'status'
    if command == 'install':
        return install()
    if command != 'status':
        print(__doc__)
        return 2
    s = status()
    if s is None:
        return 2
    report(s)
    return 0


if __name__ == '__main__':
    sys.exit(main())
PY

    chmod 755 "$KIT/bin/"*
    ln -sf "$KIT/bin/"* /usr/local/bin/
}

summary() {
    log "--------------------------------------------------------------------"
    log "LoRA Dataset Studio is provisioned."
    log "  open it with 'Open' on the instance card (OPEN_BUTTON_PORT=$LDS_EXTERNAL_PORT) or the '$PORTAL_NAME' tile"
    log "  studio   : $LDS_DIR ($(git -C "$LDS_DIR" rev-parse --short HEAD)), auto-update: $LDS_AUTO_UPDATE"
    log "  data     : $LDS_DATA"
    log "  models   : '$LDS_MODELS' - downloading in the background (log: supervisorctl tail -f lds-models)"
    [[ $LDS_INSTALL_AITK == 1 ]] && log "  training : $AITK_DIR ($(git -C "$AITK_DIR" rev-parse --short HEAD))"
    [[ $LDS_INSTALL_OLLAMA == 1 ]] && log "  ollama   : $OLLAMA_VERSION, models in $OLLAMA_DIR/models"
    log "  helpers  : lds-status, lds-models, lds-token, lds-patreon, lds-restart, comfy-restart, lds-reprovision"
    log "--------------------------------------------------------------------"
}

main() {
    if [[ ${1:-} == deps ]]; then
        # Called by the studio's service before every start.
        exec 9>"$WORKSPACE/.lds-provision.lock"
        flock -w 900 9 || die "provisioning still holds $WORKSPACE/.lds-provision.lock"
        lds_deps
        return
    fi
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
