#!/system/bin/sh

# 后端统一 CLI：WebUI / 终端 / 自动化共用入口（scripts/api.sh）
# 用法: api.sh <命令> [参数]
#   命令: joyose|sync_battery|powerkeeper|refresh|status|restart_pk|backup|
#         restore_charging|freeze|unfreeze
#        config | config_get <key> | config_set <key> <值>
#        backup_list | backup_delete <文件名>
#        whitelist_list|whitelist_add|whitelist_remove
#        wl_sys_list <名单> | wl_sys_add <名单> <包名> | wl_sys_remove <名单> <包名>
#        restart_joyose | restart_systemui | reboot | version | help
#
# 逻辑说明：所有功能实现在独立脚本 / action_lib.sh；本文件只做命令分发，
# 不承担任何功能实现，从而避免 WebUI 操作在 action.sh 菜单入口处阻塞。

MODDIR=$(cd "$(dirname "$0")/.." && pwd)
. "$MODDIR/scripts/utils.sh"
. "$MODDIR/scripts/action_lib.sh"

SQLITE="${SQLITE:-$MODDIR/bin/sqlite3}"
CC_DB="${CC_DB:-/data/data/com.miui.powerkeeper/databases/cloud_configure.db}"
UC_DB="${UC_DB:-/data/data/com.miui.powerkeeper/databases/user_configure.db}"
JOYOSE_DB="${JOYOSE_DB:-/data/data/com.xiaomi.joyose/databases/teg_config.db}"

# 读取系统白名单当前值（供 wl_sys_list/add/remove 使用）：
# 走 sqlite3_x（busy_timeout 10s + .bail on），PowerKeeper 并发写库时等待而非立即失败。
# 返回 0=成功（无行则输出为空）；返回非 0=读取失败。
# 调用方必须区分「读取失败」与「名单为空」：把失败的空结果当现状写回会清空整份名单。
wl_sys_read() {
    case "$1" in
        FrozenNewWhiteList|dozeWhiteListApps|levelUtimateSpecialApps)
            [ -f "$CC_DB" ] || return 1
            sqlite3_x "$CC_DB" "SELECT configureParam FROM GlobalFeatureTable WHERE configureName='$1';"
            ;;
        sleep_mode_network_white_apps)
            [ -f "$UC_DB" ] || return 1
            sqlite3_x "$UC_DB" "SELECT value FROM misc WHERE name='sleep_mode_network_white_apps';"
            ;;
        *) return 2 ;;
    esac
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
            MODULE_LOCK_TIMEOUT=45
            ensure_module_lock
            case "$2" in
                cloud_configure_*|user_configure_*|joyose_teg_*|highrefreshrate_*) ;;
                *)
                    echo "[action] 非法备份文件名: $2" >&2
                    return 1
                    ;;
            esac
            case "$2" in
                *[!A-Za-z0-9_.-]*|..*)
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
        restart_joyose)
            [ -z "$2" ] || { echo "[action] 该命令不接受参数" >&2; return 1; }
            exec_system "am force-stop com.xiaomi.joyose"
            exec_system "am broadcast -a android.intent.action.BOOT_COMPLETED -p com.xiaomi.joyose"
            ;;
        restart_systemui)
            [ -z "$2" ] || { echo "[action] 该命令不接受参数" >&2; return 1; }
            exec_system "am force-stop com.android.systemui"
            ;;
        reboot)
            [ -z "$2" ] || { echo "[action] 该命令不接受参数" >&2; return 1; }
            exec_system "reboot"
            ;;
        whitelist_list)
            if [ -f "$MODDIR/config/screen_off_freeze_whitelist_user" ]; then
                cat "$MODDIR/config/screen_off_freeze_whitelist_user"
            fi
            ;;
        whitelist_add)
            is_valid_pkg "$2" || { echo "[action] 非法包名: $2" >&2; return 1; }
            MODULE_LOCK_TIMEOUT=45
            ensure_module_lock
            mkdir -p "$MODDIR/config"
            WL_FILE="$MODDIR/config/screen_off_freeze_whitelist_user"
            touch "$WL_FILE"
            if grep -qxF "$2" "$WL_FILE"; then
                echo "[action] 已在豁免名单: $2"
            else
                echo "$2" >>"$WL_FILE" && echo "[action] 已添加豁免: $2" || { echo "[action] 写入失败" >&2; return 1; }
            fi
            ;;
        whitelist_remove)
            is_valid_pkg "$2" || { echo "[action] 非法包名: $2" >&2; return 1; }
            MODULE_LOCK_TIMEOUT=45
            ensure_module_lock
            WL_FILE="$MODDIR/config/screen_off_freeze_whitelist_user"
            if [ ! -f "$WL_FILE" ]; then
                echo "[action] 豁免名单为空" >&2
                return 1
            fi
            if grep -qxF "$2" "$WL_FILE"; then
                grep -vxF "$2" "$WL_FILE" >"$WL_FILE.tmp.$$" || true
                mv -f "$WL_FILE.tmp.$$" "$WL_FILE"
                echo "[action] 已移除豁免: $2"
            else
                echo "[action] 不在豁免名单: $2" >&2
                return 1
            fi
            ;;
        wl_sys_list)
            # 用法: wl_sys_list <名单名>  输出每行一个包名
            case "$2" in
                FrozenNewWhiteList|dozeWhiteListApps|levelUtimateSpecialApps|sleep_mode_network_white_apps) ;;
                *)
                    echo "[action] 未知名单: $2 (可用: FrozenNewWhiteList dozeWhiteListApps levelUtimateSpecialApps sleep_mode_network_white_apps)" >&2
                    return 1
                    ;;
            esac
            if ! WLS_VAL="$(wl_sys_read "$2" 2>/dev/null)"; then
                echo "[action] 读取 $2 失败（数据库缺失或忙），请稍后重试" >&2
                return 1
            fi
            printf '%s' "$WLS_VAL" | tr ';' '\n' | tr ':' '\n' | tr ',' '\n' | sed '/^[[:space:]]*$/d'
            ;;
        wl_sys_add)
            # 用法: wl_sys_add <名单名> <包名>
            case "$2" in
                FrozenNewWhiteList|dozeWhiteListApps|levelUtimateSpecialApps|sleep_mode_network_white_apps) ;;
                *) echo "[action] 未知名单: $2" >&2; return 1 ;;
            esac
            is_valid_pkg "$3" || { echo "[action] 非法包名: $3" >&2; return 1; }
            MODULE_LOCK_TIMEOUT=45
            ensure_module_lock
            SEP=";"
            case "$2" in dozeWhiteListApps|levelUtimateSpecialApps) SEP=":" ;; sleep_mode_network_white_apps) SEP="," ;; esac
            # 读取失败必须中止：CUR 误为空会把整份现有名单覆盖成单个包名
            if ! CUR="$(wl_sys_read "$2" 2>/dev/null)"; then
                echo "[action] 读取 $2 失败（数据库缺失或忙），已中止，名单未改动" >&2
                return 1
            fi
            if printf '%s' "$CUR" | tr "$SEP" '\n' | grep -qxF "$3"; then
                echo "[action] 已在 $2: $3"
            else
                NEWVAL="$3"
                [ -n "$CUR" ] && NEWVAL="$CUR$SEP$3"
                case "$2" in
                    FrozenNewWhiteList|dozeWhiteListApps|levelUtimateSpecialApps)
                        backup_db "$CC_DB" cloud_configure
                        sqlite3_x "$CC_DB" "INSERT OR REPLACE INTO GlobalFeatureTable (userId, configureName, configureParam) VALUES (0, '$2', '$NEWVAL');" || { echo "[action] 写入失败" >&2; return 1; }
                        ;;
                    sleep_mode_network_white_apps)
                        backup_db "$UC_DB" user_configure
                        sqlite3_x "$UC_DB" "INSERT OR REPLACE INTO misc (userId, name, value) VALUES (0, '$2', '$NEWVAL');" || { echo "[action] 写入失败" >&2; return 1; }
                        ;;
                esac
                echo "[action] 已加入 $2: $3"
            fi
            ;;
        wl_sys_remove)
            # 用法: wl_sys_remove <名单名> <包名>
            case "$2" in
                FrozenNewWhiteList|dozeWhiteListApps|levelUtimateSpecialApps|sleep_mode_network_white_apps) ;;
                *) echo "[action] 未知名单: $2" >&2; return 1 ;;
            esac
            is_valid_pkg "$3" || { echo "[action] 非法包名: $3" >&2; return 1; }
            MODULE_LOCK_TIMEOUT=45
            ensure_module_lock
            SEP=";"
            case "$2" in dozeWhiteListApps|levelUtimateSpecialApps) SEP=":" ;; sleep_mode_network_white_apps) SEP="," ;; esac
            if ! CUR="$(wl_sys_read "$2" 2>/dev/null)"; then
                echo "[action] 读取 $2 失败（数据库缺失或忙），已中止，名单未改动" >&2
                return 1
            fi
            if ! printf '%s' "$CUR" | tr "$SEP" '\n' | grep -qxF "$3"; then
                echo "[action] 不在 $2: $3" >&2
                return 1
            fi
            NEWVAL="$(printf '%s' "$CUR" | tr "$SEP" '\n' | grep -vxF "$3" | paste -sd"$SEP" -)"
            case "$2" in
                FrozenNewWhiteList|dozeWhiteListApps|levelUtimateSpecialApps)
                    backup_db "$CC_DB" cloud_configure
                    sqlite3_x "$CC_DB" "INSERT OR REPLACE INTO GlobalFeatureTable (userId, configureName, configureParam) VALUES (0, '$2', '$NEWVAL');" || { echo "[action] 写入失败" >&2; return 1; }
                    ;;
                sleep_mode_network_white_apps)
                    backup_db "$UC_DB" user_configure
                    sqlite3_x "$UC_DB" "INSERT OR REPLACE INTO misc (userId, name, value) VALUES (0, '$2', '$NEWVAL');" || { echo "[action] 写入失败" >&2; return 1; }
                    ;;
            esac
            echo "[action] 已从 $2 移除: $3"
            ;;

        help|-h|--help)
            echo "  可用命令: joyose sync_battery powerkeeper refresh status restart_pk backup restore_charging freeze unfreeze reset"
            echo "    whitelist_list whitelist_add whitelist_remove wl_sys_list wl_sys_add wl_sys_remove"
            echo "    restart_joyose restart_systemui reboot config config_get config_set backup_list backup_delete version"
            ;;
        *)
            ID="$(cli_action_id "$1")"
            if [ -z "$ID" ]; then
                echo "[action] 未知命令: $1 (api.sh help 查看用法)" >&2
                return 1
            fi
            if [ "$ID" = "12" ]; then
                echo "[action] 退出"
                return 0
            fi
            echo "[action] 已选择: [$ID] $(menu_label "$ID")"
            run_selected "$ID"
            return $?
            ;;
    esac
}

cli_dispatch "$@"
exit $?
