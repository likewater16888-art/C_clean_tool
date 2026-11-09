# Cline Agent Skills 使用说明（本机已装 win11-storage-governance）

> 这份文档就是"以后怎么用 / 怎么加新 skill"的速查表。文件位置：`D:\VS&Cline\C_clean\SKILL-使用说明.md`

---

## 一、已经装好了什么

| 项目 | 值 |
|---|---|
| Skill 名称 | `win11-storage-governance` |
| 安装位置（全局，所有项目可用） | `C:\Users\deepvision\.cline\skills\win11-storage-governance\` |
| 触发命令 | `/win11-storage-governance` |
| 中文触发词（写进 description） | C盘满了 / C盘清理 / C盘空间不足 / 整理系统盘 / 回收C盘空间 / 磁盘爆满 |
| 依赖 | 无。纯 Markdown + PowerShell；**不需要 Codex、不需要 Python、不需要装任何东西** |

目录内容：

```
C:\Users\deepvision\.cline\skills\win11-storage-governance\
├── SKILL.md                      ← 入口（frontmatter 里的 description 决定何时自动触发）
├── agents\openai.yaml            ← 给 OpenAI/Codex 用的元数据，Cline 可忽略
├── references\
│   ├── safety-model.md           ← 风险分级：哪些能删、哪些只能官方工具、哪些碰不得
│   ├── runbook.md                ← 七阶段流程：定范围→观测→分类→清理→迁移→自动化→验证
│   └── device-profile-template.md ← 换机器时套用的设备档案模板
└── scripts\
    ├── Invoke-CDriveAudit.ps1    ← 只读审计（本人新增）
    └── Invoke-SafeClean.ps1      ← 白名单清理，默认 dry-run（本人新增）
```

**渐进加载机制**：平时只有 `SKILL.md` 的 frontmatter（约 500 字节）参与匹配；真正触发后才读正文；`references/*.md` 里的内容只有被正文点名时才读。所以装再多 skill 也不会一次性吃满上下文。

---

## 二、怎么调用它（3 种触发方式 + 复制即用话术）

### 1. 斜杠命令（最稳，100% 生效）

在 Cline 输入框里打 `/`，会弹出命令列表，里面能看到 skill 名字，选中即可：

```
/win11-storage-governance
```

### 2. 自然语言（靠 description 自动匹配）

直接说人话，命中 description 里的关键词就会加载：

- "C盘又满了，帮我看看哪儿占地方"
- "C盘只剩 13G，整理一下系统盘"
- "帮我做个 Win11 存储治理方案"
- "把开发缓存迁到 D 盘"

### 3. 消息里点名

```
用 win11-storage-governance 这个 skill 给我做一次 C 盘审计
```

### 4. 复制即用的四条话术（本机已实测）

| 想干的事 | 直接在 Cline 输入框里发这句 |
|---|---|
| 只看不动 | `/win11-storage-governance 先跑一次只读审计，Top 25` |
| 看"如果清理会动哪些文件" | `用 win11-storage-governance 跑 dry-run：7 天以上的临时文件` |
| 真清理（搬进隔离区，不是删除） | `用 win11-storage-governance 执行清理：7 天以上，先告诉我隔离区在哪` |
| 把开发缓存迁到 D 盘 | `用 win11-storage-governance 把 npm/pip/NuGet 缓存迁到 D:\DevCaches` |

不想让 AI 参与、想自己手跑也可以（参数名与上面的话术一一对应，`reports\` 默认落在**当前目录**下）：

```powershell
$S = "$env:USERPROFILE\.cline\skills\win11-storage-governance\scripts"

# 1) 只读审计（不改任何东西）
powershell -NoProfile -ExecutionPolicy Bypass -File "$S\Invoke-CDriveAudit.ps1" -Top 25 -AppDataDetail

# 2) 计划：列出"如果执行会搬走什么"，仍然不动文件
powershell -NoProfile -ExecutionPolicy Bypass -File "$S\Invoke-SafeClean.ps1" -OlderThanDays 7

# 3) 真执行：搬进隔离区（默认保留 14 天，-KeepDays 可改）
powershell -NoProfile -ExecutionPolicy Bypass -File "$S\Invoke-SafeClean.ps1" -OlderThanDays 7 -Execute

# 4) 连浏览器 / 着色器缓存一起算（默认**不含**，因为浏览器没关就搬不动）
powershell -NoProfile -ExecutionPolicy Bypass -File "$S\Invoke-SafeClean.ps1" -OlderThanDays 7 `
  -IncludeBrowserCache -IncludeShaderCache
```

长任务（`-Execute` 十几分钟、`-Deep` 审计几分钟）用工作区里的 `tools\Start-Detached.ps1` 起，
VS Code 终端断了任务也不会断：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\tools\Start-Detached.ps1" `
  -Script "$env:USERPROFILE\.cline\skills\win11-storage-governance\scripts\Invoke-SafeClean.ps1" `
  -ScriptArgs '-OlderThanDays 7 -Execute' `
  -WorkDir 'D:\VS&Cline\C_clean' `
  -Out '.\reports\clean.out.txt' -Err '.\reports\clean.err.txt'
```

常用参数一览（`Get-Help .\Invoke-SafeClean.ps1 -Full` 也有）：

| 脚本 | 参数 |
|---|---|
| `Invoke-CDriveAudit.ps1` | `-Top` `-OutDir` `-Deep` `-AppDataDetail` `-FullTopLevel` `-NoReport` `-MaxSecondsPerPath` |
| `Invoke-SafeClean.ps1` | `-OlderThanDays` `-Execute` `-QuarantineRoot` `-KeepDays` `-IncludeBrowserCache` `-IncludeShaderCache` `-Scanner` `-MaxScanSecondsPerRoot` `-LogDir` |

> 找不到 skill 的话：点输入框上方（模型选择器左侧）的**天秤/工具图标** → Skills 菜单，确认它是启用状态。

---

## 三、第一次用怎么走（推荐顺序）

**第 1 步：只读审计**（不改任何东西）

```
/win11-storage-governance 先跑一次只读审计，我要看 C 盘占用大头
```

Cline 会执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\deepvision\.cline\skills\win11-storage-governance\scripts\Invoke-CDriveAudit.ps1" -Top 25
```

报告落在 `.\reports\audit-<时间戳>.md/.csv`，每个路径都带风险分级：
`safe-clean` / `official-tool` / `migrate-configure` / `investigate` / `do-not-touch`。

想更细（AppData 拆到子目录，通常最能找出大头）：

```
加 -AppDataDetail 再跑一次
```

两种模式的区别（默认是快模式，本机实测约 26 秒）：

| 模式 | 跳过的慢目录 | 用途 |
|---|---|---|
| 默认（快） | WinSxS、Windows Installer、WindowsApps、Packages、整个 LocalAppData / Roaming、浏览器 profile 根、各类包缓存 | 日常看"能清的大头"，报告里会写 `Not measured (slow trees, use -Deep)` |
| `-Deep` | 不跳过，全部测量 | 需要知道 WinSxS / AppData 总量时用，多个几分钟 |

不管哪种模式，单路径枚举都有时间预算（默认 45 秒，`-MaxSecondsPerPath` 可调），
超预算的路径会明确标成"未测完"，不会给出假数字。

**第 2 步：看 dry-run 计划**（仍然不动文件）

```powershell
...\Invoke-SafeClean.ps1 -OlderThanDays 7
```

它会列出"如果执行，哪些文件会被移走、共多少 GB"，并打印需要你自己跑的管理员命令（DISM、powercfg 等）。

扫描器说明（`-Scanner`，默认 `Auto`）：

| 场景 | 实际使用的实现 | 本机实测耗时 |
|---|---|---|
| 默认 dry-run | `robocopy /L /MINAGE` 只列不改 | 5 个根约 40 秒（`%TEMP%` 11 GB 约 20 秒） |
| `-Execute` | 逐文件 PowerShell 遍历（要精确路径 + 日志） | 扫描 `%TEMP%` 约 2.3 分钟；搬运 6.7 万个 / 7 GB 约 20 分钟（跨盘复制 + 杀软实时扫描，约 140 个文件/秒） |

`-MaxScanSecondsPerRoot` 默认 120 秒（`-Execute` 时 900 秒），超时的根会被标成 `TRUNCATED`，
意思是"报出来的数字只是下限"。实测本机 `%TEMP%` 有 20,699 个目录 / 79,720 个文件，
PowerShell 纯遍历就要 123 秒，所以默认 dry-run 才改用 robocopy。

**第 3 步：逐项批准后才真动手**

```powershell
...\Invoke-SafeClean.ps1 -OlderThanDays 7 -Execute
```

`-Execute` 不是删除，而是**移动到隔离区**，目录结构为 `<隔离根>\<时间戳>\<盘符>\<原始相对路径>`（隔离根默认选空闲最多、且至少 5 GB 的固定盘，避免往快满的 C 盘搬），同时生成：

- `reports\clean-<时间戳>.json`：逐文件操作日志（成功 / 失败 / 被黑名单拒绝，含字节数）
- `reports\restore-<时间戳>.ps1`：一键还原脚本，内部用 `robocopy /MOVE` 把整棵隔离树搬回原处，六万多个文件也只是一份十几行的小脚本

确认应用都正常、过了 `-KeepDays`（默认 14 天）再手动删隔离区。想让隔离区固定放在某盘，加 `-QuarantineRoot 'E:\Quarantine'`。

> 回收站属于 `safe-clean`，但**必须先问用户**才动。本机 2026-11-09 经同意后用
> `Clear-RecycleBin -DriveLetter C -Force` 清空，C 盘 +2.64 GB。

**第 4 步：迁移而非删除**（真正让 C 盘长期不再爆）

让 skill 按 `runbook.md` 的阶段 5 出配置清单。本机已经按这个思路做过一遍（2026-11-09 实测）：

| 目标 | 做法（改配置，**不是** junction） | 迁移量 | 怎么校验 |
|---|---|---|---|
| npm | `npm config set cache D:\DevCaches\npm-cache --location=user` | 0.19 GB | `npm cache verify` → `Cache verified and compressed (D:\DevCaches\npm-cache\_cacache)` |
| pip | 用户环境变量 `PIP_CACHE_DIR=D:\DevCaches\pip` | 0.08 GB | `pip cache dir` → `d:\devcaches\pip` |
| NuGet 全局包 | 用户环境变量 `NUGET_PACKAGES=D:\DevCaches\nuget-packages` | 0.30 GB | `dotnet nuget locals global-packages --list` → 新路径 |
| NuGet http 缓存 | 纯缓存，直接清 `%LOCALAPPDATA%\NuGet\v3-cache` | 0.09 GB | NuGet 下次自动重建 |
| Codex 旧运行时 | `.cache\codex-runtimes\*.previous-*` 两个残留 → 隔离到 `D:\Quarantine\codex-runtimes-<时间戳>` | 0.22 GB | 保留期结束再删；restore 命令写在该报告里 |
| winget 便携包根 | **没动**：存的是已安装便携应用，改根目录会让它们失联 | – | 归 `investigate` |
| VS Code 扩展 | **没动**：只能 junction 迁移，与 `safety-model.md` 冲突 | – | 归 `investigate` |

合计 C 盘再省 **0.88 GB**（回收站 2.64 GB 另算）。搬迁一律用 `robocopy /E /MOVE`，
搬完立刻用工具自己打印的路径校验，不信配置猜测。

回滚（每条都可逆，旧值都记在 `reports\migrate-dev-caches.txt` 里）：

```powershell
# npm
npm config set cache "$env:LOCALAPPDATA\npm-cache" --location=user
robocopy "D:\DevCaches\npm-cache" "$env:LOCALAPPDATA\npm-cache" /E /MOVE

# pip / NuGet（删掉用户环境变量即回到默认路径）
[Environment]::SetEnvironmentVariable('PIP_CACHE_DIR', $null, 'User')
[Environment]::SetEnvironmentVariable('NUGET_PACKAGES', $null, 'User')
robocopy "D:\DevCaches\pip" "$env:LOCALAPPDATA\pip\Cache" /E /MOVE
robocopy "D:\DevCaches\nuget-packages" "$env:USERPROFILE\.nuget\packages" /E /MOVE
```

本机这些目录都不存在，所以没做，换机器时可以照抄对应开关：
`pnpm`（`pnpm config set store-dir`）、Yarn（`YARN_CACHE_FOLDER`）、uv（`UV_CACHE_DIR`）、
Playwright（`PLAYWRIGHT_BROWSERS_PATH`）、Puppeteer（`PUPPETEER_CACHE_DIR`）、
HuggingFace（`HF_HOME`）、Cargo（`CARGO_HOME`）、Gradle（`GRADLE_USER_HOME`）、
Maven（`-Dmaven.repo.local`）、Scoop（`SCOOP`）。
注意**不要**迁 `%LOCALAPPDATA%\Programs`（按用户安装的程序本体）——那是重装/改安装路径的事，不是改配置。

---

## 四、后续怎么加新 skill

### 方式 A：从 GitHub / 别人给的 zip 装（推荐流程）

1. **看目录结构**：必须是 `<skill-name>\SKILL.md`（有的仓库是 `skills\<name>\SKILL.md`，只复制 `<name>` 那一层）。
2. **检查 4 条**（Cline 的硬性要求）：
   - 目录名 == frontmatter 里的 `name`
   - `description` ≤ 1024 字符，且**写清楚"什么时候该用"**（这是自动触发的唯一依据）
   - 正文里引用其它文件用**相对路径**（`references/xx.md`、`scripts/xx.ps1`）
   - 有副作用的东西放 `scripts\` 里，并且默认 dry-run
3. **复制到全局目录**：

```powershell
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.cline\skills" | Out-Null
Copy-Item -Recurse -Force ".\仓库\skills\某skill" "$env:USERPROFILE\.cline\skills\某skill"
```

4. **重启 skill 列表**：在 Cline 的 Skills 菜单里刷新/开关一次，或重开 VS Code 窗口。
5. **验证**：输入 `/` 看是否出现该名字。

> 只给某个项目用 → 放 `<项目>\.cline\skills\<name>\`（工作区级，优先级更高，可提交进 git 给团队共享）。

### 方式 B：让 Cline 自己写一个新的

直接说："用 skill-creator 的规范，帮我建一个 skill，名字 xxx，用来 xxx"。
Cline 的 Skills 面板里也有 **New skill…** 按钮，会生成标准骨架。

也可以直接用我写的脚手架：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\VS&Cline\C_clean\tools\New-ClineSkill.ps1" -Name my-skill -Description "..." 
```

它会生成 `SKILL.md` + `references\` + `scripts\` 四件套，并把 4 条检查项写进注释。

### 方式 C：把重复的对话"沉淀"成 skill

凡是发现自己第三次让 AI 做同一件事（同一套步骤、同一批命令），就抽成 skill：
正文只写**判断规则 + 步骤 + 安全边界**，把具体命令丢到 `scripts\`，把长表格丢到 `references\`。

---

## 五、Skill / Rules / Workflows 别混用

| 类型 | 何时加载 | 适合放什么 |
|---|---|---|
| **Skill**（`.cline\skills\`） | 按需、触发时才加载 | 领域流程、专业方法论、带脚本的成套能力 |
| **Rules**（`.clinerules\`） | 常驻、每轮都带上 | 项目代码规范、目录约定、必须始终遵守的约束 |
| **Workflow**（`.cline\workflows\`） | 斜杠命令触发 | 固定步骤的重复任务清单 |

判断口诀：**"每次都该记得"→ Rules；"偶尔要用、用了就要专业"→ Skill；"步骤固定的操作"→ Workflow。**

---

## 六、常见问题

- **打了 `/` 没看到 skill**：目录层级不对（多套了一层），或 frontmatter 的 `name` 与目录名不一致。
- **自然语言不触发**：`description` 里缺中文关键词。中文提问时英文 description 命中率低，**务必补中文触发词**（本 skill 已经补了）。
- **skill 生效了但"不干活"**：skill 只注入知识和流程，真正执行靠 AI 调工具。所以必须有 `scripts\*.ps1`，并在正文里写明命令。
- **会不会很吃 token**：只有被触发时才加载正文，`references` 是被点名才读。单个 skill 正文控制在 5k 字符内比较稳妥。
- **能删吗**：直接删整个目录即可，无注册表、无残留。建议先备份到 D 盘。
- **要管理员权限吗**：本 skill 的审计脚本不需要；`Invoke-SafeClean.ps1 -Execute` 清 `C:\Windows\Temp` 需要。DISM / `powercfg /h off` 必须管理员，脚本只打印命令、不代跑。
- **路径里有 `&`（比如 `D:\VS&Cline`）**：PowerShell 里必须用单引号包住，例如 `-LogDir 'D:\VS&Cline\C_clean\reports'`；交给 `cmd /c` 时还要再加一层引号，否则 `&` 会被当成命令分隔符，命令被截断。
- **长时间运行的命令被"打断"**：VS Code 终端里每个前台命令都绑定在当前终端上，终端一关或下一次命令进来，前一个就被杀。所以跑审计/清理这类几十秒以上的脚本，要用**脱离终端**的启动方式（`Start-Process` 仍属于终端 job，不可靠）：

```powershell
$cmd = 'cmd.exe /c powershell -NoProfile -ExecutionPolicy Bypass -File "C:\...\Invoke-SafeClean.ps1" -OlderThanDays 7 > "out.txt" 2> "err.txt"'
Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd }
```

  然后用另一个命令轮询 `out.txt` 的大小/内容。用 `Win32_Process.Create` 起的进程不属于当前终端，关掉终端也不会被杀。

  上面这套已经封装好了，直接用仓库里的 `tools\Start-Detached.ps1`：

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File "D:\VS&Cline\C_clean\tools\Start-Detached.ps1" `
      -Script "C:\...\Invoke-SafeClean.ps1" -Out "reports\execute.txt" -Err "reports\execute.err.txt" `
      -ScriptArgs "-OlderThanDays 7 -Execute"`
  ```

- **`-Execute` 跑完怎么验**：用 `tools\Test-CleanResult.ps1`，它读 `reports\clean-*.json`，
  输出候选数 / 搬走数 / 失败数 / 失败原因分类 / 隔离区实际文件数与字节数（和 JSON 对账）/
  还原脚本行数与语法检查 / 当前 C 盘空闲：

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File "D:\VS&Cline\C_clean\tools\Test-CleanResult.ps1"
  ```

  本机 2026-11-09 实测（`-OlderThanDays 7 -Execute`）：候选 66,756 → 搬走 **66,731（5.37 GB）** /
  失败 **25（1.68 GB）**；隔离区落盘 66,730 个 / 5.37 GB，JSON 记录的字节数与落盘**完全相同**；
  还原脚本 12 行、语法零错误；C 盘空闲 **13.55 → 18.95 GB**。
  失败的 25 个全是 `%TEMP%` 里 OMRON/Sysmac 安装器留下的 MSI 暂存目录（ACL 为 SYSTEM 级），
  属于"安装器缓存"，按安全模型本来就不该手工搬 —— 要清就用「设置 → 应用」修复/卸载或磁盘清理。

- **回滚**：`reports\restore-<时间戳>.ps1` 一行 `robocopy /MOVE` 把整个隔离区原路搬回：

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File "reports\restore-20261109-230231.ps1"
  ```

---

## 七、安全边界（这套 skill 的硬约束）

1. 审计永远只读，先出数字再谈清理。
2. 清理永远先 dry-run，`-Execute` 只"移入隔离区"，不直接删。
3. 黑名单硬拦截：`C:\Windows\Installer`、`WinSxS`、`WindowsApps`、`System32`、`ProgramData` 根、`AppData\Roaming` 根、`Documents`/`Desktop`/`Downloads`、`.ssh`、`.git` —— 命中即拒绝。
4. 系统目录只给官方工具指引（DISM / 设置 / Disk Cleanup），不给手删命令。
5. 聊天记录、浏览器 profile 根目录、数据库类一律 `investigate`，不迁移、不 junction。
6. 不做整体 junction / 符号链接式搬家。

## 八、图形版 CDriveGuard（发给不懂电脑的人直接用）

### 1. 它是什么

同一套引擎（`engine\Invoke-SafeClean.ps1`）外面套了一个**单页 WinForms 界面**，给完全不懂命令行的人用：

```
C 盘可用 22.45 GB / 146.48 GB   [进度条]        权限：普通用户（可「以管理员身份重新打开」）
勾选类别：☑ 用户临时文件 66,428 个 5.21 GB   ☑ Windows 临时 1,193 个 0.14 GB …
[① 扫描（不改动文件）] [② 开始清理 5.35 GB] [看清理明细] [还原上次清理] [打开隔离文件夹]
```

- 只做两件事：**只读扫描**、**移动到隔离区**（永不删除），30 天内可一键还原。
- 勾选粒度是**类别**（对应引擎的 `-OnlyRoots`），不是逐文件——小白不会点错，也不会漏看。
- PowerShell 5.1 内置 WinForms，**零依赖、免安装**；`Start.cmd` 用 `-ExecutionPolicy Bypass`，不改系统策略。
- 不写注册表、不装服务、不建计划任务、**不联网**（这几点是给杀软/朋友的信任交代）。

### 2. 产物在哪、怎么重新打包

| 路径 | 说明 |
|---|---|
| `tools\Build-Dist.ps1` | 把 skill 里的引擎**复制快照**进 `dist\CDriveGuard\engine\`，统一转成 UTF-8 BOM，写 `VERSION.txt` + `SHA256.txt`，`-Zip` 直接出压缩包 |
| `dist\CDriveGuard\` | 可分发的文件夹：`Start.cmd` / `CDriveGuard.ps1` / `README.txt` / `SHA256.txt` / `VERSION.txt` / `engine\` |
| `dist\CDriveGuard-v1.1.0.zip` | 发给朋友的成品（解压即用） |

```powershell
# 改完引擎或界面后，一条命令重出包（含校验和）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Build-Dist.ps1 -Zip
```

**规则：`dist\` 里的文件一律不手改**，它是 skill 引擎某一版的快照；改逻辑只改 skill，然后重跑构建，避免两份逻辑漂移。

### 3. 为 GUI 给引擎加的 3 个向后兼容参数

旧命令（`-OlderThanDays 7` / `-Execute`）**输出与行为完全不变**，新增的全部是可选开关：

| 参数 | 作用 |
|---|---|
| `-PlanJson <path>` | dry-run 时额外写 `plan.json`（汇总 + 每根目录统计）和同名 `.csv`（逐文件清单），GUI 用它填表。自动改用 PowerShell 扫描（只有它知道逐文件路径） |
| `-ProgressFile <path>` | `-Execute` 时每 25 个文件追加一行 JSONL（`done/total/moved/failed/moved_bytes/current`），末尾多一行 `status=finished`，GUI 用它驱动进度条 |
| `-OnlyRoots <labels>` | 只处理指定类别的白名单根目录；`labels` 一个都不匹配时**回退到全部根目录并打警告**（防止"看起来什么都没清"） |

### 4. 顺带修掉的一个引擎缺陷（重要）

原来的隔离区落盘逻辑把整条相对路径当成**一个文件名**（`GetInvalidFileNameChars()` 里包含 `\`，被替换成 `_`）：

```
修复前：<隔离区>\20261109-230231\D\Users_xxx_AppData_Local_Temp_a.tmp   ← 层级被压平
修复后：<隔离区>\20261109-230231\D\Users\xxx\AppData\Local\Temp\a.tmp   ← 层级保留
```

后果：`restore-*.ps1` 用 `robocopy /MOVE` 把 `<隔离区>\<盘符>` 搬回 `<盘符>\`，层级被压平时文件会落到**磁盘根目录**而不是原位，"还原"等于失效；同名文件还会互相覆盖。

现在只清洗**单个目录段内**的非法字符，分隔符保留 → 沙箱实测"清理 30 个 → 还原 30 个全部回原位、隔离区清空"。

> 注意：`D:\Quarantine\20261109-230231`（本次会话早期那次真实清理）是**旧逻辑**产生的，它的还原脚本会把文件丢到根目录。里面是临时文件，按原计划**满 30 天直接删除**即可，不要用它做还原演练。

### 5. 已实测的验收项（本机，PowerShell 5.1）

| 项 | 结果 |
|---|---|
| 语法（AST） | `CDriveGuard.ps1` / `Build-Dist.ps1` / `Invoke-SafeClean.ps1` 全部 `errors=0` |
| 编码 | 所有 `.ps1` / `.txt` 带 UTF-8 BOM；`Start.cmd` **不带 BOM**（cmd 会把 BOM 当字符打印） |
| 窗口自检（真实 Show + Shown 事件） | 24 个控件、C 盘状态条、权限标签、日志均正常，退出码 0 |
| 开屏使用说明页强制 10 秒 | 启动即弹出模态页；倒计时中 `Close()` 被拒并提示"还需等待 N 秒"；归零后按钮可点；点后主窗口 `scanEnabled=True`、日志记"已阅读使用说明" |
| 真实点按「① 扫描」 | 子进程 → `plan.json` → 表格出现 `User TEMP / 30 个 / 465 KB`，按钮变成「② 开始清理 465 KB」 |
| 真实点按「② 开始清理」 | 进度 0→100、状态"清理完成：释放 465 KB"、还原按钮自动启用、隔离区 30 个文件、层级完整 |
| 引擎沙箱端到端（清理→隔离→还原） | 30/30 搬走、fresh 文件保留、还原后 30/30 回原位、隔离区清空 |
| zip 解压即用 | 解压到新目录后独立运行自检通过，退出码 0 |

### 6. 发给朋友时的三步交代（README 已写）

1. 右键 zip → 属性 → 勾"解除锁定" → 再解压（否则可能双击没反应）；
2. 双击 `Start.cmd`，点「① 扫描」等 1~3 分钟；
3. 看表格、取消不想清的类别、点「② 开始清理」。
万一某软件不正常：点「还原上次清理」。

### 7. 明确没做的事（别加回来）

- ❌ 定时自动清理、静默清理、后台常驻
- ❌ "一键清理全部且不给预览"
- ❌ 清系统目录 / WinSxS / 回收站
- ❌ ps2exe 打包 exe（会被杀软加壳误报）
- ❌ 自动上传日志或统计

### 8. 开屏使用说明页（v1.1.0 新增）

每次启动，主窗口后面一出现就弹出**模态**的「使用说明」页，**10 秒内关不掉**（点右上角 × /
Esc / Alt+F4 全被 `FormClosing` 拦下，并提示"还需等待 N 秒"），倒计时归零后按钮从灰色
「开始使用」变成可点的「我知道了，开始使用」，主窗口才开始接受操作。

- 为什么要"强制"：收工具的人不会读 README，但一定会看这个弹窗；10 秒刚好读完"只移动不删除 /
  三步用法 / 怎么还原 / 绝不碰什么"。
- 计时依靠 WinForms `Timer`（1 s）+ 脚本级 `$script:IntroLeft`，纯 GUI 侧逻辑，**不改引擎**。
- 自检不再"建了就算"：`-SmokeTest` 会把说明页也建出来，打印 `gate@N` / `gate@0` 两组状态
  （`left`、按钮是否可点、按钮文字、提示语），并检查正文含"只做两件事 / 还原上次清理 / 不是删除"。
- 真实交互验证（探针注入，`-IntroSeconds 3` 压缩等待）：1 s 时尝试 `Close()` → 弹窗仍在、
  提示变"还需等待 3 秒"；倒计时归零 → 按钮可点；点按钮 → 说明页关闭、主窗口
  `scanEnabled=True / gridEnabled=True`、日志出现"已阅读使用说明"。
- 参数 `-IntroSeconds <n>` 标了 `[Parameter(DontShow)]`，只用于自动化（`0` 关闭开屏），
  不写进给用户的 README。

