#!/bin/bash
# Skill Router Sync: 自动扫描所有 skill/插件/MCP，生成 skill-router.json
# 用法: bash ~/.claude/skill-router-sync.sh [--check]

CLAUDE_DIR="$HOME/.claude"
ROUTER_JSON="$CLAUDE_DIR/skill-router.json"
COMMANDS_DIR="$CLAUDE_DIR/commands"
CHECK_MODE="${1:-}"

# --check 模式：只读取现有规则并输出状态报告
if [ "$CHECK_MODE" = "--check" ]; then
    python3 << 'CHECKEOF'
import json, os, re, glob

claude_dir = os.path.expanduser("~/.claude")
commands_dir = os.path.join(claude_dir, "commands")
router_file = os.path.join(claude_dir, "skill-router.json")
settings_file = os.path.join(claude_dir, "settings.json")

# 读规则
rules = []
if os.path.exists(router_file):
    with open(router_file) as f:
        rules = json.load(f).get("rules", [])

# 读 skill 文件
skills = [os.path.splitext(os.path.basename(f))[0] for f in glob.glob(os.path.join(commands_dir, "*.md"))]

# 读插件
plugins = []
if os.path.exists(settings_file):
    with open(settings_file) as f:
        plugins = list(json.load(f).get("enabledPlugins", {}).keys())

# 读 MCP
mcp_count = 0
for mcp_path in [os.path.join(claude_dir, ".mcp.json"), ".mcp.json"]:
    if os.path.exists(mcp_path):
        with open(mcp_path) as f:
            mcp_count += len(json.load(f).get("mcpServers", {}))

# 检查 hook
hook_ok = False
if os.path.exists(settings_file):
    with open(settings_file) as f:
        hook_ok = "skill-router" in f.read()

# Read version from VERSION file
version = "unknown"
for vpath in [
    os.path.join(claude_dir, "VERSION"),
    os.path.join(os.path.expanduser("~/workspace/skill-router"), "VERSION"),
]:
    if os.path.exists(vpath):
        with open(vpath) as vf:
            version = vf.read().strip()
        break

print(f"=== Skill Router Status (v{version}) ===")
print(f"Skills:  {len(skills)} ({', '.join(sorted(skills)) if skills else 'none'})")
print(f"Plugins: {len(plugins)} ({', '.join(p.split('@')[0] for p in plugins) if plugins else 'none'})")
print(f"MCP:     {mcp_count}")
print(f"Rules:   {len(rules)} active rules")
print(f"Hooks:   {'OK' if hook_ok else 'NOT CONFIGURED'}")
print()

# 测试匹配
test_cases = [
    ("帮我优化打包", "优化.*打包|打包.*优化|优化.{0,6}打包"),
    ("帮我调研方案", "调研|方案对比|技术选型"),
    ("帮我提交代码", "提交.*代码|commit|帮我提交"),
    ("帮我制定学习计划", "学习计划|学习路线"),
    ("多agent协作完成任务", "多.*agent|协作|子agent"),
]

print("Sample matches:")
for test_msg, _ in test_cases:
    matched = None
    for rule in rules:
        for kw in rule.get("keywords", []):
            if re.search(kw.lower(), test_msg.lower()):
                matched = rule["skill"]
                break
        if matched:
            break
    if matched:
        print(f'  "{test_msg}" -> {matched}')
    else:
        print(f'  "{test_msg}" -> (no match)')

# 检查未注册的 skill
registered = {r["skill"] for r in rules}
unregistered = [s for s in skills if s not in registered]
if unregistered:
    print(f"\nUnregistered skills: {', '.join(unregistered)}")
    print("Run: bash ~/.claude/skill-router-sync.sh")

print("===========================")
CHECKEOF
    exit 0
fi

python3 << 'PYEOF'
import json, os, re, glob, sys

claude_dir = os.path.expanduser("~/.claude")
commands_dir = os.path.join(claude_dir, "commands")
router_file = os.path.join(claude_dir, "skill-router.json")

# 加载已有规则（保留用户手动加的自定义 keywords）
existing_rules = {}
if os.path.exists(router_file):
    try:
        with open(router_file) as f:
            for rule in json.load(f).get("rules", []):
                existing_rules[rule["skill"]] = rule
    except:
        pass

rules = []

# ================================================================
# 1. 扫描 ~/.claude/commands/*.md — Skill 文件
# ================================================================
if os.path.isdir(commands_dir):
    for md_file in sorted(glob.glob(os.path.join(commands_dir, "*.md"))):
        skill_name = os.path.splitext(os.path.basename(md_file))[0]

        with open(md_file, "r", encoding="utf-8") as f:
            content = f.read()

        # 提取 frontmatter description
        description = ""
        fm_match = re.search(r'^---\s*\n(.*?)\n---', content, re.DOTALL)
        if fm_match:
            fm = fm_match.group(1)
            desc_match = re.search(r'description:\s*[|>]?\s*\n?\s*(.+)', fm)
            if desc_match:
                description = desc_match.group(1).strip()[:80]

        # 如果没有 frontmatter description，取第一行非空非标题内容
        if not description:
            for line in content.split("\n"):
                line = line.strip()
                if line and not line.startswith("#") and not line.startswith("---") and not line.startswith("用户输入"):
                    description = line[:80]
                    break

        # 自动生成关键词：从 skill 名 + description + 内容中提取
        auto_keywords = []

        # skill 名本身
        auto_keywords.append(skill_name.replace("-", ".?"))

        # 从 description 提取中文关键词（2-4字的词），过滤通用词
        STOP_WORDS = {
            # 原有停用词
            "你是一个", "一个", "用户", "输入", "以下", "可以", "使用", "进行", "通过", "根据",
            "如果", "需要", "支持", "包含", "在执行", "任何", "在执", "任务之", "何任务", "完成后",
            "按模块", "功能细", "灵感来",
            # 常见中文填充/虚词
            "这个", "那个", "什么", "为什么", "怎么", "这些", "那些", "哪些", "或者", "但是",
            "然后", "因为", "所以", "虽然", "不过", "只是", "而且", "并且", "已经", "正在",
            "应该", "能够", "必须", "可能", "当然", "其实", "确实", "一定", "非常", "特别",
            # 动词/助词类
            "实现", "完成", "执行", "处理", "确保", "提供", "生成", "创建", "定义", "开始",
            "结束", "继续", "返回", "输出", "请求", "响应", "调用", "获取", "设置", "更新",
            # 代词/指示词
            "自己", "我们", "他们", "它们", "大家", "所有", "每个", "其中", "之间", "之前",
            "之后", "以上", "以下", "左右", "上面", "下面", "里面", "外面",
            # 常见无意义组合
            "的时候", "一下", "一些", "来自", "关于", "对于", "至少", "最多", "同时", "主要",
            "具体", "相关", "基于", "适合", "合适", "方式", "方法", "步骤", "过程", "结果",
            "情况", "问题", "功能", "模块", "系统", "项目", "文件", "代码", "数据", "内容",
        }
        cn_words = [w for w in re.findall(r'[\u4e00-\u9fff]{2,4}', description) if w not in STOP_WORDS]
        auto_keywords.extend(cn_words[:5])

        # 从内容中提取信号词标记
        signal_match = re.findall(r'信号词[：:]\s*(.+)', content)
        for sig in signal_match:
            words = re.findall(r'[\u4e00-\u9fff]{2,6}|[a-zA-Z]{3,}', sig)
            auto_keywords.extend(words[:8])

        # 从参数说明中提取示例用词
        example_match = re.findall(r'/\w+\s+(.{2,20}?)(?:\s+--|$)', content)
        for ex in example_match:
            words = re.findall(r'[\u4e00-\u9fff]{2,4}', ex)
            auto_keywords.extend(words[:3])

        # 去重
        seen = set()
        unique_keywords = []
        for kw in auto_keywords:
            kw_lower = kw.lower()
            if kw_lower not in seen and len(kw) >= 2:
                seen.add(kw_lower)
                unique_keywords.append(kw)

        # 如果已有用户自定义规则
        if skill_name in existing_rules:
            old_rule = existing_rules[skill_name]
            # manual=True 的规则完全保留，不覆盖任何字段
            if old_rule.get("manual"):
                rules.append(old_rule)
                continue
            # 非 manual 的规则合并关键词
            old_kws = set(old_rule.get("keywords", []))
            new_kws = set(unique_keywords)
            merged = list(old_kws | new_kws)
            priority = old_rule.get("priority", "medium")
            description = old_rule.get("description", description)
        else:
            merged = unique_keywords
            priority = "medium"

        rules.append({
            "skill": skill_name,
            "priority": priority,
            "keywords": merged[:20],
            "description": description,
            "source": "commands"
        })

# ================================================================
# 2. 扫描插件（从 settings.json 的 enabledPlugins）
# ================================================================
settings_file = os.path.join(claude_dir, "settings.json")
if os.path.exists(settings_file):
    try:
        with open(settings_file) as f:
            settings = json.load(f)

        plugins = settings.get("enabledPlugins", {})
        for plugin_key, enabled in plugins.items():
            if not enabled:
                continue
            plugin_name = plugin_key.split("@")[0]

            # 跳过不需要手动调用的插件（自动生效的）
            auto_plugins = {"superpowers", "rust-analyzer-lsp"}
            if plugin_name in auto_plugins:
                continue

            # PUA 有自己的触发机制，不需要 router
            if plugin_name == "pua":
                continue

            # 其他插件加入路由
            if plugin_name not in existing_rules:
                rules.append({
                    "skill": plugin_name,
                    "priority": "low",
                    "keywords": [plugin_name.replace("-", ".?")],
                    "description": f"插件: {plugin_name}",
                    "source": "plugin"
                })
    except:
        pass

# ================================================================
# 3. 扫描 MCP Servers（从 .mcp.json）
# ================================================================
mcp_locations = [
    os.path.join(claude_dir, ".mcp.json"),
    os.path.join(os.getcwd(), ".mcp.json"),
]
for mcp_file in mcp_locations:
    if os.path.exists(mcp_file):
        try:
            with open(mcp_file) as f:
                mcp_config = json.load(f)

            servers = mcp_config.get("mcpServers", {})
            for server_name, server_config in servers.items():
                if server_name not in existing_rules:
                    # 从 server 名称生成关键词
                    keywords = [server_name.replace("-", ".?")]
                    # 从 command/args 提取线索
                    cmd = server_config.get("command", "")
                    if cmd:
                        keywords.append(os.path.basename(cmd).split(".")[0])

                    rules.append({
                        "skill": f"mcp__{server_name}",
                        "priority": "low",
                        "keywords": keywords,
                        "description": f"MCP Server: {server_name}",
                        "source": "mcp"
                    })
        except:
            pass

# ================================================================
# 4. 扫描项目级 skill（.claude/commands/）
# ================================================================
project_commands = os.path.join(os.getcwd(), ".claude", "commands")
if os.path.isdir(project_commands) and project_commands != commands_dir:
    for md_file in glob.glob(os.path.join(project_commands, "*.md")):
        skill_name = os.path.splitext(os.path.basename(md_file))[0]
        if any(r["skill"] == skill_name for r in rules):
            continue  # 全局已有，跳过

        with open(md_file, "r", encoding="utf-8") as f:
            first_line = ""
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and not line.startswith("---"):
                    first_line = line[:80]
                    break

        rules.append({
            "skill": skill_name,
            "priority": "medium",
            "keywords": [skill_name.replace("-", ".?")],
            "description": first_line or f"项目 Skill: {skill_name}",
            "source": "project"
        })

# ================================================================
# 输出
# ================================================================
output = {"rules": rules}

with open(router_file, "w", encoding="utf-8") as f:
    json.dump(output, f, indent=2, ensure_ascii=False)

print(f"Skill Router 已同步:")
print(f"  Skills:  {sum(1 for r in rules if r.get('source') == 'commands')}")
print(f"  Plugins: {sum(1 for r in rules if r.get('source') == 'plugin')}")
print(f"  MCP:     {sum(1 for r in rules if r.get('source') == 'mcp')}")
print(f"  Project: {sum(1 for r in rules if r.get('source') == 'project')}")
print(f"  Total:   {len(rules)} rules → {router_file}")
PYEOF
