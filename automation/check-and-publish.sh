#!/bin/bash
# ============================================================================
# 每日自動檢查 hermes-agent 是否有新版本，有的話重新打包並發佈新的 GitHub Release
# ============================================================================
# 設計給排程用的 cloud agent（或任何一次性、乾淨 checkout 的環境）執行，
# 需要：git、gh（已認證且對這個 repo 有寫入權限）、curl、python3、uv。
#
# 特意不需要 Docker：build/build-python-centos7.sh 編出來的 Python + OpenSSL
# 只跟 config/paths.conf 裡的 PYTHON_VERSION / OPENSSL_VERSION / 共用目錄路徑
# 有關，這些平常不會變 —— 所以直接沿用「目前最新 Release」裡已經編譯好的
# python.tar.gz，每天只需要重新解析、下載 hermes-agent 新版本的相依套件。
#
# 如果哪天真的要換 Python 或 OpenSSL 版本，那一次需要手動在有 Docker 的機器上
# 跑 build/build-offline-bundle.sh，把新的 python.tar.gz 發到新 release 裡，
# 之後這支腳本會自動接續沿用新的那份。
# ============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/paths.conf
source "$REPO_ROOT/config/paths.conf"

export PATH="$HOME/.local/bin:$PATH"

# 排程用的 cloud sandbox 不一定預裝 gh / uv，這裡裝到 $HOME/.local/bin，
# 不需要 root。gh 的認證沿用環境既有的 GH_TOKEN / GITHUB_TOKEN（cloud agent
# 環境通常已經有，讓它能 clone/push 這個 repo），不用另外 gh auth login。
ensure_gh() {
    command -v gh &> /dev/null && return
    echo "→ gh 不存在，安裝到 \$HOME/.local/bin ..." >&2
    local arch tmp
    arch="$(uname -m)"; case "$arch" in aarch64) arch=arm64 ;; *) arch=amd64 ;; esac
    tmp="$(mktemp -d)"
    curl -fsSL "https://github.com/cli/cli/releases/download/v2.63.2/gh_2.63.2_linux_${arch}.tar.gz" -o "$tmp/gh.tar.gz"
    tar xzf "$tmp/gh.tar.gz" -C "$tmp"
    mkdir -p "$HOME/.local/bin"
    cp "$tmp"/gh_*/bin/gh "$HOME/.local/bin/gh"
}

ensure_uv() {
    command -v uv &> /dev/null && return
    echo "→ uv 不存在，安裝到 \$HOME/.local/bin ..." >&2
    curl -LsSf https://astral.sh/uv/install.sh | sh
}

ensure_gh
ensure_uv

echo "→ 查詢 PyPI 上 hermes-agent 最新版本..."
LATEST_VERSION="$(curl -fsSL https://pypi.org/pypi/hermes-agent/json | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["version"])')"
echo "  PyPI 最新版本:     $LATEST_VERSION"
echo "  repo 目前記錄版本: $HERMES_AGENT_VERSION"

if [ "$LATEST_VERSION" = "$HERMES_AGENT_VERSION" ]; then
    echo "✓ 已經是最新版本，不需要動作。"
    exit 0
fi

echo "→ 發現新版本 $LATEST_VERSION，開始重新打包（沿用既有 Python/OpenSSL，不需要 Docker）..."

# 部分排程用的 sandbox 只允許 gh 的 REST 呼叫（`gh api repos/{owner}/{repo}/...`），
# `gh release list --json ...` 這種高階指令的 --json/--jq 輸出機制會走 GraphQL，
# 在那類環境會被 403 擋掉，所以這裡改用 `gh api` 直接打 REST 端點取得最新 tag。
REPO_SLUG="$(git -C "$REPO_ROOT" remote get-url origin | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')"
CURRENT_TAG="$(gh api "repos/$REPO_SLUG/releases/latest" --jq '.tag_name')"
echo "  沿用 $CURRENT_TAG 裡已經編譯好的 python.tar.gz"

WORK_DIR="$(mktemp -d)"
gh release download "$CURRENT_TAG" -p "python.tar.gz" -D "$WORK_DIR" --clobber

NEW_NAME="hermes-agent-offline-$LATEST_VERSION"
BUNDLE_DIR="$WORK_DIR/$NEW_NAME"
mkdir -p "$BUNDLE_DIR"/{wheels,client,config}
cp "$WORK_DIR/python.tar.gz" "$BUNDLE_DIR/python.tar.gz"
cp "$REPO_ROOT/client/"*.sh "$BUNDLE_DIR/client/"
cp "$REPO_ROOT/config/paths.conf" "$BUNDLE_DIR/config/paths.conf"

echo "→ 用 uv 解析 hermes-agent[$HERMES_AGENT_EXTRAS]==$LATEST_VERSION 的完整相依清單..."
echo "hermes-agent[${HERMES_AGENT_EXTRAS}]==${LATEST_VERSION}" > "$WORK_DIR/requirements.in"
uv pip compile "$WORK_DIR/requirements.in" \
    --python-platform x86_64-manylinux2014 \
    --python-version "3.11" \
    --no-header \
    -o "$WORK_DIR/requirements-resolved.txt"

# --no-deps 的原因見 build/build-offline-bundle.sh 裡的說明：requirements.txt
# 已經是 uv 針對 linux 目標解析好、攤平的完整相依清單，pip 只管照單抓檔案，
# 不要再自己 walk 一次相依（否則會誤判 marker，抓到用不到的平台專屬套件）。
PY_VERSION_DIGITS="${TARGET_PYTHON_TAG#cp}"
python3 -m pip download \
    -r "$WORK_DIR/requirements-resolved.txt" \
    --no-deps \
    --dest "$BUNDLE_DIR/wheels" \
    --platform "$TARGET_PLATFORM" \
    --python-version "$PY_VERSION_DIGITS" \
    --abi "$TARGET_ABI_TAG" \
    --implementation cp \
    --only-binary=:all:

WHEEL_COUNT=$(find "$BUNDLE_DIR/wheels" -type f | wc -l)
echo "  ✓ 取得 $WHEEL_COUNT 個套件檔"

echo "$LATEST_VERSION" > "$BUNDLE_DIR/VERSION"
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$BUNDLE_DIR/BUILD_TIME"

( cd "$WORK_DIR" && tar czf "$NEW_NAME.tar.gz" "$NEW_NAME" )
( cd "$WORK_DIR" && sha256sum "$NEW_NAME.tar.gz" > "$NEW_NAME.tar.gz.sha256" )

echo "→ 更新 config/paths.conf 的版本號並 commit..."
sed -i "s/^HERMES_AGENT_VERSION=.*/HERMES_AGENT_VERSION=\"$LATEST_VERSION\"/" "$REPO_ROOT/config/paths.conf"
cd "$REPO_ROOT"
git add config/paths.conf
git commit -m "chore: bump hermes-agent to $LATEST_VERSION"
git push

echo "→ 發佈 GitHub Release v$LATEST_VERSION..."
gh release create "v$LATEST_VERSION" \
    "$WORK_DIR/$NEW_NAME.tar.gz" \
    "$WORK_DIR/$NEW_NAME.tar.gz.sha256" \
    "$WORK_DIR/python.tar.gz" \
    --title "hermes-agent $LATEST_VERSION (CentOS 7 offline installer)" \
    --notes "自動偵測到 hermes-agent 新版本 $LATEST_VERSION，重新打包（沿用既有的 Python $PYTHON_VERSION + OpenSSL $OPENSSL_VERSION，未重新編譯）。"

echo "✓ 完成：v$LATEST_VERSION 已發佈"
