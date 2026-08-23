# HyperOS-3CO

基于酷安作者「苏疫杆菌」模块原型二改的 **MIUI / HyperOS Joyose 云控定制模块**，适配 Redmi K70 Pro（manet）。

支持 KernelSU / Magisk / APatch 框架，提供云控覆盖、后台防冻结、高刷管理、快充恢复等能力，并附带一个可在 KernelSU 管理器内直接使用的 Material 风格 WebUI。

## 功能特性

- **Joyose 云控覆盖**：将当前机型的定制云控写入 `teg_config.db`，写入后冻结官方云控接收器，防止定制内容被云端覆盖
- **动态白名单**：白名单类列表（`game_list` / `support_app` / `background_freeze_whitelist`）写入时动态替换为设备上全部第三方应用，无需维护固定名单
- **电池白名单同步**：把系统「电池优化/无限制」名单同步到 PowerKeeper 与 Joyose，后台行为跟随系统设置
- **PowerKeeper 静态保护**：把所有第三方应用写入 `noRestrict` 与多级白名单，减少后台冻结
- **高刷跟随系统**：清除云控 FPS 强制名单，让高刷跟随系统刷新率设置
- **恢复充电**：一键恢复热控服务、解除节点屏蔽、重读本地云控（保持防冻结定制不丢失）
- **数据安全**：所有写库前自动备份（保留最近 5 份），WebUI 内可查看与删除备份

## WebUI（KernelSU 管理器内可用）

KernelSU 管理器 → 模块 → HyperOS-3CO → 打开 WebUI：

- **状态**：概览卡片（电池 / 云控 / 高刷 / 备份）+ 自检刷新
- **开关**：五个 `config/` 开关实时读写（下次开机生效）
- **操作**：菜单 1-8 全部动作 + 备份管理（列表 / 删除）+ 恢复充电拨号暗码提示（`*#*#76937#*#*` 触发 PowerKeeper 云控拉取）
- **日志**：实时日志终端，可导出 txt 到 Download

深色 / 浅色主题跟随系统，也可手动切换。

## 安装

1. 下载 Release 中的 zip（或自行 `sh build_module.sh` 打包）
2. 在 KernelSU / Magisk / APatch 管理器中刷入
3. 刷入时按音量键交互选择（**音量↑ 是 / 音量↓ 否**，首个询问务必选择「是」）
4. 重启后生效；所有功能可随时在 WebUI 或 `action.sh` 菜单中手动执行

> 若曾遇到快速充电消失，请使用 WebUI / 菜单 [8] 一键恢复充电。

## 命令行入口

```sh
sh /data/adb/modules/HyperOS-3CO/action.sh <命令>
# joyose | sync_battery | powerkeeper | refresh | status
# restart_pk | backup | restore_charging
# config | config_get <key> | config_set <key> <值>
# backup_list | backup_delete <文件名> | version | help
```

无参数时进入音量键交互菜单。

## 适配机型

- 小米 15 系列（dada / haotian / xuanyuan）
- REDMI K80 系列（zorn / miro / dali）
- REDMI K90 系列（annibale / myron / warsaw）
- 小米 17 系列（pudding / pandora / popsicle）
- 小米 12S / 13 / 14 系列（unicorn / thor / nuwa / houji）
- Redmi K50 / K60 / Note 12 Turbo 系列（diting / mondrian / marble）
- 小米 / REDMI 平板系列（turner / uke）
- **Redmi K70 Pro（manet）**：本仓库实际测试机型

## 开发

```sh
sh build_module.sh    # 打包 -> HyperOS-3CO-260824(manet).zip
sh verify_module.sh   # 语法 / JSON / 权限 / zip 全量校验
python3 db_inspect.py # 只读查看云控数据库
```

模块源码位于 `module/`，结构与约定见 [AGENT.md](AGENT.md)。

## 开源原因

这个模块最初是我在酷安上找到的，原型由原作者编写，但缺少 K70 Pro 的兼容。我自行抓取云控配置、重新组装适配之后，原作者的项目已经不再更新；恰逢 DSH 出现，我便与 AI 合作在真机上反复试验、打磨出了现在这个版本。

需要说明的是：我目前只在 Redmi K70 Pro 上测试过，没有其他机型可以验证；仓库里这份代码更多是我个人二改的尝试，称不上成熟可用的模块。因此：

- **欢迎提交 PR** 完善功能与机型适配
- 我**一般不处理 issues**
- 如果原作者（酷安 [@苏疫杆菌](https://www.coolapk.com/u/5807874)）认为有所冒犯，请联系我删除

## 声明

- 模块会删除 `teg_config.db` 中的旧 Joyose 规则并禁用官方云控更新，可能影响官方推送的游戏优化
- 所有改动均先备份到 `config/backups/`（保留最近 5 份），可通过卸载模块或菜单 [8] 恢复
- 本模块仅供学习与自用，刷入后果自负
