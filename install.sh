#!/bin/bash
# ==========================================
# Openclaw Private Archive Deployment Script
# ==========================================
# 특징: Private 레포지토리의 특정 .tgz 버전을 선택하여 설치

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

# --- GitHub 정보 설정 ---
GITHUB_USER="nadayyh-openclaw"
REPO_NAME="openclaw-private"

# --- 유틸리티 함수 ---
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"; }

run_cmd() {
    log "명령 실행: $@"
    "$@"
}

# --- 핵심 로직 함수 ---

check_deps() {
    echo -e "${YELLOW}[1/6] 기초 실행 환경 검사 중...${NC}"
    npm config set registry "$REGISTRY"
    
    DEPS=("nodejs" "git" "openssh" "tmux" "termux-api" "termux-tools" "cmake" "python" "golang" "which")
    MISSING_DEPS=()
    for dep in "${DEPS[@]}"; do
        cmd=$dep
        if [ "$dep" = "nodejs" ]; then cmd="node"; fi
        if ! command -v $cmd &> /dev/null; then MISSING_DEPS+=($dep); fi
    done

    if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
        run_cmd pkg update -y && run_cmd pkg install ${MISSING_DEPS[*]} -y
    fi
}

configure_npm() {
    echo -e "\n${YELLOW}[2/6] Openclaw 패키지 설치 중...${NC}"
    mkdir -p "$NPM_GLOBAL"
    npm config set prefix "$NPM_GLOBAL"
    export PATH="$NPM_BIN:$PATH"

    # [핵심] 아카이브 URL 또는 일반 패키지명으로 설치
    echo -e "${BLUE}설치 소스: $PKG_SOURCE${NC}"
    run_cmd env NODE_LLAMA_CPP_SKIP_DOWNLOAD=true npm i -g "$PKG_SOURCE" --ignore-scripts

    # 설치 경로 설정 (사설 설치 시 이름 확인)
    BASE_DIR="$NPM_GLOBAL/lib/node_modules/openclaw"
}

apply_koffi_stub() {
    KOFFI_DIR="$BASE_DIR/node_modules/koffi"
    if [ -d "$KOFFI_DIR" ]; then
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
    echo -e "${YELLOW}[3/6] Android 호환성 패치 적용 중...${NC}"
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
    echo -e "${YELLOW}[5/6] 서비스 시작 중...${NC}"
    tmux kill-session -t openclaw 2>/dev/null || true
    tmux new -d -s openclaw "export PATH=$NPM_BIN:\$PATH TMPDIR=$HOME/tmp; openclaw gateway --bind lan --port $PORT --token $TOKEN --allow-unconfigured 2>&1 | tee $LOG_DIR/runtime.log"
    echo -e "${GREEN}[6/6] 배포 완료!${NC}"
}

# --- 메인 실행부 ---

mkdir -p "$LOG_DIR" "$HOME/tmp" 2>/dev/null

clear
echo -e "${BLUE}=========================================="
echo -e "    🦞 Openclaw 커스텀 아카이브 배포 도구"
echo -e "==========================================${NC}"

# 1. 저장소 설정
#read -p "NPM 레지스트리 [기본: https://registry.npmmirror.com]: " INPUT_REGISTRY
#REGISTRY=${INPUT_REGISTRY:-https://registry.npmmirror.com}

#외부 타오바오 망을 거치지 않고 내 노트북의 캐시를 우선 사용합니다.
REGISTRY="http://100.68.95.44:4873"

echo -e "${CYAN}------------------------------------------"
echo -e "📡 로컬 레지스트리 연결: $REGISTRY"
echo -e "------------------------------------------${NC}"

# 2. 버전 선택 로직
echo -e "\n${YELLOW}사용 가능한 아카이브 예시:${NC}"
echo -e "- openclaw-2026.2.26.tgz (최신)"
echo -e "- openclaw-2026.2.25-beta.1.tgz"
read -p "설치할 아카이브 파일명 입력 [기본: openclaw-2026.2.26.tgz]: " FILE_NAME
FILE_NAME=${FILE_NAME:-openclaw-2026.2.26.tgz}

# 3. Private Repo 접근용 토큰 (필수)
echo -e "\n${RED}비공개 저장소 접근을 위해 GitHub PAT(Personal Access Token)가 필요합니다.${NC}"
read -s -p "GitHub PAT 입력: " GITHUB_PAT
echo -e "\n"

# 소스 주소 구성 (인증 정보 포함)
PKG_SOURCE="https://${GITHUB_PAT}@raw.githubusercontent.com/${GITHUB_USER}/${REPO_NAME}/main/${FILE_NAME}"

# 4. 서비스 설정
read -p "포트 번호 [기본: 18789]: " PORT
PORT=${PORT:-18789}
read -p "액세스 토큰 [비워두면 자동생성]: " TOKEN
if [ -z "$TOKEN" ]; then TOKEN="token$(date +%s | cut -c 6-10)"; fi

# 프로세스 시작
check_deps
configure_npm
apply_koffi_stub
apply_patches
setup_autostart
start_service

echo -e "\n${GREEN}설치 완료! [버전: $FILE_NAME]${NC}"
echo -e "사용 토큰: ${YELLOW}$TOKEN${NC}"
