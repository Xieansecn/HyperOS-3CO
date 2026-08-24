#!/system/bin/sh

MODDIR=${0%/*}

. "$MODDIR/scripts/utils.sh"

init_node_mtk() {
	mask_val "TTJ 105000 105000 105000" /sys/kernel/thermal/ttj
	mask_val "MAX_TTJ 105000 105000 105000" /sys/kernel/thermal/max_ttj
	mask_val "MIN_TTJ 105000" /sys/kernel/thermal/min_ttj

	mask_val "1" /proc/mtk_lpm/cpuidle/enable
	mask_val "0" /proc/mtk_lpm/cpuidle/cpu_pf_en
	mask_val "1" /proc/mtk_lpm/cpuidle/cpu_ret_en

	for svc in power-hal-1-0 vendor.mtkpower_service.mediatek vendor.mtkpower_applist-default frs; do
		stop $svc
	done

	for svc in power-hal-1-0 vendor.mtkpower_service.mediatek vendor.mtkpower_applist-default; do
		start $svc
	done
}

init_node_qcom() {
    if [ "$(cat "$MODDIR/config/gpu_boost" 2>/dev/null)" = "true" ]; then
        kgsl="/sys/class/kgsl/kgsl-3d0"
        NUM_PWRLVL="$(cat $kgsl/num_pwrlevels)"
        MIN_PWRLVL="$((NUM_PWRLVL - 1))"
        lock_val "2147483647" /sys/class/devfreq/*kgsl-3d0/max_freq
        lock_val "0" /sys/class/devfreq/*kgsl-3d0/min_freq
        lock_val "2147483647" $kgsl/max_gpu_clk
        lock_val "2147483647" $kgsl/max_clock_mhz
        lock_val "0" $kgsl/min_clock_mhz
        lock_val "$MIN_PWRLVL" $kgsl/default_pwrlevel
        lock_val "$MIN_PWRLVL" $kgsl/min_pwrlevel
        lock_val "0" $kgsl/max_pwrlevel
        lock_val "0" $kgsl/thermal_pwrlevel
        lock_val "0" $kgsl/throttling
        lock_val "0" $kgsl/force_bus_on
        lock_val "0" $kgsl/force_clk_on
        lock_val "0" $kgsl/force_no_nap
        lock_val "0" $kgsl/force_rail_on
        lock_val "0" $kgsl/bcl
        lock_val "0" $kgsl/cxl
        lock_val "100" $kgsl/devfreq/mod_percent
    fi

    mask_val_in_path "0" "/proc/sys/walt/input_boost" "*"
}

init_io_config() {
    for sd in /sys/block/*; do
		lock_val "none" "$sd/queue/scheduler"
		lock_val "0" "$sd/queue/iostats"
		lock_val "2" "$sd/queue/nomerges"
		lock_val "128" "$sd/queue/read_ahead_kb"
		lock_val "128" "$sd/bdi/read_ahead_kb"
	done
}

# 性能热控调优（可能影响充电/温控，默认关闭）
init_thermal_perf_config() {
    VENDOR="$(getprop ro.hardware)"
    case "$VENDOR" in
        qcom)
            mask_val_in_path "0" "/sys/devices/system/cpu/qcom_lpm" "*disable*"
            ;;
        mt*)
            init_node_mtk
            ;;
    esac

    for i in vendor.cnss_diag vendor.tcpdump thermal-engine cnss-daemon; do
        stop $i 2>/dev/null || true
    done
    killall -9 mi_thermald 2>/dev/null || true
    for svc in mimd-service mimd-service2_0; do
        stop $svc 2>/dev/null || true
    done
}

init_platform_config() {
    VENDOR="$(getprop ro.hardware)"
    case "$VENDOR" in
    qcom)
        init_node_qcom
        ;;
    mt*)
        # 联发科热控相关已移至 enable_perf_thermal，默认不做
        ;;
    esac

    init_io_config
}

wait_until_login
init_platform_config

# ---- 性能热控调优（默认关闭，避免影响快充/温控） ----
# 需要时手动开启: echo 1 > /data/adb/modules/Asphyxia/config/enable_perf_thermal
if flag_enabled enable_perf_thermal 0; then
    log "[module] 性能热控调优已启用（可能影响充电/温控）..."
    init_thermal_perf_config
fi

# ---- 定制功能：按刷入时选择的开关执行 ----
# 开关文件由 customize.sh 写入；旧版本升级未写入时按默认值运行。

if flag_enabled enable_battery_sync 1; then
    log "[module] 开机同步电池优化白名单到云控..."
    sh "$MODDIR/scripts/sync_battery_whitelist.sh"
fi

if flag_enabled enable_static_protect 0; then
    log "[module] 开机应用 PowerKeeper 静态保护补丁（全部第三方应用）..."
    sh "$MODDIR/scripts/powerkeeper_patch.sh"
fi

if flag_enabled enable_refresh_follow 1; then
    log "[module] 开机应用高刷跟随系统刷新率策略..."
    sh "$MODDIR/scripts/refresh_follow_system.sh"
fi

# ---- 息屏冻结（默认关；开启后非豁免三方息屏可被冻结/清理） ----
if flag_enabled enable_screen_off_freeze 0; then
    log "[module] 开机应用息屏冻结策略..."
    sh "$MODDIR/scripts/screen_off_freeze.sh" apply
fi

# ---- 收尾 ----
# 若任一写库功能已执行，重启 PowerKeeper 一次，让内存策略与库一致（C5）
if flag_enabled enable_battery_sync 1 || flag_enabled enable_static_protect 0 || flag_enabled enable_refresh_follow 1 || flag_enabled enable_screen_off_freeze 0; then
    log "[module] 重启 PowerKeeper 以重新读取云控..."
    restart_powerkeeper
fi

# 标记开机初始化完成（restore_charging 据此提示）
mkdir -p "$MODDIR/config" 2>/dev/null || true
: >"$MODDIR/config/.boot_init_done"
