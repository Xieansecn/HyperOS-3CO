#!/system/bin/sh
# 可复现打包脚本
# 用法: sh build_module.sh
# 从 module/ 目录生成可刷入 KernelSU/Magisk 的 zip（排除开发产物）
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/module"
OUT="$ROOT/HyperOS-3CO-260825(manet).zip"

if [ ! -d "$SRC" ]; then
    echo "未找到模块目录: $SRC"
    exit 1
fi

cd "$SRC"

# 统一权限：脚本 0755，文档/配置 0644
chmod 0755 action.sh customize.sh service.sh uninstall.sh scripts/*.sh META-INF/com/google/android/update-binary bin/sqlite3 2>/dev/null || true
chmod 0644 README.md module.prop system.prop scripts/utils.sh META-INF/com/google/android/updater-script webroot/* 2>/dev/null || true

rm -f "$OUT"
zip -r9 -X "$OUT"     META-INF     README.md     action.sh customize.sh service.sh uninstall.sh module.prop system.prop     bin scripts functions webroot     -x 'config/*' 'dryrun*' 'simjoyose/*' 'tools/*' '*.log' '*.sql'

echo ""
echo "打包完成: $OUT"
unzip -t "$OUT" | tail -n 3
