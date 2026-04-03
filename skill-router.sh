#!/bin/bash
# Skill Router v5: 提示词优化 + 优先级 + 依赖分析 + 排除关键词 + 日志 + 自动同步
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
# Mid-session sync
# ================================================================
SYNC_SCRIPT="$HOME/.claude/skill-router-sync.sh"
ROUTER_JSON="$HOME/.claude/skill-router.json"
COMMANDS_DIR="$HOME/.claude/commands"
LAST_SYNC_FILE="$HOME/.claude/.skill-router-last-sync"

if [ -d "$COMMANDS_DIR" ] && [ -f "$ROUTER_JSON" ] && [ -f "$SYNC_SCRIPT" ]; then
    COMMANDS_MTIME=$(stat -f "%m" "$COMMANDS_DIR" 2>/dev/null || stat -c "%Y" "$COMMANDS_DIR" 2>/dev/null || echo 0)
    JSON_MTIME=$(stat -f "%m" "$ROUTER_JSON" 2>/dev/null || stat -c "%Y" "$ROUTER_JSON" 2>/dev/null || echo 0)
    if [ "$COMMANDS_MTIME" -gt "$JSON_MTIME" ] 2>/dev/null; then
        NEED_SYNC=true
        if [ -f "$LAST_SYNC_FILE" ]; then
            LAST_SYNC=$(cat "$LAST_SYNC_FILE" 2>/dev/null || echo 0)
            NOW=$(date +%s)
            if [ $((NOW - LAST_SYNC)) -lt 300 ]; then NEED_SYNC=false; fi
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

# 全部逻辑在 Python 中完成
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
# Layer 0: 智能过滤
# ================================================================
if len(msg_stripped) <= 5:
    sys.exit(0)

SKIP_PATTERNS = [
    r"^(好的?|ok|yes|no|对|嗯|继续|确认|可以|不行|停|取消|谢谢|明白|收到|知道了|是的|没有|有的|算了)$",
    r"^(这样可以吗|可以吗|行吗|对吗|是吗|怎么样|什么意思|为什么|是什么|怎么了|什么情况)$",
    r"^(看看|帮我看|你看一下|给我看).{0,4}$",
    r"^\?+$", r"^!", r"^\[Image",
    r"^(哈哈|呵呵|嘿嘿|666|牛|厉害|不错|漂亮)",
]
for pat in SKIP_PATTERNS:
    if re.search(pat, msg_stripped, re.IGNORECASE):
        sys.exit(0)

# ================================================================
# Layer 1: 加载规则
# ================================================================
try:
    with open(rules_file) as f:
        config = json.load(f)
    rules = config.get("rules", [])
except:
    sys.exit(0)

# ================================================================
# Layer 2: Meta 排除
# ================================================================
DEFAULT_META = [
    r"(skill.?router|路由|hook|插件|plugin).*(改|修|加|删|优化|完善|升级|更新|发布|推送|push)",
    r"(改|修|加|删|优化|完善|升级).*(skill.?router|路由|hook|插件|plugin)",
    r"(给我|帮我).*(看|列|说|讲|介绍).*(skill|插件|plugin|hook|配置)",
    r"(安装|卸载|启用|禁用).*(skill|插件|plugin)",
    r"(skill|插件).*(是什么|干什么|怎么用|有哪些)",
    r"github.*(push|推|发布|开源|仓库|删)",
    r"(发布|推送|开源|上传|删).*github",
]
for pat in config.get("meta_exclude", DEFAULT_META):
    if re.search(pat, msg_lower):
        sys.exit(0)

# ================================================================
# 关键词匹配函数（复用）
# ================================================================
PRIORITY_WEIGHT = {"critical": 4, "high": 3, "medium": 2, "low": 1}

def match_rules(text_lower, rules_list):
    """对给定文本执行关键词匹配，返回匹配结果列表"""
    results = []
    for rule in rules_list:
        exclude_kws = rule.get("exclude_keywords", [])
        excluded = any(re.search(ekw.lower(), text_lower) for ekw in exclude_kws)
        if excluded:
            continue

        hits = [kw for kw in rule.get("keywords", []) if re.search(kw.lower(), text_lower)]
        if hits:
            priority = rule.get("priority", "medium")
            results.append({
                "skill": rule["skill"],
                "description": rule.get("description", ""),
                "priority": priority,
                "score": (len(hits) / max(len(rule.get("keywords", [])), 1)) * PRIORITY_WEIGHT.get(priority, 2),
                "hits": hits,
            })
    results.sort(key=lambda x: x["score"], reverse=True)
    return results

# ================================================================
# Layer 3: 第一轮关键词匹配（原始消息）
# ================================================================
matches = match_rules(msg_lower, rules)

# ================================================================
# Layer 3.5: 提示词优化（仅当第一轮匹配不到时触发）
# ================================================================
prompt_enhanced = False
enhanced_msg = ""

if not matches and len(msg_stripped) >= 8:
    # 意图扩展表：把模糊表述映射到可能的意图关键词
    INTENT_EXPANSIONS = {
        # 性能相关
        r"(慢|卡|不快|速度|快一点|加速)": "优化 性能 速度",
        r"(大|太大|瘦身|减小|压缩)": "优化 体积 打包 bundle",
        r"(分数|得分|评分|跑分)": "优化 lighthouse 性能",
        # 代码质量
        r"(烂|乱|不好|难看|重构|整理)": "审计 代码质量 重构",
        r"(报错|错误|bug|崩|挂了|不work|不行)": "修复 调试 bug",
        r"(测试.*失败|test.*fail|跑不过)": "修复 测试",
        # 调研/学习
        r"(不懂|不理解|搞不清|什么是|怎么理解)": "调研 学习 研究",
        r"(用什么|选什么|哪个好|对比|比较)": "调研 技术选型 方案对比",
        r"(怎么学|学什么|入门|上手)": "学习计划 学习路线",
        # 提交/部署
        r"(改完了|写好了|搞定了|做完了)": "提交 commit",
        r"(提交|commit|push|推上去)": "提交 代码 commit",
        # 协作/拆分
        r"(太多了|拆.*开|分.*做|并行|一起)": "多 agent 协作 拆 任务",
        # 实验/迭代
        r"(试试|跑跑|实验|迭代|反复)": "自动 实验 autoresearch",
    }

    expanded_terms = []
    for pattern, expansion in INTENT_EXPANSIONS.items():
        if re.search(pattern, msg_lower):
            expanded_terms.append(expansion)

    if expanded_terms:
        # 把扩展词附加到原始消息后面做第二轮匹配
        enhanced_msg = msg_lower + " " + " ".join(expanded_terms)
        matches = match_rules(enhanced_msg, rules)
        if matches:
            prompt_enhanced = True

# ================================================================
# Layer 4: 路由决策
# ================================================================

def make_output(ctx):
    return json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": ctx
        }
    }, ensure_ascii=False)

msg_short = msg_stripped[:50].replace('\t', ' ').replace('\n', ' ')

# 没匹配到 → 放行
if not matches:
    print("")
    print(f"{msg_short}\t(none)\tnone")
    sys.exit(0)

# 提示词优化标记
enhance_note = ""
if prompt_enhanced:
    enhance_note = f"\n[提示词已优化] 原始表述较模糊，已自动识别意图。"

# --- 单 skill ---
if len(matches) == 1:
    m = matches[0]
    ctx = (
        f'[SKILL-ROUTER] 匹配到 skill: {m["skill"]}（{m["description"]}，'
        f'优先级: {m["priority"]}，命中: {",".join(m["hits"])}）。{enhance_note}\n'
        f'请先理解用户的真实意图，然后使用 Skill 工具调用 skill="{m["skill"]}"，'
        f'将用户的原始消息作为 args 传入。'
    )
    log_mode = "single+enhanced" if prompt_enhanced else "single"
    print(make_output(ctx))
    print(f"{msg_short}\t{m['skill']}\t{log_mode}")
    sys.exit(0)

# --- 多 skill ---
SEQ_PATTERNS = [
    r"(先|首先).*(然后|再|接着|之后)",
    r"(调研|研究|分析).*(然后|再).*(优化|修复|实现|开发)",
    r"(完成|做完|搞定).*(再|然后|接着)",
    r"(了解|弄清).*(再|然后|开始)",
]
has_explicit_seq = any(re.search(p, msg) for p in SEQ_PATTERNS)

DEPENDENCY_ORDER = {
    "research": 0, "learning-plan": 1, "autoresearch": 2,
    "audit": 2, "orchestrate": 3, "smart-commit": 4,
}

skill_names = [m["skill"] for m in matches[:3]]
skill_descs = [f'{m["skill"]}（{m["description"]}）' for m in matches[:3]]

if has_explicit_seq:
    mode = "serial"
else:
    orders = [DEPENDENCY_ORDER.get(s, 2) for s in skill_names]
    if len(set(orders)) == 1:
        mode = "parallel"
    else:
        mode = "serial"
        paired = sorted(zip(skill_names, skill_descs, orders), key=lambda x: x[2])
        skill_names = [p[0] for p in paired]
        skill_descs = [p[1] for p in paired]

skills_str = "、".join(skill_descs)

if mode == "serial":
    steps = "。".join([f'第{i+1}步 Skill 工具 skill="{s}"' for i, s in enumerate(skill_names)])
    ctx = (
        f'[SKILL-ROUTER 串行] 匹配到多个 skill: {skills_str}。{enhance_note}\n'
        f'按依赖顺序执行：{steps}。\n'
        f'前一个 skill 完成后再调用下一个。将用户原始消息作为 args 传入第一个 skill。'
    )
else:
    ctx = (
        f'[SKILL-ROUTER 并行] 匹配到多个 skill: {skills_str}。{enhance_note}\n'
        f'这些任务无依赖关系，可并行执行。\n'
        f'使用 Agent 工具为每个 skill 各启动一个子 agent 并行处理，'
        f'每个 agent 内部调用对应的 Skill 工具。'
    )

matched_skills = ",".join(skill_names)
log_mode = f"{mode}+enhanced" if prompt_enhanced else mode
print(make_output(ctx))
print(f"{msg_short}\t{matched_skills}\t{log_mode}")
PYEOF
)

# 分离输出
RESULT=$(echo "$FULL_OUTPUT" | head -n 1)
LOG_INFO=$(echo "$FULL_OUTPUT" | tail -n 1)

# 日志
if [ -n "$LOG_INFO" ]; then
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${TIMESTAMP}\t${LOG_INFO}" >> "$HOME/.claude/skill-router-log.tsv"
fi

# 输出
[ -n "$RESULT" ] && echo "$RESULT"
exit 0
