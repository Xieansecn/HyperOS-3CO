# AGENT.md — 给 AI 协作代理的工作约定

本仓库是 **HyperOS-3CO**：一个 MIUI/HyperOS Joyose 云控定制的 KernelSU / Magisk / APatch 模块源码仓库。AI 代理在此仓库内工作前请先阅读本文件。

## 项目概览

模块运行在 Android（root）环境，用 POSIX sh 写系统脚本、写 Joyose / PowerKeeper 的 SQLite 云控数据库，并附带一个 KernelSU 管理器内加载的 WebUI（`webroot/`）。

| 路径 | 说明 |
|---|---|
| `module/` | 模块源码（刷入包内容） |
| `module/action.sh` | 交互菜单 + 命令行入口（WebUI/终端/自动化共用） |
| `module/customize.sh` | 刷入时主脚本 |
| `module/service.sh` | 开机脚本 |
| `module/scripts/` | 功能脚本（joyose_config / sync_battery_whitelist / powerkeeper_patch / refresh_follow_system / screen_off_freeze / restore_charging / backup_cloud_db / check_status / utils） |
| `module/webroot/` | KernelSU WebUI（index.html / style.css / app.js / ksu.js） |
| `module/functions/<device>/` | 各机型 Joyose 云控 JSON 配置 |
| `module/bin/sqlite3` | 内置 SQLite 二进制（勿替换为旧版） |
| `build_module.sh` | 打包脚本 → `HyperOS-3CO-<版本>(机型).zip` |
| `verify_module.sh` | 语法 / JSON / 权限 / zip 全量校验 |
| `db_inspect.py` | 云控数据库只读查看工具 |

## 常用命令

```sh
sh build_module.sh     # 从 module/ 打包 zip
sh verify_module.sh    # 全量校验（改完必须跑）
python3 db_inspect.py  # 查看云控库
```

## 硬性约定（违反会出问题）

1. **shell 一律 POSIX sh**（Android toybox，无 bash 特性）：`[ ]`、`$(...)`、`printf`；不要用 `[[ ]]`、数组、`local` 以外的非 POSIX 语法。
2. **webroot 前端为 ES5**、无构建、无网络依赖（CDN/网络字体/远程图标一律禁止），图标用内联 SVG。
3. **写数据库必须**：
   - 在脚本入口调用 `ensure_module_lock`（互斥锁，防并发写库）；**父脚本不得持锁再调用子脚本**（子脚本自锁，避免自锁死锁）。
   - SQL 经 `sqlite3_x` 执行（自带 busy_timeout 10s + `.bail on`）。
   - 写前调用 `backup_db` 备份（保留最近 5 份）。
   - 临时 SQL 文件名必须带 `.$$`（PID）后缀，用后删除。
4. **`module.prop` 元信息**：`id=HyperOS-3CO`、`name=HyperOS-3CO`、`author=Xieansecn & Deepseek Harness & CoolApk@苏疫杆菌`；不要随意改 id（影响运行时路径 `/data/adb/modules/HyperOS-3CO`）。
5. **版本号规则**：功能变更按 `YYYYMMDD` 递增（当前 260825），并同步 `module.prop`、`build_module.sh` / `verify_module.sh` 中的 zip 名、README 版本说明。
6. **锁路径**：`utils.sh` 已按模块 id 派生统一锁文件 `/data/adb/modules/.<模块id>.module.lock`，安装期（modules_update）与运行期（modules）共用，保证安装与旧实例互斥。
7. **toybox 兼容陷阱**：`flock` 在 toybox 上仅支持 `flock [-sxun] fd`（无 `-w`），统一用 `flock -n <fd>` + 轮询实现超时（见 `utils.sh::flock_wait`）；不要用 GNU 独有参数。

## WebUI 桥（window.ksu）

- `webroot/ksu.js` 是 `kernelsu` npm 包的最小自包含实现：`exec`（返回 Promise）、`spawn`（流式）、`toast`、`moduleInfo`。
- `moduleInfo()` 返回模块信息 **JSON 字符串**（含 `moduleDir` 字段），使用时需 `JSON.parse`。
- 页面以 root 权限执行命令：统一经 `action.sh <命令>` 驱动，**不要**在 WebUI 里直接拼系统命令。
- 新增功能需在 `action.sh` 加对应 CLI 命令，再在 `app.js` 里调用。

## 新增机型适配

1. 在 `module/functions/<device>/` 放置 `common_config.json` 与 `<版本>_<device>.json`（JSON 必须合法，verify 会校验）。
2. 在 `module/README.md` 的适配列表补充机型。
3. 白名单类列表（`game_list` / `support_app` / `background_freeze_whitelist`）会在写入时动态替换为设备全部第三方应用；`migt` / `frc_game_params` 等逐游戏调参列表必须保留，**不要**动态化。

## 变更流程

1. 修改代码 → 本地 `sh -n` 语法检查（所有 `.sh`）→ `node --check`（webroot JS）。
2. 若改脚本/WebUI，跑 `sh build_module.sh && sh verify_module.sh`。
3. 若改配置项 / CLI / 界面，同步更新 `README.md`。
4. 版本号按规则递增并更新 changelog。

## 真机验证清单（无真机时在 README 标注）

- 刷入流程（音量键交互 / 安装成功）
- WebUI：四 Tab、开关读写、备份删除、日志导出、深浅主题
- 动作：覆盖云控 / 同步白名单 / 恢复充电
- 拨号暗码 `*#*#76937#*#*` 触发 PowerKeeper 云控拉取
