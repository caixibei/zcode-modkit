# zcode-modkit

![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D4?logo=windows11&logoColor=white)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)
![GitHub top language](https://img.shields.io/github/languages/top/caixibei/zcode-modkit)

![GitHub stars](https://img.shields.io/github/stars/caixibei/zcode-modkit?style=social)
![GitHub forks](https://img.shields.io/github/forks/caixibei/zcode-modkit?style=social)
![GitHub watchers](https://img.shields.io/github/watchers/caixibei/zcode-modkit?style=social)
![GitHub contributors](https://img.shields.io/github/contributors/caixibei/zcode-modkit)

![GitHub issues](https://img.shields.io/github/issues/caixibei/zcode-modkit)
![GitHub closed issues](https://img.shields.io/github/issues-closed/caixibei/zcode-modkit?color=success)
![GitHub PRs](https://img.shields.io/github/issues-pr/caixibei/zcode-modkit)
![GitHub closed PRs](https://img.shields.io/github/issues-pr-closed/caixibei/zcode-modkit?color=success)

![GitHub last commit](https://img.shields.io/github/last-commit/caixibei/zcode-modkit)
![GitHub commit activity](https://img.shields.io/github/commit-activity/m/caixibei/zcode-modkit)
![GitHub repo size](https://img.shields.io/github/repo-size/caixibei/zcode-modkit)
![GitHub code size](https://img.shields.io/github/languages/code-size/caixibei/zcode-modkit)
![GitHub file count](https://img.shields.io/github/directory-file-count/caixibei/zcode-modkit)

ZCode 桌面客户端补丁工具包，包含七个独立补丁与一个统一工具箱入口：

1. **UI 字体美化补丁**（`patch-zcode-font`）——替换界面字体栈
2. **会话标题自动生成修复补丁**（`patch-zcode-title-lastturn`）——在原有修复上改为“两阶段摘要”，标题统一为 `（修复/新增/设计/排查/分析/其他）任务总结`，并内置每 N 个成功轮次持续重提炼；同时规避 provider 丢弃 system、回答首行被误存为标题的问题。3.14.1 推荐，3.14.3 起官方已修复
3. **桌面壁纸补丁**（`patch-zcode-wallpaper`）——把窗口根背景换成自选照片（半透明主题色纱罩保证可读性）
4. **更新检查禁用补丁**（`patch-zcode-updates`）——彻底关闭自动更新检测，侧边栏不再出现绿色「更新」徽标；想升级时自行下载安装包
5. **定时任务时区修复补丁**（`patch-zcode-timezone`）——让 ZCode 的 cron 定时任务按上海时间（UTC+8）触发，修复系统级 `TZ=UTC` 环境变量造成的 8 小时偏差
6. **用量历史保留补丁**（`patch-zcode-usage`）——停用用量统计的 30 天滚动清理，「累计 Token 数」跨月持续累加不再缩水
7. **挡位壁纸补丁**（`patch-zcode-wallpaper-gear`）——壁纸跟随输入框「思考级别」自动切换，纯 CSS 实现，切档即时换图（「关闭思考」不配图，M1–M4 覆盖其余全部档位，详见第七章映射表）

**统一工具箱**（`zcode-toolbox.bat`）：把 7 个补丁 + 7 个还原做成一张任务清单，支持一次输入多个任务编号（如 `1 3` 或 `1,3,4`）按序执行；ZCode 退出检查只做一次，全部完成后统一重启一次。四个 asar 补丁（字体 / 壁纸 / 挡位壁纸 / 禁更新）全部基于**当前 asar 原位操作**，打/还原/换图互不影响（详见「互不影响保证」）；两个 `zcode.cjs` 补丁（标题 v6+refresh / 用量保留）同样基于**当前文件原位操作**，互不覆盖；时区补丁不改动 ZCode 程序文件，只调整用户环境变量（见「五、定时任务时区修复补丁」）。

---

## 〇、工具箱统一入口

1. 完全退出 ZCode（托盘图标右键 → Quit）
2. 双击 `zcode-toolbox.bat`
3. 在菜单里输入任务编号（可多选，空格或逗号分隔）：
   - `[1]` 字体补丁 `[2]` 标题修复+持续重提炼 `[3]` 壁纸补丁 `[4]` 禁用更新检查 `[5]` 时区修复 `[6]` 用量历史保留 `[7]` 挡位壁纸
   - `[9]` 还原字体 `[10]` 还原标题+持续重提炼 `[11]` 还原壁纸 `[12]` 恢复更新检查 `[13]` 还原时区 `[14]` 还原用量清理 `[15]` 还原挡位壁纸
4. 确认后按序执行；某任务失败立即停止后续任务（已完成的任务保持其状态），修好后再跑一次即可
5. 全部成功后自动重启一次 ZCode

单独的 `patch-*-*.bat` / `restore-*-*.bat` 依然可用，行为与工具箱内对应任务一致。

任务编号清单（1–7 为打补丁，9–15 为对应还原；原 [8]/[16] 已整合到 [2]/[10]）：

- 打补丁：`[1]` 字体 `[2]` 标题修复+持续重提炼 `[3]` 壁纸 `[4]` 禁用更新检查 `[5]` 时区修复 `[6]` 用量历史保留 `[7]` 挡位壁纸
- 还原：`[9]` 字体 `[10]` 标题+持续重提炼 `[11]` 壁纸 `[12]` 更新检查 `[13]` 时区 `[14]` 用量清理 `[15]` 挡位壁纸

### 互不影响保证

三个 `app.asar` 补丁（字体 / 壁纸 / 禁更新）修改的文件互不重叠（字体与壁纸在渲染层 CSS，禁更新在 `out/main/index.js`），且**所有打补丁、换图和还原操作都基于当前 asar 原位进行**：

- 字体补丁：在当前 asar 上等长替换字体栈（不从备份重算全文）；
- 壁纸补丁：在当前 asar 上「剥旧块 → 加新块」后重打包（不从备份重建整包）；还原时优先原位剥块；
- 禁更新补丁：在当前 asar 上 25 字节等长替换；还原时优先原位反替换。

挡位壁纸补丁（第七章）与桌面壁纸补丁同为 CSS 追加块，但使用**独立标记**（`ZCODE-GWP-*` vs `ZCODE-WALLPAPER-*`）与**独立备份**（`app.asar.gwp-backup` vs `app.asar.wallpaper-backup`），各自的打补丁 / 换图 / 还原只识别和剥除自己的块，两个壁纸补丁可共存。

两个 `zcode.cjs` 补丁（标题 v6+refresh / 用量保留）修改同一文件的不同字节区域，全部基于**当前文件原位操作**：标题补丁会改变文件长度（`zcode.cjs` 为独立文件，长度可变且安全），用量保留为等长替换；还原优先在当前文件上反替换补丁片段（备份整文件覆盖仅作兜底，且仅当当前文件无法识别补丁痕迹时使用）。因此任意顺序叠加、重打或逐一还原，其余补丁始终保持完好。

各补丁的 `*-backup` 备份仅作为「出厂状态兜底还原」使用（当且仅当当前文件找不到可识别的补丁痕迹时才会启用，届时会明确提示）。备份与目标文件必须是同一 ZCode 构建版本，长度不一致时脚本会拒绝复用并提示删除重建，避免把 A 版本的备份覆盖到 B 版本的安装上。

**重跑安全（2026-10-15 修复）**：此前版本的壁纸 / 挡位壁纸补丁在「已有备份的重跑」场景（删过备份后换图、还原后再打等）存在 asar 双重建缺陷——同一对象上连续两次重打包会从错误偏移读数据，损坏 CSS 之后的所有文件（含启动入口 package.json），表现为 ZCode 静默无法启动、只能重装。现已根治：重建函数纯函数化（内部克隆 header，不再原地改写），且写盘前从磁盘重读源 asar、逐字节抽检 package.json 与 `out/main/index.js` 两个哨兵文件，任何错位立即中止且原 asar 不动。**若您在 2026-10-15 之前遇到过重跑后无法启动，不必重装——用本工具包重跑一次该补丁（或其还原）即可修复。**

---

## 一、UI 字体美化补丁

通过**等长字节替换**修改 ZCode 安装目录下 `resources/app.asar` 中的 Tailwind 根字体变量（`--font-sans` / `--font-mono`），两个变量使用各自独立的优先级栈（首个已安装的字体族命中）：

- **`--font-sans`（界面正文）**：Fragment Mono（英文）→ SFMono-Regular（macOS 专属，Windows 上为惰性声明）→ HarmonyOS Sans SC → PingFang SC（苹方，汉字）→ Source Han Sans SC（思源黑体）→ Noto Sans SC
- **`--font-mono`（代码 / 等宽）**：AnthropicMono Medium（英文）→ Fragment Mono → SFMono-Regular → HarmonyOS Sans SC → Noto Sans SC → PingFang SC（汉字由它们渲染）→ JetBrains Mono

无需重装客户端，可随时一键还原。

> 注：等长替换窗口有限，补丁后的字体栈不再包含 `Segoe UI Emoji` / `Noto Color Emoji`；emoji 在 Chromium 渲染管线中仍会通过系统回退链正常显示，不受影响。

## 环境要求

- Windows 10 / 11（仅需系统自带 PowerShell，无第三方依赖）
- ZCode 桌面版（Electron 应用，安装目录含 `resources\app.asar`）

## 使用方法

### 字体补丁

**打补丁**

1. 完全退出 ZCode（托盘图标右键 → Quit；点窗口 X 可能只是最小化到托盘）
2. 双击 `patch-zcode-font.bat`
3. 脚本自动定位安装目录（运行中的进程 → 注册表卸载项 → 常见安装路径），全部失败时按提示手动输入包含 `app.asar` 的 `resources` 目录
4. 补丁完成后自动重启 ZCode

**还原**

1. 完全退出 ZCode
2. 双击 `restore-zcode-font.bat`，从备份恢复原始 `app.asar` 并重启 ZCode

### 标题自动生成修复补丁（3.12.3 / 3.14.x）

**适用症状**：ZCode 3.12.3 起，侧边栏新会话不再自动提炼中文短标题，标题停留在首条消息的原始截断文本（如 `NODE_ENV=development VUE_APP_BUILD_TYPE=…`），只能手动重命名。

**打补丁**

1. 完全退出 ZCode（托盘图标右键 → Quit）
2. 双击 `patch-zcode-title.bat`
3. 脚本自动定位安装目录，定位失败时手动输入包含 `zcode.cjs` 的 `resources\glm` 目录
4. 补丁完成后自动重启 ZCode；此后新建会话首轮对话完成后，侧边栏标题会自动替换为 LLM 提炼的短标题

**还原**

1. 完全退出 ZCode
2. 双击 `restore-zcode-title.bat`，从备份恢复原始 `zcode.cjs` 并重启 ZCode

> 三个 UI 补丁相互独立，可单独打/单独还原；同时使用时顺序不限。`restore-zcode-font.bat` 只还原字体、不影响标题补丁和壁纸补丁，壁纸补丁还原时也会保留字体补丁。更新禁用补丁改的是主进程文件，与三者互不干扰。

## 工作原理与安全机制（字体 / 标题补丁）

- **等长替换**：新字体栈比原字符串短，用空格填充到等长后写入。asar 索引头部记录的偏移量与尺寸全部保持不变，文件大小不变，无需重打包。
- **自动备份**：打补丁前把当前 `app.asar` 原样备份到工具包目录（`app.asar.font-backup`），并写入 SHA-256 指纹（`app.asar.font-backup.sha256`）。若已有备份与本机当前 asar 不一致（工具包拷贝自其他机器、或 ZCode 已升级），会先静默重建备份再打补丁，保证还原点始终是"本机打补丁前的原始状态"。
- **幂等**：重复运行自动识别当前状态——未打补丁则打，已打补丁则直接跳过并重启 ZCode，旧版本补丁自动升级。
- **版本保护**：asar 中找不到已知的原始 / 已补丁字符串（说明 ZCode 版本已变化）时拒绝写入，避免破坏性替换。
- **运行检查**：ZCode 未退出（asar 被占用）时拒绝执行；还原前校验备份文件与指纹一致，不一致时拒绝覆盖。

---

## 二、会话标题自动生成修复补丁

### 背景

ZCode 3.12.3（2026-09-17 发布）起，新建交互会话不再触发标题自动提炼。排查确认：

- 旧版（3.12.2 及更早）中，首轮对话完成后 agent 运行时会发起一次 `querySource=session_title` 的独立模型请求，把用户首条消息提炼成 3–7 词的短标题写回会话；
- 3.12.3 起运行时（`resources\glm\zcode.cjs`）中该请求彻底消失，且日志无任何 `session_title_generation.*` 事件（连 skipped 都没有）；
- 功能代码（标题提示词、模型调用、写回逻辑）全部保留，未被移除。

### 根因

`zcode.cjs` 中两个标题生成资格判断函数（内部名 `shouldAttemptSessionTitleGeneration` / `shouldAttemptGoalSummaryTitleGeneration`；混淆名随版本变化：3.12.3 为 `FYi`/`NYi`，3.14.1 为 `Pba`/`Tba`）的短路条件为：

```js
... || e.config.titleGeneration?.enabled===!1 || !e.config.titleGeneration || ...
```

其中 `!e.config.titleGeneration` 要求配置对象必须存在（真值）。桌面端 host 创建会话时传入的是空对象 `{}`，经上游运行时配置合并后可能变为 `undefined`，于是该条件恒为真，函数在发出任何日志前就返回 `false`——标题生成被静默跳过。**经逐字节比对确认 3.12.3 至 3.14.1 均保留同一回归 bug**（官方更新日志未声明此变更）。

### 补丁原理（v3，共两处修改）

**修改 1：恢复标题生成触发**。将两个函数中的 `||!e.config.titleGeneration` 条件删除（其余门槛全部保留：显式关闭、子会话、非交互任务、已尝试过、首条输入过短等仍正常拦截），删除出的 27 字节用等长的 `/*...*/` 空注释填充。补丁后的函数体经 Node 实测——配置 `undefined` / `{}` 时放行生成，`{enabled:!1}`（显式关闭）、短输入、非交互任务仍正确拦截；自动化/定时任务仍传 `titleGenerationEnabled:!1`，显式关闭语义不受影响。

**修改 2：强化标题语言规则**。标题提示词中的语言规则原文是弱约束 `- Use the user's primary language.`，实测部分模型（如 minimax-m3）不遵守，对全中文输入会输出英文标题。补丁将其强化为 `- MUST use the user's primary language.`（+5 字节）。`zcode.cjs` 是独立文件（不在 asar 归档内，无偏移量/长度头依赖），文件小幅变长安全。

**多版本适配（v3 新增）**：函数名随版本被混淆器改名，v3 起脚本内置**按版本的特征签名表**，自动识别本机 `zcode.cjs` 对应哪个 ZCode 版本并选用对应原文片段：

| ZCode 版本 | 资格函数混淆名 | 支持状态 |
| --- | --- | --- |
| 3.14.x | `Pba` / `Tba` | ✅ 已适配 |
| 3.12.3 | `FYi` / `NYi` | ✅ 已适配 |
| 其他版本 | 未知 | ❌ 拒绝执行（安全保护） |

> 旧版补丁用户说明：直接重新运行 `patch-zcode-title.bat` 即可原地升级，脚本自动识别 v1/v2 状态（含无备份时从补丁态反向重建干净基线），无需先还原。ZCode 升级覆盖 `zcode.cjs` 后重跑脚本即可（见「升级注意」）。

### 安全机制

与字体补丁一致：

- 打补丁前把当前 `zcode.cjs` 备份到工具包目录（`zcode.cjs.title-backup`）并写入 SHA-256 指纹（`zcode.cjs.title-backup.sha256`）；
- 备份始终指向"本机打补丁前的原始状态"，已有有效备份不会被覆盖；
- 幂等：重复运行自动识别状态并跳过；
- 版本保护：`zcode.cjs` 中找不到任何已知版本的特征字符串（说明 ZCode 版本已变化）时拒绝修改；
- 运行检查：ZCode 未退出时拒绝执行。

### 生效验证

补丁并重启后，新建一个会话发一条消息，等首轮对话完成后：

- 侧边栏标题自动变为提炼后的短标题（会话列表 `title_source` 变为 `generated`）；
- 日志 `~/.zcode/cli/log/zcode-*.jsonl` 中出现 `"querySource":"session_title"` 的 `model.request.completed` 事件；
- **中文输入应产出中文标题**。若仍出现英文标题：先确认补丁已应用（检查 `zcode.cjs` 中语言规则是否为 `- MUST use the user's primary language.`），再检查该会话所用模型——个别模型对 MUST 指令遵从度仍低，属模型能力问题而非补丁失效。

### 升级注意

ZCode 版本升级会覆盖 `resources\glm\zcode.cjs`，标题补丁随之失效并出现 `unknown zcode.cjs state` 报错（这是版本保护在起作用，不是故障）。处理方式：

1. 退出 ZCode 后重新运行 `patch-zcode-title.bat`；若脚本签名表已收录新版，会自动识别并重打；
2. 若签名表未收录（报错里会打印各版本特征的命中计数），需人工定位新版 `zcode.cjs` 中的新混淆函数名（搜索 `shouldAttemptSessionTitleGeneration` 调试标注附近的 `function` 定义），把新原文追加进两个脚本的 `$versions` 表；
3. 若官方已修复此 bug 则无需重打，直接删除旧备份即可。

### v5：按“会话整体工作内容 + 动作前缀”生成标题（3.14.1）

旧标题补丁只在 `turnNumber===0` 触发：首轮被取消、或标题请求被 provider headers 刷新延迟后，标题会永久停在首句截断。v5 在保留原有资格修复、`MUST` 语言规则和 v4 触发逻辑的基础上，改为按会话整体工作内容提炼：

- 标题输入改为**会话内全部用户消息的压缩摘要**：短会话（用户文本 ≤1400 字）直接使用首条 700 字 + 最多 6 条近期消息各 220 字；长会话先把最多 4000 字的用户消息（首 1500 字 + 中间 1000 字 + 尾 1500 字）交给一次总结模型调用，压缩成不超过 100 字的工作摘要，再用摘要生成标题；
- 这是**两阶段摘要**：第一次调用只做「整体工作摘要」，第二次调用才输出标题；长会话会多一次模型调用，延迟和成本相应增加；总结调用失败时自动回退到压缩后的用户原文，不阻断标题生成；
- 标题提示词要求输出 `（修复）/（分析）/（排查）/（审查）/（方案）/（实现）/（重构）/（优化）/（配置）/（迁移）/（文档）` + 主题，并明确要求总结会话整体工作，而不是某一句话；
- 禁止逐字摘抄原文、禁止问候语和称呼、禁止把助手回复当作标题素材；
- 标题写回前做一次清洗：去掉开头的「主人/助手」称呼，把半角 `(修复)` 归一化为全角 `（修复）`；
- 失败/取消仍会在下一次成功轮次重试，`titleSource=custom` 永不覆盖。

示例：`（修复）外包单价金额修改不生效`、`（分析）委托单分组与导出不一致`、`（排查）加急审批提示任务不存在`、`（审查）样品退回页面权限与布局`。

使用方式：

- 打补丁：`patch-zcode-title-lastturn.bat`，或工具箱 `[2]`；支持从“干净文件”“旧标题补丁已打”“v4/v4-refresh/v5 已打”状态升级；
- 还原：`restore-zcode-title-lastturn.bat`，或工具箱 `[10]`；优先原位反替换，会连同内置 refresh 一起还原，并保留用量历史等其他补丁；当前不提供“只关闭 refresh”的独立入口，需要改 N 时先完整还原再重打。
- 工具箱 `[2]/[10]` 调用的是 v6 脚本（文件名保留 `lastturn`），旧的 `patch-zcode-title.bat` 仅作为兼容入口保留。

注意：v6 默认每 5 个成功轮次持续重提炼；可用 `-RefreshTurns 1` 改为每轮。当前签名仅适配 ZCode 3.14.1，其他版本会被拒绝。

### v6：固定六类任务类型 + 严格解析（3.14.1）

v6 在 v5 两阶段摘要基础上修正标题格式与脏数据问题：

- 标题格式统一为 `（任务类型）任务总结`；任务类型固定为 `修复 / 新增 / 设计 / 排查 / 分析 / 其他`，禁止 `优化/实现/审查/方案/配置/迁移/文档` 等旧类型，优化/性能类归入 `其他`；
- 标题规则同时写入 `user` 消息：当前 provider 对标题调用会丢弃 `system`，模型只看到用户原文时会把它当普通提问回答，导致标题变成回答首句；
- 标题解析器拒绝长句、Markdown、多行、空标题和非六类输出；`（优化）` 归一化为 `（其他）`，`（问题排查）` 归一化为 `（排查）`；
- 修正总体摘要阶段 `String(sm)` 可能得到 `[object Object]` 的隐患；
- 失败/取消仍按 v5 逻辑重试，`titleSource=custom` 永不覆盖。

使用方式：`patch-zcode-title-lastturn.bat`（工具箱 `[2]`）。默认 `RefreshTurns=5`，可运行 `patch-zcode-title-lastturn.bat -RefreshTurns 1` 改为每轮重提炼；v5 旧文件重跑脚本会自动升级到 v6+refresh，还原用 `restore-zcode-title-lastturn.bat`（工具箱 `[10]`）。示例：`（排查）生产环境页面登录报错`、`（新增）Excel导入与部门汇总`、`（设计）订单详情页双布局交互方案`。

### 标题持续重提炼（已整合进 v6，3.14.1）

该能力已内置到 `patch-zcode-title-lastturn.ps1` 和工具箱 `[2]`，不再单独占用菜单项。它把“只生成一次”改成“每 N 个成功轮次重新提炼”，适合话题会持续变化的长会话：

- 从 `Pba` 移除一次性 `sessionTitleGenerationAttempted` 限制；
- `Wwn` 用 `sessionTitleGenerationTurn` 做冷却：每 `RefreshTurns` 个成功轮次才允许再次生成；
- 仍然使用 v6 的“会话整体用户消息”作为标题输入；
- `Oba` 在新标题与当前标题完全相同时跳过写回，减少标题抖动；
- `titleSource=custom` 永不覆盖；失败/取消仍在下一成功轮次立即重试；
- `RefreshTurns` 默认 5；`-RefreshTurns 1` 表示每个成功轮次都重提炼。

使用方式：

- 打补丁：直接运行 `patch-zcode-title-lastturn.bat -RefreshTurns 5`，或工具箱 `[2]`；
- 还原：`restore-zcode-title-lastturn.bat`，或工具箱 `[10]`，会连同 refresh 一起还原；
- 修改 N：先运行 `restore-zcode-title-lastturn.bat` 完整还原，再用新的 `-RefreshTurns` 重新打；脚本运行中不会直接改已有 refresh 的 N。

注意：这是“每 N 轮重提炼”，不是语义级话题变化检测；如果希望“话题真正变化时才改标题”，需要额外的语义比较或模型判断，当前变体不包含。当前签名仅适配 ZCode 3.14.1。

---

## 三、桌面壁纸补丁

把 ZCode 桌面端窗口根背景（深/浅色主题下的纯色底）替换为一张照片：照片经等比缩放（长边 1920px）+ JPEG 压缩后以 data URI 形式内嵌进渲染层 CSS，整窗可见；聊天内容区叠加一层跟随主题色的半透明「纱」，纱越薄照片越清晰，越厚文字越易读。

**内置壁纸**：`wallpapers/` 目录自带 8 张（五路财神 / 仙逆佳人 / 水墨武士 / 女仆 / 白衬衫 / 动漫阳台 / 动感少女 / 水墨日出），也可在菜单选 `[0]` 输入任意本机图片路径（支持中文路径）。

**打补丁 / 换图**

1. 完全退出 ZCode（托盘图标右键 → Quit）
2. 双击 `patch-zcode-wallpaper.bat`（或 `zcode-toolbox.bat` 选 `[3]`）
3. 菜单选壁纸编号 + 输入纱浓度（0–85，`0` = 纯照片，越大纱越实、照片越淡，默认 60）
4. 完成后自动重启 ZCode

**随时换图**：直接再次运行 `patch-zcode-wallpaper.bat`，选另一张图或调整纱浓度即可，无需先还原。换图/还原基于当前 asar 原位操作，不会影响字体补丁和更新禁用补丁。

**还原**

1. 完全退出 ZCode
2. 双击 `restore-zcode-wallpaper.bat`（或工具箱选 `[11]`）：优先从当前 asar 原位剥除壁纸块（字体/更新补丁保留）；当前 asar 无可识别壁纸块时才回退备份 verbatim 还原

**工作原理与安全机制**

- **asar 重打包**（与字体补丁的等长替换不同，照片无法塞进等长窗口）：脚本自带 PowerShell 版 asar 读写器，解包 → 追加壁纸 CSS 块 → 重算全部文件偏移 → 重新打包。除目标 CSS 追加一段带 `ZCODE-WALLPAPER-PATCH` 标记的规则外，其余 27000+ 个文件逐字节保持不变（已实测比对）。产物已通过官方 `@electron/asar` 工具读取验证；本机 ZCode.exe 未启用 asar 完整性熔丝（EnableEmbeddedAsarIntegrityValidation），重打包可被正常加载。
- **自动备份**：首次打补丁时对当前 `app.asar` 做字节级备份（`app.asar.wallpaper-backup` + SHA-256 指纹）；若当前 asar 已含壁纸补丁而备份缺失，用「剥除补丁块」方式重建干净基线。还原即 verbatim 恢复备份。
- **幂等与状态识别**：重复运行自动识别已打补丁状态并支持换图；检测到损坏的补丁块时拒绝执行并提示先还原。
- **重跑自检（2026-10-15 新增）**：重打包写盘前从磁盘重读源 asar，逐字节抽检 `package.json`（Electron 启动入口）与 `out/main/index.js` 两个哨兵文件，与源不一致立即中止且原 asar 不动——杜绝重跑 / 还原场景下 asar 重建错位导致 ZCode 无法启动的问题（详见「互不影响保证」章「重跑安全」）。
- **与字体补丁共存**：字体栈在 CSS 补丁块之前，互不干扰；打壁纸补丁前打过字体补丁，还原壁纸后字体补丁仍然保留。
- **版本保护**：`app.asar` 内找不到渲染层 CSS（按 3.14.1 的路径 `out/renderer/assets/styles-C8Nayk5k.css` 定位）时拒绝执行。

> 升级注意：ZCode 升级会覆盖 `app.asar`（CSS 文件名随版本变化），壁纸补丁随之失效——先运行还原，再等工具包适配新版后重打。

---

## 四、更新检查禁用补丁

ZCode 桌面端启动时会检查更新并每小时轮询一次，检测到新版本后侧边栏左上角常驻一枚绿色「更新」徽标（点开就是提示重启安装）。本补丁让应用走其自带的「product flavor 禁用更新」分支：不再发起任何更新检测请求，徽标永远不会出现；是否升级、何时升级完全由用户手动决定（自行下载新安装包覆盖安装即可）。

**打补丁**

1. 完全退出 ZCode（托盘图标右键 → Quit）
2. 双击 `patch-zcode-updates.bat`
3. 补丁完成后自动重启 ZCode

**还原**

1. 完全退出 ZCode
2. 双击 `restore-zcode-updates.bat`，从备份恢复原始 `app.asar` 并重启 ZCode，更新检测恢复如初

**工作原理与安全机制**

- **单一入口，等长替换**：更新逻辑只在主进程包 `out/main/index.js` 初始化（`initAutoUpdater`，全包唯一调用点；host/worker/preload 均无更新逻辑）。初始化函数的第一个分支就是应用自带的禁用开关（`enabled===!1` 时清掉轮询定时器直接返回），补丁把唯一调用点的 `enabled:Ge==="production"`（`Ge` 是构建期常量 `"production"`）等长替换为 `enabled:!1/*…*/`（25 字节 → 25 字节，全文件仅 17 个字节变化），asar 头部偏移与文件大小不变，无需重打包。
- **禁用后的行为**（静态分析确认）：启动检查与每小时轮询均不注册；`UpdateStateChanged` / `UpdateReady` 不再广播；侧边栏绿色徽标由渲染层订阅这些状态渲染，状态恒为 idle，徽标不会出现；菜单「检查更新」点击后返回禁用态（渲染层弹「开发环境不检查更新」提示，不发起网络请求）。设置里的 `autoDownloadAndInstallUpdates` 开关只控制自动下载，与本补丁无关、互不影响。
- **自动备份与幂等**：与字体补丁同机制——首打时字节级备份当前 `app.asar`（`app.asar.updates-backup` + SHA-256 指纹）；备份缺失时从补丁态反向重建；重复运行自动识别已打补丁状态；写入前后自检（仅允许 17 字节差异、tmp 文件通过 asar 解析校验后才替换）。
- **与其他补丁共存**：字体/壁纸补丁只改渲染层 CSS，本补丁只改主进程 `index.js`，互不干扰。
- **版本保护**：`app.asar` 内找不到目标片段（说明 ZCode 版本已变化）时拒绝执行。

> 升级注意：ZCode 升级会覆盖 `app.asar`，更新检测会随新版恢复——在新版 `app.asar` 上重跑 `patch-zcode-updates.bat` 即可（脚本会以新版 asar 作为新的备份基线；若签名因版本变化无法匹配，脚本会拒绝执行，等待工具包适配）。

---

## 五、定时任务时区修复补丁

让 ZCode 的定时任务（cron 自动化）按**上海时间（UTC+8）**解释和触发。补丁不改动 ZCode 程序文件，也不需要提前退出 ZCode。

### 问题背景

- 本机 Windows 系统时区是正确的「中国标准时间」，但**系统级环境变量 `TZ=UTC`** 把它覆盖了；
- ZCode 基于 Electron/Node.js，解析本地时区时**优先读 `TZ` 环境变量**，于是整个 ZCode 进程（包括 cron 定时任务的「本地时区」）被当成 UTC，定时任务比上海时间提前 8 小时触发；
- 验证方法：ZCode 会话内 `echo $TZ` 输出 `UTC`；`node -e "console.log(Intl.DateTimeFormat().resolvedOptions().timeZone)"` 输出 `UTC` 而非 `Asia/Shanghai`。

### 使用方法

1. 双击 `patch-zcode-timezone.bat`（或 `zcode-toolbox.bat` 选 `[5]`）
2. 脚本依次：诊断三层时区来源 → 记录还原点（`zcode-timezone-state.json`）→ 设置**用户级**环境变量 `TZ=Asia/Shanghai`（用户级变量会遮蔽系统级 `TZ=UTC`，无需管理员权限，系统级原值保持不动）
3. 设置完成后**退出并重启 ZCode 才生效**：脚本检测到 ZCode 正在运行时会提示手动重启（托盘图标右键 → Quit 后再启动）；ZCode 未运行时自动拉起

### 生效范围与说明

- 对当前用户**新启动的进程**生效；打补丁之前已经开着的窗口（正在运行的 ZCode、旧终端）保持旧时区，重开后恢复；
- ZCode 重启后，新创建的定时任务按上海时间解释；
- Git Bash 的 `date` 命令不识别 `Asia/Shanghai`（MSYS 运行时无 zoneinfo），仍显示 GMT——这只是 Git Bash 的显示行为，与 ZCode 定时任务无关；
- 重跑此补丁是幂等的（已打过则不重复写）。

### 还原

双击 `restore-zcode-timezone.bat`（或工具箱选 `[13]`）：按还原点恢复用户级 `TZ` 的旧值（原本未设置则删除该变量），系统级 `TZ=UTC` 重新生效。还原后重启 ZCode。

---

## 六、用量历史保留补丁

停用 ZCode 的用量统计 30 天滚动清理，让设置页「累计 Token 数」跨月持续累加、不再随高峰日出窗而缩水。需要提前退出 ZCode。

### 问题背景

- 设置 → 使用统计里的「累计 Token 数」并非终身累计：agent 运行时只保留**最近 30 天**的用量明细，每写入一条新的用量记录（`model_usage` / `turn_usage` / `tool_usage`），都会顺带执行 `DELETE ... WHERE started_at < 当前时间 - 30 天`；
- 于是每当用量高峰日滑出 30 天窗口，累计值就往下掉——例如 9 月中旬每天约 1 亿 token 的高峰出窗后，累计从 20 多亿回落到 14.9 亿；
- 单次请求的 token 口径为「输入 + 输出（含缓存读取与缓存写入）」，缓存命中全额计入，这是数字庞大的主因，与本补丁无关。

### 补丁原理

修改安装目录 `resources\glm\zcode.cjs` 中保留期常量（minified 变量名随版本变化，脚本用正则捕获）：

```text
mos=30,hos=mos*24*60*60*1e3   →   mos=30,hos=9e15/*xxxxxxxx*/
```

等长 27 字节原位替换（16 字节差异），把保留期从 30 天改为约 28.5 万年——清理语句仍在执行，但永远匹配不到任何数据。`hos` 仅被清理函数引用，无其他行为变化；显式传入 `beforeTime` 的调用方（当前不存在）仍可主动清理。

### 使用方法与安全机制

1. 完全退出 ZCode（托盘图标右键 → Quit）
2. 双击 `patch-zcode-usage.bat`（或工具箱选 `[6]`）
3. 脚本依次：定位安装目录 → 识别当前补丁状态 → 备份干净原始文件（写入目标文件同目录，指纹存 `zcode.cjs.usage-backup.sha256`）→ 等长替换 → 自动重启
4. 幂等可重跑；版本更新导致目标片段变化时拒绝修改（unknown state），不会盲写

**注意**：打补丁之前已被清理掉的用量数据无法找回，累计值从打补丁当天起重新只增不减。

### 还原

双击 `restore-zcode-usage.bat`（或工具箱选 `[14]`）：优先在当前文件上原位反替换（保留同文件的其他补丁，如标题修复），必要时回退到干净备份整文件还原。还原后重启 ZCode，30 天滚动清理恢复。

---

## 七、挡位壁纸补丁（思考级别联动）

壁纸跟随输入框工具栏的「思考级别」下拉（低 / 高 / 最高）自动切换：每一档配一张图，切换档位的瞬间背景即时更换。纯 CSS 实现——ZCode 渲染层有一个隐藏状态节点实时携带当前档位属性（`data-thought="..."`），补丁向渲染层 CSS 追加一段基于 `:has()` 选择器的规则块，React 更新属性时浏览器自动重新匹配，**不注入任何 JavaScript**。

**档位与图片映射**：图片放 `images/` 目录，命名 `M1`–`M4`（jpg / jpeg / png / bmp 均可），脚本按现有文件自动选择映射方案。**「关闭思考」不配图**——关闭时背景回归默认（打过桌面壁纸补丁则显示其壁纸）；其余所有思考档位都有对应图片：

| 文件 | 4 张图（M1–M4） | 3 张图（M1–M3） |
| --- | --- | --- |
| `M1.*` | 挡 1：极低 / 低（minimal、low） | 挡 1：极低 / 低（minimal、low） |
| `M2.*` | 挡 2：中（medium，及通用开启 on 等） | 挡 2：中 / 高（medium、high，及通用开启） |
| `M3.*` | 挡 3：高 / 极高（high、xhigh） | 挡 3：最高（xhigh、max、ultra） |
| `M4.*` | 挡 4：最高 / 极致（max、ultra） | — |

- **每一档都换图、无兜底图**：脚本只生成各挡位的 `:has()` 覆盖规则，不再设基础背景图——任何未映射的档位值（关闭、未知新值）都自然回落到默认背景或静态壁纸，四张图各自只服务自己的挡位；
- 「通用开启」（on / enable / enabled / true）是部分模型的"开启思考但不分级"取值，归入挡 2；
- 张数 3–4 张任意；超过 4 张只取前 4 张（ZCode 档位值共 off / on / minimal / low / medium / high / xhigh / max / ultra 九种归一值）；
- 换图只需替换同名文件后重跑补丁（脚本幂等，可反复运行重设）。

**打补丁 / 换图**

1. 完全退出 ZCode（托盘图标右键 → Quit）
2. 双击 `patch-zcode-wallpaper-gear.bat`（或 `zcode-toolbox.bat` 选 `[7]`）
3. 确认菜单列出的档位 → 文件映射，输入纱浓度（0–85，默认 60，含义与桌面壁纸补丁相同）
4. 完成后自动重启 ZCode；切换思考级别即可看到背景切换

**还原**

1. 完全退出 ZCode
2. 双击 `restore-zcode-wallpaper-gear.bat`（或工具箱选 `[15]`）：从当前 asar 原位剥除挡位壁纸块，字体 / 静态壁纸 / 禁更新等其它补丁全部保留

**工作原理与安全机制**

- **asar 重打包**：与桌面壁纸补丁同技术——解包 → 剥旧块 → 追加新 CSS 块 → 重算偏移 → 重打包，其余 27000+ 文件逐字节不变（已实测比对，产物通过官方 `@electron/asar` 读取验证，并在隔离副本上完成真实启动验证）。
- **独立标记与备份**：CSS 块用 `ZCODE-GWP-GEAR-WALLPAPER-BEGIN/END` 标记，备份文件为 `app.asar.gwp-backup` + SHA-256 指纹，与桌面壁纸补丁（`ZCODE-WALLPAPER-*` / `app.asar.wallpaper-backup`）完全隔离，可共存、可分别还原。
- **幂等与状态识别**：重复运行自动换图换浓度；损坏块拒绝执行并提示先还原。
- **重跑自检（2026-10-15 新增）**：重打包写盘前从磁盘重读源 asar，逐字节抽检 `package.json`（Electron 启动入口）与 `out/main/index.js` 两个哨兵文件，与源不一致立即中止且原 asar 不动——杜绝重跑 / 还原场景下 asar 重建错位导致 ZCode 无法启动的问题（详见「互不影响保证」章「重跑安全」）。
- **版本保护**：找不到渲染层 CSS（`out/renderer/assets/styles-C8Nayk5k.css`）时拒绝执行。

> 升级注意：与桌面壁纸补丁相同——ZCode 升级覆盖 `app.asar` 后失效，先还原再等工具包适配后重打。

---

## 字体说明

`fonts/` 目录附带全部字体资源压缩包，需解压后安装：

| 压缩包 | 内容 | 对应补丁栈字体族 |
| --- | --- | --- |
| `Anthropic Sans.zip` | AnthropicSans 静态字体 14 款（Light ~ Black，含斜体） | `AnthropicSans`（sans 首位，英文） |
| `Anthropic Mono.zip` | AnthropicMono 静态字体 7 字重 + AnthropicMonoVariable 可变字体 | `AnthropicMono`（mono 首位，英文）、`Anthropic Mono Variable` |
| `Anthropic Serif.zip` | AnthropicSerif 静态字体 14 款（Light ~ Black，含斜体） | 备用资源，不在补丁栈内 |
| `LXGWWenKai.zip` | 霞鹜文楷 Regular | `LXGW WenKai`（sans 汉字首选） |
| `PingFang SC.zip` | 苹方 SC（ttf / woff2，Thin ~ Semibold） | `PingFang SC` |
| `HarmonyOS-Sans.zip` | HarmonyOS Sans 全家族（含 SC / TC / Condensed / Naskh Arabic） | `HarmonyOS Sans SC` |
| `SourceHanSansSC.zip` | 思源黑体 SC 全字重（ExtraLight ~ Heavy） | `Source Han Sans SC` |
| `MiSans.zip` | MiSans 全字重 + 可变字体 | `MiSans` |
| `JetBrainsMono-2.304.zip` | JetBrains Mono v2.304（ttf / woff2 / 可变字体） | `JetBrains Mono`（mono 栈） |

补丁写入的字体族名（按命中优先级）：

- `--font-sans`：`Fragment Mono` → `SFMono-Regular` → `HarmonyOS Sans SC` → `PingFang SC` → `Source Han Sans SC` → `Noto Sans SC`
- `--font-mono`：`AnthropicMono Medium` → `Fragment Mono` → `SFMono-Regular` → `HarmonyOS Sans SC` → `Noto Sans SC` → `PingFang SC` → `JetBrains Mono`

CSS 按**字体族名**精确匹配，系统里需安装同名族名的字体文件才会命中，例如：

- AnthropicMono Medium（族名 `AnthropicMono Medium`，即 AnthropicMono 静态字重的传统族名形式，nameID 1 实测带字重）
- Fragment Mono（族名 `Fragment Mono`，仅 Regular / Italic 两个字重）
- `SFMono-Regular` 为 macOS 系统字体，Windows 上未安装也不影响——CSS 对缺失族名自动跳过下一级，声明无害
- HarmonyOS Sans SC（族名 `HarmonyOS Sans SC`）
- 苹方（族名 `PingFang SC`）
- JetBrains Mono（族名 `JetBrains Mono`）

> 注意：`fonts/` 中静态字体安装后注册的族名可能与补丁引用的族名不同（如 `Anthropic Mono Web`、`思源黑体`），不会直接命中补丁字体栈。`fonts/` 目录用于留存与分发字体资源；如需实际命中补丁效果，请安装族名匹配的字体版本。

## 文件清单

| 文件 | 说明 |
| --- | --- |
| `patch-zcode-font.bat` / `patch-zcode-font.ps1` | 字体补丁入口（bat 双击后调用同名 ps1） |
| `restore-zcode-font.bat` / `restore-zcode-font.ps1` | 字体还原入口 |
| `patch-zcode-title.bat` / `patch-zcode-title.ps1` | 标题自动生成修复补丁入口（3.12.3 专用） |
| `restore-zcode-title.bat` / `restore-zcode-title.ps1` | 标题补丁还原入口 |
| `patch-zcode-title-lastturn.bat` / `.ps1` | 标题修复+持续重提炼入口（3.14.1，v6；`-RefreshTurns` 默认 5） |
| `restore-zcode-title-lastturn.bat` / `.ps1` | 标题修复+持续重提炼还原入口 |
| `patch-zcode-wallpaper.bat` / `patch-zcode-wallpaper.ps1` | 桌面壁纸补丁入口（含选图菜单与纱浓度调节） |
| `restore-zcode-wallpaper.bat` / `restore-zcode-wallpaper.ps1` | 壁纸还原入口 |
| `patch-zcode-updates.bat` / `patch-zcode-updates.ps1` | 更新检查禁用补丁入口 |
| `restore-zcode-updates.bat` / `restore-zcode-updates.ps1` | 更新检测还原入口 |
| `patch-zcode-timezone.bat` / `patch-zcode-timezone.ps1` | 定时任务时区修复入口（设置用户级 `TZ=Asia/Shanghai`，不改 ZCode 程序文件） |
| `restore-zcode-timezone.bat` / `restore-zcode-timezone.ps1` | 时区设置还原入口 |
| `patch-zcode-usage.bat` / `patch-zcode-usage.ps1` | 用量历史保留补丁入口（停用 30 天滚动清理，`zcode.cjs` 等长替换） |
| `restore-zcode-usage.bat` / `restore-zcode-usage.ps1` | 用量清理还原入口（优先原位反替换，兼容同文件其他补丁） |
| `patch-zcode-wallpaper-gear.bat` / `patch-zcode-wallpaper-gear.ps1` | 挡位壁纸补丁入口（思考级别联动换图，含纱浓度调节） |
| `restore-zcode-wallpaper-gear.bat` / `restore-zcode-wallpaper-gear.ps1` | 挡位壁纸还原入口（只剥自己的 CSS 块，其它补丁保留） |
| `images/M1.*` … `images/M4.*` | 挡位壁纸的档位图片（M1 最低挡 … M4 最高挡；「关闭思考」不配图），见第七章映射表 |
| `zcode-timezone-state.json` | 时区补丁的还原点（记录打补丁前的用户级 TZ 值；还原时自动清理） |
| `zcode-toolbox.bat` / `zcode-toolbox.ps1` | 统一工具箱入口（任务清单多选，一次退出检查，最后统一重启） |
| `wallpapers/` | 桌面壁纸补丁的内置壁纸（8 张），可自行增删图片文件，菜单自动列出 |
| `fonts/*.zip` | 字体资源压缩包，需解压安装，见「字体说明」 |
| `app.asar.font-backup.sha256` / `zcode.cjs.title-backup.sha256` / `app.asar.wallpaper-backup.sha256` / `app.asar.updates-backup.sha256` | 备份 SHA-256 指纹 |
| `app.asar.gwp-backup.sha256` | 挡位壁纸补丁备份指纹（备份本体与其它 asar 备份一样不入库） |
| `zcode.cjs.usage-backup.sha256` | 用量补丁备份指纹（与备份同放目标文件目录） |
| `app.asar.font-backup` / `zcode.cjs.title-backup` / `app.asar.wallpaper-backup` / `app.asar.updates-backup` | 首次打补丁时在本机生成的原始文件备份（体积大，已被 `.gitignore` 排除，不入库） |
| `app.asar.gwp-backup` | 挡位壁纸补丁的原始文件备份（同上不入库，`.gitignore` 已排除） |
| `zcode.cjs.usage-backup` | 用量补丁的原始文件备份（生成在 ZCode 安装目录 `resources\glm\` 下，跟随目标文件，不入库） |

工具包可整体拷贝到任意目录使用，备份与指纹始终存放在工具包所在目录内。

## 常见问题

- **提示 ZCode is running**：从托盘完全退出 ZCode 后重试。
- **提示 unknown asar state / unknown zcode.cjs state**：ZCode 版本更新导致目标字符串变化，脚本拒绝修改。先运行对应的 `restore-*.bat` 还原，再等待工具包适配新版本。
- **ZCode 升级后字体变回默认**：升级覆盖了 `app.asar`，重新运行 `patch-zcode-font.bat` 即可；脚本会以新版 asar 作为新的备份基线。
- **ZCode 升级后标题又不生成了**：升级覆盖了 `resources\glm\zcode.cjs`，见「升级注意」。
- **ZCode 升级后壁纸消失了**：升级覆盖了 `app.asar` 且渲染层 CSS 文件名随版本变化，先运行 `restore-zcode-wallpaper.bat`（识别不了会拒绝执行），再等工具包适配新版后重打。
- **壁纸文字看不清**：重新运行 `patch-zcode-wallpaper.bat`，把纱浓度调高（如 70–85）。
- **挡位壁纸不随档位切换（所有档位都显示同一张图）**：确认用的是修正版脚本（2026-10-14 之前的版本选择器多了个空格，所有档位落到兜底图），重跑 `patch-zcode-wallpaper-gear.bat` 即可。
- **挡位壁纸某档不生效**：核对 `images/` 文件名与第七章映射表（四张图必须叫 M1–M4），改完文件后重跑 `patch-zcode-wallpaper-gear.bat`。
- **「关闭思考」也有壁纸 / 想让关闭时不显示图**：v2 映射（2026-10-15 起）已把关闭档排除——关闭时回归默认背景；若仍显示图，说明 asar 里是旧版映射块，重跑 `patch-zcode-wallpaper-gear.bat` 覆盖即可。
- **又出现绿色「更新」徽标了**：ZCode 升级覆盖了 `app.asar`，更新检测随新版恢复——运行 `zcode-toolbox.bat` 勾选需要的补丁（含 `[4]` 禁用更新）一次重打即可；ZCode 升级后所有 asar 补丁都需重打。
- **ZCode 启动时打印 `Most NODE_OPTIONs are not supported in packaged apps`**：本机系统环境变量里设置了 `NODE_OPTIONS`（常见为 `--max-old-space-size=8192`），打包版 Electron 不支持该变量，每次启动都会打印这条 ERROR（仅提示，不影响功能）。本工具包的全部补丁 / 还原脚本在启动 ZCode 前会自动清掉本进程继承的 `NODE_OPTIONS`，经脚本重启的 ZCode 不再出现该报错；**手动**双击 ZCode 图标启动时仍会看到——若想去掉，请在系统环境变量中自行删除 `NODE_OPTIONS`，或接受这条无害提示。
- **还原时提示 backup not found**：本机从未打过对应补丁（备份由补丁脚本生成），或备份文件已被删除。备份丢失时无法用本工具还原，需重新安装 ZCode。
- **定时任务还是按 UTC 触发**：时区补丁只对**补丁之后启动**的进程生效——先运行 `patch-zcode-timezone.bat`，再完全退出并重启 ZCode；仍不生效时在 PowerShell 里执行 `[Environment]::GetEnvironmentVariable('TZ','User')`，应输出 `Asia/Shanghai`。Git Bash 的 `date` 显示 GMT 属正常现象（MSYS 不识别 IANA 时区名），不代表补丁失效。
- **累计 Token 数还是越来越少**：用量保留补丁只对**补丁之后写入**的数据生效——先退出 ZCode，运行 `patch-zcode-usage.bat`（工具箱 `[6]`）再启动；打补丁前已被清理的历史无法找回。验证方法：PowerShell 在 `resources\glm\zcode.cjs` 中搜索 `hos=9e15`，能搜到即补丁在位；搜到 `mos*24*60*60*1e3` 则是未打或已还原状态。
- **提示 title fix already present / 上游已修复**：ZCode 3.14.3 起官方已修复标题自动生成（与本项目补丁字节同形），标题补丁自动跳过、还原脚本拒绝反修复，均属正常。
- **还原用量补丁时提示 unknown state**：目标文件的补丁片段与脚本签名不匹配（通常是 ZCode 版本更新），脚本拒绝盲写。确认后可删除目标目录中的 `zcode.cjs.usage-backup` 让脚本重建基线，或等工具包适配新版本。

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=caixibei/zcode-modkit&type=Date)](https://star-history.com/#caixibei/zcode-modkit&Date)
