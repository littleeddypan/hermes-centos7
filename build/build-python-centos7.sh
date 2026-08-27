#!/bin/bash
# ============================================================================
# 在 centos:7 容器內，從原始碼編譯出一份可攜式 Python，供 CentOS 7 離線環境使用
# ============================================================================
# 為什麼不直接用 `uv python install` 或其他預編譯的 portable Python？
#   CentOS 7 的 glibc 是 2.17（2014 年的版本）。多數現成的 portable Python
#   建置（含 astral 的 python-build-standalone，也就是 uv 背後用的那份）
#   近期版本大多要求 glibc 2.28+，直接放到 CentOS 7 上會啟動失敗
#   （error while loading shared libraries / GLIBC_2.2x not found）。
#   在真正的 centos:7 容器裡「原地編譯」，可以保證產出的 Python 二進位檔
#   與目標機器的 glibc/ABI 完全對齊。
#
# 為什麼要自己編 OpenSSL？
#   CentOS 7 系統內建的 openssl-devel 是 1.0.2k（2017 年）。Python 3.10+
#   的 _ssl 模組需要 OpenSSL >= 1.1.1 才能建置 —— 用系統版本編譯，
#   configure/make 都不會報錯，只是 _ssl 這個 extension module 建置失敗
#   會被默默跳過，結果是一個「看起來編譯成功、但完全不能發 HTTPS 請求」
#   的 Python（對一個幾乎每個操作都要打 LLM API 的 agent 程式是致命的，
#   而且不會在編譯當下報錯，只會在真正呼叫 API 時才爆炸）。
#   解法：先在同一個最終路徑下編一份新版 OpenSSL，Python 的 configure
#   用 --with-openssl 指過去即可，兩者共用同一組 rpath。
#
# 為什麼要自己編 SQLite？
#   CentOS 7 系統內建的 sqlite-devel 是 3.7.17（2013 年）。hermes-agent 的
#   session 資料庫（hermes_state.py）大量使用 partial index（CREATE INDEX
#   ... WHERE ...，需要 >= 3.8.0）、UPSERT（ON CONFLICT ... DO UPDATE，
#   需要 >= 3.24.0）、遞迴 CTE（WITH RECURSIVE，需要 >= 3.8.3）。用系統版本
#   編譯一樣不會在編譯當下報錯（_sqlite3 module 照樣建置成功），只會在真正
#   執行到這些語法時（例如 /sessions 指令）才丟出
#   "OperationalError: near "WHERE": syntax error" 這類看起來莫名其妙的錯誤。
#   解法跟 OpenSSL 一樣：同一個最終路徑下先編一份新版 SQLite，讓 Python
#   的 _sqlite3 extension 透過 CPPFLAGS/LDFLAGS 連到這份而不是系統那份。
#
# 用法（在有 Docker、能連網的機器上執行 — 不需要是 CentOS 7）：
#   ./build-python-centos7.sh <輸出目錄> <python版本> <最終安裝絕對路徑前綴> <openssl版本> <sqlite版本> <sqlite年份>
#
# 範例：
#   ./build-python-centos7.sh ./out 3.11.11 /mnt/shared/hermes-agent/releases/0.15.1/python 3.0.15 3.53.4 2026
#
# 第三個參數非常重要：Python 跟 OpenSSL/SQLite 編譯時的 --prefix 就是寫死的
# 最終安裝路徑，之後在 CentOS 7 上「必須」解壓到完全相同的絕對路徑，否則標準
# 函式庫、site-packages、動態連結庫都會找不到。這個路徑要跟 config/paths.conf
# 的 HERMES_SHARE_ROOT 算出來的路徑一致。
#
# SQLite 版本/年份要跟 https://www.sqlite.org/download.html 上公告的一致
# （下載網址是 https://www.sqlite.org/<年份>/sqlite-autoconf-<版本去掉點>.tar.gz，
# 年份是「該版本發佈的年份」，不是編譯當下的年份，之後版本升級時要一起確認更新）。
# ============================================================================
set -euo pipefail

OUT_DIR="${1:?用法: $0 <輸出目錄> <python版本> <最終安裝絕對路徑前綴> <openssl版本> <sqlite版本> <sqlite年份>}"
PY_VERSION="${2:?缺少 python 版本，例如 3.11.11}"
FINAL_PREFIX="${3:?缺少最終安裝絕對路徑，例如 /mnt/shared/hermes-agent/releases/0.15.1/python}"
OPENSSL_VERSION="${4:?缺少 OpenSSL 版本，例如 3.0.15}"
SQLITE_VERSION="${5:?缺少 SQLite 版本，例如 3.53.4}"
SQLITE_YEAR="${6:?缺少 SQLite 發佈年份，見 https://www.sqlite.org/download.html，例如 2026}"

if ! command -v docker &> /dev/null; then
    echo "✗ 需要 Docker 才能在乾淨的 centos:7 環境裡編譯。請先安裝 Docker。" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

# 在 Git Bash / MSYS（Windows 上跑這支腳本時）下，docker -v 的兩段路徑都會被 MSYS
# 誤判成 Unix 路徑並亂改寫，导致掛載失敗。偵測到 cygpath 存在時，host 端路徑轉成
# Windows 原生路徑、並用 MSYS_NO_PATHCONV=1 保護 container 端的 /out 不被誤改寫。
DOCKER_MOUNT_SRC="$OUT_DIR"
if command -v cygpath &> /dev/null; then
    DOCKER_MOUNT_SRC="$(cygpath -w "$OUT_DIR")"
    export MSYS_NO_PATHCONV=1
fi

echo "→ 在 centos:7 容器內編譯 OpenSSL ${OPENSSL_VERSION} + SQLite ${SQLITE_VERSION} + Python ${PY_VERSION}"
echo "  安裝前綴固定為 ${FINAL_PREFIX}"
echo "  （這一步會下載 CentOS 7 相依套件、OpenSSL 與 Python 原始碼，需要網路，約需 15-25 分鐘）"

# CentOS 7 已於 2024 年 EOL，官方 yum mirror 多半已下線，改用 vault.centos.org。
docker run --rm \
    -v "$DOCKER_MOUNT_SRC:/out" \
    -e PY_VERSION="$PY_VERSION" \
    -e FINAL_PREFIX="$FINAL_PREFIX" \
    -e OPENSSL_VERSION="$OPENSSL_VERSION" \
    -e SQLITE_VERSION="$SQLITE_VERSION" \
    -e SQLITE_YEAR="$SQLITE_YEAR" \
    centos:7 \
    bash -c '
        set -euo pipefail
        set -x

        # CentOS 7 官方源已下線，改指向 vault
        sed -i s/mirror.centos.org/vault.centos.org/g /etc/yum.repos.d/*.repo
        sed -i s/^#.*baseurl=http/baseurl=http/g /etc/yum.repos.d/*.repo
        sed -i s/^mirrorlist=http/#mirrorlist=http/g /etc/yum.repos.d/*.repo

        # perl / perl-IPC-Cmd：OpenSSL 的 Configure/config 腳本是 perl 寫的，
        # CentOS 7 預設的 perl 5.16 常常缺 IPC::Cmd 這個核心模組。
        # 特意不裝 openssl-devel、也不裝 sqlite-devel：我們要編自己的版本，
        # 不用系統那兩份太舊的（系統 sqlite-devel 是 3.7.17，見上面的說明）。
        yum install -y -q \
            gcc gcc-c++ make perl perl-IPC-Cmd \
            zlib-devel bzip2-devel ncurses-devel \
            readline-devel tk-devel gdbm-devel \
            libffi-devel xz-devel libuuid-devel \
            wget tar

        mkdir -p "$FINAL_PREFIX"

        # ---------------------------------------------------------------
        # OpenSSL：裝到跟 Python 一樣的最終路徑下，Python 的 configure
        # 用 --with-openssl 指過去；兩者共用同一組 rpath ($FINAL_PREFIX/lib)。
        # ---------------------------------------------------------------
        cd /tmp
        wget -q "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"
        tar xf "openssl-${OPENSSL_VERSION}.tar.gz"
        cd "openssl-${OPENSSL_VERSION}"

        # --libdir=lib：OpenSSL 的 ./config 在 RHEL/CentOS 系 x86_64 上會自動
        # 偵測成 RPM 的 lib64 慣例，把 .so 裝到 $FINAL_PREFIX/lib64 而不是
        # lib —— 但 Python 自己的 --prefix 是裝在 lib/，兩邊 rpath 對不起來，
        # 之後 python3 -c "import ssl" 會 "cannot open shared object file:
        # libssl.so.3"。強制 --libdir=lib 讓兩者用同一個目錄、同一組 rpath。
        ./config \
            --prefix="$FINAL_PREFIX" \
            --openssldir="$FINAL_PREFIX/ssl" \
            --libdir=lib \
            shared zlib \
            -Wl,-rpath,"$FINAL_PREFIX/lib"

        make -j"$(nproc)"
        # install_sw：只裝 library/header/執行檔，跳過 install_docs（man page），
        # 省時間，也避開 CentOS 7 上某些 doc 安裝路徑的小毛病。
        make install_sw

        export LD_LIBRARY_PATH="$FINAL_PREFIX/lib"
        "$FINAL_PREFIX/bin/openssl" version

        # ---------------------------------------------------------------
        # SQLite：同樣裝到跟 Python 一樣的最終路徑下（見上面的說明：系統的
        # 3.7.17 太舊，hermes-agent 的 session 資料庫用到的 partial index /
        # UPSERT / 遞迴 CTE 都不支援）。sqlite-autoconf 的建置腳本會自動產生
        # sqlite3.pc，跟 Python 共用同一個 lib/ 目錄與 rpath。
        # ---------------------------------------------------------------
        cd /tmp
        SQLITE_AUTOCONF_VER="$(printf "%d%02d%02d00" $(echo "$SQLITE_VERSION" | tr "." " "))"
        wget -q "https://www.sqlite.org/${SQLITE_YEAR}/sqlite-autoconf-${SQLITE_AUTOCONF_VER}.tar.gz"
        tar xf "sqlite-autoconf-${SQLITE_AUTOCONF_VER}.tar.gz"
        cd "sqlite-autoconf-${SQLITE_AUTOCONF_VER}"
        ./configure --prefix="$FINAL_PREFIX" --disable-static
        make -j"$(nproc)"
        make install

        "$FINAL_PREFIX/bin/sqlite3" --version

        # ---------------------------------------------------------------
        # Python：--with-openssl 指到上面剛裝好的私有 OpenSSL；CPPFLAGS/
        # LDFLAGS 讓 _sqlite3 extension 連到上面剛裝好的私有 SQLite（配置階段
        # 找不到系統的 sqlite3.h，因為我們特意沒裝 sqlite-devel，只會找到這份）。
        # ---------------------------------------------------------------
        cd /tmp
        wget -q "https://www.python.org/ftp/python/${PY_VERSION}/Python-${PY_VERSION}.tgz"
        tar xf "Python-${PY_VERSION}.tgz"
        cd "Python-${PY_VERSION}"

        # 特意不加 --enable-optimizations（PGO）：CentOS 7 內建的 gcc 4.8.5（2015
        # 年）在編 Python 3.11 的 profile-opt 階段會讓剛編出來、自舉用來產生
        # frozen modules 的 python 直譯器炸掉（SystemError: <built-in function
        # compile> returned NULL without setting an exception）。這是舊 gcc 搭配
        # PGO 已知會踩到的地雷，不是資源不足。拿掉 PGO 換來的是執行檔慢個
        # 10-20%，對這種以 LLM API 呼叫為主、CPU-bound 不多的 agent CLI
        # 影響可忽略，換取編譯穩定可重現。
        # --with-ensurepip=install：內建 pip，離線安裝 wheel 用得到。
        # CPPFLAGS/LDFLAGS 的 -I/-L 指到私有 SQLite（見上面說明）；
        # PKG_CONFIG_PATH 讓 configure 的 pkg-config 偵測也找得到同一份，
        # 不會不小心 fallback 去抓系統版本（反正也沒裝，但求保險一致）。
        export PKG_CONFIG_PATH="$FINAL_PREFIX/lib/pkgconfig"
        ./configure \
            --prefix="$FINAL_PREFIX" \
            --with-openssl="$FINAL_PREFIX" \
            --with-ensurepip=install \
            --enable-shared \
            CPPFLAGS="-I$FINAL_PREFIX/include" \
            LDFLAGS="-L$FINAL_PREFIX/lib -Wl,-rpath=$FINAL_PREFIX/lib"

        make -j"$(nproc)"
        make install

        # install 只裝 python3.11，沒有 python3 / python 符號連結，這裡補上，
        # 方便之後的腳本用固定檔名呼叫。
        PY_MINOR="$(echo "$PY_VERSION" | cut -d. -f1,2)"
        ln -sf "python${PY_MINOR}" "$FINAL_PREFIX/bin/python3"
        ln -sf "python${PY_MINOR}" "$FINAL_PREFIX/bin/python"
        ln -sf "pip${PY_MINOR}" "$FINAL_PREFIX/bin/pip3"
        ln -sf "pip${PY_MINOR}" "$FINAL_PREFIX/bin/pip"

        echo "✓ 編譯完成，驗證（含 SSL / SQLite）："
        "$FINAL_PREFIX/bin/python3" --version
        "$FINAL_PREFIX/bin/python3" -c "import ssl; print(\"OpenSSL:\", ssl.OPENSSL_VERSION)"
        "$FINAL_PREFIX/bin/python3" -c "import lzma, sqlite3, ctypes, curses; print(\"lzma/sqlite3/ctypes/curses OK\")"
        "$FINAL_PREFIX/bin/python3" -c "import sqlite3; print(\"SQLite:\", sqlite3.sqlite_version)"
        # 不只檢查版本號，直接跑一次 hermes-agent 實際會用到、CentOS 7 系統版
        # SQLite (3.7.17) 會炸掉的語法（partial index / UPSERT / 遞迴 CTE），
        # 確認真的修好了，而不是只是「看起來」是新版。
        "$FINAL_PREFIX/bin/python3" -c "import sqlite3; conn = sqlite3.connect(\":memory:\"); conn.execute(\"CREATE TABLE t (id INTEGER PRIMARY KEY, active INTEGER)\"); conn.execute(\"CREATE INDEX idx ON t(active) WHERE active IS NULL\"); conn.execute(\"INSERT INTO t VALUES (1, 1) ON CONFLICT(id) DO UPDATE SET active = excluded.active\"); conn.execute(\"WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM c WHERE n < 3) SELECT * FROM c\"); print(\"partial index / UPSERT / WITH RECURSIVE all OK\")"

        # 打包成 tar.gz 再送出容器，不要把檔案原封不動 cp 到 /out。
        # 原因：/out 是 bind mount 到 Windows/NTFS 的路徑，NTFS 不記錄 Linux
        # 的可執行位元 (x bit)，實測會讓 python3.11 主執行檔的 +x 在跨過這條
        # 邊界時被默默弄丟（檔案內容完好，只是權限位元消失，導致外面的腳本
        # 判斷「找不到可執行的 python3」）。tar 的每個 entry 都會把權限位元
        # 存成資料的一部分，不依賴檔案系統屬性，所以只要全程用「解壓 tar.gz」
        # 而不是「複製檔案」跨越這個邊界，權限就不會遺失。
        tar czf /out/python.tar.gz -C "$FINAL_PREFIX" .
        echo "✓ 已打包: /out/python.tar.gz ($(du -h /out/python.tar.gz | cut -f1))"
    '

echo ""
echo "✓ 產出位置: ${OUT_DIR}/python.tar.gz"
echo "  下一步：build-offline-bundle.sh 會自動把這份 Python 打包進離線安裝包。"
echo ""
echo "⚠ 強烈建議：正式派送前，先在一台實際 CentOS 7（或相同 glibc）機器上，"
echo "  把 ${OUT_DIR}/python.tar.gz 解壓到 ${FINAL_PREFIX} 這個路徑，"
echo "  執行 <路徑>/bin/python3 -c 'import ssl; print(ssl.OPENSSL_VERSION)' 驗證真的能跑，"
echo "  再進行後續打包發佈。"
