# C_clean_tool · CDriveGuard

给不懂命令行的人用的 C 盘瘦身小工具：**一个窗口、两个按钮、永不删除文件**。
解压即用，不用安装任何东西（Windows 自带 PowerShell 5.1 + WinForms），不联网、不写注册表、不装服务、不建计划任务。

```
C 盘可用 22.45 GB / 146.48 GB        [进度条]          权限：普通用户
☑ 用户临时文件  66,428 个  5.21 GB   ☑ Windows 临时  1,193 个  0.14 GB
[① 扫描（不改动文件）] [② 开始清理 5.35 GB] [看清理明细] [还原上次清理] [打开隔离文件夹]
```

## 直接用（推荐）

1. 下载 [`dist/CDriveGuard-v1.1.0.zip`](dist/CDriveGuard-v1.1.0.zip)（30 KB）；
2. 右键 zip → 属性 → 勾选 **解除锁定** → 再解压（否则可能双击没反应，这是 Windows 的 MOTW 机制）；
3. 双击 **`Start.cmd`** → 先读弹出的「使用说明」页 → 点「我知道了，开始使用」→ 点「① 扫描」→ 看表格 → 点「② 开始清理」。

清理只是把文件**移动到隔离区** `D:\CDriveGuard-Quarantine\<时间戳>\`（记住原目录层级），
出问题时点「还原上次清理」就能全部放回原位。默认保留 30 天。

## 开屏「使用说明」页（v1.1.0）

第一次打开（其实每次启动都会）先弹出一页模态使用说明：**10 秒内关不掉** —— 点右上角 ×、
按 Esc、Alt+F4 都会被拦下并提示「还需等待 N 秒」；倒计时归零后按钮才可点，
点「我知道了，开始使用」进入主界面。主窗口从弹出那刻起就在背后，只是**在说明页关掉之前不接受操作**。

写这个是因为：收工具的人通常不读 README，但一定会读这个弹窗。这一页讲清了
「只移动不删除」「三步用法」「怎么还原」「绝不碰什么」。
`-IntroSeconds <n>`（隐藏参数，`0` = 关闭）只留给自动化测试用，不对外说明。

## 安全设计

| 约束 | 说明 |
|---|---|
| 只移动，绝不删除 | 引擎只有 `Move-Item` 路径，没有 `Remove-Item` 候选循环；删除由用户 30 天后自己决定 |
| 黑名单硬拦截 | `Windows\Installer`、`WinSxS`、`WindowsApps`、`System32`、`ProgramData` 根、`AppData\Roaming` 根、文档/桌面/下载、`.ssh`、`.git` 一律跳过 |
| 只清缓存类目录 | 浏览器/Electron/包管理器缓存里的**过期文件**，不碰 profile 根目录、不碰聊天记录与数据库 |
| 先扫描再动手 | 「① 扫描」是纯只读；不扫描时「② 开始清理」是禁用的 |
| 普通权限可用 | 被占用的少数文件自动跳过并计数；另提供「以管理员身份重新打开」 |
| 完全离线 | 不发起任何网络请求，不上传日志 |

## 仓库结构

```
dist/CDriveGuard/            可直接运行的成品（由构建脚本生成，别手改）
  Start.cmd                  双击入口（ASCII-only + CRLF + 无 BOM）
  CDriveGuard.ps1            单页 WinForms 界面
  README.txt                 给最终用户的三步说明
  engine/                    清理引擎快照（Invoke-SafeClean / Invoke-CDriveAudit）
  SHA256.txt / VERSION.txt   校验和与版本戳
dist/CDriveGuard-v1.1.0.zip  发给别人的压缩包
tools/Build-Dist.ps1         构建：拷贝引擎快照 → 统一 UTF-8 BOM → 版本戳 → SHA256 → 打包
tools/Test-CleanResult.ps1   校验 clean-*.json（搬动数、失败原因、隔离区字节数、还原脚本可解析）
tools/Start-Detached.ps1     后台启动辅助（避免前台子进程被终端重启带走）
tools/New-ClineSkill.ps1     脚手架：生成符合 Cline 规范的 skill（引擎就以此形式维护）
SKILL-使用说明.md            这套引擎作为 Cline skill 的完整使用说明（含量化审计与迁移）
```

## 从源码重新打包

改完引擎或界面后重跑构建（会刷新 `SHA256.txt` 并重新打 zip）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Build-Dist.ps1 -Zip
```

自检（真实建窗、触发 Shown 事件、检查控件状态，不弹确认框）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File dist\CDriveGuard\CDriveGuard.ps1 -SmokeTest
```

> 引擎的**唯一来源**是 Cline skill 目录（`~\.cline\skills\win11-storage-governance\scripts`）；
> `dist\` 里的 `engine\` 是它某一版的快照。改逻辑只改 skill，然后重跑 `Build-Dist.ps1`，
> 避免两份逻辑漂移。`-SourceScripts` 参数可以指向别的引擎目录。

## 引擎新增的三个向后兼容开关

GUI 需要的机器可读输出，命令行默认行为完全不变：

| 参数 | 作用 |
|---|---|
| `-PlanJson <path>` | dry-run 额外写 `plan.json`（汇总）+ 同名 `.csv`（逐文件），自动改用 PowerShell 扫描 |
| `-ProgressFile <path>` | `-Execute` 每 25 个文件追加一行 JSONL，末尾追加 `status=finished` |
| `-OnlyRoots <labels>` | 只处理指定类别的根目录；都不匹配时回退全部并告警 |

## 已实测的验收项（Windows 11 + PowerShell 5.1）

| 项 | 结果 |
|---|---|
| 语法（AST） | 3 个脚本 `errors=0` |
| 编码 | `.ps1/.txt` 带 UTF-8 BOM；`Start.cmd` 无 BOM + 全 CRLF（cmd 会把 BOM 当字符打印） |
| 真实建窗自检 | 24 个控件、磁盘状态条、权限标签、日志均正常，退出码 0 |
| 开屏说明页（v1.1.0） | 启动即弹出；倒计时中 `Close()` 被拒且提示「还需等待 N 秒」；归零后按钮可点；关掉后主窗口 `scanEnabled=True`、日志记「已阅读使用说明」 |
| 真实点按「① 扫描」 | 表格出现 `User TEMP / 30 / 465 KB`，按钮变「② 开始清理 465 KB」 |
| 真实点按「② 开始清理」 | 进度 0→100、`清理完成：释放 465 KB`、还原按钮自动启用、隔离区 30 个文件且层级完整 |
| 沙箱端到端 | 清理 30/30 → 运行 `restore-*.ps1` → 30/30 回原位、隔离区清空、新文件保留 |
| zip 解压即用 | 解压到新目录独立运行自检通过 |

细节见 `reports/gui-tool-validation-20261109.txt`（本地生成，未入库）。

## 已知限制

1. 只在 Windows 11 + PowerShell 5.1 上验证过；Windows 10 理论可用但未实测。
2. 目标机首次运行可能被 SmartScreen / 杀软拦一次（未签名脚本），README.txt 里写了处理方式。
3. 「以管理员身份重新打开」的 UAC 交互没有自动化测试覆盖（只验证了控件状态逻辑）。
4. 隔离区放在空间最大的非系统盘；空间不足时会拒绝执行，需要在设置里改 `-QuarantineRoot`。

## 免责声明

按现状提供（AS IS）。清理的是"被认为可以重新生成的临时文件"，但任何清理都有风险：
请先用「① 扫描」确认清单，重要软件出问题时立刻用「还原上次清理」撤销。
