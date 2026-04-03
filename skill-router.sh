#!/bin/bash
# Skill Router v3: 提示词优化 + 优先级 + 依赖分析 + 非阻塞 LLM 兜底
# UserPromptSubmit hook

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

# 写入临时文件避免中文 shell 传递问题
TMPFILE=$(mktemp)
echo "$USER_MSG" > "$TMPFILE"

# 全部逻辑在 Python 中完成
RESULT=$(python3 - "$TMPFILE" << 'PYEOF'
import json, re, sys, os

# 从临时文件读取消息
tmpfile = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    with open(tmpfile, "r") as f:
        msg = f.read().strip()
    os.unlink(tmpfile)
except:
    sys.exit(0)

if not msg:
    sys.exit(0)
msg_stripped = msg.strip()
msg_lower = msg_stripped.lower()
rules_file = os.path.expanduser("~/.claude/skill-router.json")

# ================================================================
# Layer 0: 智能过滤 — 该不该进 router
# ================================================================

# 短消息（<=5字）放行
if len(msg_stripped) <= 5:
    sys.exit(0)

# 对话类/确认类消息放行
SKIP_PATTERNS = [
    r"^(好的?|ok|yes|no|对|嗯|继续|确认|可以|不行|停|取消|谢谢|明白|收到|知道了|是的|没有|有的|算了)$",
    r"^(这样可以吗|可以吗|行吗|对吗|是吗|怎么样|什么意思|为什么|是什么|怎么了|什么情况)$",
    r"^(看看|帮我看|你看一下|给我看).{0,4}$",  # "看看这个"这种短指令不路由
    r"^\?+$",
    r"^!",           # shell 命令
    r"^\[Image",     # 图片消息
    r"^(哈哈|呵呵|嘿嘿|666|牛|厉害|不错|漂亮)",  # 情绪回应
]
for pat in SKIP_PATTERNS:
    if re.search(pat, msg_stripped, re.IGNORECASE):
        sys.exit(0)

# ================================================================
# Layer 1: 加载规则 + 上下文
# ================================================================

try:
    with open(rules_file) as f:
        config = json.load(f)
    rules = config.get("rules", [])
except:
    sys.exit(0)

# ================================================================
# Layer 2: 意图排除 — 检测是否在谈论 skill/router 本身
# ================================================================
# 如果用户在讨论 skill-router/插件/配置本身，不应该触发任何 skill
META_PATTERNS = [
    r"(skill.?router|路由|hook|插件|plugin).*(改|修|加|删|优化|完善|升级|更新|发布|推送|push)",
    r"(改|修|加|删|优化|完善|升级).*(skill.?router|路由|hook|插件|plugin)",
    r"(给我|帮我).*(看|列|说|讲|介绍).*(skill|插件|plugin|hook|配置)",
    r"(安装|卸载|启用|禁用).*(skill|插件|plugin)",
    r"(skill|插件).*(是什么|干什么|怎么用|有哪些)",
    r"github.*(push|推|发布|开源|仓库)",
    r"(发布|推送|开源|上传).*github",
]
for pat in META_PATTERNS:
    if re.search(pat, msg_lower):
        sys.exit(0)

# ================================================================
# Layer 3: 关键词匹配 + 优先级评分
# ================================================================

# 优先级权重
PRIORITY_WEIGHT = {"critical": 4, "high": 3, "medium": 2, "low": 1}

matches = []
for rule in rules:
    keywords = rule.get("keywords", [])
    hits = []
    for kw in keywords:
        if re.search(kw.lower(), msg_lower):
            hits.append(kw)

    if hits:
        priority = rule.get("priority", "medium")
        priority_score = PRIORITY_WEIGHT.get(priority, 2)
        hit_ratio = len(hits) / max(len(keywords), 1)
        # 综合分 = 命中比 * 优先级权重
        score = hit_ratio * priority_score

        matches.append({
            "skill": rule["skill"],
            "description": rule.get("description", ""),
            "priority": priority,
            "score": score,
            "hits": hits,
            "hit_ratio": hit_ratio,
        })

# 按综合分排序
matches.sort(key=lambda x: x["score"], reverse=True)

# ================================================================
# Layer 4: 路由决策
# ================================================================

if not matches:
    # 没匹配到任何规则，放行让 CC 自己处理
    sys.exit(0)

def make_output(ctx):
    return json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": ctx
        }
    }, ensure_ascii=False)

# --- 单 skill 匹配 ---
if len(matches) == 1:
    m = matches[0]
    if m["hits"]:  # 命中任何关键词就调
        ctx = (
            f'[SKILL-ROUTER] 匹配到 skill: {m["skill"]}（{m["description"]}，'
            f'优先级: {m["priority"]}，命中: {",".join(m["hits"])}）。\n'
            f'请先理解用户的真实意图，然后使用 Skill 工具调用 skill="{m["skill"]}"，'
            f'将用户的原始消息作为 args 传入。'
        )
        print(make_output(ctx))
    sys.exit(0)

# --- 多 skill 匹配：依赖分析 ---

# 检测显式顺序关系
SEQ_PATTERNS = [
    r"(先|首先).*(然后|再|接着|之后)",
    r"(调研|研究|分析).*(然后|再).*(优化|修复|实现|开发)",
    r"(完成|做完|搞定).*(再|然后|接着)",
    r"(了解|弄清).*(再|然后|开始)",
]
has_explicit_seq = any(re.search(p, msg) for p in SEQ_PATTERNS)

# 隐式依赖关系表（A 应该在 B 之前）
DEPENDENCY_ORDER = {
    "research": 0,       # 调研最先
    "learning-plan": 1,  # 学习规划次之
    "autoresearch": 2,   # 实验循环
    "audit": 2,          # 审计（可与 autoresearch 并行）
    "orchestrate": 3,    # 协调在后
    "smart-commit": 4,   # 提交最后
}

skill_names = [m["skill"] for m in matches[:3]]
skill_descs = [f'{m["skill"]}（{m["description"]}）' for m in matches[:3]]
skills_str = "、".join(skill_descs)

# 判断是串行还是并行
if has_explicit_seq:
    mode = "serial"
else:
    # 用依赖关系表判断
    orders = [DEPENDENCY_ORDER.get(s, 2) for s in skill_names]
    if len(set(orders)) == 1:
        mode = "parallel"  # 同级，可并行
    else:
        mode = "serial"    # 不同级，按依赖顺序串行
        # 按依赖顺序重排
        paired = list(zip(skill_names, skill_descs, orders))
        paired.sort(key=lambda x: x[2])
        skill_names = [p[0] for p in paired]
        skill_descs = [p[1] for p in paired]
        skills_str = "、".join(skill_descs)

if mode == "serial":
    steps = "。".join([f'第{i+1}步 Skill 工具 skill="{s}"' for i, s in enumerate(skill_names)])
    ctx = (
        f'[SKILL-ROUTER 串行] 匹配到多个 skill: {skills_str}。\n'
        f'按依赖顺序执行：{steps}。\n'
        f'前一个 skill 完成后再调用下一个。将用户原始消息作为 args 传入第一个 skill。'
    )
else:
    ctx = (
        f'[SKILL-ROUTER 并行] 匹配到多个 skill: {skills_str}。\n'
        f'这些任务无依赖关系，可并行执行。\n'
        f'使用 Agent 工具为每个 skill 各启动一个子 agent 并行处理，'
        f'每个 agent 内部调用对应的 Skill 工具。'
    )

print(make_output(ctx))
PYEOF
)

[ -n "$RESULT" ] && echo "$RESULT"
