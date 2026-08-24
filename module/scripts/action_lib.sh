#!/system/bin/sh

# 共享动作实现：run_* / show_status / menu_label / cli_action_id / run_selected /
# CONFIG_KEYS / flag_default / cli_config_get / cli_config_set
#
# 由两处 source：
#   - action.sh（KernelSU 模块列表 action 按钮 → 纯音量键交互菜单）
#   - scripts/api.sh（WebUI / 终端 / 自动化统一 CLI 后端）
# 本文件不含任何入口逻辑；调用方须在 source 前设置 MODDIR。

CONFIG_KEYS="enable_battery_sync enable_static_protect enable_refresh_follow enable_perf_thermal gpu_boost enable_screen_off_freeze enable_kernel_freeze enable_nightly_freeze freeze_start_time freeze_end_time"

flag_default() {
    case "$1" in
        enable_battery_sync)  echo "1" ;;
        enable_refresh_follow) echo "1" ;;
        gpu_boost)            echo "false" ;;
        freeze_start_time)    echo "23:00" ;;
        freeze_end_time)      echo "07:00" ;;
        *)                    echo "0" ;;
    esac
}

run_joyose() {
    echo "[action] 覆盖 Joyose 云控..."
    sh "$MODDIR/scripts/joyose_config.sh"
    echo "[action] Joyose 云控已覆盖"
}

run_sync_battery() {
    echo "[action] 同步电池优化白名单到云控..."
    PK_RESTART=1 sh "$MODDIR/scripts/sync_battery_whitelist.sh"
}

run_powerkeeper() {
    echo "[action] 应用 PowerKeeper 静态保护补丁（全部第三方应用）..."
    PK_RESTART=1 sh "$MODDIR/scripts/powerkeeper_patch.sh"
}

run_refresh_follow_system() {
    echo "[action] 高刷跟随系统刷新率设置..."
    sh "$MODDIR/scripts/refresh_follow_system.sh"
}

run_restart_pk() {
    echo "[action] 重启 PowerKeeper 以重新读取云控..."
    restart_powerkeeper
    echo "[action] 已完成；PowerKeeper 将由系统自动拉起"
}

run_backup_db() {
    echo "[action] 备份云控数据库原文件..."
    sh "$MODDIR/scripts/backup_cloud_db.sh"
}

run_restore_charging() {
    echo "[action] 恢复充电（解锁热控/恢复服务/重读本地云控）..."
    sh "$MODDIR/scripts/restore_charging.sh"
}

run_screen_off_freeze() {
    echo "[action] 息屏冻结（非豁免三方切为可冻结态，重启 PowerKeeper 生效）..."
    PK_RESTART=1 sh "$MODDIR/scripts/screen_off_freeze.sh" apply
}

run_screen_off_unfreeze() {
    echo "[action] 即时恢复（全部三方恢复 noRestrict，解除冻结）..."
    PK_RESTART=1 sh "$MODDIR/scripts/screen_off_freeze.sh" restore
}

# 一键还原（清理式）：撤销模块限制/冻结、恢复云控接收器，让云控重拉；不写回备份、不清手机管家数据
run_reset() {
    echo "[action] 一键还原（清理式，让云控重拉；不清手机管家数据）..."
    sh "$MODDIR/scripts/reset_module.sh"
}

show_status() {
    echo ""
    echo "=== 功能自检 ==="
    sh "$MODDIR/scripts/check_status.sh"
    echo ""
}

# 菜单项名称（选择器指示用）
menu_label() {
    case "$1" in
        1) echo "覆盖 Joyose 云控" ;;
        2) echo "同步电池优化白名单到云控" ;;
        3) echo "应用 PowerKeeper 静态保护补丁（全部第三方应用）" ;;
        4) echo "高刷跟随系统刷新率设置" ;;
        5) echo "查看当前云控状态" ;;
        6) echo "重启 PowerKeeper（重新读取云控）" ;;
        7) echo "备份云控数据库原文件" ;;
        8) echo "恢复充电（解除热控限制/恢复服务/重读本地云控）" ;;
        9) echo "息屏冻结（立即应用）" ;;
        10) echo "即时恢复（解除冻结）" ;;
        11) echo "一键还原（清理式，让云控重拉）" ;;
        12) echo "退出" ;;
        *) echo "无效选项" ;;
    esac
}

cli_action_id() {
    case "$1" in
        1|joyose)           echo "1" ;;
        2|sync|sync_battery) echo "2" ;;
        3|powerkeeper)      echo "3" ;;
        4|refresh|refresh_follow) echo "4" ;;
        5|status)           echo "5" ;;
        6|restart_pk)       echo "6" ;;
        7|backup)           echo "7" ;;
        8|restore|restore_charging) echo "8" ;;
        9|freeze)           echo "9" ;;
        10|unfreeze)        echo "10" ;;
        11|reset)           echo "11" ;;
        12|exit)            echo "12" ;;
        *)                  echo "" ;;
    esac
}

run_selected() {
    case "$1" in
        1) run_joyose; return $? ;;
        2) run_sync_battery; return $? ;;
        3) run_powerkeeper; return $? ;;
        4) run_refresh_follow_system; return $? ;;
        5) show_status ;;
        6) run_restart_pk ;;
        7) run_backup_db; return $? ;;
        8) run_restore_charging ;;
        9) run_screen_off_freeze; return $? ;;
        10) run_screen_off_unfreeze; return $? ;;
        11) run_reset; return $? ;;
        12) echo "[action] 退出"; exit 0 ;;
        *) echo "[action] 无效选择" ;;
    esac
}

cli_config_get() {
    case " $CONFIG_KEYS " in
        *" $1 "*)
            if [ -f "$MODDIR/config/$1" ]; then
                echo "$1=$(cat "$MODDIR/config/$1")"
            else
                echo "$1=$(flag_default "$1")"
            fi
            ;;
        *)
            echo "[action] 未知配置项: $1" >&2
            return 1
            ;;
    esac
}

cli_config_set() {
    case " $CONFIG_KEYS " in
        *" $1 "*) ;;
        *)
            echo "[action] 未知配置项: $1" >&2
            return 1
            ;;
    esac
    case "$1" in
        freeze_start_time|freeze_end_time)
            # 时间键：仅接受 HH:MM
            case "$2" in
                [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;;
                *)
                    echo "[action] 非法时间: $2 (期望 HH:MM，如 23:00)" >&2
                    return 1
                    ;;
            esac
            ;;
        *)
            case "$2" in
                0|1|true|false) ;;
                *)
                    echo "[action] 非法取值: $2 (允许 0/1/true/false)" >&2
                    return 1
                    ;;
            esac
            ;;
    esac
    mkdir -p "$MODDIR/config"
    printf '%s\n' "$2" >"$MODDIR/config/$1.tmp.$$" && mv -f "$MODDIR/config/$1.tmp.$$" "$MODDIR/config/$1" || {
        rm -f "$MODDIR/config/$1.tmp.$$" 2>/dev/null || true
        echo "[action] 写入配置失败" >&2
        return 1
    }
    echo "[action] $1=$2"
}
