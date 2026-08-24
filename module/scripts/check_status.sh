#!/system/bin/sh
# 功能生效自检：只读查询，不修改任何数据
MODDIR=$(cd "$(dirname "$0")/.." && pwd)
. "$MODDIR/scripts/utils.sh"

SQLITE="${SQLITE:-$MODDIR/bin/sqlite3}"
CC_DB="${CC_DB:-/data/data/com.miui.powerkeeper/databases/cloud_configure.db}"
UC_DB="${UC_DB:-/data/data/com.miui.powerkeeper/databases/user_configure.db}"
JOYOSE_DB="${JOYOSE_DB:-/data/data/com.xiaomi.joyose/databases/teg_config.db}"
HR_DB="${HR_DB:-/data/data/com.miui.powerkeeper/databases/highrefreshrate.db}"

echo "========== 模块与开关 =========="
grep -E '^(name|version)=' "$MODDIR/module.prop" 2>/dev/null || echo "module.prop 缺失"
for f in enable_battery_sync enable_static_protect enable_refresh_follow enable_perf_thermal gpu_boost enable_screen_off_freeze enable_kernel_freeze; do
    if [ -f "$MODDIR/config/$f" ]; then
        echo "  $f = $(cat "$MODDIR/config/$f")"
    else
        echo "  $f = (未设置/默认)"
    fi
done

echo ""
echo "========== Joyose 云控 =========="
if [ -f "$JOYOSE_DB" ] && [ -x "$SQLITE" ]; then
    "$SQLITE" "$JOYOSE_DB" "SELECT rule_module || ' (ver=' || rule_version || ')' FROM rules ORDER BY rule_module;" 2>/dev/null
    echo "  background_freeze_whitelist 数量: $("$SQLITE" "$JOYOSE_DB" "SELECT json_array_length(json_extract(rule_content,'$.params.game_booster.background_freeze_whitelist')) FROM rules WHERE rule_module='booster_config';" 2>/dev/null)"
else
    echo "  未找到 $JOYOSE_DB"
fi

echo ""
echo "========== PowerKeeper =========="
if [ -f "$UC_DB" ]; then
    echo "  userTable 策略统计:"
    "$SQLITE" "$UC_DB" "SELECT '    ' || bgControl || ' : ' || COUNT(*) FROM userTable GROUP BY bgControl;" 2>/dev/null
fi
if [ -f "$CC_DB" ]; then
    for key in dozeWhiteListApps FrozenNewWhiteList levelUtimateSpecialApps; do
        len=$("$SQLITE" "$CC_DB" "SELECT length(configureParam) FROM GlobalFeatureTable WHERE configureName='$key';" 2>/dev/null)
        echo "  $key length=${len:-0}"
    done
fi

echo ""
echo "========== 高刷跟随系统 =========="
if [ -f "$UC_DB" ]; then
    "$SQLITE" "$UC_DB" "SELECT '  fps_group 长度=' || length(value) FROM misc WHERE name='fps_group';" 2>/dev/null || echo "  misc 无 fps_group（可能已置空）"
fi
if [ -f "$HR_DB" ]; then
    echo "  highRefreshRateTable 数量: $("$SQLITE" "$HR_DB" "SELECT COUNT(*) FROM highRefreshRateTable;" 2>/dev/null)"
fi

echo ""
echo "========== 电池白名单同步 =========="
echo "  deviceidle user 白名单数量: $(dumpsys deviceidle whitelist 2>/dev/null | awk -F',' '$1 == "user"' | wc -l)"
echo "  userTable noRestrict 数量: $("$SQLITE" "$UC_DB" "SELECT COUNT(*) FROM userTable WHERE bgControl='noRestrict';" 2>/dev/null)"

echo ""
echo "========== 充电/热控服务 =========="
echo "  battery: status=$(cat /sys/class/power_supply/battery/status 2>/dev/null || echo N/A) capacity=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null || echo N/A)% temp=$(cat /sys/class/power_supply/battery/temp 2>/dev/null || echo N/A) current=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null || echo N/A)uA voltage=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null || echo N/A)uV"
ps -A 2>/dev/null | grep -E 'mi_thermald|thermal-engine|mimd-service' || echo "  热控服务未运行（默认不干预，属正常）"

echo ""
echo "========== 备份 =========="
ls -1 "$MODDIR/config/backups/" 2>/dev/null | head -n 10 || echo "  暂无备份"

echo ""
echo "========== 息屏冻结 =========="
echo "  screen_off_clean_app=$("$SQLITE" "$UC_DB" "SELECT value FROM misc WHERE name='screen_off_clean_app';" 2>/dev/null)  params=$("$SQLITE" "$UC_DB" "SELECT value FROM misc WHERE name='screen_off_clean_app_params';" 2>/dev/null)"
echo "  sleep_mode_cloud=$("$SQLITE" "$UC_DB" "SELECT value FROM misc WHERE name='sleep_mode_cloud';" 2>/dev/null)"
echo "  FrozenControlStatus=$("$SQLITE" "$CC_DB" "SELECT IFNULL(configureParam,'(缺失)') FROM GlobalFeatureTable WHERE configureName='FrozenControlStatus';" 2>/dev/null)"
echo "  FrozenNewWhiteList 长度=$("$SQLITE" "$CC_DB" "SELECT length(configureParam) FROM GlobalFeatureTable WHERE configureName='FrozenNewWhiteList';" 2>/dev/null)"
echo "  userTable: miuiAuto=$("$SQLITE" "$UC_DB" "SELECT COUNT(*) FROM userTable WHERE bgControl='miuiAuto';" 2>/dev/null)  noRestrict=$("$SQLITE" "$UC_DB" "SELECT COUNT(*) FROM userTable WHERE bgControl='noRestrict';" 2>/dev/null)"
echo "  状态: $(cat "$MODDIR/config/.screen_off_freeze_state" 2>/dev/null || echo 未执行过)"

echo ""
echo "========== 自检完成 =========="
