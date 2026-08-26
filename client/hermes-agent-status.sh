#!/bin/bash
# ============================================================================
# hermes-agent 個人安裝狀態檢查
# 用法: bash /mnt/shared/hermes-agent/client/hermes-agent-status.sh
# ============================================================================
set -euo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'

SHARE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CURRENT_LINK="$SHARE_ROOT/current"
BIN_DIR="$HOME/.local/bin"
HERMES_HOME_DIR="${HERMES_HOME:-$HOME/.hermes}"

echo ""
echo -e "${CYAN}⚕ hermes-agent 狀態${NC}"
echo ""

if [ -e "$CURRENT_LINK" ]; then
    echo -e "${GREEN}✓${NC} 共用環境目前版本: $(cat "$CURRENT_LINK/VERSION" 2>/dev/null || echo 未知)"
    echo "   路徑: $(readlink -f "$CURRENT_LINK")"
else
    echo -e "${RED}✗${NC} 共用環境尚未發佈任何版本 ($CURRENT_LINK 不存在)"
fi

if [ -x "$BIN_DIR/hermes" ]; then
    echo -e "${GREEN}✓${NC} 個人指令已安裝: $BIN_DIR/hermes"
else
    echo -e "${RED}✗${NC} 尚未安裝個人指令，請先執行 hermes-agent-setup.sh"
fi

if [ -d "$HERMES_HOME_DIR" ]; then
    echo -e "${GREEN}✓${NC} 個人設定目錄: $HERMES_HOME_DIR"
    [ -f "$HERMES_HOME_DIR/config.yaml" ] && echo "   - config.yaml 存在"
    [ -f "$HERMES_HOME_DIR/.env" ] && echo "   - .env 存在"
else
    echo -e "${YELLOW}!${NC} 個人設定目錄尚未建立: $HERMES_HOME_DIR"
fi

if command -v hermes &> /dev/null; then
    echo ""
    echo "── hermes doctor ──────────────────────────────────────────"
    hermes doctor || true
fi
