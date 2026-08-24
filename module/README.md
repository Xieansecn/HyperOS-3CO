# 设备适配列表

## 小米 15 系列
- 小米 15 (dada)
- 小米 15 Pro (haotian)
- 小米 15 Ultra (xuanyuan)

## REDMI K80 系列
- REDMI K80 / POCO F7 Pro (zorn)
- REDMI K80 Pro / POCO F7 Ultra (miro)
- REDMI K80 至尊版 (dali)

## REDMI K90 系列
- REDMI K90 / POCO F8 Pro (annibale)
- REDMI K90 Pro Max / POCO F8 Ultra (myron)
- REDMI K90 至尊版 (warsaw)

## 小米 17 系列
- 小米 17 (pudding)
- 小米 17 Pro (pandora)
- 小米 17 Pro Max (popsicle)

## 小米 12S / 13 / 14 系列
- 小米 12S Pro (unicorn)
- 小米 12S Ultra (thor)
- 小米 13 Pro (nuwa)
- 小米 14 (houji)

## Redmi K50 / K60 / Note 12 Turbo 系列
- Redmi K50 至尊版 / 小米 12T Pro (diting)
- Redmi K60 / POCO F5 Pro (mondrian)
- Redmi Note 12 Turbo / POCO F5 (marble)

## 小米 / REDMI 平板系列
- REDMI K Pad / Xiaomi Pad Mini (turner)
- 小米平板 7 (uke)

---

# HyperOS-3CO v14（260825）说明

基于原 260721 manet 模块，在保留原有机型适配、GPU/IO/温控节点调优的基础上，增加并强化以下云控定制能力。

> **WebUI（260824）**：KernelSU WebUI 界面（`webroot/`）已升级为**底部四 Tab**（状态 / 开关 / 操作 / 日志）：
> - **状态**：概览卡片（电池 / Joyose / PowerKeeper / 高刷 / deviceidle / 备份）+ 手动刷新；
> - **开关**：五个 `config/` 开关实时读写；
> - **操作**：菜单 1-8 全部动作 + 拨号暗码提示（`*#*#76937#*#*` 触发 PowerKeeper 云控拉取）+ **备份管理**（列出 / 删除 `config/backups/` 备份）；
> - **日志**：占满整页的实时日志终端，可**导出 txt 到 Download**。
> - 全部功能仍经 `action.sh <命令>` 驱动；作者署名 Xieansecn & Deepseek Harness & CoolApk@苏疫杆菌。

> **动态白名单（260824）**：Joyose 云控写入时，白名单类列表（`game_list` / `support_app` / `background_freeze_whitelist`）动态替换为**设备上全部第三方应用**（`pm list packages -3`）；获取失败时保留原名单。逐游戏调参列表（`migt` / `frc_game_params` 等）保持不变。

> **息屏冻结（260825 新增）**：独立于恢复充电的省电功能——把非豁免三方应用切为可冻结态，息屏后由 PowerKeeper 冻结/清理（B 站等默认不豁免，直接解决夜间偷跑耗电）；「即时恢复」一键解除冻结（重启 PowerKeeper 秒级生效）。豁免 = 系统电池白名单 + 内置 `screen_off_freeze_whitelist` + 用户白名单（`whitelist_add/remove`）（音乐应用必须豁免）。
> **夜间定时（260825）**：`enable_nightly_freeze=1` 时开机启动定时守护，在 `freeze_start_time ~ freeze_end_time`（默认 23:00-07:00，可调）窗口内自动冻结、窗口外自动恢复；窗口时间用 `config_set freeze_start_time 22:30` 等设置。

> **充电安全性（260723 重点）**：本版已从 `system.prop` 移除全部热控/温控覆盖，且 `service.sh` 默认**不再**停止 `thermal-engine` / `mi_thermald` / `mimd-service` 等热控服务。若你曾遇到快速充电消失，请重刷本版；也可在 `action.sh` 菜单 [8] 一键恢复充电并重读本地云控。

## 0. 升级/重装时的数据安全
- 重装/更新模块时**不清理手机管家**（PowerKeeper/安全中心）的用户配置，也不做任何旧版本数据清除；Joyose 仍会重建并写入定制云控，手机管家设置原样保留。

## 1. Joyose 云控覆盖
- 安装时把当前机型 JSON 写入 `teg_config.db`（common_config + booster_config）。
- 写入前自动备份 `teg_config.db` 到 `config/backups/`（保留最近 5 份）。
- 写入后停止 Joyose 并禁用 `CloudServerReceiver`，防止官方云控再次覆盖。

## 2. 动态电池白名单同步（跟随系统）
- 读取 `dumpsys deviceidle whitelist` 中 `user` 类白名单，同步到：
  - PowerKeeper `userTable.bgControl=noRestrict`
  - `dozeWhiteListApps` / `FrozenNewWhiteList` / `levelUtimateSpecialApps`
  - Joyose `background_freeze_whitelist`
- 刷入时音量键选择是否启用；开机时按配置自动同步；可随时在 `action.sh` 手动执行。

## 3. PowerKeeper 静态保护（全部第三方应用）
- 自动收集 `pm list packages -3` 全部第三方应用，写入 `noRestrict` 与多白名单。
- 刷入时音量键选择是否启用；开机时按配置自动执行；可随时在 `action.sh` 手动执行。
- 所有写入前自动备份 `cloud_configure.db` / `user_configure.db`。

## 4. 高刷跟随系统刷新率
- 清除云控下发的 FPS 强制/限制名单（`fps_group` 等）。
- 把全部第三方应用写入 `highrefreshrate.db`，由系统刷新率设置决定实际高刷。
- 刷入时音量键选择是否启用；开机时按配置自动执行；可随时在 `action.sh` 手动执行。

## 5. 数据安全
- 所有对 PowerKeeper / Joyose / 高刷数据库的写入，均先备份到 `$MODDIR/config/backups/`（保留最近 5 份）。
- 包名写入前经过白名单字符校验，避免 SQL 注入/误写。
- 支持 `BACKUP_DB=0` 关闭备份、`DRY_RUN=1` 跳过系统服务操作，便于在数据库副本上做 dry-run 验证。

## 6. 手动管理
- **WebUI（KernelSU）**：在 KernelSU 管理器 → 模块 → 定制优化 → 打开 WebUI。底部四 Tab：
  - **状态**：概览卡片（电池/云控/高刷/备份）+ 手动刷新；
  - **开关**：七个 `config/` 开关实时读写（含息屏冻结、内核级冻结）；
  - **操作**：十个快捷操作按钮（菜单 1-10）+ 恢复充电拨号暗码提示（`*#*#76937#*#*` 触发 PowerKeeper 云控拉取）+ **备份管理**（列出 `config/backups/`、可逐份删除）；其中「息屏冻结（立即）/ 即时恢复」为即时操作即时恢复的省电功能；
  - **日志**：占满整页的实时日志终端，可**导出 txt 到 Download**。
  - WebUI 仅在 KernelSU 管理器内可用（Magisk/APatch 无此入口，不影响其他功能）。
- **命令行入口**（WebUI / 终端 / 自动化通用）：`action.sh` 支持带参数直接执行，不再进入交互菜单：
  ```sh
  sh /data/adb/modules/HyperOS-3CO/action.sh <命令>
  # 命令: joyose | sync_battery | powerkeeper | refresh | status
  #       restart_pk | backup | restore_charging | config | version | help
  #       config_get <key> | config_set <key> <值>
  #       backup_list | backup_delete <文件名>
  ```
  数字 1-9 同样可用（对应交互菜单）。`config_set` 可写：`enable_battery_sync` / `enable_static_protect` / `enable_refresh_follow` / `enable_perf_thermal` / `gpu_boost` / `enable_screen_off_freeze` / `enable_kernel_freeze`。`backup_list` 输出 `文件名<TAB>字节数`，`backup_delete` 带文件名白名单校验（防路径穿越）。
- `action.sh` 交互（funbox 风格）：**所有动作执行完输出后都会“按任意音量键返回菜单”**，不再被重绘冲掉。优先调用 `/data/adb/modules/funbox/keycheck` 检测按键（无 funbox 时回退 `getevent` 去抖，键位已对齐）；**音量↓ 移动、音量↑ 确认**；每次按键前**无条件 `clear` 清屏**再重绘菜单（与 funbox 一致，避免管理器里刷屏），当前项用 **`-> [N] 功能名`** 高亮；`sleep 0.4` 等待按键抬起，一次按压只算一次输入。
- `action.sh` 菜单：
  1. 覆盖 Joyose 云控
  2. 同步电池优化白名单
  3. 应用 PowerKeeper 静态保护
  4. 高刷跟随系统刷新率
  5. 查看当前云控状态
  6. 重启 PowerKeeper（重新读取云控）
  7. 备份云控数据库原文件
  8. 恢复充电（解除热控限制/恢复服务/重读本地云控）
  9. 息屏冻结（立即应用）
  10. 即时恢复（解除冻结）
  11. 退出

## 6.5 功能自检
- `action.sh` 菜单 [5] 现在调用 `scripts/check_status.sh`（只读）：显示模块版本/开关、Joyose 规则、PowerKeeper 策略统计、全局白名单长度、高刷名单数量、电池白名单同步数量、热控服务状态与备份列表，可一键确认各功能是否生效。

## 7. 充电恢复与备份
- 菜单 [7] `backup_cloud_db.sh`：把 PowerKeeper / Joyose / 高刷数据库原文件备份到 `config/backups/`（保留最近 5 份），刷入时也会自动执行一次。
- 菜单 [8] `restore_charging.sh`：先备份云控库，然后：
  - 重新启动被模块停止的热控/系统服务（`thermal-engine`、`vendor.cnss_diag`、`vendor.tcpdump`、`cnss-daemon`、`mimd-service` 等）；
  - 尝试重新拉起 `mi_thermald`；
  - 解除 `/dev/mount_masks` 热控节点 bind mount，恢复节点可写；
  - 只重启 PowerKeeper 重新读取**本地**云控（**不**启用 Joyose 官方云控拉取，避免官方冻结策略覆盖）；
  - 自动重新同步电池白名单（静态保护已开启时一并重跑），保持“防冻结”定制。
- 若仍不恢复，重启一次；或重刷新版模块包（默认不再改变热控）。
- 执行 [8] 后会输出**充电状态诊断**（battery status/容量/温度/电流/电压、各 power_supply 节点、热控进程），方便定位快充问题。

## 8. 性能热控调优（默认关闭）
- 默认不执行任何可能影响充电/温控的操作。
- 如确实需要，手动开启：`echo 1 > /data/adb/modules/HyperOS-3CO/config/enable_perf_thermal`，重启后生效；恢复充电时直接删掉该开关或执行菜单 [8]。
