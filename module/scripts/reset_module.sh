#!/system/bin/sh
# 一键还原（清理式）：撤销模块写入的"限制/冻结"，恢复云控接收器，让官方云控自行重拉。
# 与"恢复备份"不同：本功能不做基线写回，也不 pm clear 手机管家（PowerKeeper/安全中心），
# 只清理模块写入的冻结/限制项并解冻三方应用，恢复 Joyose 云控与系统服务，之后交由云控重拉。
# 用法：scripts/reset_module.sh（WebUI「重置」按钮 / api.sh reset / 终端）
# 提示：恢复前会先备份当前库（可回滚）。

MODDIR=$(cd "$(dirname "$0")/.." && pwd)
. "$MODDIR/scripts/utils.sh"

SQLITE="${SQLITE:-$MODDIR/bin/sqlite3}"
CC_DB="${CC_DB:-/data/data/com.miui.powerkeeper/databases/cloud_configure.db}"
UC_DB="${UC_DB:-/data/data/com.miui.powerkeeper/databases/user_configure.db}"
HR_DB="${HR_DB:-/data/data/com.miui.powerkeeper/databases/highrefreshrate.db}"

echo "[reset] 开始还原（清理式，不写回备份，让云控重拉）..."

# 0) 先备份当前状态，便于回滚（只作安全网，不作为恢复手段）
backup_db "$CC_DB" cloud_configure
backup_db "$UC_DB" user_configure
backup_db "$HR_DB" highrefreshrate

# 1) 解除息屏冻结（最小化解冻，不重加模块白名单）：清掉模块写入的"限制"键，
#    并把三方应用 bgControl 统一回 noRestrict（系统唯一硬豁免，不会被冻结），
#    其余交给云控重拉时按官方值覆盖。
ensure_module_lock
# ① misc 里的息屏清理 / 睡眠模式开关（模块强制置 true 的）
sqlite3_x "$UC_DB" "DELETE FROM misc WHERE name IN ('screen_off_clean_app','sleep_mode_cloud');" \
    || echo "[reset] 提示：清除 misc 限制键失败"
# ② 内核级冻结键（仅 enable_kernel_freeze 时写入）
sqlite3_x "$CC_DB" "DELETE FROM GlobalFeatureTable WHERE configureName IN ('FrozenControlStatus','FrozenControlNewStatus');" \
    || echo "[reset] 提示：清除内核冻结键失败"
# ③ 三方应用 bgControl -> noRestrict（解除可冻结态）
THIRD="$(pm list packages -3 2>/dev/null | sed 's/^package://' | tr '\n' ' ')"
TMP_SQL="$MODDIR/config/.reset_unfreeze.sql.$$"
{
    echo "BEGIN TRANSACTION;"
    for pkg in $THIRD; do
        case "$pkg" in ''|*[^A-Za-z0-9_.]*) continue ;; esac
        printf "INSERT OR REPLACE INTO userTable (userId, pkgName, lastConfigured, bgControl, bgLocation, bgDelayMin) SELECT 0, '%s', lastConfigured, 'noRestrict', bgLocation, bgDelayMin FROM userTable WHERE pkgName='%s';\n" "$pkg" "$pkg"
    done
    echo "COMMIT;"
} >"$TMP_SQL"
sqlite3_x "$UC_DB" ".read $TMP_SQL" && echo "[reset] 三方应用已恢复 noRestrict（不再被冻结）" || echo "[reset] 提示：恢复 bgControl 失败"
rm -f "$TMP_SQL" 2>/dev/null || true
module_unlock

# 3) 恢复 Joyose 云控接收器 + 清除 Joyose 数据（回出厂，重新拉取官方云控）
joyose_enable_cloud
exec_system "pm clear com.xiaomi.joyose"
exec_system "am force-stop com.xiaomi.joyose"

# 4) 恢复 system service.sh 停过的系统服务 / 解除 bind mount
do_start() {
    start "$1" 2>/dev/null || setprop ctl.start "$1" 2>/dev/null || true
}
for i in vendor.cnss_diag vendor.tcpdump thermal-engine cnss-daemon; do
    do_start "$i"
done
for svc in mimd-service mimd-service2_0; do
    do_start "$svc"
done
do_start "mi_thermald"

# 解除模块 bind mount（若有残留）
while read -r src dst rest; do
    case "$src" in
        /dev/mount_masks/*) umount "$dst" 2>/dev/null || true ;;
    esac
done < /proc/mounts

# 5) 重启 PowerKeeper 重读（此时不再被模块限制键约束，云端将可重拉）
restart_powerkeeper

echo "[reset] 已还原。说明："
echo "  - Joyose 云控接收器已恢复，游戏优化将重新拉取官方云控"
echo "  - 息屏冻结限制键已清除，三方应用已恢复 noRestrict"
echo "  - 手机管家（PowerKeeper/安全中心）用户数据未清除（无 pm clear）"
echo "  - 官方云控重拉需联网并等待；若稍后仍未更新，请到手机管家手动刷新/重拉一次"
echo "[reset] 若需还原为模块定制，重新执行 action.sh 覆盖即可；如需回滚本次重置，用 config/backups 最新备份。"
