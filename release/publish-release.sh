#!/bin/bash
# ============================================================================
# 在封閉網路內發佈一個新版本的 hermes-agent（管理員執行，不需要 root）
# ============================================================================
# 前提：hermes-agent-offline-<版本>.tar.gz + .sha256 已經透過 FTP 傳進來，
#       放在共用目錄的 incoming/ 底下。
#
# 用法：
#   bash publish-release.sh /mnt/shared/hermes-agent/incoming/hermes-agent-offline-0.15.1.tar.gz
#
# 這個腳本會：
#   1. 驗證 checksum
#   2. 解壓到 releases/<版本>/
#   3. 用包內附的 Python，在共用目錄「原地」建立 venv 並離線安裝所有套件
#      （venv 的路徑寫死在它自己的設定檔裡，所以一定要在最終路徑上建立，
#        不能在別的地方建好再搬過來）
#   4. 開放讀取/執行權限給所有人（不給寫入權限）
#   5. 原子性地把 current 符號連結切到新版本
#   6. 更新 client/ 底下同仁自助安裝用的腳本
#   7. 清掉太舊的版本
# ============================================================================
set -euo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'

TARBALL="${1:?用法: $0 <hermes-agent-offline-版本.tar.gz 的完整路徑>}"
if [ ! -f "$TARBALL" ]; then
    echo -e "${RED}✗${NC} 找不到檔案: $TARBALL" >&2
    exit 1
fi

# ----------------------------------------------------------------------------
# 0. 驗證 checksum（FTP 傳輸有時會用文字模式毀損二進位檔，一定要先檢查）
# ----------------------------------------------------------------------------
if [ -f "$TARBALL.sha256" ]; then
    echo -e "${CYAN}→${NC} 驗證 checksum ..."
    ( cd "$(dirname "$TARBALL")" && sha256sum -c "$(basename "$TARBALL.sha256")" )
    echo -e "${GREEN}✓${NC} checksum 正確"
else
    echo -e "${YELLOW}⚠${NC} 找不到 $TARBALL.sha256，略過 checksum 驗證（建議務必連 .sha256 一起用 FTP 傳）"
fi

# ----------------------------------------------------------------------------
# 1. 解壓到暫存目錄，讀出版本號與包內的 paths.conf
# ----------------------------------------------------------------------------
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

echo -e "${CYAN}→${NC} 解壓安裝包 ..."
tar xzf "$TARBALL" -C "$STAGE_DIR"

BUNDLE_DIR="$(find "$STAGE_DIR" -maxdepth 1 -type d -name 'hermes-agent-offline-*')"
if [ -z "$BUNDLE_DIR" ]; then
    echo -e "${RED}✗${NC} 安裝包內容結構不符預期" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$BUNDLE_DIR/config/paths.conf"
VERSION="$(cat "$BUNDLE_DIR/VERSION")"

echo -e "${GREEN}✓${NC} 版本: $VERSION"
echo -e "${GREEN}✓${NC} 共用目錄: $HERMES_SHARE_ROOT"

if [ ! -d "$HERMES_SHARE_ROOT" ]; then
    echo -e "${RED}✗${NC} 共用目錄 $HERMES_SHARE_ROOT 不存在或無法存取。" >&2
    echo "   請確認這台機器的共用目錄掛載，以及 config/paths.conf 是否與實際路徑一致。" >&2
    exit 1
fi

RELEASE_DIR="$HERMES_SHARE_ROOT/releases/$VERSION"
if [ -d "$RELEASE_DIR" ]; then
    echo -e "${YELLOW}⚠${NC} $RELEASE_DIR 已存在，將會覆蓋重建。"
    rm -rf "$RELEASE_DIR"
fi
mkdir -p "$RELEASE_DIR"

# ----------------------------------------------------------------------------
# 2. 放置 Python 與 wheels 到最終路徑
# ----------------------------------------------------------------------------
echo -e "${CYAN}→${NC} 部署 Python 與套件檔到 $RELEASE_DIR ..."
# python 是包成 tar.gz 帶過來的（見 build-python-centos7.sh 的說明：跨 Windows/NTFS
# 複製檔案會弄丟執行檔的 +x 位元，只有解壓 tar.gz 才能正確還原權限），這裡在真正
# 的 Linux 上解壓，權限中繼資料就會正確還原。
mkdir -p "$RELEASE_DIR/python"
tar xzf "$BUNDLE_DIR/python.tar.gz" -C "$RELEASE_DIR/python"
cp -a "$BUNDLE_DIR/wheels" "$RELEASE_DIR/wheels"
cp "$BUNDLE_DIR/VERSION" "$RELEASE_DIR/VERSION"
cp "$BUNDLE_DIR/BUILD_TIME" "$RELEASE_DIR/BUILD_TIME" 2>/dev/null || true

PYTHON_BIN="$RELEASE_DIR/python/bin/python3"
if [ ! -x "$PYTHON_BIN" ]; then
    echo -e "${RED}✗${NC} $PYTHON_BIN 不存在或不可執行。" >&2
    echo "   常見原因：這台機器的 glibc 跟編譯 Python 的 centos:7 容器不相容。" >&2
    exit 1
fi

echo -e "${CYAN}→${NC} 驗證 Python 可執行 ..."
"$PYTHON_BIN" --version

# ----------------------------------------------------------------------------
# 3. 在最終路徑上建立 venv 並離線安裝（venv 路徑是寫死的，必須原地建立）
# ----------------------------------------------------------------------------
echo -e "${CYAN}→${NC} 建立虛擬環境並離線安裝 hermes-agent[$HERMES_AGENT_EXTRAS] ..."
"$PYTHON_BIN" -m venv "$RELEASE_DIR/venv"
# 不特別升級 pip/setuptools/wheel：venv 帶的 ensurepip 版本就夠用了，
# 而且 wheel 套件本身不在 wheels/ 裡（hermes-agent 不需要它 —— 全部套件
# 都是預先下載好的 wheel，不需要在這裡臨時把任何 sdist build 成 wheel）。
"$RELEASE_DIR/venv/bin/pip" install --no-index --find-links="$RELEASE_DIR/wheels" \
    "hermes-agent[${HERMES_AGENT_EXTRAS}]==${VERSION}"

echo -e "${GREEN}✓${NC} 安裝完成，驗證指令："
"$RELEASE_DIR/venv/bin/hermes" --version || true

# ----------------------------------------------------------------------------
# 4. 權限：所有人可讀可執行，只有管理員（目前這個帳號）可寫
# ----------------------------------------------------------------------------
echo -e "${CYAN}→${NC} 設定權限（所有人可讀/執行，不可寫）..."
chmod -R a+rX "$RELEASE_DIR"

# ----------------------------------------------------------------------------
# 5. 更新同仁自助安裝腳本（client/ 永遠保留最新版工具，不隨版本分開存放）
# ----------------------------------------------------------------------------
mkdir -p "$HERMES_SHARE_ROOT/client"
cp "$BUNDLE_DIR/client/"*.sh "$HERMES_SHARE_ROOT/client/"
chmod a+rx "$HERMES_SHARE_ROOT/client/"*.sh
echo -e "${GREEN}✓${NC} 已更新 $HERMES_SHARE_ROOT/client/ 底下的同仁自助腳本"

# ----------------------------------------------------------------------------
# 6. 原子性切換 current 符號連結
# ----------------------------------------------------------------------------
echo -e "${CYAN}→${NC} 切換 current → $VERSION ..."
ln -sfn "releases/$VERSION" "$HERMES_SHARE_ROOT/current.tmp"
mv -T "$HERMES_SHARE_ROOT/current.tmp" "$HERMES_SHARE_ROOT/current"
echo -e "${GREEN}✓${NC} current 已指向 releases/$VERSION"

# ----------------------------------------------------------------------------
# 7. 清掉太舊的版本
# ----------------------------------------------------------------------------
echo -e "${CYAN}→${NC} 清理舊版本（保留最新 ${KEEP_RELEASES:-3} 個）..."
mapfile -t OLD_RELEASES < <(
    find "$HERMES_SHARE_ROOT/releases" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %p\n' \
    | sort -rn | awk '{print $2}' | tail -n +$((${KEEP_RELEASES:-3} + 1))
)
for old in "${OLD_RELEASES[@]:-}"; do
    [ -z "$old" ] && continue
    if [ "$(readlink -f "$HERMES_SHARE_ROOT/current")" = "$(cd "$old" && pwd)" ]; then
        continue  # 保險：絕不刪掉 current 正在指的版本
    fi
    echo "   移除舊版本: $old"
    rm -rf "$old"
done

LOG_FILE="$HERMES_SHARE_ROOT/publish.log"
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ")  published $VERSION  by $(whoami)" >> "$LOG_FILE"

echo ""
echo "════════════════════════════════════════════════════════════"
echo -e " ${GREEN}✓ 發佈完成：hermes-agent $VERSION${NC}"
echo "   所有同仁下次執行 hermes 指令時會自動使用這個版本。"
echo "   尚未安裝過的同仁，請他們執行："
echo "     bash $HERMES_SHARE_ROOT/client/hermes-agent-setup.sh"
echo "════════════════════════════════════════════════════════════"
