#!/system/bin/sh
# 息屏冻结 + 即时恢复
# 依据 cc_config/息屏冻结功能方案.md（含真机 PowerKeeper 反编译证据）：
#   - userTable.bgControl 只有 miuiAuto(可冻结)/noRestrict(唯一硬豁免)/restrictBg/noBg
#   - 息屏冻结执行组件为 PowerKeeper（FrozenAppController 内核冻结 + screen_off_clean_app 息屏清理）
#   - shell 直写 sqlite 不触发 ContentObserver，必须重启 PowerKeeper 才生效
# 用法: screen_off_freeze.sh apply|restore
#   apply  : 非豁免三方应用 -> miuiAuto + 从 FrozenNewWhiteList 移除 + 确保息屏清理/睡眠开关
#   restore: 全部三方恢复 noRestrict + 重加三名单 + 回滚内核冻结键（复用 powerkeeper_patch/sync）
# 豁免集: dumpsys deviceidle 白名单(user) + $MODDIR/screen_off_freeze_whitelist + 系统组件
# 环境变量: PK_RESTART=1 写后重启 PowerKeeper | DRY_RUN=1 跳过 PowerKeeper 重启（DB 仍写入） | THIRD_PARTY_APPS 覆盖三方列表
MODDIR=$(cd "$(dirname "$0")/.." && pwd)
. "$MODDIR/scripts/utils.sh"

SQLITE="${SQLITE:-$MODDIR/bin/sqlite3}"
CC_DB="${CC_DB:-/data/data/com.miui.powerkeeper/databases/cloud_configure.db}"
UC_DB="${UC_DB:-/data/data/com.miui.powerkeeper/databases/user_configure.db}"
BACKUP_DB="${BACKUP_DB:-1}"
PK_RESTART="${PK_RESTART:-0}"

WHITELIST_FILE="$MODDIR/screen_off_freeze_whitelist"
STATE_FILE="$MODDIR/config/.screen_off_freeze_state"

# 豁免集：deviceidle user 白名单 + 白名单文件 + 系统组件兜底
get_exempt_apps() {
    {
        dumpsys deviceidle whitelist 2>/dev/null | awk -F',' '$1 == "user" {print $2}'
        cat "$WHITELIST_FILE" 2>/dev/null
        echo "com.miui.powerkeeper"
        echo "com.xiaomi.joyose"
    } | normalize_pkgs
}

# 全部三方应用（THIRD_PARTY_APPS 可覆盖，便于 dry-run 测试）
get_third_party_apps() {
    if [ -n "${THIRD_PARTY_APPS:-}" ]; then
        printf '%s\n' "$THIRD_PARTY_APPS" | normalize_pkgs
    else
        pm list packages -3 2>/dev/null | sed -n 's/^package://p' | normalize_pkgs
    fi
}

# 可冻结集 = 三方 - 豁免（POSIX：用临时文件，toybox 不支持进程替换）
get_freezable_apps() {
    THIRD="$(get_third_party_apps)"
    EXEMPT="$(get_exempt_apps)"
    T3="$MODDIR/config/.freeze_third.$$"
    TE="$MODDIR/config/.freeze_exempt.$$"
    printf '%s\n' "$THIRD" >"$T3"
    printf '%s\n' "$EXEMPT" >"$TE"
    comm -23 "$T3" "$TE"
    rm -f "$T3" "$TE"
}

do_apply() {
    ensure_module_lock
    backup_db "$UC_DB" user_configure
    backup_db "$CC_DB" cloud_configure

    EXEMPT="$(get_exempt_apps)"
    FREEZABLE="$(get_freezable_apps)"
    echo "[screen-off-freeze] 可冻结: $(echo "$FREEZABLE" | wc -l) / 豁免: $(echo "$EXEMPT" | wc -l)"

    # ① userTable：可冻结集 -> miuiAuto（系统自动，可被息屏冻结）
    if [ -n "$FREEZABLE" ]; then
        TMP_SQL="$MODDIR/config/.screen_off_freeze_apply.sql.$$"
        {
            echo "BEGIN;"
            for pkg in $FREEZABLE; do
                echo "INSERT OR REPLACE INTO userTable (userId, pkgName, lastConfigured, bgControl, bgLocation, bgDelayMin)"
                echo "    VALUES (0, '$pkg', CAST(strftime('%s','now') AS INTEGER)*1000, 'miuiAuto', NULL, NULL);"
            done
            echo "COMMIT;"
        } >"$TMP_SQL"
        sqlite3_x "$UC_DB" ".read $TMP_SQL" || { echo "[screen-off-freeze] userTable 写入失败"; rm -f "$TMP_SQL"; return 1; }
        rm -f "$TMP_SQL"
    fi

    # ② misc：确保息屏清理 / 睡眠模式开启（幂等，params 一律不动）
    sqlite3_x "$UC_DB" "INSERT OR REPLACE INTO misc (userId, name, value) VALUES (0, 'screen_off_clean_app', 'true');
                        INSERT OR REPLACE INTO misc (userId, name, value) VALUES (0, 'sleep_mode_cloud', 'true');" \
        || { echo "[screen-off-freeze] misc 写入失败"; return 1; }

    # ③ GlobalFeatureTable：可冻结集从 FrozenNewWhiteList 移除（';' 分隔重拼）
    if [ -n "$FREEZABLE" ] && [ -f "$CC_DB" ]; then
        OLD_LIST="$("$SQLITE" "$CC_DB" "SELECT configureParam FROM GlobalFeatureTable WHERE configureName='FrozenNewWhiteList';" 2>/dev/null)"
        RM_FILE="$MODDIR/config/.freeze_rm.$$"
        printf '%s\n' "$FREEZABLE" >"$RM_FILE"
        NEW_LIST="$(printf '%s\n' "$OLD_LIST" | tr ';' '\n' | grep -v -x -f "$RM_FILE" | paste -sd';' -)"
        rm -f "$RM_FILE"
        sqlite3_x "$CC_DB" "UPDATE GlobalFeatureTable SET configureParam='$NEW_LIST' WHERE configureName='FrozenNewWhiteList';" \
            || { echo "[screen-off-freeze] FrozenNewWhiteList 写入失败"; return 1; }
    fi

    # ④ 可选：内核级冻结（实验，config/enable_kernel_freeze=1）
    if flag_enabled enable_kernel_freeze 0; then
        echo "[screen-off-freeze] 实验：写入 FrozenControlStatus 启用内核冻结"
        sqlite3_x "$CC_DB" "INSERT OR REPLACE INTO GlobalFeatureTable (userId, configureName, configureParam) VALUES (0, 'FrozenControlStatus', 'true');
                            INSERT OR REPLACE INTO GlobalFeatureTable (userId, configureName, configureParam) VALUES (0, 'FrozenControlNewStatus', 'true');" \
            || { echo "[screen-off-freeze] 内核冻结键写入失败"; return 1; }
    fi

    echo "applied" >"$STATE_FILE"
    echo "[screen-off-freeze] apply 完成（息屏后 PowerKeeper 将冻结/清理非豁免应用）"
}

do_restore() {
    # 先持锁写自己的键（内核冻结键回滚），释放后再调用会自锁的子脚本
    ensure_module_lock
    backup_db "$UC_DB" user_configure
    backup_db "$CC_DB" cloud_configure
    sqlite3_x "$CC_DB" "DELETE FROM GlobalFeatureTable WHERE configureName IN ('FrozenControlStatus', 'FrozenControlNewStatus');" \
        || echo "[screen-off-freeze] 内核冻结键回滚失败（继续）"
    module_unlock

    # 全部三方 -> noRestrict + 重加三名单（= powerkeeper_patch 语义，恢复防冻结基线）
    echo "[screen-off-freeze] 恢复全部三方应用为 noRestrict + 重加白名单..."
    sh "$MODDIR/scripts/powerkeeper_patch.sh" || echo "[screen-off-freeze] 静态保护恢复失败（继续）"
    # 电池白名单同步（豁免集保持 noRestrict + Joyose 防冻结名单）
    sh "$MODDIR/scripts/sync_battery_whitelist.sh" || echo "[screen-off-freeze] 电池白名单同步失败（继续）"

    echo "restored" >"$STATE_FILE"
    echo "[screen-off-freeze] restore 完成（全部三方恢复防冻结态，重启 PowerKeeper 后即时解冻）"
}

case "$1" in
    apply)
        do_apply
        ;;
    restore)
        do_restore
        ;;
    *)
        echo "用法: screen_off_freeze.sh apply|restore" >&2
        exit 1
        ;;
esac

if [ "$PK_RESTART" = "1" ] && [ "${DRY_RUN:-0}" != "1" ]; then
    restart_powerkeeper
fi
echo "[screen-off-freeze] done"
