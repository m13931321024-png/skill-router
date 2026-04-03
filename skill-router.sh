#!/bin/bash
# Skill Router v2: 关键词匹配 + 短消息过滤 + 多 skill 并行/串行
# UserPromptSubmit hook

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

# 空消息直接放行
if [ -z "$USER_MSG" ]; then
    exit 0
fi

# 已是 /命令 的输入直接放行
if echo "$USER_MSG" | grep -q '^/'; then
    exit 0
fi

RESULT=$(python3 << 'PYEOF'
import json, re, sys, os

msg = os.environ.get("SKILL_ROUTER_MSG", "")
msg_lower = msg.lower()
rules_file = os.path.expanduser("~/.claude/skill-router.json")

# ========== P0: 短消息 + 对话类消息过滤 ==========
# 5 个字以内直接放行
if len(msg.strip()) <= 5:
    sys.exit(0)

# 排除纯对话类消息
EXCLUDE_PATTERNS = [
    r"^(好的?|ok|yes|no|对|嗯|继续|确认|可以|不行|停|取消|谢谢|明白|收到|知道了)$",
    r"^(这样可以吗|可以吗|行吗|对吗|是吗|怎么样|什么意思|为什么|是什么)$",
    r"^\?+$",
    r"^!",  # ! 开头是 shell 命令
    r"^\[Image",  # 图片消息
]
for pat in EXCLUDE_PATTERNS:
    if re.search(pat, msg.strip(), re.IGNORECASE):
        sys.exit(0)

# ========== 加载规则 ==========
try:
    with open(rules_file) as f:
        config = json.load(f)
    rules = config.get("rules", [])
except:
    sys.exit(0)

# ========== 关键词匹配（带置信度）==========
matches = []
for rule in rules:
    hit_count = 0
    total_kw = len(rule.get("keywords", []))
    for kw in rule.get("keywords", []):
        if re.search(kw.lower(), msg_lower):
            hit_count += 1
    if hit_count > 0:
        confidence = hit_count / max(total_kw, 1)
        matches.append({
            "skill": rule["skill"],
            "description": rule.get("description", ""),
            "confidence": confidence,
            "hits": hit_count
        })

# 没匹配到，放行
if not matches:
    sys.exit(0)

# 按置信度排序
matches.sort(key=lambda x: x["confidence"], reverse=True)

# ========== 路由决策 ==========

# 只匹配到 1 个 skill
if len(matches) == 1:
    m = matches[0]
    if m["confidence"] >= 0.3:
        # 高置信度：直接调用
        ctx = f'[SKILL-ROUTER] 匹配到 skill: {m["skill"]}（{m["description"]}）。使用 Skill 工具调用 skill="{m["skill"]}"，将用户原始消息作为 args 传入。'
    else:
        # 低置信度：建议但不强制
        ctx = f'[SKILL-ROUTER 建议] 用户的请求可能与 /{m["skill"]}（{m["description"]}）相关，置信度较低。如果合适就调用，不合适就正常回答。'
    output = {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": ctx}}
    print(json.dumps(output, ensure_ascii=False))
    sys.exit(0)

# 匹配到多个 skill
if len(matches) >= 2:
    # 检测是否有先后顺序关键词
    SEQUENCE_PATTERNS = [
        r"(先|首先).*(然后|再|接着|之后)",
        r"(调研|研究|分析).*(然后|再).*(优化|修复|实现|开发)",
        r"(完成|做完).*(再|然后|接着)",
    ]
    is_sequential = any(re.search(p, msg) for p in SEQUENCE_PATTERNS)

    skill_list = [f'{m["skill"]}（{m["description"]}）' for m in matches[:3]]
    skills_str = "、".join(skill_list)
    skill_names = [m["skill"] for m in matches[:3]]

    if is_sequential:
        # 串行：按提到顺序执行
        ctx = (
            f'[SKILL-ROUTER 串行] 用户请求涉及多个 skill: {skills_str}。'
            f'按顺序执行：先调用 Skill 工具 skill="{skill_names[0]}"，'
            f'完成后再调用 skill="{skill_names[1]}"。'
            f'将用户原始消息作为 args 传入第一个 skill。'
        )
    else:
        # 并行：用 orchestrate 或 Agent 工具并行
        ctx = (
            f'[SKILL-ROUTER 并行] 用户请求涉及多个 skill: {skills_str}。'
            f'这些任务可以并行执行。使用 Agent 工具为每个 skill 各启动一个子 agent，'
            f'或使用 Skill 工具调用 skill="orchestrate" 来协调并行执行。'
            f'每个子 agent 分别调用对应的 skill。'
        )

    output = {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": ctx}}
    print(json.dumps(output, ensure_ascii=False))
PYEOF
)

# 通过环境变量传递消息（避免 shell 注入）
export SKILL_ROUTER_MSG="$USER_MSG"

RESULT=$(SKILL_ROUTER_MSG="$USER_MSG" python3 << 'PYEOF'
import json, re, sys, os

msg = os.environ.get("SKILL_ROUTER_MSG", "")
msg_lower = msg.lower()
rules_file = os.path.expanduser("~/.claude/skill-router.json")

# ========== P0: 短消息 + 对话类消息过滤 ==========
if len(msg.strip()) <= 5:
    sys.exit(0)

EXCLUDE_PATTERNS = [
    r"^(好的?|ok|yes|no|对|嗯|继续|确认|可以|不行|停|取消|谢谢|明白|收到|知道了)$",
    r"^(这样可以吗|可以吗|行吗|对吗|是吗|怎么样|什么意思|为什么|是什么)$",
    r"^\?+$",
    r"^!",
    r"^\[Image",
]
for pat in EXCLUDE_PATTERNS:
    if re.search(pat, msg.strip(), re.IGNORECASE):
        sys.exit(0)

# ========== 加载规则 ==========
try:
    with open(rules_file) as f:
        config = json.load(f)
    rules = config.get("rules", [])
except:
    sys.exit(0)

# ========== 关键词匹配（带置信度）==========
matches = []
for rule in rules:
    hit_count = 0
    total_kw = len(rule.get("keywords", []))
    for kw in rule.get("keywords", []):
        if re.search(kw.lower(), msg_lower):
            hit_count += 1
    if hit_count > 0:
        confidence = hit_count / max(total_kw, 1)
        matches.append({
            "skill": rule["skill"],
            "description": rule.get("description", ""),
            "confidence": confidence,
            "hits": hit_count
        })

if not matches:
    sys.exit(0)

matches.sort(key=lambda x: x["confidence"], reverse=True)

# ========== 单 skill ==========
if len(matches) == 1:
    m = matches[0]
    if m["confidence"] >= 0.3:
        ctx = f'[SKILL-ROUTER] 匹配到 skill: {m["skill"]}（{m["description"]}）。使用 Skill 工具调用 skill="{m["skill"]}"，将用户原始消息作为 args 传入。'
    else:
        ctx = f'[SKILL-ROUTER 建议] 可能与 /{m["skill"]}（{m["description"]}）相关。如果合适就调用，不合适就正常回答。'
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": ctx}}, ensure_ascii=False))
    sys.exit(0)

# ========== 多 skill ==========
SEQUENCE_PATTERNS = [
    r"(先|首先).*(然后|再|接着|之后)",
    r"(调研|研究|分析).*(然后|再).*(优化|修复|实现|开发)",
    r"(完成|做完).*(再|然后|接着)",
]
is_sequential = any(re.search(p, msg) for p in SEQUENCE_PATTERNS)

skill_list = [f'{m["skill"]}（{m["description"]}）' for m in matches[:3]]
skills_str = "、".join(skill_list)
skill_names = [m["skill"] for m in matches[:3]]

if is_sequential:
    ctx = (
        f'[SKILL-ROUTER 串行] 涉及多个 skill: {skills_str}。'
        f'按顺序：先 Skill 工具 skill="{skill_names[0]}"，完成后再 skill="{skill_names[1]}"。'
    )
else:
    ctx = (
        f'[SKILL-ROUTER 并行] 涉及多个 skill: {skills_str}。'
        f'可并行执行：用 Agent 工具为每个 skill 各启动子 agent，或用 Skill 工具调用 orchestrate 协调。'
    )

print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": ctx}}, ensure_ascii=False))
PYEOF
)

if [ -n "$RESULT" ]; then
    echo "$RESULT"
fi
