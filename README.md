# capability-access-cleaner

**DeepSeek Harness 插件**：修复 Windows 上 `CapabilityAccessManager.db-wal`（camsvc 的 SQLite WAL
日志）异常占用 C 盘数十 GB 的问题。

> 以前这类问题要跑到同事电脑上开管理员 cmd / PowerShell 一步步操作；现在它是 dsh 的一个
> **插件（npm 包形态）**：同事一条命令装进 profile，Agent 就能把
> "检测 → 修复（截断）→ 验证" 当作工具调用，全程不用手敲命令。

原始人工流程见 [docs/清理指南-原始流程.md](docs/清理指南-原始流程.md)，本插件的 `cleanup.ps1`
是它的忠实脚本化实现。

## 修复原理（为什么是截断不是删除）

- 目标文件：`C:\ProgramData\Microsoft\Windows\CapabilityAccessManager\CapabilityAccessManager.db-wal`
- 它是 **camsvc（功能访问管理器服务）** 的 SQLite WAL 日志；异常时可达数十 GB
- 正确做法：`takeown`+`icacls` 接管目录 → `Stop-Service camsvc` → **截断（Truncate）文件内容**（保留文件）→ `Start-Service camsvc` → 验证 ≈0 KB
- ⚠️ **不要删除该文件**：直接删除会损坏 SQLite 数据库，影响 Windows 应用权限功能

## 目录内容

| 文件 | 作用 |
|---|---|
| `package.json` | npm 包声明，含 `dsh.bundle.patch`（声明自己是 profile 层） |
| `cordis.patch.yml` | bundle patch：把本插件挂载进 profile 层栈 |
| `lib/index.js` | 插件本体：注册工具 `clean_capability_access`（调用下方脚本） |
| `cleanup.ps1` | 固定修复脚本：检测 / 修复 / 验证，带 DryRun 与 SelfTest |
| `docs/清理指南-原始流程.md` | 原始人工流程指南（存档） |

## 安装到同事机器（公开仓库，无需账号）

```bash
# 同事机器上（已装 dsh）执行 —— 一条命令，从 GitHub 直装
dsh plugin --profile web add github:<你的用户名>/capability-access-cleaner#main
```

装完后 **重启 dsh 会话**，对 Agent 说（示例）：
> 用 clean_capability_access 工具检测这台电脑的 CapabilityAccessManager 异常文件

Agent 会先 `dryRun=true` 检测 → 确认命中后提示以管理员身份执行修复（takeown/icacls 需要管理员）。

```bash
# 卸载
dsh plugin --profile web remove capability-access-cleaner
```

> 提示：Windows 路径含空格时，`add` 的路径参数在部分 shell 包装下会被拆错，
> 优先用 `github:<user>/<repo>#main` 这种无空格的引用方式。

## 本地自测（不需要装插件也能验脚本）

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\cleanup.ps1 -SelfTest
```
预期：伪造异常文件 → 命中 → 截断修复 → 验证 ≈0 → 清理演示文件。不需要管理员，不碰真实系统。

## License
MIT
