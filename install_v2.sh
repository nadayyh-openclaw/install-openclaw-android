#!/bin/bash
# ==========================================
# Openclaw Official Registry Deployment Script (Clean Install)
# ==========================================
# 특징: 시스템 패키지(APT/PKG) 및 NPM 패키지 전체 로컬 캐싱 통합
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

# --- 고정 설정 (노트북 WSL2 캐시 서버) ---
APT_PROXY="http://100.68.95.44:3142"
NPM_REGISTRY="http://100.68.95.44:4873"
PKG_SOURCE="openclaw"

# --- 유틸리티 함수 ---
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"; }
run_cmd() { log "명령 실행: $@"; "$@"; }

# --- 핵심 로직 함수 ---

setup_caching() {
    echo -e "${YELLOW}[0/5] 시스템 패키지 캐싱 활성화 (노트북 3142)...${NC}"
    # 이 설정이 되어야 pkg install 시 모든 .deb 파일이 노트북에 저장됩니다.
    echo "Acquire::http::Proxy \"$APT_PROXY\";" > $PREFIX/etc/apt/apt.conf.d/01proxy
    echo "Acquire::https::Proxy \"$APT_PROXY\";" >> $PREFIX/etc/apt/apt.conf.d/01proxy
    run_cmd pkg update -y
}

check_deps() {
    echo -e "${YELLOW}[1/5] 기초 실행 환경 검사 및 Node.js 설치...${NC}"
    
    # Node.js 설치 (이제 노트북의 apt-cacher-ng를 통해 다운로드됨)
    if ! command -v node &> /dev/null || ! command -v npm &> /dev/null; then
        echo -e "${CYAN}Node.js 설치 중...${NC}"
        run_cmd pkg install nodejs -y
        hash -r
    fi

    echo -e "${BLUE}📡 NPM 로컬 레지스트리 연결: $NPM_REGISTRY${NC}"
    npm config set registry "$NPM_REGISTRY"
    
    # 의존성 패키지들 (이 무거운 파일들이 전부 노트북에 박제됩니다)
    DEPS=("git" "openssh" "tmux" "termux-api" "termux-tools" "cmake" "python" "golang" "which")
    MISSING_DEPS=()
    for dep in "${DEPS[@]}"; do
        if ! command -v $dep &> /dev/null; then MISSING_DEPS+=($dep); fi
    done

    if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
        echo -e "${CYAN}의존성 설치 중 (노트북 백업 중): ${MISSING_DEPS[*]}${NC}"
        run_cmd pkg install ${MISSING_DEPS[*]} -y
    fi
}

configure_npm() {
    echo -e "\n${YELLOW}[2/5] Openclaw 패키지 설치 중 (via Laptop NPM Cache)...${NC}"
    mkdir -p "$NPM_GLOBAL"
    npm config set prefix "$NPM_GLOBAL"
    export PATH="$NPM_BIN:$PATH"

    # Verdaccio를 통해 700여개의 패키지가 노트북에 박제됩니다.
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
    echo -e "${YELLOW}[4/5] Alias 및 환경변수 설정 중...${NC}"
    touch "$BASHRC" # 파일 없을 때 sed 에러 방지
    run_cmd sed -i '/# --- OpenClaw Start ---/,/# --- OpenClaw End ---/d' "$BASHRC" || true
    cat >> "$BASHRC" <<EOT
# --- OpenClaw Start ---
export TERMUX_VERSION=1
export TMPDIR=\$HOME/tmp
export OPENCLAW_GATEWAY_TOKEN=$TOKEN
export PATH=$NPM_BIN:\$PATH
alias ocr="pkill -9 -f 'openclaw' 2>/dev/null; tmux kill-session -t openclaw 2>/dev/null; sleep 1; tmux new -d -s openclaw; tmux send-keys -t openclaw 'export PATH=$NPM_BIN:\$PATH TMPDIR=\$HOME/tmp; openclaw gateway --bind loopback --port $PORT --token $TOKEN --allow-unconfigured' Enter"
alias oclog='tmux attach -t openclaw'
alias ockill='pkill -9 -f "openclaw" 2>/dev/null; tmux kill-session -t openclaw 2>/dev/null'
# --- OpenClaw End ---
EOT
}

start_service() {
    echo -e "${YELLOW}[5/5] 서비스 시작 중...${NC}"
    tmux kill-session -t openclaw 2>/dev/null || true
    # 터미널 완전 로드 후 매크로 입력 방식 (에러 추적 용이, 조기 종료 방지)
    tmux new -d -s openclaw
    tmux send-keys -t openclaw "export PATH=$NPM_BIN:\$PATH TMPDIR=$HOME/tmp; openclaw gateway --bind loopback --port $PORT --token $TOKEN --allow-unconfigured 2>&1 | tee $LOG_DIR/runtime.log" Enter
    echo -e "${GREEN}배포 공정 완료!${NC}"
}

# --- 메인 실행부 ---
mkdir -p "$LOG_DIR" "$HOME/tmp" 2>/dev/null
clear
echo -e "${BLUE}=========================================="
echo -e "    🦞 Openclaw 통합 캐싱 배포 (S9)"
echo -e "    📡 APT Proxy: $APT_PROXY"
echo -e "    📡 NPM Registry: $NPM_REGISTRY"
echo -e "==========================================${NC}"

read -p "포트 번호 [기본: 18789]: " PORT
PORT=${PORT:-18789}
read -p "액세스 토큰 [비워두면 자동생성]: " TOKEN
if [ -z "$TOKEN" ]; then TOKEN="token$(date +%s | cut -c 6-10)"; fi

setup_caching     # 0. 시스템 패키지 캐시 설정
check_deps        # 1. 의존성 설치 (노트북에 백업됨)
configure_npm     # 2. NPM 설치 (Verdaccio에 백업됨)
apply_koffi_stub  # 3. 안드로이드 패치 1
apply_patches     # 4. 안드로이드 패치 2
setup_autostart   # 5. 자동실행 설정
start_service     # 6. 서비스 구동

echo -e "\n${GREEN}설치 및 전체 백업 완료!${NC}"
echo -e "사용 토큰: ${YELLOW}$TOKEN${NC}"
echo -e "이제 노트북 하드에 모든 시스템/NPM 데이터가 보관되었습니다."
