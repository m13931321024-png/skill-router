# Skill Router for Claude Code

让 Claude Code 根据你说的话自动调用对应的 Skill，不需要记命令名。

## 效果

```
你说："帮我优化打包体积"     → 自动调用 /autoresearch
你说："帮我调研技术方案"     → 自动调用 /research  
你说："帮我提交代码"         → 自动调用 /smart-commit
你说："帮我打开个文件"       → 无匹配，正常执行
```

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/skill-router/main/install.sh | bash
```

或手动安装：

```bash
git clone https://github.com/YOUR_USERNAME/skill-router.git
cd skill-router
bash install.sh
```

## 工作原理

1. `UserPromptSubmit` hook 拦截每条用户消息
2. `skill-router.sh` 用关键词匹配 `skill-router.json` 里的规则
3. 匹配成功 → 注入指令到 Claude 上下文，让它调用对应 Skill
4. 匹配失败 → 不干扰，正常执行

## 自定义规则

编辑 `~/.claude/skill-router.json`，添加你自己的 skill：

```json
{
  "rules": [
    {
      "skill": "你的skill名",
      "keywords": ["触发词1", "触发词2", "正则也行.*"],
      "description": "一句话描述"
    }
  ]
}
```

关键词支持正则表达式。

## 配合使用

- [superpowers](https://github.com/obra/superpowers) — agent 工作纪律
- [pua](https://github.com/tanweai/pua) — agent 工作态度
- 你自己写的任何 `~/.claude/commands/*.md` skill

## 文件结构

```
~/.claude/
  skill-router.sh        # 路由脚本（hook 调用）
  skill-router.json      # 路由规则配置
  settings.json          # ← install.sh 自动注入 hook
  commands/
    autoresearch.md      # 示例 skill
    research.md          # 示例 skill
    ...
```

## License

MIT
