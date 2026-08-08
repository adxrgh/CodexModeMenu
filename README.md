# Codex 模式菜单栏工具 (CodexModeMenu)

一个 macOS 菜单栏小工具:在 **GPT 主控** 与 **DeepSeek 全量模式** 之间一键切换 Codex 的 model 配置,并在状态栏直接显示 GPT 套餐额度(剩余用量 / 重置时间)。全部数据来自本地 `~/.codex`,只读监测,不修改任何服务端状态。

## 功能

- 🎯 **一键切换模式**:点击菜单栏图标,切换 Codex 的 `config.toml` 到 GPT 或 DeepSeek(通过本地 `switch-client-mode.py` 脚本)
- 📊 **GPT 额度显示**:只读调用 `chatgpt.com/backend-api/wham/usage`,显示 pro/plus 套餐剩余百分比、重置时间;状态栏标题附带 `▸ 剩余 X%`
- 🕘 **历史对话列表**:从本地 `~/.codex/session_index.jsonl` 读取跨模式会话,点击后通过 `codex://threads` deep link 直接在 Codex App 内打开
- 🔄 额度每 60 秒静默刷新一次,点击菜单项可立即手动刷新

## 工作原理

```
┌─────────────────────────────────────────────────────┐
│  Codex 模式菜单栏工具 (SwiftUI/AppKit, macOS 13+)      │
│                                                     │
│  ├─ 模式切换 → 修改 ~/.codex/config.toml (model/provider)
│  ├─ 额度查询 → GET chatgpt.com/backend-api/wham/usage
│  │            (Authorization: Bearer ~/.codex/auth.json)
│  └─ 历史会话 → 读 ~/.codex/session_index.jsonl + rollouts
└─────────────────────────────────────────────────────┘
```

> 额度查询走系统代理(macOS 自动读取系统 HTTP 代理设置)。若 Clash Party 等代理把 `chatgpt.com` 分流为直连,请在代理的分流规则中把 OpenAI 域名加入代理规则。

## 安装

```bash
git clone <your-fork-url>
cd CodexModeMenu
./script/build_and_run.sh install
```

依赖:`swift` 5.9+、macOS 13+。

> ⚠️ 首次安装需要 `switch-client-mode.py` 脚本存在于 `~/.codex/codex-deepseek-go/bin/`。该脚本负责改写 `~/.codex/config.toml`,是本工具模式切换的核心依赖,请按你的环境自行准备(示例见 `script/` 目录说明)。

## 使用

- 点击菜单栏图标 → 切换模式 / 查看额度 / 打开历史对话
- 点击「GPT 额度」行 → 立即刷新额度

## 数据与隐私

- 仅读取本地 `~/.codex/` 下的文件(`config.toml`、`auth.json`、`session_index.jsonl`、`sessions/`)
- 额度查询仅携带 `Authorization` 头读取用量,不做任何写入
- 运行时日志只写在本地 `runtime/` 目录,已被 `.gitignore` 排除

## 测试

```bash
swift test
```

覆盖:配置解析、会话索引读取、额度 JSON 解析(含空响应容错)。
