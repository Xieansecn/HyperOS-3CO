#!/system/bin/sh

# 公共工具函数
# 供 customize.sh / service.sh / action.sh / uninstall.sh / scripts/*.sh 共用

MODDIR="${MODDIR:-$(cd "$(dirname "$0")/.." && pwd)}"
BACKUP_DIR="${BACKUP_DIR:-$MODDIR/config/backups}"
KEEP_BACKUPS="${KEEP_BACKUPS:-5}"

mkdir -p /dev/mount_masks 2>/dev/null || true

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

lock_val() {
    find "$2" -type f | while read -r file; do
        file="$(realpath "$file")"
        umount "$file"
        chown root:root "$file"
        chmod 0644 "$file"
        echo "$1" >"$file"
        chmod 0444 "$file"
    done
}

lock_val_in_path() {
    if [ "$#" = "4" ]; then
        find "$2/" -path "*$3*" -name "$4" -type f | while read -r file; do
            lock_val "$1" "$file"
        done
    else
        find "$2/" -name "$3" -type f | while read -r file; do
            lock_val "$1" "$file"
        done
    fi
}

mask_val() {
    find "$2" -type f | while read -r file; do
        file="$(realpath "$file")"
        lock_val "$1" "$file"

        TIME="$(date "+%s%N")"
        echo "$1" >"/dev/mount_masks/mount_mask_$TIME"
        mount --bind "/dev/mount_masks/mount_mask_$TIME" "$file"
        restorecon -R -F "$file" >/dev/null 2>&1
    done
}

mask_val_in_path() {
    if [ "$#" = "4" ]; then
        find "$2/" -path "*$3*" -name "$4" -type f | while read -r file; do
            mask_val "$1" "$file"
        done
    else
        find "$2/" -name "$3" -type f | while read -r file; do
            mask_val "$1" "$file"
        done
    fi
}

disable_corectl() {
    lock_val_in_path "1" "/sys/devices/system/cpu" "core_ctl" "enable"
    lock_val_in_path "99" "/sys/devices/system/cpu" "core_ctl" "min_cpus"
    lock_val_in_path "99" "/sys/devices/system/cpu" "core_ctl" "max_cpus"
    lock_val_in_path "0" "/sys/devices/system/cpu" "core_ctl" "enable"
}

# 等待指定按键释放（只认 UP），避免长按 repeat / 松开事件被当成第二次按键
wait_key_release() {
    while true; do
        relInfo=$(getevent -qlc 1 | grep "$1" 2>/dev/null)
        case "$relInfo" in
            *"$1"*UP*) break ;;
        esac
    done
    sleep 0.15
}

key_click() {
    while true; do
        sleep 0.1
        keyInfo=$(getevent -qlc 1 | grep KEY_VOLUME)
        if [ -n "$keyInfo" ]; then
            case "$keyInfo" in
                *KEY_VOLUMEUP*)
                    wait_key_release KEY_VOLUMEUP
                    return 0 ;;
                *KEY_VOLUMEDOWN*)
                    wait_key_release KEY_VOLUMEDOWN
                    return 1 ;;
            esac
        fi
    done
}

exec_system() {
    eval "$1" </dev/null 2>&1 | cat
}

reset_joyose_cloud() {
    exec_system "pm clear com.xiaomi.joyose"
    exec_system "am force-stop com.xiaomi.joyose"
    exec_system "pm enable com.xiaomi.joyose/com.xiaomi.joyose.cloud.CloudServerReceiver"
    exec_system "pm enable com.xiaomi.joyose/com.xiaomi.joyose.smartop.SmartOpService"
    exec_system "am startservice com.xiaomi.joyose/com.xiaomi.joyose.smartop.SmartOpService"
    exec_system "am broadcast -a android.intent.action.BOOT_COMPLETED -p com.xiaomi.joyose"
    exec_system "am broadcast com.xiaomi.joyose/com.xiaomi.joyose.cloud.CloudServerReceiver"
    exec_system "am broadcast com.xiaomi.joyose/com.xiaomi.joyose.JoyoseBroadCastReceiver"
}

wait_until_login() {
    while [ "$(getprop sys.boot_completed)" != "1" ]; do
        sleep 1
    done

    until [ -d "/data/data/android" ]; do
        sleep 1
    done

    sleep 15s
}

# ---------- 新增：模块级安全/辅助函数 ----------

# 校验 Android 包名：仅字母/数字/下划线/点，不以点开头/结尾，不含连续点
is_valid_pkg() {
    case "$1" in
        ''|.*|*.|*[!A-Za-z0-9_.]*|*..*) return 1 ;;
        *) return 0 ;;
    esac
}

# 从 stdin 读取（空格或换行分隔），去重并过滤非法包名，每行输出一个
normalize_pkgs() {
    tr -d '\r' 2>/dev/null | tr ' ' '\n' 2>/dev/null | sed '/^[[:space:]]*$/d' | while read -r pkg; do
        if is_valid_pkg "$pkg"; then
            echo "$pkg"
        fi
    done | sort -u
}

# 备份数据库到 $BACKUP_DIR，自动清理只保留最近 $KEEP_BACKUPS 份
# 用法: backup_db <db路径> <标签>
# 优先用 sqlite3 .backup（对并发写安全），失败回退 cp；文件名带 PID 防同秒冲突
backup_db() {
    # 显式关闭备份（dry-run / 测试）
    [ "${BACKUP_DB:-1}" = "0" ] && return 0
    [ -n "$1" ] || return 0
    [ -f "$1" ] || return 0

    mkdir -p "$BACKUP_DIR" || return 1
    DB_BASE="$(basename "$1")"
    DB_LABEL="$2"
    DB_STAMP="$(date '+%Y%m%d-%H%M%S')"
    DB_DEST="$BACKUP_DIR/${DB_LABEL}_${DB_STAMP}_$$_${DB_BASE}"
    if [ -x "${SQLITE:-$MODDIR/bin/sqlite3}" ]; then
        "${SQLITE:-$MODDIR/bin/sqlite3}" "$1" ".backup '$DB_DEST'" 2>/dev/null || cp -f "$1" "$DB_DEST" || return 1
    else
        cp -f "$1" "$DB_DEST" || return 1
    fi
    log "[backup] 已备份 $1 -> $DB_DEST"

    # 只保留最近 KEEP_BACKUPS 份
    OLD_LIST="$(ls -1t "$BACKUP_DIR"/${DB_LABEL}_*_${DB_BASE} 2>/dev/null | sed -n "$((KEEP_BACKUPS + 1)),\$p")"
    if [ -n "$OLD_LIST" ]; then
        for f in $OLD_LIST; do
            rm -f "$f"
        done
    fi
    return 0
}

# sqlite 统一入口：busy_timeout 10s + 出错即停，避免并发写直接失败
sqlite3_x() {
    "${SQLITE:-$MODDIR/bin/sqlite3}" -cmd ".timeout 10000" -cmd ".bail on" "$@"
}

# 模块级互斥锁：串行化所有写库入口（开机/动作/刷入/卸载可能并发）
# 由直接写库的叶子脚本入口自行调用；父脚本（action/customize/service/restore）
# 不得持锁调用子脚本，避免自锁死等。
#
# 锁文件路径统一：安装期 MODDIR=modules_update/<id>、运行期=modules/<id>，
# 用模块 id 派生固定路径，使「安装写入」与「旧实例开机写入」共用同一把锁。
# 可用环境变量覆盖（测试/特殊环境）。
MODULE_LOCK_FILE="${MODULE_LOCK_FILE:-/data/adb/modules/.$(basename "$MODDIR").module.lock}"
MODULE_LOCK_DIR="${MODULE_LOCK_DIR:-/data/adb/modules/.$(basename "$MODDIR").module.lock.d}"

# flock 非阻塞轮询：三平台（toybox/busybox/GNU）均支持 `flock -n <fd>`；
# toybox/busybox 无 -w，超时由轮询实现。调用前须已 `exec 9>锁文件`。
# 返回 0=已持锁，1=超时。
flock_wait() {
    LOCK_TIMEOUT="${1:-60}"
    i=0
    while ! flock -n 9 2>/dev/null; do
        i=$((i + 1))
        if [ $i -ge "$LOCK_TIMEOUT" ]; then
            return 1
        fi
        sleep 1
    done
    return 0
}

MODULE_LOCKED=0
ensure_module_lock() {
    [ "$MODULE_LOCKED" = "1" ] && return 0
    mkdir -p "$MODDIR/config" 2>/dev/null || true
    if command -v flock >/dev/null 2>&1; then
        # flock 由内核在进程退出/被杀时自动释放，正配 WebUI 看门狗。
        # toybox flock 仅支持 `flock [-sxun] fd`（无 -w），统一 -n 轮询。
        exec 9>"$MODULE_LOCK_FILE"
        if ! flock_wait "${MODULE_LOCK_TIMEOUT:-60}"; then
            echo "[lock] 获取模块锁超时（可能有任务正在运行），中止"
            exit 1
        fi
    else
        # mkdir 原子锁兜底：带 PID 存活检测与超时
        LOCK_DIR="$MODULE_LOCK_DIR"
        i=0
        while ! mkdir "$LOCK_DIR" 2>/dev/null; do
            if [ -f "$LOCK_DIR/pid" ]; then
                LPID="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
                if [ -n "$LPID" ] && ! kill -0 "$LPID" 2>/dev/null; then
                    rm -rf "$LOCK_DIR" 2>/dev/null
                    continue
                fi
            elif [ $i -ge 3 ]; then
                # 无 pid 文件的残留目录（持锁者 mkdir 后即被杀）：重试多次后视为陈旧
                rm -rf "$LOCK_DIR" 2>/dev/null
                continue
            fi
            i=$((i + 1))
            if [ $i -ge 600 ]; then
                echo "[lock] 获取模块锁超时（可能有任务正在运行），中止"
                exit 1
            fi
            sleep 0.2
        done
        echo "$$" >"$LOCK_DIR/pid"
        trap 'rm -rf "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM
    fi
    MODULE_LOCKED=1
}

# 重启 PowerKeeper，促使它重新读取云控数据库（可选）
restart_powerkeeper() {
    log "[utils] 强制停止 PowerKeeper，等待系统重新拉起并读取云控..."
    exec_system "am force-stop com.miui.powerkeeper"
    exec_system "am broadcast -a android.intent.action.BOOT_COMPLETED -p com.miui.powerkeeper"
}

# Joyose 写入定制规则后：停止服务并禁用云控接收器，防止官方云控覆盖
joyose_freeze_cloud() {
    log "[utils] 停止 Joyose 并禁用云控接收器..."
    exec_system "am force-stop com.xiaomi.joyose"
    exec_system "pm disable com.xiaomi.joyose/com.xiaomi.joyose.cloud.CloudServerReceiver"
    exec_system "am broadcast -a android.intent.action.BOOT_COMPLETED -p com.xiaomi.joyose"
}

# 恢复 Joyose 云控接收器（卸载/异常恢复用）
joyose_enable_cloud() {
    log "[utils] 恢复 Joyose 云控接收器..."
    exec_system "pm enable com.xiaomi.joyose/com.xiaomi.joyose.cloud.CloudServerReceiver"
    exec_system "am broadcast -a android.intent.action.BOOT_COMPLETED -p com.xiaomi.joyose"
}

# 从模块配置文件读取开关；文件不存在时返回默认值 ($2)
flag_enabled() {
    if [ -f "$MODDIR/config/$1" ]; then
        [ "$(cat "$MODDIR/config/$1")" = "1" ]
    else
        [ "$2" = "1" ]
    fi
}

# From Pandora Kernel Project
