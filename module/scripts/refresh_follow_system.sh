#!/system/bin/sh
# 让应用高刷跟随系统刷新率设置，而不是跟随云控 FPS 名单。
MODDIR=$(cd "$(dirname "$0")/.." && pwd)
. "$MODDIR/scripts/utils.sh"

SQLITE="${SQLITE:-$MODDIR/bin/sqlite3}"
UC_DB="${UC_DB:-/data/data/com.miui.powerkeeper/databases/user_configure.db}"
HR_DB="${HR_DB:-/data/data/com.miui.powerkeeper/databases/highrefreshrate.db}"
BACKUP_DB="${BACKUP_DB:-1}"

# 默认：把所有第三方应用加入高刷白名单，让系统刷新率设置决定
ENABLE_ALL_APPS_HIGH_REFRESH="${ENABLE_ALL_APPS_HIGH_REFRESH:-1}"

if [ ! -f "$UC_DB" ]; then
    echo "[refresh] 未找到 user_configure.db，跳过"
    exit 0
fi
if [ ! -x "$SQLITE" ]; then
    echo "[refresh] sqlite3 不可执行"
    exit 1
fi

mkdir -p "$MODDIR/config"

# 写库互斥锁：避免与开机任务/其它动作并发写 user_configure / 高刷库
ensure_module_lock

# 0) 写入前备份
backup_db "$UC_DB" user_configure
backup_db "$HR_DB" highrefreshrate

# 清空/置空云控下发的 FPS 限制配置，避免云端按应用强制 60Hz 或指定高刷名单
TMP_SQL="$MODDIR/config/.refresh_follow_system.sql.$$"
{
    echo "BEGIN;"
    for key in \
        fps_group \
        fps_smart_group \
        fps_top_video_pkg \
        fps_top_short_video_pkg \
        fps_top_video_idle_pkg \
        fps_exclude_pkg \
        fps_fun_state_group \
        fps_idle_config \
        fps_tp_exclude \
        display_fps_group \
        low_fps_group \
        full_screen_fps_group \
        highest_fps_group \
        lazy_fps_group \
        map_fps_group \
        dfps_group \
        thermal_highfps_group_activities \
        thermal_limit_refresh_rate \
        fps_group_config
    do
        echo "INSERT OR REPLACE INTO misc (userId, name, value) VALUES (0, '$key', '');"
    done
    echo "COMMIT;"
} > "$TMP_SQL"
sqlite3_x "$UC_DB" ".read $TMP_SQL" || { echo "[refresh] 清理 FPS 云控配置失败"; rm -f "$TMP_SQL"; exit 1; }
rm -f "$TMP_SQL"

# 可选：把第三方应用全部写入 highRefreshRateTable，让高刷跟随系统刷新率设置
if [ "${ENABLE_ALL_APPS_HIGH_REFRESH}" = "1" ] && [ -f "$HR_DB" ]; then
    TMP_HR="$MODDIR/config/.refresh_hr.sql.$$"
    {
        echo "BEGIN;"
        echo "CREATE TABLE IF NOT EXISTS highRefreshRateTable (_id INTEGER PRIMARY KEY AUTOINCREMENT, package_name TEXT NOT NULL);"
        pm list packages -3 2>/dev/null | sed -n 's/^package://p' | normalize_pkgs | while read -r pkg; do
            [ -z "$pkg" ] && continue
            echo "DELETE FROM highRefreshRateTable WHERE package_name = '$pkg';"
            echo "INSERT INTO highRefreshRateTable (package_name) VALUES ('$pkg');"
        done
        echo "COMMIT;"
    } > "$TMP_HR"
    sqlite3_x "$HR_DB" ".read $TMP_HR" || { echo "[refresh] 高刷白名单写入失败"; rm -f "$TMP_HR"; exit 1; }
    rm -f "$TMP_HR"
fi

echo "[refresh] 高刷已切换为跟随系统刷新率设置"
