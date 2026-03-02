#!/bin/bash
# ==========================================
# Openclaw Private Archive Deployment Script
# ==========================================
# 특징: 노트북(WSL2) Verdaccio 레지스트리 우선 사용 및 순환 의존성 해결

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
    echo -e "${YELLOW}[1/6] 기초 실행 환경 검사 및 설치 중...${NC}"
    
    # 1. Node.js 존재 여부 확인 및 우선 설치 (순환 오류 방지)
    if ! command -v node &> /dev/null || ! command -v npm &> /dev/null; then
        echo -e "${CYAN}Node.js가 없습니다. 시스템 패키지를 먼저 설치합니다...${NC}"
        run_cmd pkg update -y
        run_cmd pkg install nodejs -y
    fi

    # 2. 이제 npm이 확실히 있으므로 노트북 레지스트리 설정
    echo -e "${BLUE}📡 로컬 레지스트리 연결: $REGISTRY${NC}"
    npm config set registry "$REGISTRY"
    
    # 3. 나머지 필수 의존성 패키지 목록
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
    echo -e "\n${YELLOW}[2/6] Openclaw 패키지 설치 중...${NC}"
    mkdir -p "$NPM_GLOBAL"
    npm config set prefix "$NPM_GLOBAL"
    
    # 환경변수 즉시 반영 (현재 세션용)
    export PATH="$NPM_BIN:$PATH"

    # [핵심] 아카이브 URL 또는 일반 패키지명으로 설치
    echo -e "${BLUE}설치 소스: $PKG_SOURCE${NC}"
    # 노트북 레지스트리를 통해 의존성을 광속으로 긁어옵니다.
    run_cmd env NODE_LLAMA_CPP_SKIP_DOWNLOAD=true npm i -g "$PKG_SOURCE" --ignore-scripts

    # 설치 경로 설정 (사설 설치 시 이름 확인)
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
    echo -e "${YELLOW}[3/6] Android 호환성 패치 적용 중...${NC}"
    # 임시 디렉토리 경로 수정
    FILES=$(grep -rl "/
