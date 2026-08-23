#!/system/bin/sh
# 备份云控数据库原文件到 config/backups（保留最近5份）
MODDIR=$(cd "$(dirname "$0")/.." && pwd)
. "$MODDIR/scripts/utils.sh"

SQLITE="${SQLITE:-$MODDIR/bin/sqlite3}"
CC_DB="${CC_DB:-/data/data/com.miui.powerkeeper/databases/cloud_configure.db}"
UC_DB="${UC_DB:-/data/data/com.miui.powerkeeper/databases/user_configure.db}"
JOYOSE_DB="${JOYOSE_DB:-/data/data/com.xiaomi.joyose/databases/teg_config.db}"
HR_DB="${HR_DB:-/data/data/com.miui.powerkeeper/databases/highrefreshrate.db}"

echo "[backup] 备份目录: $BACKUP_DIR"
# 写库互斥锁：备份与写库互斥，避免备份到写了一半的库
ensure_module_lock
backup_db "$CC_DB" cloud_configure
backup_db "$UC_DB" user_configure
backup_db "$JOYOSE_DB" joyose_teg
backup_db "$HR_DB" highrefreshrate

echo "[backup] 当前备份列表:"
ls -lt "$BACKUP_DIR" 2>/dev/null | head -n 10
echo "[backup] 备份完成"