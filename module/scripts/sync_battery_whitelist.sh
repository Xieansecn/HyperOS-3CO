#!/system/bin/sh
# 动态同步电池优化白名单
# 从 dumpsys deviceidle whitelist 读取 user 列表，
# 同步到 PowerKeeper userTable / 全局保护名单 / Joyose background_freeze_whitelist。
MODDIR=$(cd "$(dirname "$0")/.." && pwd)
. "$MODDIR/scripts/utils.sh"

SQLITE="${SQLITE:-$MODDIR/bin/sqlite3}"
CC_DB="${CC_DB:-/data/data/com.miui.powerkeeper/databases/cloud_configure.db}"
UC_DB="${UC_DB:-/data/data/com.miui.powerkeeper/databases/user_configure.db}"
JOYOSE_DB="${JOYOSE_DB:-/data/data/com.xiaomi.joyose/databases/teg_config.db}"
BACKUP_DB="${BACKUP_DB:-1}"
PK_RESTART="${PK_RESTART:-0}"

# PowerKeeper 基础保护名单（不要动）
BASE_JOYOSE_WHITELIST="com.xiaomi.joyose com.miui.powerkeeper com.xiaomi.migameservice mcd com.xiaomi.gamecenter.sdk.service"

get_battery_unrestricted_apps() {
    dumpsys deviceidle whitelist 2>/dev/null \
        | awk -F',' '$1 == "user" {print $2}' \
        | sort -u
}

# 生成 JSON 数组字符串
build_json_array() {
    echo "["
    first=1
    for app in $1; do
        if is_valid_pkg "$app"; then
            if [ "$first" = "1" ]; then
                printf '"%s"' "$app"
                first=0
            else
                printf ',"%s"' "$app"
            fi
        fi
    done
    echo "]"
}

if [ -n "${BATTERY_APPS:-}" ]; then
    APPS="$BATTERY_APPS"
else
    APPS="$(get_battery_unrestricted_apps)"
fi
APPS="$(echo "$APPS" | normalize_pkgs)"
echo "[battery-sync] 当前电池白名单应用数量: $(echo "$APPS" | wc -w)"

# 写库互斥锁：避免与开机任务/其它动作并发写 PK / Joyose 库
ensure_module_lock

if [ -n "$APPS" ] && [ -f "$CC_DB" ] && [ -f "$UC_DB" ]; then
    mkdir -p "$MODDIR/config"

    # 0) 写入前备份（dry-run 时设置 BACKUP_DB=0 跳过）
    backup_db "$CC_DB" cloud_configure
    backup_db "$UC_DB" user_configure

    TMP_CC_SQL="$MODDIR/config/.battery_sync_cc.sql.$$"
    TMP_UC_SQL="$MODDIR/config/.battery_sync_uc.sql.$$"

    # cloud_configure.db：追加 Doze/Frozen/Ultimate 白名单
    {
        echo "BEGIN;"
        for app in $APPS; do
            for key in dozeWhiteListApps FrozenNewWhiteList levelUtimateSpecialApps; do
                echo "UPDATE GlobalFeatureTable SET configureParam = CASE"
                echo "    WHEN configureParam IS NULL OR configureParam = '' THEN '$app'"
                echo "    WHEN (':' || configureParam || ':') LIKE '%:' || '$app' || ':%' THEN configureParam"
                echo "    WHEN (';' || configureParam || ';') LIKE '%;' || '$app' || ';%' THEN configureParam"
                echo "    ELSE configureParam || CASE '$key'"
                echo "        WHEN 'FrozenNewWhiteList' THEN ';' || '$app'"
                echo "        ELSE ':' || '$app' END"
                echo "    END"
                echo "    WHERE configureName = '$key';"
            done
        done
        echo "COMMIT;"
    } > "$TMP_CC_SQL"

    # user_configure.db：把电池白名单设为 noRestrict
    {
        echo "BEGIN;"
        for app in $APPS; do
            echo "INSERT OR REPLACE INTO userTable"
            echo "    (userId, pkgName, lastConfigured, bgControl, bgLocation, bgDelayMin)"
            echo "    VALUES (0, '$app', CAST(strftime('%s','now') AS INTEGER)*1000, 'noRestrict', NULL, 0);"
        done
        echo "COMMIT;"
    } > "$TMP_UC_SQL"

    sqlite3_x "$CC_DB" ".read $TMP_CC_SQL" || { echo "[battery-sync] PowerKeeper 写入失败"; rm -f "$TMP_CC_SQL" "$TMP_UC_SQL"; exit 1; }
    sqlite3_x "$UC_DB" ".read $TMP_UC_SQL" || { echo "[battery-sync] user_configure 写入失败"; rm -f "$TMP_CC_SQL" "$TMP_UC_SQL"; exit 1; }
    rm -f "$TMP_CC_SQL" "$TMP_UC_SQL"
fi

# 同步 Joyose background_freeze_whitelist
if [ -n "$APPS" ] && [ -f "$JOYOSE_DB" ]; then
    backup_db "$JOYOSE_DB" joyose_teg
    ROW_COUNT="$("$SQLITE" "$JOYOSE_DB" "SELECT COUNT(*) FROM rules WHERE rule_module='booster_config';" 2>/dev/null)"
    if [ -z "$ROW_COUNT" ] || [ "$ROW_COUNT" -eq 0 ]; then
        echo "[battery-sync] Joyose 未找到 booster_config 规则，跳过 Joyose 更新"
    else
        WHITELIST="$BASE_JOYOSE_WHITELIST $APPS"
        JSON_ARRAY="$(build_json_array "$WHITELIST")"
        # 把 JSON 作为单行 SQL 字符串；包名不含引号，安全
        ESCAPED_JSON="$(echo "$JSON_ARRAY" | tr -d '\n' | sed "s/'/''/g")"
        if ! sqlite3_x "$JOYOSE_DB" "UPDATE rules SET rule_content = json_set(rule_content, '\$."params"."game_booster"."background_freeze_whitelist"', '$ESCAPED_JSON') WHERE rule_module='booster_config';"; then
            echo "[battery-sync] Joyose 写入失败"
            exit 1
        fi
    fi
    # 冻结云控接收器（无条件执行）：即使跳过 Joyose 更新，PK 侧已定制，
    # 必须保持冻结，避免官方云控拉回覆盖
    if [ "${DRY_RUN:-0}" = "1" ]; then
        echo "[battery-sync] dry-run：跳过 Joyose 服务冻结"
    else
        joyose_freeze_cloud
    fi
fi

# 可选：重启 PowerKeeper 促使重新读取云控
if [ "$PK_RESTART" = "1" ] && [ "${DRY_RUN:-0}" != "1" ]; then
    restart_powerkeeper
fi

echo "[battery-sync] done"
