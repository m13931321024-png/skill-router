#!/bin/bash
# Skill Router for Claude Code — 卸载脚本
# 只移除 router 自身文件，不删除用户的 skills 和插件

CLAUDE_DIR="$HOME/.claude"
REMOVED=0

echo "=== Skill Router 卸载 ==="
echo ""

# 1. 移除核心脚本
for file in "skill-router.sh" "skill-router-sync.sh" "skill-router.json"; do
    filepath="$CLAUDE_DIR/$file"
    if [ -f "$filepath" ]; then
        rm "$filepath"
        echo "  [DEL] $filepath"
        REMOVED=$((REMOVED + 1))
    else
        echo "  [--]  $filepath (不存在，跳过)"
    fi
done

# 2. 检查 settings.json 中的 hook
SETTINGS="$CLAUDE_DIR/settings.json"
echo ""
if [ -f "$SETTINGS" ] && grep -q "skill-router" "$SETTINGS" 2>/dev/null; then
    echo "  [!] settings.json 中仍包含 skill-router 的 hook 配置"
    echo "      需要手动移除以下内容："
    echo ""
    echo "      hooks.SessionStart 中包含 skill-router-sync.sh 的条目"
    echo "      hooks.UserPromptSubmit 中包含 skill-router.sh 的条目"
    echo ""
    echo "      你可以让 Claude Code 帮你移除："
    echo "      说：'帮我从 settings.json 中移除 skill-router 的 hook'"
    echo ""
else
    echo "  [OK] settings.json 无需修改"
fi

# 3. 保留说明
echo "  以下内容已保留（属于你自己的内容）："
echo "    - ~/.claude/commands/*.md  (你的 skills)"
echo "    - ~/.claude/settings.json  (你的配置)"
echo "    - 所有已安装的插件和 MCP 配置"
echo ""

# 4. 总结
if [ "$REMOVED" -gt 0 ]; then
    echo "=== 卸载完成：已移除 $REMOVED 个文件 ==="
else
    echo "=== 未发现需要移除的文件（可能已经卸载过） ==="
fi
echo ""
