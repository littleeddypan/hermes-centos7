#!/bin/bash
# ============================================================================
# hermes-agent 個人安裝移除
# 用法:
#   bash hermes-agent-uninstall.sh          # 只移除指令，保留個人設定/對話紀錄
#   bash hermes-agent-uninstall.sh --purge  # 連同 ~/.hermes 個人資料一起刪除
# ============================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'

BIN_DIR="$HOME/.local/bin"
HERMES_HOME_DIR="${HERMES_HOME:-$HOME/.hermes}"

rm -f "$BIN_DIR/hermes"
echo -e "${GREEN}✓${NC} 已移除 $BIN_DIR/hermes"

if [ "${1:-}" = "--purge" ]; then
    if [ -d "$HERMES_HOME_DIR" ]; then
        read -p "確定要永久刪除個人設定與對話紀錄 $HERMES_HOME_DIR 嗎？此動作無法復原 [y/N] " -n 1 -r REPLY
        echo ""
        if [[ "$REPLY" =~ ^[Yy]$ ]]; then
            rm -rf "$HERMES_HOME_DIR"
            echo -e "${GREEN}✓${NC} 已刪除 $HERMES_HOME_DIR"
        else
            echo "已取消，個人資料保留。"
        fi
    fi
else
    echo -e "${YELLOW}!${NC} 個人設定目錄 $HERMES_HOME_DIR 未刪除（保留 API 金鑰與對話紀錄）"
    echo "   若要一併刪除，請加上 --purge 參數重新執行。"
fi
