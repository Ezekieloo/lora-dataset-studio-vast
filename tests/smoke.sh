#!/bin/bash
# Boots the real vastai/comfy image with provision.sh, the way a Vast template does,
# on a CPU-only host, and checks that every service comes up behind Caddy's login.
#
#   tests/smoke.sh first    empty volume: full install
#   tests/smoke.sh second   same volume, brand-new container: must reuse the install
#
# Needs Docker and ~60 GB free. IMAGE, VOL and KITDIR can be overridden.
set -Eeuo pipefail

MODE=${1:?usage: smoke.sh first|second}
IMAGE=${IMAGE:-vastai/comfy:v0.41.0-cuda-12.9-py312}
VOL=${VOL:-/mnt/lds-smoke/workspace}
KITDIR=${KITDIR:-/mnt/lds-smoke/kit}
TOKEN=ci-open-button-token-0123456789
NAME=lds-smoke-$MODE
HERE=$(cd "$(dirname "$0")/.." && pwd)

say()  { echo "::group::$*" 2>/dev/null || true; echo "== $*"; }
done_group() { echo "::endgroup::" 2>/dev/null || true; }
fail() { echo "FAIL: $*" >&2; exit 1; }
inside() { docker exec "$NAME" bash -lc "$*"; }

wait_for() {  # wait_for <seconds> <description> <command...>
    local limit=$1 what=$2 t=0; shift 2
    until "$@" >/dev/null 2>&1; do
        docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null | grep -q true \
            || fail "container stopped while waiting for: $what"
        (( t >= limit )) && fail "timed out after ${limit}s waiting for: $what"
        sleep 10; t=$((t + 10))
    done
    echo "ok: $what (${t}s)"
}

say "start $NAME from $IMAGE"
sudo mkdir -p "$VOL" "$KITDIR"
sudo cp "$HERE/provision.sh" "$KITDIR/provision.sh"
docker rm -f lds-smoke-first lds-smoke-second >/dev/null 2>&1 || true
docker run -d --name "$NAME" \
    -v "$VOL:/workspace" \
    -v "$KITDIR:/kit" \
    -e PROVISIONING_SCRIPT=/kit/provision.sh \
    -e PROVISIONER_RETRY_MAX=1 \
    -e OPEN_BUTTON_TOKEN="$TOKEN" \
    -e OPEN_BUTTON_PORT=1111 \
    -e DATA_DIRECTORY=/workspace/ \
    -e PORTAL_CONFIG="localhost:1111:11111:/:Instance Portal|localhost:8188:18188:/:ComfyUI|localhost:5050:15050:/:LoRA Dataset Studio" \
    -e COMFYUI_ARGS="--disable-auto-launch --port 18188 --enable-cors-header --cpu" \
    -e LDS_AITK_CPU=1 \
    -p 127.0.0.1:5050:5050 \
    "$IMAGE" >/dev/null
started=$SECONDS
done_group

say "provisioning"
wait_for 5400 "provisioning finished" \
    docker exec "$NAME" bash -c 'test -f /.provisioning_complete || test -f /.provisioning_failed'
if docker exec "$NAME" test -f /.provisioning_failed; then
    docker logs "$NAME" 2>&1 | tail -150
    fail "provisioning reported failure"
fi
echo "provisioned in $(( (SECONDS - started) / 60 )) min"
done_group

say "services"
wait_for 600 "studio answers on loopback :15050" docker exec "$NAME" curl -sf http://127.0.0.1:15050/api/health
wait_for 600 "ComfyUI answers on :18188"       docker exec "$NAME" curl -sf http://127.0.0.1:18188/system_stats
wait_for 300 "Ollama answers on :11434"        docker exec "$NAME" curl -sf http://127.0.0.1:11434/api/version
# exit 3 = some image service is not running (jupyter/syncthing are off in CI)
inside 'supervisorctl status' || true
inside 'supervisorctl status lds lds-ollama comfyui' || fail "a studio service is not running"
done_group

say "Caddy login in front of the studio"
code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5050/api/health || true)
echo "without credentials: HTTP $code"
[[ $code == 401 || $code == 403 || $code == 302 ]] || fail "studio reachable without Vast's login (HTTP $code)"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" http://127.0.0.1:5050/api/health)
echo "with the Open-button token: HTTP $code"
[[ $code == 200 ]] || fail "studio not reachable through Caddy with the token (HTTP $code)"
curl -sf -H "Authorization: Bearer $TOKEN" http://127.0.0.1:5050/ | grep -qi '<div id="root"' \
    || fail "the studio page did not render through Caddy"
done_group

say "environments"
inside '/workspace/lora-dataset-studio/.venv/bin/python -c "import flask, torch, insightface, cv2, open_clip, rembg; print(\"studio venv:\", torch.__version__)"'
inside '/workspace/ai-toolkit/.venv/bin/python -c "import torch, transformers, accelerate, bitsandbytes; print(\"ai-toolkit venv:\", torch.__version__)"'
inside 'readlink -f /workspace/lora-dataset-studio/.venv/bin/python /workspace/ai-toolkit/.venv/bin/python'
inside 'readlink -f /workspace/lora-dataset-studio/.venv/bin/python | grep -q "^/workspace/"' \
    || fail "the studio venv interpreter is not on the volume"
inside 'readlink -f /workspace/ai-toolkit/.venv/bin/python | grep -q "^/workspace/"' \
    || fail "the ai-toolkit venv interpreter is not on the volume"
done_group

say "studio configuration"
inside 'cat /workspace/lds-data/config.json'
inside '/workspace/lora-dataset-studio/.venv/bin/python - <<"PY"
import json
c = json.load(open("/workspace/lds-data/config.json"))
assert c["comfyui"]["api_url"] == "http://127.0.0.1:18188", c["comfyui"]
assert c["comfyui"]["base_dir"] == "/workspace/ComfyUI", c["comfyui"]
assert c["aitoolkit"]["dir"] == "/workspace/ai-toolkit", c["aitoolkit"]
assert c["aitoolkit"]["python"] == "/workspace/ai-toolkit/.venv/bin/python", c["aitoolkit"]
print("config ok")
PY'
inside 'curl -sf http://127.0.0.1:15050/api/capabilities' > /tmp/caps.json || fail "/api/capabilities failed"
python3 - /tmp/caps.json <<'PY'
import json, sys
caps = json.load(open(sys.argv[1]))
for key in ("comfyui", "aitoolkit", "ollama"):
    value = caps.get(key)
    if isinstance(value, dict):
        short = {k: v for k, v in value.items() if not isinstance(v, (dict, list))}
        print(f"{key}: {json.dumps(short)[:600]}")
    else:
        print(f"{key}: {value!r}")
PY
inside 'lds-status' || true
test -n "$(inside 'lds-token')" || fail "lds-token printed nothing"
done_group

if [[ $MODE == second ]]; then
    say "second boot reused the volume"
    docker logs "$NAME" 2>&1 | grep -E 'studio dependencies up to date|ai-toolkit environment up to date|Ollama .* present' \
        || fail "the second boot reinstalled instead of reusing the volume"
    done_group
fi

echo "SMOKE $MODE PASSED in $(( (SECONDS - started) / 60 )) min"
