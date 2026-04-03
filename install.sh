#!/bin/bash
# Skill Router for Claude Code — 一键安装脚本
set -e

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"

echo "🔧 Installing Skill Router for Claude Code..."

# 1. 复制路由脚本
cp "$(dirname "$0")/skill-router.sh" "$CLAUDE_DIR/skill-router.sh"
chmod +x "$CLAUDE_DIR/skill-router.sh"
echo "  ✓ skill-router.sh → $CLAUDE_DIR/"

# 2. 安装路由规则（如果不存在则用默认，已存在则保留用户的）
if [ ! -f "$CLAUDE_DIR/skill-router.json" ]; then
    cp "$(dirname "$0")/skill-router.json" "$CLAUDE_DIR/skill-router.json"
    echo "  ✓ skill-router.json → $CLAUDE_DIR/ (默认规则)"
else
    echo "  ⊘ skill-router.json 已存在，保留你的自定义规则"
fi

# 3. 安装示例 skills（如果 commands 目录为空）
mkdir -p "$CLAUDE_DIR/commands"
SKILL_COUNT=$(ls "$CLAUDE_DIR/commands/"*.md 2>/dev/null | wc -l)
if [ "$SKILL_COUNT" -eq 0 ]; then
    cp "$(dirname "$0")/skills/"*.md "$CLAUDE_DIR/commands/" 2>/dev/null || true
    echo "  ✓ 示例 skills → $CLAUDE_DIR/commands/"
else
    echo "  ⊘ commands/ 已有 $SKILL_COUNT 个 skills，不覆盖"
fi

# 4. 注入 UserPromptSubmit hook 到 settings.json
if [ ! -f "$SETTINGS" ]; then
    # 没有 settings.json，创建一个
    cat > "$SETTINGS" << 'EOF'
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/skill-router.sh",
            "timeout": 3,
            "statusMessage": "Skill Router"
          }
        ]
      }
    ]
  }
}
EOF
    echo "  ✓ 创建 settings.json 并注入 hook"
else
    # settings.json 已存在，检查是否已有 skill-router hook
    if grep -q "skill-router" "$SETTINGS" 2>/dev/null; then
        echo "  ⊘ settings.json 已包含 skill-router hook"
    else
        echo ""
        echo "  ⚠️  请手动将以下内容添加到 $SETTINGS 的 hooks.UserPromptSubmit 中："
        echo ""
        echo '    "UserPromptSubmit": ['
        echo '      {'
        echo '        "hooks": ['
        echo '          {'
        echo '            "type": "command",'
        echo '            "command": "~/.claude/skill-router.sh",'
        echo '            "timeout": 3,'
        echo '            "statusMessage": "Skill Router"'
        echo '          }'
        echo '        ]'
        echo '      }'
        echo '    ]'
        echo ""
        echo "  或者让 Claude Code 帮你加：直接说 '帮我把 skill-router hook 加到 settings.json'"
    fi
fi

echo ""
echo "✅ 安装完成！重启 Claude Code 生效。"
echo ""
echo "使用方式："
echo "  直接用自然语言说话，router 会自动匹配对应的 skill"
echo "  编辑 ~/.claude/skill-router.json 添加你自己的规则"
