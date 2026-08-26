#!/bin/bash
# ============================================================================
# hermes-agent 個人安裝腳本（同仁自己執行，不需要 root，不需要網路）
# ============================================================================
# 用法：
#   bash /mnt/shared/hermes-agent/client/hermes-agent-setup.sh
#
# 這個腳本只會動到你自己的帳號：
#   ~/.local/bin/hermes   — 一個指向共用執行環境的小指令
#   ~/.hermes/            — 你個人的設定檔、API 金鑰、對話紀錄、技能等
#
# 真正的程式本體（Python 直譯器、所有套件）放在共用目錄，由管理員統一更新，
# 不會佔用你自己的硬碟空間，也不需要你手動更新 —— 管理員發佈新版後，
# 你下次執行 hermes 就會自動是新版。
# ============================================================================
set -euo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'

# client/ 腳本固定放在 <共用目錄>/client/ 底下，往上一層就是共用目錄根目錄。
SHARE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CURRENT_LINK="$SHARE_ROOT/current"

echo ""
echo -e "${CYAN}⚕ hermes-agent 個人安裝${NC}"
echo -e "  共用執行環境: $SHARE_ROOT"
echo ""

if [ ! -e "$CURRENT_LINK" ]; then
    echo -e "${RED}✗${NC} 找不到 $CURRENT_LINK，代表管理員還沒發佈任何版本。"
    echo "   請聯絡負責維護 hermes-agent 的管理員。"
    exit 1
fi

HERMES_BIN="$CURRENT_LINK/venv/bin/hermes"
if [ ! -x "$HERMES_BIN" ]; then
    echo -e "${RED}✗${NC} $HERMES_BIN 不存在或不可執行，共用環境可能損毀。"
    echo "   請聯絡管理員，或請管理員重新執行 publish-release.sh。"
    exit 1
fi

INSTALLED_VERSION="$(cat "$CURRENT_LINK/VERSION" 2>/dev/null || echo "未知")"
echo -e "${GREEN}✓${NC} 目前共用版本: $INSTALLED_VERSION"

# ----------------------------------------------------------------------------
# 1. 個人指令：~/.local/bin/hermes
# ----------------------------------------------------------------------------
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"

cat > "$BIN_DIR/hermes" <<EOF
#!/bin/bash
# 由 hermes-agent-setup.sh 自動產生，指向共用執行環境的目前版本 (current 符號連結)。
# 個人資料一律寫到 HERMES_HOME，不會動到共用目錄。
export HERMES_HOME="\${HERMES_HOME:-\$HOME/.hermes}"
exec "$CURRENT_LINK/venv/bin/hermes" "\$@"
EOF
chmod +x "$BIN_DIR/hermes"
echo -e "${GREEN}✓${NC} 已建立 ~/.local/bin/hermes"

# ----------------------------------------------------------------------------
# 2. 確保 ~/.local/bin 在 PATH 上
# ----------------------------------------------------------------------------
SHELL_CONFIG="$HOME/.bashrc"
[[ "$SHELL" == *zsh* ]] && SHELL_CONFIG="$HOME/.zshrc"
touch "$SHELL_CONFIG"

if ! grep -q '\.local/bin' "$SHELL_CONFIG" 2>/dev/null; then
    {
        echo ""
        echo "# hermes-agent — 確保 ~/.local/bin 在 PATH 上"
        echo 'export PATH="$HOME/.local/bin:$PATH"'
    } >> "$SHELL_CONFIG"
    echo -e "${GREEN}✓${NC} 已將 ~/.local/bin 加入 $SHELL_CONFIG 的 PATH"
else
    echo -e "${GREEN}✓${NC} ~/.local/bin 已經在 PATH 設定中"
fi
export PATH="$HOME/.local/bin:$PATH"

# ----------------------------------------------------------------------------
# 3. 個人設定目錄：~/.hermes（第一次執行 hermes 時，它自己也會補齊需要的子目錄）
# ----------------------------------------------------------------------------
export HERMES_HOME="$HOME/.hermes"
mkdir -p "$HERMES_HOME"
chmod 700 "$HERMES_HOME" 2>/dev/null || true
echo -e "${GREEN}✓${NC} 個人設定目錄: $HERMES_HOME"

echo ""
echo -e "${GREEN}✓ 安裝完成！${NC}"
echo ""
echo "接下來："
echo "  1. 重新載入 shell 設定（或重新登入）："
echo "       source $SHELL_CONFIG"
echo "  2. 執行設定精靈，輸入你自己的 API 金鑰等個人設定："
echo "       hermes setup"
echo "  3. 開始使用："
echo "       hermes"
echo ""
echo "常用指令："
echo "  hermes status   # 檢查目前設定"
echo "  hermes doctor   # 健康檢查"
echo ""
echo -e "${YELLOW}提醒：${NC}版本更新由管理員統一發佈，不需要你自己跑更新指令。"
echo "     如果 hermes 突然出現版本不相容的錯誤訊息，先跑 hermes doctor，"
echo "     還是不行的話請聯絡管理員。"
echo ""

read -p "要現在執行設定精靈 (hermes setup) 嗎？ [Y/n] " -n 1 -r REPLY || true
echo ""
if [[ -z "${REPLY:-}" || "$REPLY" =~ ^[Yy]$ ]]; then
    "$BIN_DIR/hermes" setup || true
fi
