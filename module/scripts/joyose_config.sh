#!/system/bin/sh

MODDIR=$(cd "$(dirname "$0")/.." && pwd)

. "$MODDIR/scripts/utils.sh"

mkdir -p "$MODDIR/config"

compact_json() {
    [ ! -f "$1" ] && return

    sed -i ':a;N;$!ba;s/\n//g' "$1"
}

# 单行 JSON 字符串数组
build_pkg_json_array() {
    first=1
    for app in $1; do
        is_valid_pkg "$app" || continue
        if [ "$first" = "1" ]; then
            printf '"%s"' "$app"
            first=0
        else
            printf ',"%s"' "$app"
        fi
    done
}

# 动态获取设备全部第三方应用（THIRD_PARTY_APPS 环境变量可覆盖，便于 dry-run 测试）
get_third_party_apps() {
    if [ -n "${THIRD_PARTY_APPS:-}" ]; then
        printf '%s\n' "$THIRD_PARTY_APPS" | normalize_pkgs
    else
        pm list packages -3 2>/dev/null | sed -n 's/^package://p' | normalize_pkgs
    fi
}

# 白名单类列表动态注入：按文件类型限定键集，避免误改嵌套同名键
#   common_config -> game_list / support_app（顶层，唯一出现）
#   booster_config -> background_freeze_whitelist（唯一出现；game_list/support_app
#     在 fisr_config.enhance_config / mift_settings 等嵌套调参里同名，不得注入）
# 获取失败时保留原名单。
inject_dynamic_whitelists() {
    TARGET_JSON="$1"
    ALLOWED_KEYS="$2"
    [ -f "$TARGET_JSON" ] || return 0

    if [ -z "${THIRD_PARTY_LIST+x}" ]; then
        THIRD_PARTY_LIST="$(get_third_party_apps)"
    fi
    [ -z "$THIRD_PARTY_LIST" ] && return 0
    JSON_ALL="$(build_pkg_json_array "$THIRD_PARTY_LIST")"
    JSON_FREEZE="$(build_pkg_json_array "$BASE_JOYOSE_WHITELIST $THIRD_PARTY_LIST")"
    [ -n "$JSON_ALL" ] || return 0

    for key in $ALLOWED_KEYS; do
        case "$key" in
            background_freeze_whitelist) NEW_LIST="$JSON_FREEZE" ;;
            *) NEW_LIST="$JSON_ALL" ;;
        esac
        if ! sed -i "s/\"$key\" *: *\[[^]]*\]/\"$key\": [$NEW_LIST]/" "$TARGET_JSON" 2>/dev/null; then
            echo "[joyose] 警告: 动态注入 $key 失败"
        fi
    done
}

gen_teg_config_sql() {
    GEN_JSON="$MODDIR/config/generated/teg_$1.json"
    {
        printf '{"config_name":"%s","group_name":"%s","with_model":false,"enable":true,"version":%s,"params":' "$1" "$1" "$2"
        cat "$3"
        printf '}'
    } >"$GEN_JSON"

    compact_json "$GEN_JSON"

    # 动态白名单注入：键集按模块类型限定（见 inject_dynamic_whitelists 注释）
    case "$1" in
        common_config) INJECT_KEYS="game_list support_app" ;;
        booster_config) INJECT_KEYS="background_freeze_whitelist" ;;
        *) INJECT_KEYS="" ;;
    esac
    [ -n "$INJECT_KEYS" ] && inject_dynamic_whitelists "$GEN_JSON" "$INJECT_KEYS"

    {
        printf "delete from rules where rule_module = '%s';\n" "$1"
        printf "insert into rules (rule_id, rule_version, rule_module, rule_content) values \n"
        printf "(2147483646, 2147483646, '%s', CAST(readfile('%s') AS TEXT));\n" "$1" "$GEN_JSON"
        printf "select changes();\n"
    } >>"$MODDIR/config/generated/joyose_teg.sql"
}

init_joyose_config() {
    TEG_CFG="${JOYOSE_DB:-/data/data/com.xiaomi.joyose/databases/teg_config.db}"
    [ ! -f "$TEG_CFG" ] && return

    # 写库互斥锁：避免与开机任务/其它动作并发写 teg_config.db
    ensure_module_lock

    # 写入前备份
    backup_db "$TEG_CFG" joyose_teg

    if [ "${DRY_RUN:-0}" = "1" ]; then
        echo "[joyose] dry-run：跳过系统服务停止"
    else
        exec_system "am force-stop com.xiaomi.joyose"
    fi
    GEN_DIR="$MODDIR/config/generated"
    case "$GEN_DIR" in
        "$MODDIR"/*) ;;
        *) echo "[joyose] 路径异常，拒绝清理：$GEN_DIR"; return 1 ;;
    esac
    rm -rf "$GEN_DIR"
    mkdir -p "$GEN_DIR"
    : >"$MODDIR/config/generated/joyose_teg.sql"

    DEVICE="${MODULE_DEVICE:-$(getprop ro.product.device)}"
    COMMON_VERSION="2056010101"
    BOOSTER_VERSION="2056010101"
    DEVICE_DIR="$MODDIR/$DEVICE"
    if [ ! -d "$DEVICE_DIR" ]; then
        # 源码目录便于开发测试：设备 JSON 位于 functions/<device>/
        DEVICE_DIR="$MODDIR/functions/$DEVICE"
    fi
    COMMON_JSON="$DEVICE_DIR/common_config.json"
    # 仅允许唯一一个 <device>.json，避免 ls/glob 多匹配导致写入错乱
    set -- "$DEVICE_DIR/"*_"$DEVICE".json
    if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
        echo "[joyose] 未找到唯一的 <device> 优化 JSON ($DEVICE_DIR/*_$DEVICE.json)，拒绝写入"
        return 1
    fi
    BOOSTER_JSON="$1"

    # 动态白名单：一次性获取设备全部第三方应用（获取失败时注入跳过，保留原名单）
    BASE_JOYOSE_WHITELIST="com.xiaomi.joyose com.miui.powerkeeper com.xiaomi.migameservice mcd com.xiaomi.gamecenter.sdk.service"
    THIRD_PARTY_LIST="$(get_third_party_apps)"
    if [ -n "$THIRD_PARTY_LIST" ]; then
        echo "[joyose] 动态白名单应用数量: $(echo "$THIRD_PARTY_LIST" | wc -l)"
    else
        echo "[joyose] 未获取到第三方应用列表，保留原白名单"
    fi

    gen_teg_config_sql "common_config" "$COMMON_VERSION" "$COMMON_JSON"
    gen_teg_config_sql "booster_config" "$BOOSTER_VERSION" "$BOOSTER_JSON"

    # SQL 整体事务化 + 超时/出错即停（C1/C3）：DELETE+INSERT 全部在一个事务内
    SQL_FILE="$MODDIR/config/generated/joyose_teg.sql"
    {
        echo ".timeout 10000"
        echo ".bail on"
        echo "BEGIN;"
        cat "$SQL_FILE"
        echo "COMMIT;"
    } >"$SQL_FILE.wrap.$$" && mv -f "$SQL_FILE.wrap.$$" "$SQL_FILE"

    sqlite3_x "$TEG_CFG" ".read $SQL_FILE" || {
        echo "[joyose] teg_config.db 写入失败"
        return 1
    }

    # 停止 Joyose 并禁用云控接收器，避免官方云控覆盖定制内容
    if [ "${DRY_RUN:-0}" = "1" ]; then
        echo "[joyose] dry-run：跳过系统服务冻结"
    else
        joyose_freeze_cloud
    fi
}

init_joyose_config
