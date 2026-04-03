#!/bin/bash
# Skill Router for Claude Code — 一键安装脚本
set -e

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "🔧 Installing Skill Router for Claude Code..."

# 1. 复制核心脚本
cp "$SCRIPT_DIR/skill-router.sh" "$CLAUDE_DIR/skill-router.sh"
cp "$SCRIPT_DIR/skill-router-sync.sh" "$CLAUDE_DIR/skill-router-sync.sh"
chmod +x "$CLAUDE_DIR/skill-router.sh" "$CLAUDE_DIR/skill-router-sync.sh"
echo "  ✓ skill-router.sh → $CLAUDE_DIR/"
echo "  ✓ skill-router-sync.sh → $CLAUDE_DIR/"

# 2. 安装示例 skills（如果 commands 目录为空）
mkdir -p "$CLAUDE_DIR/commands"
SKILL_COUNT=$(ls "$CLAUDE_DIR/commands/"*.md 2>/dev/null | wc -l || echo 0)
if [ "$SKILL_COUNT" -eq 0 ] 2>/dev/null; then
    cp "$SCRIPT_DIR/skills/"*.md "$CLAUDE_DIR/commands/" 2>/dev/null || true
    echo "  ✓ 示例 skills → $CLAUDE_DIR/commands/"
else
    echo "  ⊘ commands/ 已有 skill，不覆盖"
fi

# 3. 自动扫描生成 skill-router.json
echo "  ⟳ 自动扫描 skills/插件/MCP..."
bash "$CLAUDE_DIR/skill-router-sync.sh"

# 4. 注入 hooks 到 settings.json
if [ ! -f "$SETTINGS" ]; then
    cat > "$SETTINGS" << 'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/skill-router-sync.sh >/dev/null 2>&1; echo '{\"systemMessage\":\"[Skill Router 已同步] 所有 skill/插件/MCP 已自动加载。\"}'",
            "timeout": 10
          }
        ]
      }
    ],
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
    echo "  ✓ 创建 settings.json（含 SessionStart 自动同步 + UserPromptSubmit 路由）"
else
    if grep -q "skill-router" "$SETTINGS" 2>/dev/null; then
        echo "  ⊘ settings.json 已包含 skill-router hook"
    else
        echo ""
        echo "  ⚠️  请让 Claude Code 帮你加 hook，说：'帮我把 skill-router 的 hook 加到 settings.json'"
        echo "  需要加两个 hook："
        echo "    SessionStart → bash ~/.claude/skill-router-sync.sh（自动同步规则）"
        echo "    UserPromptSubmit → ~/.claude/skill-router.sh（自动路由）"
    fi
fi

echo ""
echo "✅ 安装完成！"
echo ""
echo "工作方式："
echo "  1. 每次开 CC 会话 → 自动扫描所有 skill/插件/MCP 生成路由规则"
echo "  2. 你说话 → 自动匹配关键词 → 调用对应 skill"
echo "  3. 新增 skill/插件 → 下次开会话自动注册，不用手动改配置"
echo ""
echo "手动同步：bash ~/.claude/skill-router-sync.sh"
echo "编辑规则：~/.claude/skill-router.json"
