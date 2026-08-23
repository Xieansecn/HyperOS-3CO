#!/system/bin/sh

MODDIR=${0%/*}
. "$MODDIR/scripts/utils.sh"

wait_until_login() {
    # in case of /data encryption is disabled
    while [ "$(getprop sys.boot_completed)" != "1" ]; do
        sleep 1
    done

    # in case of the user unlocked the screen
    until [ -d "/data/data/android" ]; do
        sleep 1
    done
}
uninstall_module() {
    # 尽力加锁（非致命）：模块任务运行中则短等；拿不到锁不阻塞卸载（pm clear 幂等）
    mkdir -p "$MODDIR/config" 2>/dev/null || true
    if command -v flock >/dev/null 2>&1; then
        # 与运行期/安装期共用同一锁文件（utils.sh MODULE_LOCK_FILE）
        exec 9>"$MODULE_LOCK_FILE"
        flock_wait 5 || echo "[uninstall] 模块任务可能仍在运行，继续卸载"
    fi
    # 与 /storage/emulated/0/恢复joy(异常时使用).sh 同款清理机制
    exec_system "pm clear com.xiaomi.joyose"
    exec_system "pm clear com.android.htmlviewer"
    exec_system "pm clear com.miui.daemon"
    exec_system "pm clear com.miui.powerkeeper"
    exec_system "pm clear com.miui.securitycenter"
    exec_system "am force-stop com.xiaomi.joyose"

    # 恢复 Joyose 云控与 SmartOp 服务
    exec_system "pm enable com.xiaomi.joyose/com.xiaomi.joyose.cloud.CloudServerReceiver"
    exec_system "pm enable com.xiaomi.joyose/com.xiaomi.joyose.smartop.SmartOpService"
    exec_system "am startservice com.xiaomi.joyose/com.xiaomi.joyose.smartop.SmartOpService"
    exec_system "am broadcast -a android.intent.action.BOOT_COMPLETED -p com.xiaomi.joyose"
    exec_system "am broadcast com.xiaomi.joyose/com.xiaomi.joyose.cloud.CloudServerReceiver"
    exec_system "am broadcast com.xiaomi.joyose/com.xiaomi.joyose.JoyoseBroadCastReceiver"
    exec_system "am broadcast -a android.intent.action.BOOT_COMPLETED -n com.xiaomi.joyose/com.xiaomi.joyose.JoyoseBroadCastReceiver"

    # 恢复模块 service.sh 停止过的系统服务
    for i in vendor.cnss_diag vendor.tcpdump thermal-engine cnss-daemon; do
        exec_system "start $i"
    done
    for svc in mimd-service mimd-service2_0; do
        exec_system "start $svc"
    done
}

if [ "$1" = "wait" ]; then
	uninstall_module
else
	{
		# 清理 Dalvik 缓存，确保卸载后系统重新编译/恢复
		rm -rf /data/dalvik-cache/*
		wait_until_login
		uninstall_module
	} &
fi