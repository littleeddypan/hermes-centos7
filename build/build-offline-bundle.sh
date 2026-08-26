#!/bin/bash
# ============================================================================
# 產生 hermes-agent CentOS 7 離線安裝包（總控腳本）
# ============================================================================
# 在一台「能連網、能跑 Docker」的機器上執行（不需要是 CentOS 7，Linux/WSL 皆可）。
# 產出一個 hermes-agent-offline-<版本>.tar.gz，內含：
#   - 針對 CentOS 7 (glibc 2.17) 原地編譯的可攜式 Python
#   - hermes-agent 核心功能（[all] extra）所需的全部相依套件 wheel
#   - 同仁自助安裝 / 更新 / 移除用的腳本
#
# 這個 tar.gz 就是要透過 FTP 傳進封閉網路、放到共用目錄 incoming/ 底下的東西。
#
# 用法：
#   ./build-offline-bundle.sh
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../config/paths.conf
source "$ROOT_DIR/config/paths.conf"

VERSION="$HERMES_AGENT_VERSION"
FINAL_PY_PREFIX="$HERMES_SHARE_ROOT/releases/$VERSION/python"

WORK_DIR="$ROOT_DIR/build/work-$VERSION"
BUNDLE_DIR="$WORK_DIR/hermes-agent-offline-$VERSION"
PY_OUT_DIR="$WORK_DIR/python-build"
# 只清掉安裝包本身，保留 python-build/（Python 編譯很花時間，PYTHON_VERSION 跟
# 共用目錄路徑沒變的話，見下面 [1/3] 會直接沿用，不用每次都重編）。
mkdir -p "$WORK_DIR"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR"/{wheels,client,config}

echo "════════════════════════════════════════════════════════════"
echo " hermes-agent 離線安裝包建置"
echo "   版本:       $VERSION"
echo "   目標平台:   $TARGET_PLATFORM / $TARGET_PYTHON_TAG"
echo "   Python:     $PYTHON_VERSION (OpenSSL $OPENSSL_VERSION)"
echo "   共用目錄:   $HERMES_SHARE_ROOT"
echo "   功能範圍:   [$HERMES_AGENT_EXTRAS]"
echo "════════════════════════════════════════════════════════════"

# ----------------------------------------------------------------------------
# 1. 編譯 Python（見 build-python-centos7.sh 說明：容器內編譯，prefix 固定路徑）
# ----------------------------------------------------------------------------
echo ""
PY_TARBALL="$PY_OUT_DIR/python.tar.gz"
PY_CACHE_MARKER="$PY_OUT_DIR/.build-marker"
PY_CACHE_KEY="$PYTHON_VERSION|$OPENSSL_VERSION|$FINAL_PY_PREFIX"

if [ -f "$PY_TARBALL" ] && [ "$(cat "$PY_CACHE_MARKER" 2>/dev/null || true)" = "$PY_CACHE_KEY" ]; then
    echo "[1/3] Python/OpenSSL 版本與共用目錄路徑都沒變，沿用先前編譯好的 $PY_TARBALL"
else
    echo "[1/3] 編譯 CentOS 7 專用 OpenSSL ${OPENSSL_VERSION} + Python ${PYTHON_VERSION} ..."
    "$SCRIPT_DIR/build-python-centos7.sh" "$PY_OUT_DIR" "$PYTHON_VERSION" "$FINAL_PY_PREFIX" "$OPENSSL_VERSION"
    echo "$PY_CACHE_KEY" > "$PY_CACHE_MARKER"
fi

# python.tar.gz（而非解壓開的資料夾）從容器裡帶出來，一路保持是 tar.gz 到
# publish-release.sh 在真正的 Linux 上解壓為止 —— bind mount 到 Windows/NTFS
# 的路徑不會保留 Linux 執行檔的可執行位元，只有 tar entry 自己的權限中繼資料
# 不受影響，所以絕對不能在跨過這條邊界時用「複製檔案」，只能整包搬 tar.gz。
if [ ! -f "$PY_TARBALL" ]; then
    echo "✗ 找不到編譯出來的 python.tar.gz，Python 編譯步驟可能失敗。" >&2
    exit 1
fi
cp "$PY_TARBALL" "$BUNDLE_DIR/python.tar.gz"

# ----------------------------------------------------------------------------
# 2. 解析並下載 hermes-agent 與所有相依套件的 wheel（manylinux2014 / cp311）
# ----------------------------------------------------------------------------
echo ""
echo "[2/3] 解析並下載 hermes-agent[$HERMES_AGENT_EXTRAS]==$VERSION 及相依套件的 wheel ..."

if ! command -v uv &> /dev/null; then
    echo "✗ 需要 uv 來解析套件版本（比 pip 的 resolver 快很多也穩很多）。" >&2
    echo "  安裝方式: https://docs.astral.sh/uv/getting-started/installation/" >&2
    exit 1
fi

# 為什麼不直接 `pip download "hermes-agent[all]==版本"`：
#   1. hermes-agent 的直接相依都是 exact-pin，但部分再下一層的相依（例如
#      croniter 帶進來的 pytz）版本範圍很寬，pip 的 backtracking resolver
#      會為了找一組相容組合，把 pytz/tqdm 之類套件的每一個歷史版本都抓 metadata
#      來試，最後直接以 "resolution-too-deep" 失敗。
#   2. 就算不失敗，environment marker（例如 `uvloop ; sys_platform != 'win32'`）
#      在 `pip download` 裡是用「目前執行 pip 的這台機器」的平台去判斷，不是
#      `--platform` 那個目標平台 —— 在 Windows 上下載會把 Linux 用得到的
#      uvloop 誤判排除掉、卻把用不到的 Windows 專用套件抓進來。
# uv pip compile 用自己的 resolver（不會卡住），並且 --python-platform /
# --python-version 是「拿去決定 marker 怎麼判斷」的目標平台，不是本機平台，
# 兩個問題一次解決，產出的 requirements.txt 每一行都是 exact pin、沒有殘留的
# marker，pip download 只要照著抓檔案就好，不用再做任何版本判斷。
REQUIREMENTS_IN="$WORK_DIR/requirements.in"
REQUIREMENTS_TXT="$WORK_DIR/requirements-resolved.txt"
echo "hermes-agent[${HERMES_AGENT_EXTRAS}]==${VERSION}" > "$REQUIREMENTS_IN"

uv pip compile "$REQUIREMENTS_IN" \
    --python-platform x86_64-manylinux2014 \
    --python-version "3.11" \
    --no-header \
    -o "$REQUIREMENTS_TXT"

PKG_COUNT=$(grep -cE '^[a-zA-Z0-9_.-]+==' "$REQUIREMENTS_TXT")
echo "  ✓ 解析出 $PKG_COUNT 個套件（含所有相依），版本已全部鎖定"

PIP_DOWNLOAD_PY=""
for _candidate in python3 python; do
    if command -v "$_candidate" &> /dev/null && "$_candidate" --version &> /dev/null; then
        PIP_DOWNLOAD_PY="$(command -v "$_candidate")"
        break
    fi
done
# Windows 的 App Execution Alias 會讓 `command -v python3` 找到一個不能執行的假指令
# （雙擊會跳去開 Microsoft Store），上面用 `--version` 實際測試可執行才採用，避免誤判。
if [ -z "$PIP_DOWNLOAD_PY" ]; then
    echo "✗ 建置機需要一個能執行的 python3（僅用來跑 pip download，版本不用是 3.11）" >&2
    exit 1
fi
echo "  使用 $PIP_DOWNLOAD_PY 執行 pip download"

# pip 的 --python-version 只吃數字（例如 311），不是 "cp311" 這種 wheel tag 格式；
# "cp" 前綴是給 --implementation 用的、完整的 abi tag 才是給 --abi 用的。
PY_VERSION_DIGITS="${TARGET_PYTHON_TAG#cp}"

# --no-deps 是關鍵：requirements.txt 已經是 uv 解析過、完整攤平的相依清單
# （100 個套件，每個都 exact-pin）。不加 --no-deps 的話 pip 會再自己去walk
# 每個套件自己宣告的相依（例如 mcp 宣告了 `pywin32 ; sys_platform=="win32"`），
# 又用「執行 pip 的這台機器」（Windows）去判斷 marker，於是誤判成「這個
# linux 目標也需要 pywin32」，但 manylinux 平台當然沒有 pywin32 的 wheel，
# 直接整個下載失敗。requirements.txt 裡的清單已經是 uv 針對 linux 目標
# 解析好的正確答案，pip 只需要照單抓檔案，不需要也不應該再自己判斷一次。
"$PIP_DOWNLOAD_PY" -m pip download \
    -r "$REQUIREMENTS_TXT" \
    --no-deps \
    --dest "$BUNDLE_DIR/wheels" \
    --platform "$TARGET_PLATFORM" \
    --python-version "$PY_VERSION_DIGITS" \
    --abi "$TARGET_ABI_TAG" \
    --implementation cp \
    --only-binary=:all:

WHEEL_COUNT=$(find "$BUNDLE_DIR/wheels" -name '*.whl' -o -name '*.tar.gz' | wc -l)
echo "  ✓ 取得 $WHEEL_COUNT 個套件檔"
if [ "$WHEEL_COUNT" -lt 5 ]; then
    echo "  ⚠ 套件數量看起來太少，請確認版本號、extras 名稱是否正確。" >&2
fi

# ----------------------------------------------------------------------------
# 3. 組裝安裝包：client 腳本、設定檔、版本資訊、checksum
# ----------------------------------------------------------------------------
echo ""
echo "[3/3] 組裝安裝包 ..."

cp "$ROOT_DIR/client/"*.sh "$BUNDLE_DIR/client/"
cp "$ROOT_DIR/config/paths.conf" "$BUNDLE_DIR/config/paths.conf"
echo "$VERSION" > "$BUNDLE_DIR/VERSION"
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$BUNDLE_DIR/BUILD_TIME"

cd "$WORK_DIR"
TARBALL="hermes-agent-offline-$VERSION.tar.gz"
tar czf "$TARBALL" "hermes-agent-offline-$VERSION"
sha256sum "$TARBALL" > "$TARBALL.sha256"

mkdir -p "$ROOT_DIR/dist"
mv "$TARBALL" "$TARBALL.sha256" "$ROOT_DIR/dist/"

echo ""
echo "════════════════════════════════════════════════════════════"
echo " ✓ 完成"
echo "   $ROOT_DIR/dist/$TARBALL"
echo "   ($(du -h "$ROOT_DIR/dist/$TARBALL" | cut -f1))"
echo ""
echo " 下一步："
echo "   1. 用 FTP 把這兩個檔案（.tar.gz 與 .sha256）傳進封閉網路，"
echo "      放到共用目錄的 incoming/ 資料夾。"
echo "   2. 在封閉網路內、有權限寫共用目錄的帳號上執行 release/publish-release.sh。"
echo "════════════════════════════════════════════════════════════"
