#!/bin/bash
# ==========================================
# Openclaw Official Registry Deployment Script
# ==========================================
# 특징: 공식 openclaw 패키지를 노트북(Verdaccio)을 통해 설치 및 캐싱

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
# S9이 바라볼 노트북의 Tailscale IP입니다.
REGISTRY="http://100.68.95.44:4873"
PKG_SOURCE="openclaw"  # 공식 패키지명 고정

# --- 유틸리티 함수 ---
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"; }
run_cmd() { log "명령 실행: $@"; "$@"; }

# --- 핵심 로직 함수 ---

check_deps() {
    echo -e "${YELLOW}[1/5] 기초 실행 환경 검사 및 Node.js 설치...${NC}"
    
    # 1. Node.js 우선 설치 (순환 오류 방지)
    if ! command -v node &> /dev/null || ! command -v npm &> /dev/null; then
        echo -e "${CYAN}Node.js가 없습니다. 시스템 패키지를 먼저 설치합니다...${NC}"
        run_cmd pkg update -y
        run_cmd pkg install nodejs -y
    fi

    # 2. 이제 npm이 확실히 있으므로 노트북 레지스트리 설정
    echo -e "${BLUE}📡 로컬 레지스트리 연결: $REGISTRY${NC}"
    npm config set registry "$REGISTRY"
    
    # 3. 나머지 필수 의존성 패키지
    DEPS=("git" "openssh" "tmux" "termux-api" "termux-tools" "cmake" "python" "golang" "which")
    MISSING_DEPS=()
    for dep in "${DEPS[@]}"; do
        if ! command -v $dep &> /dev/null; then MISSING_DEPS+=($dep); fi
    done

    if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
        echo -e "${CYAN}누락된 의존성 설치 중: ${MISSING_DEPS[*]}${NC}"
        run_cmd pkg install ${MISSING_DEPS[*]} -y
    fi
}

configure_npm() {
    echo -e "\n${YELLOW}[2/5] Openclaw 공식 패키지 설치 중 (via Laptop Cache)...${NC}"
    mkdir -p "$NPM_GLOBAL"
    npm config set prefix "$NPM_GLOBAL"
    export PATH="$NPM_BIN:$PATH"

    # [핵심] 노트북 레지스트리를 통해 공식 'openclaw'를 내려받습니다.
    # 만약 노트북에 없으면 노트북이 자동으로 타오바오에서 긁어와서 저장합니다.
    run_cmd env NODE_LLAMA_CPP_SKIP_DOWNLOAD=true npm i -g "$PKG_SOURCE" --ignore-scripts

    BASE_DIR="$NPM_GLOBAL/lib/node_modules/openclaw"
}

apply_koffi_stub() {
    KOFFI_DIR="$BASE_DIR/node_modules/koffi"
    if [ -d "$KOFFI_DIR" ]; then
        echo -e "${CYAN}Koffi 안드로이드 스텁 적용 중...${NC}"
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
    # 임시 디렉토리 경로 수정 (/tmp 에러 방지)
    FILES=$(grep -rl "/tmp/openclaw" "$BASE_DIR/dist" 2>/dev/null || true)
    for f in $FILES; do
        node -e "const fs=require('fs');let c=fs.readFileSync('$f','utf8');fs.writeFileSync('$f',c.replace(/\/tmp\/openclaw/g, process.env.HOME+'/openclaw-logs'));"
    done
    
    # 클립보드 에러 방지 패치
    CLIP_DIR="$BASE_DIR/node_modules/@mariozechner/clipboard"
    if [ -d "$CLIP_DIR" ]; then
        echo "module.exports = { availableFormats:()=>[], getText:()=>'', setText:()=>false, watch:()=>({stop:()=>{}}) };" > "$CLIP_DIR/index.js"
    fi
}

setup_autostart() {
    echo -e "${YELLOW}[4/5] 환경 변수 및 Alias 설정 중...${NC}"
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
    echo -e "${GREEN}모든 배포 공정이 완료되었습니다!${NC}"
}

# --- 메인 실행부 ---

mkdir -p "$LOG_DIR" "$HOME/tmp" 2>/dev/null
clear
echo -e "${BLUE}=========================================="
echo -e "    🦞 Openclaw 공식 버전 설치 (S9)"
echo -e "    📡 Registry: $REGISTRY"
echo -e "==========================================${NC}"

# 포트 및 토큰 설정 (사용자 편의용)
read -p "포트 번호 [기본: 18789]: " PORT
PORT=${PORT:-18789}
read -p "액세스 토큰 [비워두면 자동생성]: " TOKEN
if [ -z "$TOKEN" ]; then TOKEN="token$(date +%s | cut -c 6-10)"; fi

# 프로세스 순차 실행
check_deps
configure_npm
apply_koffi_stub
apply_patches
setup_aut
