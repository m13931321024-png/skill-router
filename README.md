# Skill Router for Claude Code

**你说中文，Claude Code 自动调用对应的 Skill。不需要记命令名。**

---

## 效果演示

**Before** -- 手动调用 slash command：
```
你：/autoresearch 优化 form-engine 的打包体积
```

**After** -- 直接说话，自动路由：
```
你：帮我优化打包体积
  -> [Skill Router] 匹配到 autoresearch（自主实验循环），自动调用

你：帮我调研技术方案
  -> [Skill Router] 匹配到 research（需求调研），自动调用

你：帮我提交代码
  -> [Skill Router] 匹配到 smart-commit（智能提交），自动调用

你：帮我打开个文件
  -> 无匹配，Claude Code 正常执行，零干扰
```

多 Skill 串行也能自动处理：
```
你：先调研方案，再帮我优化打包
  -> [Skill Router 串行] research -> autoresearch，按依赖顺序执行
```

---

## 一键安装

```bash
git clone https://github.com/anthropics/skill-router.git
cd skill-router
bash install.sh
```

新用户（`~/.claude/commands/` 为空）会自动安装 5 个 Starter Skills。
已有 Skills 的用户不会被覆盖，只补充缺失的。

---

## 工作原理

```
用户说话
  |
  v
UserPromptSubmit Hook (skill-router.sh)
  |
  v
Layer 0: 智能过滤（短消息/确认/情绪 -> 放行）
  |
  v
Layer 1: 加载 skill-router.json 规则
  |
  v
Layer 2: 意图排除（讨论 router 本身 -> 放行）
  |
  v
Layer 3: 关键词匹配 + 优先级评分
  |
  v
Layer 4: 路由决策
  |-- 0 匹配 -> 放行，Claude Code 正常处理
  |-- 1 匹配 -> 注入指令调用该 Skill
  |-- N 匹配 -> 依赖分析，串行或并行执行
```

**SessionStart Hook** 负责每次开会话时自动扫描 `~/.claude/commands/`、插件、MCP Server，
生成 `skill-router.json`。新增 Skill 不需要手动改配置。

---

## 配置

### 路由规则

规则文件位于 `~/.claude/skill-router.json`，自动生成，也可手动编辑：

```json
{
  "rules": [
    {
      "skill": "autoresearch",
      "priority": "high",
      "keywords": ["优化打包", "修复.*测试", "bundle", "autoresearch"],
      "description": "自主实验循环 -- 代码优化或知识研究",
      "source": "commands"
    }
  ]
}
```

### 字段说明

| 字段 | 说明 |
|------|------|
| `skill` | Skill 名称（对应 `~/.claude/commands/<name>.md`） |
| `priority` | 优先级：`critical` > `high` > `medium` > `low` |
| `keywords` | 触发关键词数组，支持正则表达式 |
| `description` | 一句话描述，用于路由上下文注入 |
| `source` | 来源：`commands` / `plugin` / `mcp` / `project` |

### 优先级权重

| 优先级 | 权重 | 适用场景 |
|--------|------|----------|
| `critical` | 4x | 核心工作流，必须精确匹配 |
| `high` | 3x | 高频使用的 Skill |
| `medium` | 2x | 默认级别 |
| `low` | 1x | 辅助工具，不主动触发 |

匹配得分 = `命中关键词比例 x 优先级权重`，多个 Skill 匹配时取最高分。

### 添加自定义规则

手动同步后编辑：
```bash
# 先同步（确保自动规则是最新的）
bash ~/.claude/skill-router-sync.sh

# 然后编辑
vim ~/.claude/skill-router.json
```

手动添加的关键词在下次同步时会被保留（合并而非覆盖）。

---

## Starter Skills

安装时附带 5 个开箱即用的 Skill：

| Skill | 触发示例 | 说明 |
|-------|----------|------|
| `autoresearch` | "帮我优化打包体积" | 自主实验循环引擎，支持代码优化和知识研究两种模式 |
| `research` | "帮我调研技术方案" | 需求调研专家：问题清单 -> 方案对比 -> 执行摘要 |
| `smart-commit` | "帮我提交代码" | 按模块分批提交，中文 commit message |
| `orchestrate` | "多 agent 协作完成" | 子 Agent 任务拆解、并行派发、验收闭环 |
| `learning-plan` | "帮我制定学习计划" | 前端工程师向 AI 时代构建师转型的学习教练 |

所有 Starter Skills 源码在 `skills/` 目录，可自由修改。

---

## 自检命令

```bash
bash ~/.claude/skill-router-sync.sh --check
```

输出示例：
```
=== Skill Router Status ===
Skills:  5 (autoresearch, learning-plan, orchestrate, research, smart-commit)
Plugins: 0 (none)
MCP:     0 (none)
Rules:   5 active rules
Hooks:   OK

Sample matches:
  "帮我优化打包" -> autoresearch
  "帮我调研方案" -> research
  "帮我提交代码" -> smart-commit
  "帮我制定学习计划" -> learning-plan
  "多agent协作完成任务" -> orchestrate
===========================
```

---

## 卸载

```bash
cd skill-router
bash uninstall.sh
```

卸载只移除 router 自身的 3 个文件，**不会删除**你的 Skills、插件、MCP 配置。
settings.json 中的 hook 需要手动移除（脚本会给出提示）。

---

## 对比

| 特性 | Skill Router | [superpowers](https://github.com/obra/superpowers) | [pua](https://github.com/anthropics/pua) | [diet103](https://github.com/anthropics/diet103) |
|------|:---:|:---:|:---:|:---:|
| 定位 | Skill 自动路由 | Agent 工作纪律 | Agent 工作态度 | 轻量 Prompt |
| 自动调用 Skill | Yes | -- | -- | -- |
| 关键词匹配 | Yes (正则) | -- | 内置触发词 | -- |
| 多 Skill 串行/并行 | Yes | -- | -- | -- |
| 优先级系统 | 4 级 | -- | -- | -- |
| 自动扫描注册 | Yes | -- | -- | -- |
| 插件/MCP 整合 | Yes | -- | -- | -- |
| Hook 机制 | UserPromptSubmit | PreToolUse/PostToolUse | UserPromptSubmit | -- |
| 可组合使用 | Yes | Yes (互补) | Yes (互补) | Yes |

**推荐组合**：Skill Router（自动调用）+ superpowers（工作纪律）+ pua（工作态度）

---

## 架构

```
~/.claude/
  settings.json               # Hook 配置入口
    |-- SessionStart hook ---> skill-router-sync.sh    # 自动扫描生成规则
    |-- UserPromptSubmit hook -> skill-router.sh       # 实时路由匹配
  skill-router.json            # 路由规则（自动生成 + 手动自定义）
  commands/
    autoresearch.md            # Skill 文件
    research.md                #   |
    smart-commit.md            #   |-- skill-router-sync.sh 扫描这些
    orchestrate.md             #   |
    learning-plan.md           #   |
    ...                        #   v
                               # 生成 skill-router.json 中的规则

skill-router/                  # 项目仓库
  install.sh                   # 安装脚本
  uninstall.sh                 # 卸载脚本
  skill-router.sh              # 路由核心（复制到 ~/.claude/）
  skill-router-sync.sh         # 同步脚本（复制到 ~/.claude/）
  skills/                      # Starter Skill Pack
    autoresearch.md
    research.md
    smart-commit.md
    orchestrate.md
    learning-plan.md
```

---

## Contributing

欢迎贡献：

1. **新增 Starter Skill** -- 添加 `.md` 文件到 `skills/` 目录
2. **改进关键词提取** -- 修改 `skill-router-sync.sh` 中的 Python 逻辑
3. **改进路由决策** -- 修改 `skill-router.sh` 中的匹配/评分算法
4. **Bug 修复** -- Issue + PR

Skill 文件格式参考 `skills/research.md`（最简单的例子）。

---

## License

MIT
