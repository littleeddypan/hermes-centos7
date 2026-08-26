# hermes-agent CentOS 7 封閉網路安裝包

給沒有網路的 CentOS 7（oVirt + LDAP + 共用目錄，FTP 為唯一進站管道）環境用的
hermes-agent 離線安裝 / 更新方案。同仁自己跑一行指令安裝，個人設定留在自己的
`$HOME`，之後管理員發新版時同仁不用做任何事就自動用到新版。

## 架構總覽

```
                          ┌─────────────────────────┐
   有網路的機器            │  build/                  │
   （跑 Docker 就好，      │  build-offline-bundle.sh │  → dist/hermes-agent-offline-<版本>.tar.gz
    不必是 CentOS 7）      │   ├─ build-python-centos7.sh (容器內編譯 Python)
                          │   └─ pip download (抓 manylinux2014 wheel)
                          └────────────┬─────────────┘
                                       │ FTP（唯一進站管道）
                                       ▼
                     封閉網路 / 共用目錄 incoming/
                                       │
                                       │ release/publish-release.sh
                                       ▼
        共用目錄 (HERMES_SHARE_ROOT，例如 /mnt/shared/hermes-agent)
        ├── releases/0.15.1/{python, venv, wheels, VERSION}
        ├── releases/0.15.2/{...}
        ├── current -> releases/0.15.2        ← 管理員發新版就是切這個連結
        └── client/*.sh                       ← 同仁自助安裝腳本
                                       │
                     同仁在自己帳號下執行 client/hermes-agent-setup.sh
                                       ▼
        $HOME
        ├── .local/bin/hermes     一個小 wrapper，永遠指向 current
        └── .hermes/              個人設定、API 金鑰、對話紀錄、技能（HERMES_HOME）
```

**核心設計**：執行環境（Python + 所有套件）只在共用目錄裝「一份」，所有同仁共用、
唯讀；個人資料完全靠 hermes-agent 原生支援的 `HERMES_HOME` 環境變數（預設
`~/.hermes`）隔離到每個人自己的 Home 目錄。因此：

- **自助安裝**＝同仁自己在共用目錄下跑一個 setup 腳本，幾秒鐘完成，不佔用個人硬碟空間，不需要 root。
- **自動更新**＝管理員發佈新版時原子性切換 `current` 符號連結，同仁完全不用做任何事，
  下一次執行 `hermes` 指令就是新版（正在跑的舊 session 不受影響，因為 shebang 用的是
  當時就已解析好的絕對路徑）。
- **不需要對外連線**：全部套件都是預先下載好的 wheel、Python 是離線編譯好的可攜版本，
  安裝與更新完全不觸網。

## 角色與資料夾對應

| 角色 | 使用哪個資料夾 | 需要的權限 |
|---|---|---|
| 建置者（你，或 DevOps）| `build/` | 有網路、有 Docker 的任意機器（不必是 CentOS 7）|
| 封閉網路管理員 | `release/` | 對共用目錄有寫入權限的帳號（不需要 root）|
| 一般同仁 | `client/`（發佈後會自動同步到共用目錄的 `client/`）| 自己的 LDAP 帳號即可 |

---

## 第一次設定

1. 打開 [config/paths.conf](config/paths.conf)，把 `HERMES_SHARE_ROOT` 改成貴單位共用目錄
   實際的掛載路徑（例如 `/mnt/shared/hermes-agent`）。**這個路徑一旦拿去編譯 Python 之後
   就不能再換**（Python 的安裝路徑是編譯時寫死的），要換路徑必須整包重新編譯。
2. 確認 `HERMES_AGENT_VERSION` 是你要安裝的 hermes-agent 版本號（對應
   [PyPI 上的 hermes-agent](https://pypi.org/project/hermes-agent/)）。

## 步驟一：建置離線安裝包（在有網路的機器上）

需要 Docker（用來在乾淨的 `centos:7` 容器內編譯 Python，確保 glibc/ABI 對得上目標機器）
與 [uv](https://docs.astral.sh/uv/getting-started/installation/)（用來解析套件版本 —— `pip` 自己的
resolver 在遇到 hermes-agent 這種相依數量的專案時容易 backtracking 到
`resolution-too-deep` 失敗，且無法正確處理跨平台 environment marker，uv 兩個問題都沒有）。

```bash
cd build
./build-offline-bundle.sh
```

會依序做：
1. **編譯 Python**：在 `centos:7` 容器內從原始碼編譯 Python 3.11，`--prefix` 直接設成
   `<共用目錄>/releases/<版本>/python` 這個最終絕對路徑。
2. **下載套件**：`pip download "hermes-agent[all]==<版本>"`，用
   `--platform manylinux2014_x86_64 --python-version 311` 抓 CentOS 7 相容的 wheel，
   不需要在本機執行安裝，所以建置機甚至不必是 Linux。
   - `[all]` 是 hermes-agent 自己在 `pyproject.toml` 定義的核心功能集合（對話、cron、
     CLI、MCP、Google、web 等），**不含**語音辨識、Slack/Matrix 等重量級可選整合 —
     符合先前確認的「核心功能即可」。
3. **打包**：產出 `dist/hermes-agent-offline-<版本>.tar.gz` 與對應的 `.sha256`。

> ⚠️ **務必驗證一次**：CentOS 7 的 glibc 是 2.17，非常舊。雖然是在 `centos:7` 容器內編譯，
> 理論上 ABI 會對，但強烈建議正式派送前，先在一台真正的 CentOS 7 機器上把
> `python/` 解壓到跟 `HERMES_SHARE_ROOT` 完全一致的路徑，執行
> `<路徑>/python/bin/python3 --version` 確認能跑，再進到下一步。

## 步驟二：傳進封閉網路

把 `dist/hermes-agent-offline-<版本>.tar.gz` 和 `dist/hermes-agent-offline-<版本>.tar.gz.sha256`
兩個檔案**都**用 FTP 傳進封閉網路，放到共用目錄的 `incoming/` 底下（第一次要自己建立這個資料夾）。

FTP 傳輸請務必用 **binary 模式**，否則二進位檔（wheel、Python 執行檔）可能被文字模式
轉檔工具（例如自動轉換換行符號）默默毀損——這也是為什麼一定要連 `.sha256` 一起傳、
一起驗證。

## 步驟三：在封閉網路內發佈版本

用一個對共用目錄有寫入權限的帳號（不需要 root）執行：

```bash
bash release/publish-release.sh /mnt/shared/hermes-agent/incoming/hermes-agent-offline-0.15.1.tar.gz
```

會自動：驗證 checksum → 解壓到 `releases/<版本>/` → 用包內的 Python 在最終路徑上
建立 venv 並離線安裝 → 開放所有人讀取/執行權限（不給寫入）→ 原子性切換 `current` →
同步最新的 `client/` 自助腳本 → 清掉太舊的版本（預設留最新 3 個，見 `KEEP_RELEASES`）。

發佈完成後，**所有已經安裝過的同仁下次執行 `hermes` 就會自動是新版**，不用通知、
不用他們做任何事。

## 步驟四：同仁自己安裝

請同仁在自己的帳號下執行（一行指令，人傳人即可，不需要 IT 協助）：

```bash
bash /mnt/shared/hermes-agent/client/hermes-agent-setup.sh
```

會建立：
- `~/.local/bin/hermes` — 指向共用環境目前版本的小指令
- `~/.hermes/` — 個人設定目錄（API 金鑰、對話紀錄、技能等）

安裝完會問要不要直接跑 `hermes setup` 設定精靈填入個人 API 金鑰等資訊。

其他自助工具：
- `hermes-agent-status.sh` — 檢查自己的安裝狀態
- `hermes-agent-uninstall.sh [--purge]` — 移除個人指令（`--purge` 才會連個人資料一起刪，預設不刪）

---

## 之後要升級版本怎麼做

之後每次 hermes-agent 有新版要導入，重複 **步驟一 → 二 → 三** 即可：
1. 改 `config/paths.conf` 裡的 `HERMES_AGENT_VERSION`，重跑 `build-offline-bundle.sh`
   （Python 只要 glibc 相容不用重編，可以重複用同一份，見下方「加速後續版本建置」）。
2. FTP 傳新的 tar.gz 進去。
3. `publish-release.sh` 發佈。

同仁端完全不用重跑安裝腳本、也不需要跑任何更新指令。

### 加速後續版本建置

`build-offline-bundle.sh` 會自動快取編譯好的 Python：只要 `PYTHON_VERSION` 和
`HERMES_SHARE_ROOT` 都沒變，重跑時會直接沿用 `build/work-<版本>/python-build/python.tar.gz`，
跳過容器編譯那幾分鐘，不需要手動操作。wheel 下載每次都會重跑（因為套件版本可能變了）。
如果改了 `PYTHON_VERSION` 或 `HERMES_SHARE_ROOT`，腳本會自動偵測並重新編譯。

---

## GitHub Release 與每日自動更新

這個 repo 本身是公開的，每個版本的離線安裝包都發佈在
[Releases](../../releases)（GitHub 單一檔案有 100MB 限制，安裝包直接
`git commit` 會超過，所以用 Release 附件發佈，不進 git 樹）。每個 Release
附三個檔案：

- `hermes-agent-offline-<版本>.tar.gz` — 完整離線安裝包
- `hermes-agent-offline-<版本>.tar.gz.sha256` — 校驗碼
- `python.tar.gz` — 單獨附一份，讓下面的自動化不用每次都重新編譯

[automation/check-and-publish.sh](automation/check-and-publish.sh) 由排程的
cloud agent 每天執行一次：查詢 PyPI 上 hermes-agent 的最新版本，如果比
`config/paths.conf` 記錄的版本新，就沿用「目前最新 Release」裡已經編譯好的
`python.tar.gz`（**不需要 Docker、不需要重新編譯 Python/OpenSSL**——這兩個
版本平常不會變），只重新解析、下載 hermes-agent 新版的相依套件，打包成新的
Release，並把 `config/paths.conf` 的版本號 commit 回 repo。

如果哪天真的要換 Python 或 OpenSSL 版本，那一次需要手動在有 Docker 的機器上
跑 `build/build-offline-bundle.sh`，把新的 `python.tar.gz` 發到新 Release 裡，
之後 `check-and-publish.sh` 會自動接續沿用新的那份。

---

## 已知限制與風險

- **glibc 相容性**：整個方案的前提是「在 centos:7 容器內編譯」保證 ABI 對齊。
  如果貴單位的 CentOS 7 機器有做過非標準的 glibc 升級，請務必照步驟一的提醒先驗證。
- **`current` 切版是全體同步的**：沒有分批 / canary 發佈機制。如果新版有問題，
  回退方式是重新對舊版本的資料夾執行「切換 current」（`ln -sfn releases/<舊版本> current`
  後 `mv -T` 成 `current`，`publish-release.sh` 內有同樣的邏輯可以參考／改寫成
  `rollback.sh`，目前未附上，如需要可以再補）。
- **FTP 完整性**：務必用 binary 模式且核對 sha256，這是目前設計裡唯一的資料
  完整性防線。
- **共用目錄權限**：`releases/` 應該只有管理員帳號（或管理員群組）可寫，其他人
  唯讀＋可執行即可 —— `publish-release.sh` 已經會 `chmod -R a+rX`，但共用目錄本身
  的擁有者／群組權限請依貴單位規範另行確認。
- **正在執行中的 session**：管理員切換 `current` 的當下，正在使用舊版的同仁不會
  被打斷（他們的 process 已經解析到舊版的絕對路徑），下次重新執行才會用到新版。
