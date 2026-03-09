#!/bin/bash
# =============================================
#  Forzar CDP en perfil DiCloak (macOS)
#  Equivalente de forzar_cdp_perfil_dicloak.ps1
# =============================================

PREFERRED_PORT="${1:-9225}"
TIMEOUT_SEC="${2:-60}"
OPEN_DEBUG="${3:-}"

DICLOAK_DATA="$HOME/Library/Application Support/DICloak"
CDP_INFO="$DICLOAK_DATA/cdp_debug_info.json"

# Buscar proceso principal de ginsbrowser (sin --type=)
get_main_gins_pid() {
    ps aux | grep -i "ginsbrowser" | grep -v "grep" | grep -v "\-\-type=" | awk '{print $2}' | head -1
}

get_main_gins_cmd() {
    MAIN_PID=$(get_main_gins_pid)
    [ -z "$MAIN_PID" ] && return 1
    ps -o command= -p "$MAIN_PID" 2>/dev/null
}

test_cdp_port() {
    local port=$1
    curl -s --max-time 2 "http://127.0.0.1:$port/json/version" 2>/dev/null | grep -q "webSocketDebuggerUrl"
}

get_free_port() {
    local start=$1
    local span=${2:-200}
    for ((p=start; p<=start+span; p++)); do
        if ! lsof -ti :$p >/dev/null 2>&1; then
            echo $p
            return
        fi
    done
    echo $start
}

upsert_cdp_info() {
    local port=$1
    local ws_url=$2
    local pid=$3
    local env_id="${4:-unknown_env}"

    mkdir -p "$(dirname "$CDP_INFO")"

    if [ -f "$CDP_INFO" ]; then
        EXISTING=$(cat "$CDP_INFO" 2>/dev/null || echo "{}")
    else
        EXISTING="{}"
    fi

    python3 -c "
import json, sys
try:
    data = json.loads('''$EXISTING''')
except:
    data = {}
data['$env_id'] = {
    'debugPort': $port,
    'webSocketUrl': '$ws_url',
    'pid': $pid,
    'envId': '$env_id'
}
print(json.dumps(data, indent=2))
" > "$CDP_INFO" 2>/dev/null

    echo "$CDP_INFO"
}

# --- Main ---
MAIN_PID=$(get_main_gins_pid)
if [ -z "$MAIN_PID" ]; then
    echo "ERROR=NO_MAIN_GINS_PROCESS"
    exit 1
fi

CMD=$(get_main_gins_cmd)

# Extraer env_id del comando
ENV_ID=$(python3 - "$CMD" <<'PY'
import re, sys
cmd = sys.argv[1] if len(sys.argv) > 1 else ""
m = re.search(r"\.DICloakCache/(\d{10,})/", cmd)
print(m.group(1) if m else "")
PY
)
[ -z "$ENV_ID" ] && ENV_ID="unknown_env"

# Verificar si ya tiene debug port activo
EXISTING_PORT=$(python3 - "$CMD" <<'PY'
import re, sys
cmd = sys.argv[1] if len(sys.argv) > 1 else ""
m = re.search(r"--remote-debugging-port(?:=|\s+)(\d+)", cmd)
print(m.group(1) if m else "")
PY
)
if [ -n "$EXISTING_PORT" ] && test_cdp_port "$EXISTING_PORT"; then
    WS_URL=$(curl -s "http://127.0.0.1:$EXISTING_PORT/json/version" | python3 -c "import json,sys; print(json.load(sys.stdin).get('webSocketDebuggerUrl',''))" 2>/dev/null)
    CDP_PATH=$(upsert_cdp_info "$EXISTING_PORT" "$WS_URL" "$MAIN_PID" "$ENV_ID")
    echo "DEBUG_PORT=$EXISTING_PORT"
    echo "CDP_JSON_PATH=$CDP_PATH"
    exit 0
fi

# Necesita reiniciar con debug port
TARGET_PORT=$(get_free_port "$PREFERRED_PORT")

# Matar ginsbrowser actual
pkill -f "ginsbrowser" 2>/dev/null
sleep 1

# Reconstruir comando con debug port
# Lanzar el proceso de forma segura (sin eval) para soportar rutas con espacios.
NEW_PID=$(python3 - "$CMD" "$TARGET_PORT" <<'PY'
import os
import re
import shlex
import subprocess
import sys

cmd = sys.argv[1] if len(sys.argv) > 1 else ""
target_port = sys.argv[2] if len(sys.argv) > 2 else "9225"

if not cmd.strip():
    print("ERROR=EMPTY_CMD")
    raise SystemExit(1)

try:
    args = shlex.split(cmd)
except Exception:
    print("ERROR=PARSE_CMD_FAILED")
    raise SystemExit(1)

if not args:
    print("ERROR=NO_ARGS")
    raise SystemExit(1)

new_args = []
i = 0
replaced = False
while i < len(args):
    a = args[i]
    if a == "--remote-debugging-port":
        new_args.extend([a, str(target_port)])
        replaced = True
        i += 2
        continue
    m = re.match(r"^--remote-debugging-port=(\d+)$", a)
    if m:
        new_args.append(f"--remote-debugging-port={target_port}")
        replaced = True
        i += 1
        continue
    new_args.append(a)
    i += 1

if not replaced:
    new_args.append(f"--remote-debugging-port={target_port}")

proc = subprocess.Popen(
    new_args,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    preexec_fn=os.setsid,
)
print(proc.pid)
PY
)
if ! echo "$NEW_PID" | grep -Eq '^[0-9]+$'; then
    echo "ERROR=RELAUNCH_FAILED DETAIL=$NEW_PID"
    exit 1
fi

# Esperar a que CDP responda
DEADLINE=$((SECONDS + TIMEOUT_SEC))
OK=0
while [ $SECONDS -lt $DEADLINE ]; do
    if test_cdp_port "$TARGET_PORT"; then
        OK=1
        break
    fi
    sleep 0.6
done

if [ $OK -eq 0 ]; then
    echo "ERROR=DEBUG_PORT_NOT_READY PORT=$TARGET_PORT"
    exit 1
fi

WS_URL=$(curl -s "http://127.0.0.1:$TARGET_PORT/json/version" | python3 -c "import json,sys; print(json.load(sys.stdin).get('webSocketDebuggerUrl',''))" 2>/dev/null)
CDP_PATH=$(upsert_cdp_info "$TARGET_PORT" "$WS_URL" "$NEW_PID" "$ENV_ID")

echo "DEBUG_PORT=$TARGET_PORT"
echo "DEBUG_WS=$WS_URL"
echo "PID=$NEW_PID"
echo "ENV_ID=$ENV_ID"
echo "CDP_JSON_PATH=$CDP_PATH"

exit 0
