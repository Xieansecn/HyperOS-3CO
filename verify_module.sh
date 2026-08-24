#!/system/bin/sh
# 模块校验脚本：语法 / JSON / 权限 / zip 完整性
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/module"
ZIP="$ROOT/HyperOS-3CO-260825(manet).zip"
FAIL=0

echo "==== 1. shell 语法检查 ===="
for f in "$SRC"/action.sh "$SRC"/customize.sh "$SRC"/service.sh "$SRC"/uninstall.sh "$SRC"/scripts/*.sh; do
    if sh -n "$f" 2>/dev/null; then
        echo "  OK  $f"
    else
        echo "  FAIL $f"
        FAIL=1
    fi
done

echo "==== 2. JSON 校验 ===="
JSON_COUNT=0
for f in $(find "$SRC/functions" -name '*.json' | sort); do
    if python3 -m json.tool "$f" >/dev/null 2>&1; then
        JSON_COUNT=$((JSON_COUNT + 1))
    else
        echo "  FAIL $f"
        FAIL=1
    fi
done
echo "  通过 JSON 文件数: $JSON_COUNT"

echo "==== 3. 包内脚本权限 ===="
for f in action.sh customize.sh service.sh uninstall.sh scripts/joyose_config.sh scripts/powerkeeper_patch.sh scripts/sync_battery_whitelist.sh scripts/refresh_follow_system.sh scripts/backup_cloud_db.sh scripts/restore_charging.sh scripts/check_status.sh META-INF/com/google/android/update-binary; do
    if [ ! -x "$SRC/$f" ]; then
        echo "  FAIL 不可执行: $f"
        FAIL=1
    fi
done
echo "  可执行权限检查完成"

echo "==== 4. zip 校验 ===="
if [ -f "$ZIP" ]; then
    if unzip -t "$ZIP" >/dev/null 2>&1; then
        echo "  zip 完整性 OK"
    else
        echo "  FAIL zip 损坏"
        FAIL=1
    fi
    echo "  包内不应包含的目录检查:"
    if unzip -l "$ZIP" | grep -E 'dryrun|simjoyose|config/battery_sync' >/dev/null 2>&1; then
        echo "    FAIL 包内混入开发产物"
        unzip -l "$ZIP" | grep -E 'dryrun|simjoyose|config/battery_sync'
        FAIL=1
    else
        echo "    未混入开发产物 OK"
    fi
else
    echo "  未找到 zip: $ZIP（先运行 build_module.sh）"
fi

echo ""
if [ "$FAIL" = "0" ]; then
    echo "==== 校验全部通过 ===="
else
    echo "==== 存在失败项 ===="
    exit 1
fi
