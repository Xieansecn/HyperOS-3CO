#!/system/bin/sh

# KernelSU 模块列表 action 按钮唯一入口：音量键交互菜单。
# 所有功能实现均在 scripts/（见 action_lib.sh / api.sh），本文件仅负责
# 绘制菜单 + 按键选择 + 派发到共享动作函数，不含任何 CLI / WebUI 逻辑。

MODDIR=${0%/*}
. "$MODDIR/scripts/utils.sh"
. "$MODDIR/scripts/action_lib.sh"

# 菜单项绘制（funbox 风格：当前项 -> 高亮 + 编号）
print_item() {
    local idx="$1"
    local sel="$2"
    local label="$3"
    if [ "$idx" = "$sel" ]; then
        echo " -> [${idx}] ${label}"
    else
        echo "    [${idx}] ${label}"
    fi
}

# 重绘菜单（funbox 同款：无条件 clear 再重绘，当前项 -> 高亮）
draw_menu() {
    clear
    echo ""
    echo "======================"
    echo " 选择操作："
    echo " 音量↓: 切换选项"
    echo " 音量↑: 确认当前选项"
    echo "----------------------"
    print_item 1 "$selected" "覆盖 Joyose 云控"
    print_item 2 "$selected" "同步电池优化白名单到云控"
    print_item 3 "$selected" "应用 PowerKeeper 静态保护补丁（全部第三方应用）"
    print_item 4 "$selected" "高刷跟随系统刷新率设置"
    print_item 5 "$selected" "查看当前云控状态"
    print_item 6 "$selected" "重启 PowerKeeper（重新读取云控）"
    print_item 7 "$selected" "备份云控数据库原文件"
    print_item 8 "$selected" "恢复充电（解除热控限制/恢复服务/重读本地云控）"
    print_item 9 "$selected" "息屏冻结（立即应用）"
    print_item 10 "$selected" "即时恢复（解除冻结）"
    print_item 11 "$selected" "一键还原（清理式，让云控重拉）"
    print_item 12 "$selected" "退出"
    echo "======================"
}

# ---- 按键检测：模块内置 keycheck 优先，回退 getevent（不依赖外部 funbox）----
KEY_CHECK="${KEY_CHECK:-$MODDIR/bin/keycheck}"
VOL_UP_SIGNAL=42
VOL_DOWN_SIGNAL=41

key_click_compat() {
    if [ -x "$KEY_CHECK" ]; then
        "$KEY_CHECK" >/dev/null 2>&1
        key=$?
        case "$key" in
            "$VOL_DOWN_SIGNAL") return 0 ;; # 音量下：移动
            "$VOL_UP_SIGNAL") return 1 ;;   # 音量上：确认
            *) return 2 ;;
        esac
    else
        # getevent 回退：key_click 返回 0=音量上 / 1=音量下，
        # 统一转换为 0=移动(音量下) / 1=确认(音量上)
        if key_click; then
            return 1
        else
            return 0
        fi
    fi
}

# 动作执行前输出一条日志，便于在管理器日志中确认做了什么
show_selected() {
    echo "[action] 已选择: [${selected}] $(menu_label "$selected")"
}

# 兼容性检查：keycheck 或 getevent 至少有一个可用
if [ ! -x "$KEY_CHECK" ] && ! command -v getevent >/dev/null 2>&1; then
    echo "[action] 当前环境不支持音量键交互，请在 KernelSU/Magisk 模块管理器中运行"
    exit 1
fi

selected=1
while true; do
    draw_menu "$selected"
    # 等待按键抬起，避免同一次按压的按下/抬起被处理两次（funbox 同款）
    sleep 0.4
    key_click_compat
    ret=$?
    case "$ret" in
        0) # 音量下：移动下一项
            selected=$((selected + 1))
            [ "$selected" -gt 12 ] && selected=1
            ;;
        1) # 音量上：确认执行
            echo ""
            show_selected
            run_selected "$selected"
            # 所有动作输出后等待按键返回（[12] 退出已 exit，不会到这里）
            echo ""
            echo "按任意音量键返回菜单..."
            key_click_compat >/dev/null 2>&1 || true
            ;;
        2)
            echo "[action] 按键监听失败，退出"
            exit 1
            ;;
    esac
done
