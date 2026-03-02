#!/bin/bash
# ==========================================
# Openclaw Official Registry Deployment Script (Final)
# ==========================================
set -e
set -o pipefail

# --- 색상 및 경로 정의 ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

BASHRC="$HOME/.bashrc"
NPM_GLOBAL="$HOME/.npm-global"
NPM_BIN="$NPM_GLOBAL/bin"
LOG_DIR="$HOME/openclaw-logs"
LOG_FILE="$LOG_DIR/install.log"

# --- 고정 설정 (노트북 WSL2 Verdaccio) ---
REGISTRY="http://100.68.95.44:4873"
PKG_SOURCE="openclaw"

# --- 유틸리티 함수 ---
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"; }
run_cmd() { log "명령 실행: $@"; "$@"; }

# --- 핵심 로직 함수 ---
check_deps() {
    echo -e "${YELLOW}[1/5] 기초 실행 환경 검사 및 Node.js 설치...${NC}"
    if ! command -v node &> /dev/null || ! command -v npm &> /dev/null; then
        echo -e "${CYAN}Node.js 설치 중...${NC}"
        run_cmd pkg update -y
        run_cmd pkg install nodejs -y
        hash -r  # 커맨드 해시 갱신
    fi

    echo -e "${BLUE}📡 로컬 레지스트리 연결: $REGISTRY${NC}"
    npm config set registry "$REGISTRY"
    
    DEPS=("git" "openssh" "tmux" "termux-api" "termux-tools" "cmake" "python" "golang" "which")
    MISSING_DEPS=()
    for dep in "${DEPS[@]}"; do
        if ! command -v $dep &> /dev/null; then MISSING_DEPS+=($dep); fi
    done

    if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
        echo -e "${CYAN}의존성 설치 중: ${MISSING_DEPS[*]}${NC}"
        run_cmd pkg install ${MISSING_DEPS[*]} -y
    fi
}

configure_npm() {
    echo -e "\n${YELLOW}[2/5] 패키지 설치 중 (via Laptop Cache)...${NC}"
    mkdir -p "$NPM_GLOBAL"
    npm config set prefix "$NPM_GLOBAL"
    export PATH="$NPM_BIN:$PATH"

    run_cmd env NODE_LLAMA_CPP_SKIP_DOWNLOAD=true npm i -g "$PKG_SOURCE" --ignore-scripts
    BASE_DIR="$NPM_GLOBAL/lib/node_modules/openclaw"
}

apply_koffi_stub() {
    KOFFI_DIR="$BASE_DIR/node_modules/koffi"
    if [ -d "$KOFFI_DIR" ]; then
        echo -e "${CYAN}Koffi 안드로이드 스텁 적용...${NC}"
        cat > "$KOFFI_DIR/index.js" << 'EOF'
const handler = { get(_, prop) { 
    if (prop === '__esModule') return false;
    if (prop === 'default') return proxy;
    return function() { throw new Error('koffi stub: not available on android-arm64'); };
}};
const proxy = new Proxy({}, handler);
module.exports = proxy;
module.exports.default = proxy;
EOF
    fi
}

apply_patches() {
    echo -e "${YELLOW}[3/5] Android 호환성 패치 적용 중...${NC}"
    FILES=$(grep -rl "/tmp/openclaw" "$BASE_DIR/dist" 2>/dev/null || true)
    for f in $FILES; do
        node -e "const fs=require('fs');let c=fs.readFileSync('$f','utf8');fs.writeFileSync('$f',c.replace(/\/tmp\/openclaw/g, process.env.HOME+'/openclaw-logs'));"
    done
    
    CLIP_DIR="$BASE_DIR/node_modules/@mariozechner/clipboard"
    if [ -d "$CLIP_DIR" ]; then
        echo "module.exports = { availableFormats:()=>[], getText:()=>'', setText:()=>false, watch:()=>({stop:()=>{}}) };" > "$CLIP_DIR/index.js"
    fi
}

setup_autostart() {
    echo -e "${YELLOW}[4/5] Alias 설정 중...${NC}"
    run_cmd sed -i '/# --- OpenClaw Start ---/,/# --- OpenClaw End ---/d' "$BASHRC"
    cat >> "$BASHRC" <<EOT
# --- OpenClaw Start ---
export TERMUX_VERSION=1
export TMPDIR=\$HOME/tmp
export OPENCLAW_GATEWAY_TOKEN=$TOKEN
export PATH=$NPM_BIN:\$PATH
alias ocr="pkill -9 -f 'openclaw' 2>/dev/null; tmux kill-session -t openclaw 2>/dev/null; sleep 1; tmux new -d -s openclaw 'export PATH=$NPM_BIN:\$PATH TMPDIR=\$HOME/tmp; openclaw gateway --bind lan --port $PORT --token $TOKEN --allow-unconfigured'"
alias oclog='tmux attach -t openclaw'
alias ockill='pkill -9 -f "openclaw" 2>/dev/null; tmux kill-session -t openclaw 2>/dev/null'
# --- OpenClaw End ---
EOT
}

start_service() {
    echo -e "${YELLOW}[5/5] 서비스 시작 중...${NC}"
    tmux kill-session -t openclaw 2>/dev/null || true
    tmux new -d -s openclaw "export PATH=$NPM_BIN:\$PATH TMPDIR=$HOME/tmp; openclaw gateway --bind lan --port $PORT --token $TOKEN --allow-unconfigured 2>&1 | tee $LOG_DIR/runtime.log"
    echo -e "${GREEN}배포 공정 완료!${NC}"
}

# --- 메인 실행부 ---
mkdir -p "$LOG_DIR" "$HOME/tmp" 2>/dev/null
clear
echo -e "${BLUE}=========================================="
echo -e "    🦞 Openclaw 공식 버전 설치 (S9)"
echo -e "    📡 Registry: $REGISTRY"
echo -e "==========================================${NC}"

read -p "포트 번호 [기본: 18789]: " PORT
PORT=${PORT:-18789}
read -p "액세스 토큰 [비워두면 자동생성]: " TOKEN
if [ -z "$TOKEN" ]; then TOKEN="token$(date +%s | cut -c 6-10)"; fi

check_deps
configure_npm
apply_koffi_stub
apply_patches
setup_autostart
start_service

echo -e "\n${GREEN}설치 완료! [패키지: $PKG_SOURCE]${NC}"
echo -e "사용 토큰: ${YELLOW}$TOKEN${NC}"
echo -e "로컬 미러 서버에 모든 데이터가 보관되었습니다."
