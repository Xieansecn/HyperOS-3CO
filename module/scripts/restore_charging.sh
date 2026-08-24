#!/system/bin/sh
# 恢复充电/热控：撤销模块停止的系统服务、解除热控节点绑定、
# 并保持“防冻结”定制（不启用 Joyose 官方云控拉取，避免官方冻结策略覆盖）。
# 用法：菜单 [8]；DRY_RUN=1 只打印计划不执行系统操作。
MODDIR=$(cd "$(dirname "$0")/.." && pwd)
. "$MODDIR/scripts/utils.sh"

SQLITE="${SQLITE:-$MODDIR/bin/sqlite3}"
CC_DB="${CC_DB:-/data/data/com.miui.powerkeeper/databases/cloud_configure.db}"
UC_DB="${UC_DB:-/data/data/com.miui.powerkeeper/databases/user_configure.db}"
JOYOSE_DB="${JOYOSE_DB:-/data/data/com.xiaomi.joyose/databases/teg_config.db}"
HR_DB="${HR_DB:-/data/data/com.miui.powerkeeper/databases/highrefreshrate.db}"
DRY_RUN="${DRY_RUN:-0}"
# dry-run 不写备份文件（备份块在 DRY_RUN 判断前，直接关闭）
[ "$DRY_RUN" = "1" ] && BACKUP_DB=0

echo "[charging] 开始恢复充电相关配置..."

# 开机初始化进行中提示（service.sh 结束时写 config/.boot_init_done）
if [ ! -f "$MODDIR/config/.boot_init_done" ]; then
    echo "[charging] 提示：开机初始化可能仍在进行；若热控节点恢复不彻底，请稍后重试"
fi

# 0) 先备份当前云控数据库原文件（可回滚）
backup_db "$CC_DB" cloud_configure
backup_db "$UC_DB" user_configure
backup_db "$JOYOSE_DB" joyose_teg
backup_db "$HR_DB" highrefreshrate

do_sys() {
    if [ "$DRY_RUN" = "1" ]; then
        echo "[charging] (dry-run) 跳过: $1"
    else
        exec_system "$1"
    fi
}

# 启动服务：start 失败再试 ctl.start，仍失败说明由系统自管/不存在，静默忽略
do_start() {
    if [ "$DRY_RUN" = "1" ]; then
        echo "[charging] (dry-run) 跳过: start $1"
    else
        start "$1" 2>/dev/null || setprop ctl.start "$1" 2>/dev/null || true
    fi
}

# 1) 恢复被 service.sh 停止的系统服务
for i in vendor.cnss_diag vendor.tcpdump thermal-engine cnss-daemon; do
    do_start "$i"
done
for svc in mimd-service mimd-service2_0; do
    do_start "$svc"
done

# 2) 重新拉起 mi_thermald（如果被 killall）
do_start "mi_thermald"

# 3) 解除模块 bind mount，恢复热控/节电节点由系统管理
if [ "$DRY_RUN" = "1" ]; then
    echo "[charging] (dry-run) 跳过解除 bind mount"
else
    while read -r src dst rest; do
        case "$src" in
            /dev/mount_masks/*) umount "$dst" 2>/dev/null || true ;;
        esac
    done < /proc/mounts

    for f in \
        /sys/kernel/thermal/ttj \
        /sys/kernel/thermal/max_ttj \
        /sys/kernel/thermal/min_ttj \
        /proc/mtk_lpm/cpuidle/enable \
        /proc/mtk_lpm/cpuidle/cpu_pf_en \
        /proc/mtk_lpm/cpuidle/cpu_ret_en \
        /proc/sys/walt/input_boost
    do
        [ -e "$f" ] && chmod 0644 "$f" 2>/dev/null || true
    done
    for f in /sys/devices/system/cpu/qcom_lpm/*disable*; do
        [ -e "$f" ] && chmod 0644 "$f" 2>/dev/null || true
    done
fi

# 4) 只重启 PowerKeeper 重新读取本地云控
#    注意：不启用 Joyose CloudServerReceiver、不发官方拉取广播，
#    否则官方云控会把冻结策略拉回来覆盖定制白名单。
do_sys "am force-stop com.miui.powerkeeper"
do_sys "am broadcast -a android.intent.action.BOOT_COMPLETED -p com.miui.powerkeeper"

# 5) 重新应用防冻结定制（幂等）：
#    - 同步电池白名单（内部会禁用 Joyose 云控接收器，防止官方覆盖）
#    - 若开启了静态保护则一并重跑
RESTORE_FAIL=0
if [ "$DRY_RUN" = "1" ]; then
    echo "[charging] (dry-run) 跳过重新应用防冻结定制"
else
    echo "[charging] 重新同步电池优化白名单到云控（防止官方冻结策略覆盖）..."
    sh "$MODDIR/scripts/sync_battery_whitelist.sh" || RESTORE_FAIL=1
    if flag_enabled enable_static_protect 0; then
        echo "[charging] 重新应用 PowerKeeper 静态保护（全部第三方应用）..."
        sh "$MODDIR/scripts/powerkeeper_patch.sh" || RESTORE_FAIL=1
    fi
    if flag_enabled enable_screen_off_freeze 0; then
        echo "[charging] 重新应用息屏冻结（防止恢复充电撤销冻结）..."
        sh "$MODDIR/scripts/screen_off_freeze.sh" apply || RESTORE_FAIL=1
    fi
fi

echo "[charging] 恢复指令已执行"
VERSION=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | head -n 1)
echo "[charging] 当前模块: ${VERSION:-未知}"
echo "[charging] 注意：若仍未恢复快充，请重启一次。"

# 6) 充电状态诊断（只读，方便定位快充问题）
echo ""
echo "[charging] ---- 充电状态诊断 ----"
echo "  battery: status=$(cat /sys/class/power_supply/battery/status 2>/dev/null || echo N/A) capacity=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null || echo N/A)% temp=$(cat /sys/class/power_supply/battery/temp 2>/dev/null || echo N/A) current=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null || echo N/A)uA voltage=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null || echo N/A)uV"
for t in /sys/class/power_supply/*; do
    [ -d "$t" ] || continue
    [ -f "$t/type" ] || continue
    echo "  supply $(basename "$t"): type=$(cat "$t/type" 2>/dev/null) status=$(cat "$t/status" 2>/dev/null) charge_type=$(cat "$t/charge_type" 2>/dev/null) online=$(cat "$t/online" 2>/dev/null)"
done
echo "  热控进程: $(ps -A 2>/dev/null | grep -E 'thermal-engine|mi_thermald|mimd' | grep -v grep | awk '{print $NF}' | tr '\n' ' ')"
echo "[charging] 已保持 Joyose 云控接收器禁用，官方冻结策略不会覆盖防冻结定制。"

# 检测是否存在「电池热保护限流」：电池温度过高时内核 BCL 会压低充电电流，
# 这是系统安全策略，与模块无关，也不是重启/恢复服务能解除的。
BATT_TEMP="$(cat /sys/class/power_supply/battery/temp 2>/dev/null)"
CCL="$(cat /sys/class/power_supply/battery/charge_control_limit 2>/dev/null)"
CCL_MAX="$(cat /sys/class/power_supply/battery/charge_control_limit_max 2>/dev/null)"
if [ -n "$BATT_TEMP" ] && [ "$BATT_TEMP" -ge 410 ] 2>/dev/null; then
    BATT_DEG=$((BATT_TEMP / 10))
    BATT_TENTH=$((BATT_TEMP % 10))
    echo "[charging] ⚠ 检测到电池温度过高（${BATT_DEG}.${BATT_TENTH}°C），快充被系统热保护限流，与模块无关。"
    echo "[charging]   请拔掉充电器、移开遮挡、避免一边充一边用，等电池降到 ~40°C 以下再试；"
    echo "[charging]   或到「手机管家→电池」查看是否开启了充电保护。热保护被触发时点 [8] 无法解除。"
elif [ -n "$CCL" ] && [ -n "$CCL_MAX" ] && [ "$CCL" -ge "$((CCL_MAX - 1))" ] 2>/dev/null; then
    echo "[charging] ⚠ 内核充电限流已达上限（charge_control_limit=$CCL/$CCL_MAX），多数由电池温度/健康度触发，与模块无关。"
fi
if [ "$RESTORE_FAIL" = "1" ]; then
    echo "[charging] 部分步骤失败，请查看上方日志" >&2
    exit 1
fi
