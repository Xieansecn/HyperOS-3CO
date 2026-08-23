#!/system/bin/sh
# PowerKeeper 静态保护补丁（全部第三方应用）
# 默认作用于真机数据库，但可用环境变量 CC_DB/UC_DB 指向副本做 dry-run。
# 可用 APPS 指定自定义包名列表（空格或换行分隔）。
MODDIR=$(cd "$(dirname "$0")/.." && pwd)
. "$MODDIR/scripts/utils.sh"

SQLITE="${SQLITE:-$MODDIR/bin/sqlite3}"
CC_DB="${CC_DB:-/data/data/com.miui.powerkeeper/databases/cloud_configure.db}"
UC_DB="${UC_DB:-/data/data/com.miui.powerkeeper/databases/user_configure.db}"
BACKUP_DB="${BACKUP_DB:-1}"
PK_RESTART="${PK_RESTART:-0}"
TMP_DIR="${TMP_DIR:-$MODDIR/config}"

# 默认自动收集当前设备所有第三方应用
# 银行/音乐/社交/支付/学习/开源软件等都会包含在 pm list packages -3 中
get_static_apps() {
    if [ -n "${APPS:-}" ]; then
        printf '%s\n' "$APPS"
    else
        pm list packages -3 2>/dev/null | sed -n 's/^package://p'
    fi
}

APPS="$(get_static_apps | normalize_pkgs)"
if [ -z "$APPS" ]; then
    echo "[PowerKeeper patch] 未获取到第三方应用，跳过"
    exit 0
fi
echo "[PowerKeeper patch] 目标应用数量: $(echo "$APPS" | wc -l)"

# 写库互斥锁：避免与开机任务/其它动作并发写 PK 库
ensure_module_lock

# 基础检查
if [ ! -f "$CC_DB" ] || [ ! -f "$UC_DB" ]; then
    echo "[PowerKeeper patch] 找不到数据库，跳过"
    echo "  CC_DB=$CC_DB"
    echo "  UC_DB=$UC_DB"
    exit 0
fi

if [ ! -x "$SQLITE" ]; then
    echo "[PowerKeeper patch] sqlite3 不可执行: $SQLITE"
    exit 1
fi

mkdir -p "$TMP_DIR"

# 0) 写入前备份（dry-run 时设置 BACKUP_DB=0 跳过）
backup_db "$CC_DB" cloud_configure
backup_db "$UC_DB" user_configure

# 1) 生成并执行全局名单补丁 SQL
CC_SQL="$TMP_DIR/.powerkeeper_patch_cc.sql.$$"
{
    echo "BEGIN;"
    for app in $APPS; do
        # list 以 : 或 ; 分隔，使用首尾拼接后精确匹配，避免 substring 误判
        echo "UPDATE GlobalFeatureTable SET configureParam = CASE"
        echo "    WHEN configureParam IS NULL OR configureParam = '' THEN '$app'"
        echo "    WHEN (':' || configureParam || ':') LIKE '%:' || '$app' || ':%' THEN configureParam"
        echo "    WHEN (';' || configureParam || ';') LIKE '%;' || '$app' || ';%' THEN configureParam"
        echo "    ELSE configureParam || ':' || '$app' END"
        echo "    WHERE configureName = 'dozeWhiteListApps';"
        echo "UPDATE GlobalFeatureTable SET configureParam = CASE"
        echo "    WHEN configureParam IS NULL OR configureParam = '' THEN '$app'"
        echo "    WHEN (':' || configureParam || ':') LIKE '%:' || '$app' || ':%' THEN configureParam"
        echo "    WHEN (';' || configureParam || ';') LIKE '%;' || '$app' || ';%' THEN configureParam"
        echo "    ELSE configureParam || ';' || '$app' END"
        echo "    WHERE configureName = 'FrozenNewWhiteList';"
        echo "UPDATE GlobalFeatureTable SET configureParam = CASE"
        echo "    WHEN configureParam IS NULL OR configureParam = '' THEN '$app'"
        echo "    WHEN (':' || configureParam || ':') LIKE '%:' || '$app' || ':%' THEN configureParam"
        echo "    WHEN (';' || configureParam || ';') LIKE '%;' || '$app' || ';%' THEN configureParam"
        echo "    ELSE configureParam || ':' || '$app' END"
        echo "    WHERE configureName = 'levelUtimateSpecialApps';"
    done
    echo "COMMIT;"
} > "$CC_SQL"

if ! sqlite3_x "$CC_DB" ".read $CC_SQL"; then
    echo "[PowerKeeper patch] cloud_configure.db 写入失败，已中止"
    rm -f "$CC_SQL"
    exit 1
fi
rm -f "$CC_SQL"

# 2) 生成并执行 userTable 补丁 SQL
UC_SQL="$TMP_DIR/.powerkeeper_patch_uc.sql.$$"
{
    echo "BEGIN;"
    for app in $APPS; do
        echo "INSERT OR REPLACE INTO userTable"
        echo "    (userId, pkgName, lastConfigured, bgControl, bgLocation, bgDelayMin)"
        echo "    VALUES (0, '$app', CAST(strftime('%s','now') AS INTEGER)*1000, 'noRestrict', NULL, 0);"
    done
    echo "COMMIT;"
} > "$UC_SQL"

if ! sqlite3_x "$UC_DB" ".read $UC_SQL"; then
    echo "[PowerKeeper patch] user_configure.db 写入失败，已中止"
    rm -f "$UC_SQL"
    exit 1
fi
rm -f "$UC_SQL"

echo "[PowerKeeper patch] done"
echo "  apps=$APPS"

# 3) 可选：重启 PowerKeeper 促使重新读取云控
if [ "$PK_RESTART" = "1" ] && [ "${DRY_RUN:-0}" != "1" ]; then
    restart_powerkeeper
fi
