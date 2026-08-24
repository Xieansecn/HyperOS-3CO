#!/system/bin/sh
# 夜间定时息屏冻结守护
# 在 config/freeze_start_time ~ freeze_end_time 窗口内自动 apply 息屏冻结，
# 离开窗口自动 restore（若冻结仍处于生效态）。窗口期间的冻结状态由本守护管理；
# 手动 freeze/unfreeze 可随时覆盖，但离开窗口时会按定时语义恢复冻结。
# 由 service.sh 在 enable_nightly_freeze=1 时后台启动；关闭开关后自清理退出。
MODDIR=$(cd "$(dirname "$0")/.." && pwd)
. "$MODDIR/scripts/utils.sh"

INTERVAL="${FREEZE_SCHEDULER_INTERVAL:-300}"
NIGHTLY_STATE="$MODDIR/config/.nightly_active"
PID_FILE="$MODDIR/config/.nightly_scheduler.pid"

# 单实例保护：已在运行则退出（防止重复开机/手动启动叠加）
if [ -f "$PID_FILE" ]; then
    OLD_PID="$(cat "$PID_FILE" 2>/dev/null)"
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        exit 0
    fi
fi
mkdir -p "$MODDIR/config" 2>/dev/null || true
echo "$$" >"$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT INT TERM

in_window() {
    START="$(cat "$MODDIR/config/freeze_start_time" 2>/dev/null || echo "23:00")"
    END="$(cat "$MODDIR/config/freeze_end_time" 2>/dev/null || echo "07:00")"
    NOW_N="$(date '+%H%M' 2>/dev/null)"
    S_N="$(printf '%s' "$START" | tr -d ':')"
    E_N="$(printf '%s' "$END" | tr -d ':')"
    case "$NOW_N" in ''|*[!0-9]*) return 1 ;; esac
    case "$S_N" in ''|*[!0-9]*) return 1 ;; esac
    case "$E_N" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$S_N" -eq "$E_N" ]; then
        # start=end：视为空窗口（永不进入），避免歧义
        return 1
    fi
    if [ "$S_N" -lt "$E_N" ]; then
        [ "$NOW_N" -ge "$S_N" ] && [ "$NOW_N" -lt "$E_N" ]
    else
        [ "$NOW_N" -ge "$S_N" ] || [ "$NOW_N" -lt "$E_N" ]
    fi
}

log_n() {
    echo "[nightly-freeze] $*"
}

while true; do
    if ! flag_enabled enable_nightly_freeze 0; then
        # 定时已关闭：若本守护之前 apply 过则恢复，然后退出
        if [ -f "$NIGHTLY_STATE" ]; then
            log_n "定时已关闭，恢复冻结并退出"
            PK_RESTART=1 sh "$MODDIR/scripts/screen_off_freeze.sh" restore >/dev/null 2>&1 && rm -f "$NIGHTLY_STATE"
        fi
        exit 0
    fi
    if in_window; then
        if [ ! -f "$NIGHTLY_STATE" ]; then
            log_n "进入夜间窗口（$(cat "$MODDIR/config/freeze_start_time" 2>/dev/null || echo 23:00) 起），应用息屏冻结"
            if PK_RESTART=1 sh "$MODDIR/scripts/screen_off_freeze.sh" apply >/dev/null 2>&1; then
                : >"$NIGHTLY_STATE"
            else
                log_n "apply 失败，本次不标记（下轮重试）"
            fi
        fi
    else
        if [ -f "$NIGHTLY_STATE" ]; then
            log_n "离开夜间窗口，恢复冻结"
            PK_RESTART=1 sh "$MODDIR/scripts/screen_off_freeze.sh" restore >/dev/null 2>&1 && rm -f "$NIGHTLY_STATE"
        fi
    fi
    sleep "$INTERVAL"
done
