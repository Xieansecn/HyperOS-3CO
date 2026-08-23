#!/system/bin/sh

MODDIR=${0%/*}
. "$MODDIR/scripts/utils.sh"

SQLITE="${SQLITE:-$MODDIR/bin/sqlite3}"
CC_DB="${CC_DB:-/data/data/com.miui.powerkeeper/databases/cloud_configure.db}"
UC_DB="${UC_DB:-/data/data/com.miui.powerkeeper/databases/user_configure.db}"
JOYOSE_DB="${JOYOSE_DB:-/data/data/com.xiaomi.joyose/databases/teg_config.db}"

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
    echo "[action] 恢复充电（解锁热控/恢复服务/重拉云控）..."
    sh "$MODDIR/scripts/restore_charging.sh"
}

show_status() {
    echo ""
    echo "=== 功能自检 ==="
    sh "$MODDIR/scripts/check_status.sh"
    echo ""
}

# 菜单项绘制（funbox 风格：当前项 -> 高亮 + 编号）
print_item() {
    local idx="$1"
    local sel="$2"
    local label="$3"
    if [ "$idx" = "$sel" ]; then
        echo " -> [${idx}] ${label}"
    else
        echo "    [${idx}] ${label}"
    fi
}

# 重绘菜单（funbox 同款：无条件 clear 再重绘，当前项 -> 高亮）
draw_menu() {
    clear
    echo ""
    echo "======================"
    echo " 选择操作："
    echo " 音量↓: 切换选项"
    echo " 音量↑: 确认当前选项"
    echo "----------------------"
    print_item 1 "$selected" "覆盖 Joyose 云控"
    print_item 2 "$selected" "同步电池优化白名单到云控"
    print_item 3 "$selected" "应用 PowerKeeper 静态保护补丁（全部第三方应用）"
    print_item 4 "$selected" "高刷跟随系统刷新率设置"
    print_item 5 "$selected" "查看当前云控状态"
    print_item 6 "$selected" "重启 PowerKeeper（重新读取云控）"
    print_item 7 "$selected" "备份云控数据库原文件"
    print_item 8 "$selected" "恢复充电（解除热控限制/恢复服务/重读本地云控）"
    print_item 9 "$selected" "退出"
    echo "======================"
}

run_selected() {
    case "$1" in
        1) run_joyose ;;
        2) run_sync_battery ;;
        3) run_powerkeeper ;;
        4) run_refresh_follow_system ;;
        5) show_status ;;
        6) run_restart_pk ;;
        7) run_backup_db ;;
        8) run_restore_charging ;;
        9) echo "[action] 退出"; exit 0 ;;
        *) echo "[action] 无效选择" ;;
    esac
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
        9) echo "退出" ;;
        *) echo "无效选项" ;;
    esac
}

# ---- 命令行入口（WebUI / 终端 / 自动化调用） ----
# 用法: action.sh <命令> [参数]
#   命令: joyose|1  sync_battery|2  powerkeeper|3  refresh|4
#         status|5  restart_pk|6  backup|7  restore_charging|8  exit|9
#         config | config_get <key> | config_set <key> <值>
#         backup_list | backup_delete <文件名> | version | help
# 无参数时进入音量键交互菜单（原行为不变）。

CONFIG_KEYS="enable_battery_sync enable_static_protect enable_refresh_follow enable_perf_thermal gpu_boost"

flag_default() {
    case "$1" in
        enable_battery_sync)  echo "1" ;;
        enable_refresh_follow) echo "1" ;;
        gpu_boost)            echo "false" ;;
        *)                    echo "0" ;;
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
        9|exit)             echo "9" ;;
        *)                  echo "" ;;
    esac
}

cli_config_get() {
    case "$CONFIG_KEYS" in
        *"$1"*)
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
    case "$CONFIG_KEYS" in
        *"$1"*) ;;
        *)
            echo "[action] 未知配置项: $1" >&2
            return 1
            ;;
    esac
    case "$2" in
        0|1|true|false) ;;
        *)
            echo "[action] 非法取值: $2 (允许 0/1/true/false)" >&2
            return 1
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

cli_dispatch() {
    case "$1" in
        config)
            for k in $CONFIG_KEYS; do
                cli_config_get "$k"
            done
            ;;
        config_get)
            cli_config_get "$2"
            ;;
        config_set)
            cli_config_set "$2" "$3"
            ;;
        version)
            grep -E '^(name|version|versionCode|author)=' "$MODDIR/module.prop" 2>/dev/null || echo "module.prop 缺失"
            ;;
        backup_list)
            # 输出: 文件名<TAB>字节数，新→旧
            if [ -d "$MODDIR/config/backups" ]; then
                for f in "$MODDIR/config/backups/"*; do
                    [ -f "$f" ] || continue
                    printf '%s\t%s\n' "$(basename "$f")" "$(wc -c < "$f")"
                done | sort -r
            fi
            ;;
        backup_delete)
            ensure_module_lock
            case "$2" in
                cloud_configure_*|user_configure_*|joyose_teg_*|highrefreshrate_*) ;;
                *)
                    echo "[action] 非法备份文件名: $2" >&2
                    return 1
                    ;;
            esac
            case "$2" in
                *[!/A-Za-z0-9_.-]*|..*)
                    echo "[action] 非法备份文件名: $2" >&2
                    return 1
                    ;;
            esac
            if [ -f "$MODDIR/config/backups/$2" ]; then
                rm -f "$MODDIR/config/backups/$2"
                echo "[action] 已删除备份: $2"
            else
                echo "[action] 备份不存在: $2" >&2
                return 1
            fi
            ;;
        help|-h|--help)
            grep '^# 用法' "$0" | head -n 1 | sed 's/^# *//'
            echo "  可用命令: joyose sync_battery powerkeeper refresh status restart_pk backup restore_charging config config_get config_set backup_list backup_delete version"
            ;;
        *)
            ID="$(cli_action_id "$1")"
            if [ -z "$ID" ]; then
                echo "[action] 未知命令: $1 (action.sh help 查看用法)" >&2
                return 1
            fi
            if [ "$ID" = "9" ]; then
                echo "[action] 退出"
                return 0
            fi
            echo "[action] 已选择: [$ID] $(menu_label "$ID")"
            run_selected "$ID"
            ;;
    esac
}

# ---- funbox 同款按键检测：优先 keycheck，回退 getevent ----
KEY_CHECK="${KEY_CHECK:-/data/adb/modules/funbox/keycheck}"
VOL_UP_SIGNAL=42
VOL_DOWN_SIGNAL=41

key_click_compat() {
    if [ -x "$KEY_CHECK" ]; then
        "$KEY_CHECK" >/dev/null 2>&1
        key=$?
        case "$key" in
            "$VOL_DOWN_SIGNAL") return 0 ;; # 音量下：移动
            "$VOL_UP_SIGNAL") return 1 ;;   # 音量上：确认
            *) return 2 ;;
        esac
    else
        # getevent 回退：key_click 返回 0=音量上 / 1=音量下，
        # 统一转换为 0=移动(音量下) / 1=确认(音量上)
        if key_click; then
            return 1
        else
            return 0
        fi
    fi
}

# 动作执行前输出一条日志，便于在管理器日志中确认做了什么
show_selected() {
    echo "[action] 已选择: [${selected}] $(menu_label "$selected")"
}

# 命令行模式：带参数直接执行，不进入交互菜单（WebUI/自动化用）
if [ "$#" -gt 0 ]; then
    cli_dispatch "$@"
    exit $?
fi

# 兼容性检查：keycheck 或 getevent 至少有一个可用
if [ ! -x "$KEY_CHECK" ] && ! command -v getevent >/dev/null 2>&1; then
    echo "[action] 当前环境不支持音量键交互，请在 KernelSU/Magisk 模块管理器中运行"
    exit 1
fi

selected=1
while true; do
    draw_menu "$selected"
    # 等待按键抬起，避免同一次按压的按下/抬起被处理两次（funbox 同款）
    sleep 0.4
    key_click_compat
    ret=$?
    case "$ret" in
        0) # 音量下：移动下一项
            selected=$((selected + 1))
            [ "$selected" -gt 9 ] && selected=1
            ;;
        1) # 音量上：确认执行
            echo ""
            show_selected
            run_selected "$selected"
            # 所有动作输出后等待按键返回（[9] 退出已 exit，不会到这里）
            echo ""
            echo "按任意音量键返回菜单..."
            key_click_compat >/dev/null 2>&1 || true
            ;;
        2)
            echo "[action] 按键监听失败，退出"
            exit 1
            ;;
    esac
done
