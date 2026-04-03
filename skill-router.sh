#!/bin/bash
# Skill Auto-Router: 匹配关键词，强制 CC 调用对应 skill
# UserPromptSubmit hook — 返回 additionalContext 让 CC 执行 Skill 调用

RULES_FILE="$HOME/.claude/skill-router.json"

INPUT=$(cat 2>/dev/null || echo "{}")

USER_MSG=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    print(data.get('message', data.get('prompt', '')))
except:
    print('')
" 2>/dev/null)

if [ -z "$USER_MSG" ]; then
    exit 0
fi

# 跳过已经是 /命令 的输入（用户手动调 skill 时不要重复匹配）
if echo "$USER_MSG" | grep -q '^/'; then
    exit 0
fi

RESULT=$(python3 -c "
import json, re, sys

msg = sys.stdin.read().lower()
rules_file = '$RULES_FILE'

try:
    with open(rules_file) as f:
        rules = json.load(f)['rules']
except:
    sys.exit(0)

matches = []
for rule in rules:
    for kw in rule['keywords']:
        if re.search(kw, msg):
            matches.append(rule)
            break

if not matches:
    sys.exit(0)

best = matches[0]
skill = best['skill']
desc = best['description']

output = {
    'hookSpecificOutput': {
        'hookEventName': 'UserPromptSubmit',
        'additionalContext': f'[SKILL-ROUTER 自动匹配] 用户的请求匹配到 skill: {skill}（{desc}）。你必须立即使用 Skill 工具调用 skill=\"{skill}\"，并将用户的原始消息作为 args 传入。不要跳过这一步直接回答。'
    }
}
print(json.dumps(output, ensure_ascii=False))
" <<< "$USER_MSG" 2>/dev/null)

if [ -n "$RESULT" ]; then
    echo "$RESULT"
fi
