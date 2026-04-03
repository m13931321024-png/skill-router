#!/bin/bash
# Skill Router v2.1: 关键词匹配 + 短消息过滤 + 多 skill 串行/并行
# UserPromptSubmit hook — 命中就调，不犹豫

RULES_FILE="$HOME/.claude/skill-router.json"

# 读取 hook stdin
INPUT=$(cat 2>/dev/null || echo "{}")

# 提取用户消息
USER_MSG=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    print(data.get('message', data.get('prompt', '')))
except:
    print('')
" 2>/dev/null)

# 空消息 / /命令 直接放行
[ -z "$USER_MSG" ] && exit 0
echo "$USER_MSG" | grep -q '^/' && exit 0

# 单段 Python 完成所有逻辑
RESULT=$(SKILL_ROUTER_MSG="$USER_MSG" python3 << 'PYEOF'
import json, re, sys, os

msg = os.environ.get("SKILL_ROUTER_MSG", "")
msg_lower = msg.lower().strip()
rules_file = os.path.expanduser("~/.claude/skill-router.json")

# === 短消息过滤 ===
if len(msg.strip()) <= 5:
    sys.exit(0)

EXCLUDE = [
    r"^(好的?|ok|yes|no|对|嗯|继续|确认|可以|不行|停|取消|谢谢|明白|收到|知道了)$",
    r"^(这样可以吗|可以吗|行吗|对吗|是吗|怎么样|什么意思|为什么|是什么)$",
    r"^\?+$",
    r"^!",
    r"^\[Image",
]
for pat in EXCLUDE:
    if re.search(pat, msg.strip(), re.IGNORECASE):
        sys.exit(0)

# === 加载规则 ===
try:
    with open(rules_file) as f:
        rules = json.load(f).get("rules", [])
except:
    sys.exit(0)

# === 关键词匹配 ===
matches = []
for rule in rules:
    hits = sum(1 for kw in rule.get("keywords", []) if re.search(kw.lower(), msg_lower))
    if hits > 0:
        matches.append({"skill": rule["skill"], "description": rule.get("description", ""), "hits": hits})

if not matches:
    sys.exit(0)

matches.sort(key=lambda x: x["hits"], reverse=True)

# === 单 skill：命中就调 ===
if len(matches) == 1:
    m = matches[0]
    ctx = (
        f'[SKILL-ROUTER] 匹配到 skill: {m["skill"]}（{m["description"]}）。'
        f'你必须立即使用 Skill 工具调用 skill="{m["skill"]}"，将用户的原始消息作为 args 传入。'
        f'不要跳过 Skill 调用直接回答。'
    )
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": ctx}}, ensure_ascii=False))
    sys.exit(0)

# === 多 skill：判断串行/并行 ===
SEQ_PATTERNS = [
    r"(先|首先).*(然后|再|接着|之后)",
    r"(调研|研究|分析).*(然后|再).*(优化|修复|实现|开发)",
    r"(完成|做完).*(再|然后|接着)",
]
is_seq = any(re.search(p, msg) for p in SEQ_PATTERNS)

names = [m["skill"] for m in matches[:3]]
descs = [f'{m["skill"]}（{m["description"]}）' for m in matches[:3]]

if is_seq:
    ctx = (
        f'[SKILL-ROUTER 串行] 匹配到多个 skill: {"、".join(descs)}。'
        f'按顺序执行：先用 Skill 工具调用 skill="{names[0]}"，完成后再调用 skill="{names[1]}"。'
        f'将用户原始消息作为 args 传入。'
    )
else:
    ctx = (
        f'[SKILL-ROUTER 并行] 匹配到多个 skill: {"、".join(descs)}。'
        f'这些任务可并行执行。使用 Agent 工具为每个 skill 各启动一个子 agent 并行处理，'
        f'或使用 Skill 工具调用 skill="orchestrate" 来协调。'
    )

print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": ctx}}, ensure_ascii=False))
PYEOF
)

[ -n "$RESULT" ] && echo "$RESULT"
