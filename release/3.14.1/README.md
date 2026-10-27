# ZCode ModKit — 3.14.1 适配版本留存

本目录是 2026-10-27 留存的 **ZCode 3.14.1 专用**脚本快照，对应仓库根目录 `54fe62b` 提交时的脚本状态。此后仓库根目录将升级适配 ZCode 最新版本，本目录保持冻结，不再随主目录演进。

## 用途

- ZCode 升级到新版后，如需回退到 3.14.1 版本，或新版本补丁尚未适配完成，可用本目录中的脚本继续在 3.14.1 上使用。
- 新版本补丁脚本出现 `unknown asar state` / `unknown zcode.cjs state` 时（ZCode 版本变化的版本保护），可参照本目录中 3.14.1 的签名与原文片段，定位新版本对应函数。

## 使用说明

- 使用方式见 `README-3.14.1-snapshot.md`（根目录 README.md 在 3.14.1 时期的完整快照，未做改动）。
- 所有脚本均通过 `$PSScriptRoot` / `%~dp0` 自定位，`zcode-toolbox.bat` 会以自身所在目录调用子脚本，因此**整个目录可独立复制到任意位置使用**，不需要依赖仓库根目录的文件。
- `images/`、`wallpapers/` 资源目录已包含在本目录中。
- `fonts/` 目录（约 297MB 字体安装包）未被任何脚本引用，仅作字体分发素材，未复制进本目录；如需可用根目录 `fonts/`。

## 脚本清单（与 3.14.1 时期根目录一致）

| 入口 | 功能 | 适用版本标记 |
|---|---|---|
| `patch-zcode-font.bat` / `.ps1` | UI 字体补丁 | 3.14.1 |
| `patch-zcode-title.bat` / `.ps1` | 会话标题修复（v3，多版本签名表） | 3.12.3 / 3.14.1 |
| `patch-zcode-title-lastturn.bat` / `.ps1` | 标题修复+持续重提炼（v7） | 3.14.1 |
| `patch-zcode-wallpaper.bat` / `.ps1` | 壁纸补丁 | 3.14.1（CSS `styles-C8Nayk5k.css`） |
| `patch-zcode-wallpaper-gear.bat` / `.ps1` | 挡位壁纸 | 3.14.1（CSS `styles-C8Nayk5k.css`） |
| `patch-zcode-updates.bat` / `.ps1` | 禁用更新检测 | 3.14.1 |
| `patch-zcode-timezone.bat` / `.ps1` | 上海时区修复 | 版本无关 |
| `patch-zcode-usage.bat` / `.ps1` | 保留用量历史（取消 30 天清理） | 正则适配，跨版本兼容 |
| `zcode-toolbox.bat` / `.ps1` | 统一菜单（7 补丁 + 7 还原） | — |

每个补丁均有对应的 `restore-zcode-*.bat` / `.ps1` 还原脚本。

## 重要提示

- 备份文件（`*-backup`）与 `*-backup.sha256` 副档**不在本目录**：备份记录的是各机器安装目录内的实际文件，与机器相关，脚本会在首次运行时以当时的目标文件重建备份基线。仓库内仅留有 3 个哈希副档模板（`app.asar.font-backup.sha256` 等）。
- 3.14.1 及更早版本的已知回归与修复细节见本目录 `README-3.14.1-snapshot.md` 对应章节。
