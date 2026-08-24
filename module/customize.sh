#!/system/bin/sh

FUNCTIONS="$MODPATH/functions"
Hardware=$(getprop ro.hardware)
DEVICE=$(getprop ro.product.device)

set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/customize.sh" 0 0 0755
set_perm "$MODPATH/scripts/joyose_config.sh" 0 0 0755
set_perm "$MODPATH/scripts/powerkeeper_patch.sh" 0 0 0755
set_perm "$MODPATH/scripts/sync_battery_whitelist.sh" 0 0 0755
set_perm "$MODPATH/scripts/refresh_follow_system.sh" 0 0 0755
set_perm "$MODPATH/scripts/backup_cloud_db.sh" 0 0 0755
set_perm "$MODPATH/scripts/restore_charging.sh" 0 0 0755
set_perm "$MODPATH/scripts/check_status.sh" 0 0 0755
set_perm "$MODPATH/scripts/screen_off_freeze.sh" 0 0 0755
set_perm "$MODPATH/scripts/freeze_scheduler.sh" 0 0 0755
set_perm "$MODPATH/scripts/api.sh" 0 0 0755
set_perm "$MODPATH/scripts/reset_module.sh" 0 0 0755
set_perm "$MODPATH/scripts/action_lib.sh" 0 0 0644
set_perm "$MODPATH/screen_off_freeze_whitelist" 0 0 0644
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/scripts/utils.sh" 0 0 0644
set_perm "$MODPATH/module.prop" 0 0 0644
set_perm "$MODPATH/system.prop" 0 0 0644
set_perm "$MODPATH/README.md" 0 0 0644

MODDIR="$MODPATH"
. "$MODPATH/scripts/utils.sh"

CONFIG_DIR="$MODPATH/config"
mkdir -p "$CONFIG_DIR"

if [ ! -d "$MODPATH/functions/$DEVICE" ]; then
    abort "- 未适配机型，停止刷入！"
fi

if [ "$KSU" = "true" ]; then
    echo "- KernelSU 用户空间版本号: $KSU_VER_CODE"
    echo "- KernelSU 内核空间版本号: $KSU_KERNEL_VER_CODE"
    if [ "$KSU_KERNEL_VER_CODE" -lt 11089 ]; then
        echo "*********************************"
        echo "! 请安装 KernelSU 管理器 v0.6.2 或更高版本"
        abort "*********************************"
    fi
    RootImplement="KernelSU"
    version="$KSU_VER_CODE"
    versionCode="$KSU_KERNEL_VER_CODE"
elif [ "$APATCH" = "true" ]; then
    echo "- APatch 版本名: $APATCH_VER"
    echo "- APatch 版本号: $APATCH_VER_CODE"
    RootImplement="APatch"
    version="$APATCH_VER"
    versionCode="$APATCH_VER_CODE"
else
    echo "- Magisk 版本名: $MAGISK_VER"
    echo "- Magisk 版本号: $MAGISK_VER_CODE"
    RootImplement="Magisk"
    version="$MAGISK_VER"
    versionCode="$MAGISK_VER_CODE"
    if [ "$MAGISK_VER_CODE" -lt 26000 ]; then
        echo "*********************************"
        echo "! 请安装 Magisk 26.0+"
        abort "*********************************"
    fi
fi

wait_db() {
    cp -rf "$FUNCTIONS/$DEVICE" "$MODPATH"
    rm -rf "$FUNCTIONS"

    reset_joyose_cloud

    wait_time_smart=0
    while [ ! -f "/data/data/com.xiaomi.joyose/databases/SmartP.db" ]; do
        sleep 1
        wait_time_smart=$((wait_time_smart + 1))
        if [ "${wait_time_smart}" -ge 10 ]; then
            joyose_freeze_cloud
            abort "- 云控文件：SmartP.db 获取失败；请自查joy是否正常运行"
        fi
    done

    wait_time_teg=0
    while [ ! -f "/data/data/com.xiaomi.joyose/databases/teg_config.db" ]; do
        sleep 1
        wait_time_teg=$((wait_time_teg + 1))
        if [ "${wait_time_teg}" -ge 10 ]; then
            joyose_freeze_cloud
            abort "- 云控文件：teg_config.db 获取失败；请自查joy是否正常运行"
        fi
    done
}

echo "*********************************"
echo "-       刷入前是否阅读 [更新日志/说明]"
echo "          音量↑:[是]│音量↓:[否]"

if key_click; then
    echo "              ✔"

    # 清理系统包缓存，确保 Joyose/PowerKeeper 重新解析云控信息
    rm -rf /data/system/package_cache
    wait_db
    sh "$MODPATH/scripts/joyose_config.sh" || abort "- Joyose 云控写入/冻结失败"

    echo "- 备份当前云控数据库原文件到 config/backups ..."
    sh "$MODPATH/scripts/backup_cloud_db.sh"

    echo ""
    echo "-        是否同步 [电池优化白名单到云控]"
    echo "          音量↑:[同步]│音量↓:[跳过]"
    if key_click; then
        echo "              ✔"
        echo "1" > "$CONFIG_DIR/enable_battery_sync"
        sh "$MODPATH/scripts/sync_battery_whitelist.sh"
    else
        echo "0" > "$CONFIG_DIR/enable_battery_sync"
        echo "                        ✔"
    fi

    echo ""
    echo "-        是否启用 [PowerKeeper静态保护全部第三方应用]"
    echo "          音量↑:[启用]│音量↓:[跳过]"
    if key_click; then
        echo "              ✔"
        echo "1" > "$CONFIG_DIR/enable_static_protect"
        sh "$MODPATH/scripts/powerkeeper_patch.sh"
    else
        echo "0" > "$CONFIG_DIR/enable_static_protect"
        echo "                        ✔"
    fi

    echo ""
    echo "-        是否启用 [高刷跟随系统刷新率]"
    echo "          音量↑:[启用]│音量↓:[关闭]"
    if key_click; then
        echo "              ✔"
        echo "1" > "$CONFIG_DIR/enable_refresh_follow"
        sh "$MODPATH/scripts/refresh_follow_system.sh"
    else
        echo "0" > "$CONFIG_DIR/enable_refresh_follow"
        echo "                        ✔"
    fi

    echo ""
    echo "-        是否启用 [息屏冻结]（默认关闭）"
    echo "  ⚠ 非豁免三方应用息屏后可能被冻结/清理（省电；B 站等默认不豁免）"
    echo "  可随时在 WebUI/菜单 [9] 立即启用、[10] 即时恢复"
    echo "          音量↑:[启用]│音量↓:[跳过(推荐)]"
    if key_click; then
        echo "              ✔"
        echo "1" > "$CONFIG_DIR/enable_screen_off_freeze"
        sh "$MODPATH/scripts/screen_off_freeze.sh" apply
    else
        echo "0" > "$CONFIG_DIR/enable_screen_off_freeze"
        echo "                        ✔"
    fi
else
    abort "                        ✔"
fi

if [ "$Hardware" = "qcom" ]; then
    echo ""
    echo "-        是否添加 [禁用GPU Boost]"
    echo "          音量↑:[是]│音量↓:[否]"

    if key_click; then
        echo "              ✔"
        echo "true" >"$MODPATH/config/gpu_boost"
    else
        echo "                        ✔"
        echo "false" >"$MODPATH/config/gpu_boost"
    fi
fi

echo "*********************************"

echo "- 模块已执行，请重启😇"
