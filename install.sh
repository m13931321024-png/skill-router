#!/bin/bash
# Skill Router for Claude Code — 一键安装脚本
set -e

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMMANDS_DIR="$CLAUDE_DIR/commands"

echo "=== Skill Router 安装 ==="
echo ""

# 1. 复制核心脚本
mkdir -p "$CLAUDE_DIR"
cp "$SCRIPT_DIR/skill-router.sh" "$CLAUDE_DIR/skill-router.sh"
cp "$SCRIPT_DIR/skill-router-sync.sh" "$CLAUDE_DIR/skill-router-sync.sh"
chmod +x "$CLAUDE_DIR/skill-router.sh" "$CLAUDE_DIR/skill-router-sync.sh"
echo "  [OK] skill-router.sh -> $CLAUDE_DIR/"
echo "  [OK] skill-router-sync.sh -> $CLAUDE_DIR/"

# 2. Starter Skill Pack：检测并安装
mkdir -p "$COMMANDS_DIR"
SKILL_COUNT=$(find "$COMMANDS_DIR" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d ' ')

if [ "$SKILL_COUNT" -eq 0 ] 2>/dev/null; then
    echo ""
    echo "  检测到 ~/.claude/commands/ 为空，自动安装 Starter Skill Pack..."
    STARTER_COUNT=0
    for skill_file in "$SCRIPT_DIR/skills/"*.md; do
        if [ -f "$skill_file" ]; then
            cp "$skill_file" "$COMMANDS_DIR/"
            skill_name=$(basename "$skill_file" .md)
            echo "    + $skill_name"
            STARTER_COUNT=$((STARTER_COUNT + 1))
        fi
    done
    echo "  [OK] 已安装 $STARTER_COUNT 个 Starter Skills"
else
    echo ""
    echo "  检测到 ~/.claude/commands/ 已有 $SKILL_COUNT 个 skill"
    # 检查是否有新增的 starter skill 可以补充
    NEW_COUNT=0
    for skill_file in "$SCRIPT_DIR/skills/"*.md; do
        if [ -f "$skill_file" ]; then
            skill_name=$(basename "$skill_file")
            if [ ! -f "$COMMANDS_DIR/$skill_name" ]; then
                cp "$skill_file" "$COMMANDS_DIR/"
                echo "    + $(basename "$skill_file" .md) (新增)"
                NEW_COUNT=$((NEW_COUNT + 1))
            fi
        fi
    done
    if [ "$NEW_COUNT" -gt 0 ]; then
        echo "  [OK] 补充安装 $NEW_COUNT 个新 Starter Skills（已有的不覆盖）"
    else
        echo "  [OK] 所有 Starter Skills 已存在，无需更新"
    fi
fi

# 3. 自动扫描生成 skill-router.json
echo ""
echo "  扫描 skills/插件/MCP，生成路由规则..."
bash "$CLAUDE_DIR/skill-router-sync.sh"

# 4. 注入 hooks 到 settings.json
echo ""
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
    echo "  [OK] 创建 settings.json（含 SessionStart + UserPromptSubmit hook）"
else
    if grep -q "skill-router" "$SETTINGS" 2>/dev/null; then
        echo "  [OK] settings.json 已包含 skill-router hook"
    else
        echo ""
        echo "  [!] settings.json 已存在但未包含 skill-router hook"
        echo "      请让 Claude Code 帮你加 hook："
        echo "      说：'帮我把 skill-router 的 hook 加到 settings.json'"
        echo ""
        echo "      需要加两个 hook："
        echo "        SessionStart  -> bash ~/.claude/skill-router-sync.sh"
        echo "        UserPromptSubmit -> ~/.claude/skill-router.sh"
    fi
fi

# 5. 安装完成报告
echo ""
echo "=== 安装完成 ==="
echo ""
echo "  工作方式："
echo "    1. 每次开 Claude Code 会话 -> 自动扫描并同步路由规则"
echo "    2. 你说话 -> 关键词匹配 -> 自动调用对应 skill"
echo "    3. 新增 skill -> 下次开会话自动注册"
echo ""
echo "  常用命令："
echo "    状态检查：bash ~/.claude/skill-router-sync.sh --check"
echo "    手动同步：bash ~/.claude/skill-router-sync.sh"
echo "    编辑规则：vim ~/.claude/skill-router.json"
echo "    卸载：    bash $(cd "$SCRIPT_DIR" && pwd)/uninstall.sh"
echo ""
