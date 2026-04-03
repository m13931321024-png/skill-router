#!/bin/bash
# Skill Router v4: 提示词优化 + 优先级 + 依赖分析 + 排除关键词 + 日志 + 可配置过滤 + 自动同步
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

# ================================================================
# Mid-session sync: 如果 commands/ 比 skill-router.json 更新，自动同步
# ================================================================
SYNC_SCRIPT="$HOME/.claude/skill-router-sync.sh"
ROUTER_JSON="$HOME/.claude/skill-router.json"
COMMANDS_DIR="$HOME/.claude/commands"
LAST_SYNC_FILE="$HOME/.claude/.skill-router-last-sync"

if [ -d "$COMMANDS_DIR" ] && [ -f "$ROUTER_JSON" ] && [ -f "$SYNC_SCRIPT" ]; then
    COMMANDS_MTIME=$(stat -f "%m" "$COMMANDS_DIR" 2>/dev/null || stat -c "%Y" "$COMMANDS_DIR" 2>/dev/null || echo 0)
    JSON_MTIME=$(stat -f "%m" "$ROUTER_JSON" 2>/dev/null || stat -c "%Y" "$ROUTER_JSON" 2>/dev/null || echo 0)

    if [ "$COMMANDS_MTIME" -gt "$JSON_MTIME" ] 2>/dev/null; then
        # 限制同步频率：5分钟内最多一次
        NEED_SYNC=true
        if [ -f "$LAST_SYNC_FILE" ]; then
            LAST_SYNC=$(cat "$LAST_SYNC_FILE" 2>/dev/null || echo 0)
            NOW=$(date +%s)
            ELAPSED=$((NOW - LAST_SYNC))
            if [ "$ELAPSED" -lt 300 ]; then
                NEED_SYNC=false
            fi
        fi

        if [ "$NEED_SYNC" = "true" ]; then
            bash "$SYNC_SCRIPT" >/dev/null 2>&1
            date +%s > "$LAST_SYNC_FILE"
        fi
    fi
fi

# 写入临时文件避免中文 shell 传递问题
TMPFILE=$(mktemp)
echo "$USER_MSG" > "$TMPFILE"

# 全部逻辑在 Python 中完成（输出两行：第1行 JSON result, 第2行 log info）
FULL_OUTPUT=$(python3 - "$TMPFILE" << 'PYEOF'
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
# 从配置中读取 meta_exclude，如果没有则使用默认值
DEFAULT_META_PATTERNS = [
    r"(skill.?router|路由|hook|插件|plugin).*(改|修|加|删|优化|完善|升级|更新|发布|推送|push)",
    r"(改|修|加|删|优化|完善|升级).*(skill.?router|路由|hook|插件|plugin)",
    r"(给我|帮我).*(看|列|说|讲|介绍).*(skill|插件|plugin|hook|配置)",
    r"(安装|卸载|启用|禁用).*(skill|插件|plugin)",
    r"(skill|插件).*(是什么|干什么|怎么用|有哪些)",
    r"github.*(push|推|发布|开源|仓库)",
    r"(发布|推送|开源|上传).*github",
]
META_PATTERNS = config.get("meta_exclude", DEFAULT_META_PATTERNS)

for pat in META_PATTERNS:
    if re.search(pat, msg_lower):
        sys.exit(0)

# ================================================================
# Layer 3: 关键词匹配 + 优先级评分 + 排除关键词
# ================================================================

# 优先级权重
PRIORITY_WEIGHT = {"critical": 4, "high": 3, "medium": 2, "low": 1}

matches = []
for rule in rules:
    keywords = rule.get("keywords", [])
    exclude_keywords = rule.get("exclude_keywords", [])

    # 检查排除关键词：如果任何一个匹配，跳过此规则
    excluded = False
    for ekw in exclude_keywords:
        if re.search(ekw.lower(), msg_lower):
            excluded = True
            break
    if excluded:
        continue

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
    # 输出空第一行（无 result），第二行 log info
    msg_short = msg_stripped[:50].replace('\t', ' ').replace('\n', ' ')
    print("")
    print(f"{msg_short}\t(none)\tnone")
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
        msg_short = msg_stripped[:50].replace('\t', ' ').replace('\n', ' ')
        print(make_output(ctx))
        print(f"{msg_short}\t{m['skill']}\tsingle")
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

msg_short = msg_stripped[:50].replace('\t', ' ').replace('\n', ' ')
matched_skills = ",".join(skill_names)
print(make_output(ctx))
print(f"{msg_short}\t{matched_skills}\t{mode}")
PYEOF
)

# 分离 Python 输出：第1行是 RESULT JSON，第2行是 log info
RESULT=$(echo "$FULL_OUTPUT" | head -n 1)
LOG_INFO=$(echo "$FULL_OUTPUT" | tail -n 1)

# 写入日志
if [ -n "$LOG_INFO" ]; then
    LOG_FILE="$HOME/.claude/skill-router-log.tsv"
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${TIMESTAMP}\t${LOG_INFO}" >> "$LOG_FILE"
fi

# 输出 RESULT
[ -n "$RESULT" ] && echo "$RESULT"
exit 0
