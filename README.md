# yt2podcast

把 YouTube 视频变成**中文对谈播客**，自动上传到[小宇宙](https://www.xiaoyuzhoufm.com/)（默认草稿）。
给 AI agent 用的 OpenClaw skill：一条链接进去，十几分钟后一条中文播客草稿出来。

```
YouTube 链接
   │  new-job.sh  (建 job 文件)
   ▼
background worker (python3, 不依赖 LLM)
   ├─ sourcing    NotebookLM: 建 notebook → 加 YouTube 源 → 读中文摘要
   ├─ generating  Audio Overview 生成 + 下载音频（自动走代理）
   ├─ postprocess ffmpeg 转 128k m4a + 内嵌封面/元数据
   └─ uploading   opencli xiaoyuzhou upload --draft
   ▼
openclaw system event 唤醒会话 → agent 发中文通知（含链接）
```

## 特性

- **一条命令一条龙**：取源、生成、转码、上传、通知全自动，agent 只负责"识别链接 + 回执 + 结果播报"。
- **不烧配额的重试**：job 文件记录 `notebook_id` / `source_id` / `stages_done`，失败后 `--rerun` 从断点续跑，不重建 notebook、不重复生成音频。
- **草稿优先，公开需双授权**：默认只存草稿；要公开发布必须同时给 `--publish` 和
  `YT2PODCAST_ALLOW_PUBLISH=1`，否则直接报 `PUBLISH_NOT_ALLOWED`（公开不可撤销）。
- **国内网络友好**：自动读 macOS 系统代理（`scutil --proxy`）并注入 `NODE_USE_ENV_PROXY`，解决 `lh3.googleusercontent.com` 直连超时。
- **URL 归一化**：`youtu.be/xxx?si=...` 这类带追踪参数的短链会先转成 `watch?v=<id>` 再喂 NotebookLM。
- **串行安全**：文件锁 `jobs/.worker.lock`，一次只跑一个 job。
- **可离线自检**：`--dry-run` 只跑状态机，不调外部命令。

## 依赖

| 依赖 | 说明 |
| --- | --- |
| [OpenClaw](https://docs.openclaw.ai) | agent 运行环境（提供 exec / system event / skills） |
| [opencli](https://www.npmjs.com/package/@jackwener/opencli) + `notebooklm` adapter | NotebookLM 建本、加源、生成、下载 |
| [opencli](https://www.npmjs.com/package/@jackwener/opencli) + `xiaoyuzhou` adapter | 上传到小宇宙 |
| `ffmpeg` / `ffprobe` | 转码 m4a、读时长 |
| Chrome 登录态 | notebook.google.com 与 podcaster.xiaoyuzhoufm.com 都要登录（persistent session） |
| 可访问 Google 的网络 | 音频文件在 `lh3.googleusercontent.com` |

## 安装

```bash
git clone https://github.com/<owner>/yt2podcast ~/.openclaw/workspace/coding/yt2podcast
ln -sfn ~/.openclaw/workspace/coding/yt2podcast ~/.openclaw/skills/yt2podcast
openclaw skills list      # 出现 yt2podcast 即安装成功
```

设置你的小宇宙节目 id（代码里没有默认值）：

```bash
export YT2PODCAST_PODCAST_ID="<podcast id>"
```

## 使用

### 让 agent 用（推荐）

在聊天里直接发 YouTube 链接即可。agent 会读 `SKILL.md` 的流程：
取元数据 → `new-job.sh --no-start` 建 job → 用后台托管跑 `worker.py` → 秒回执 → 完成后播报。

### 手工跑

```bash
# 建 job（不启动）
bash scripts/new-job.sh "https://youtu.be/<id>" \
  --podcast "<podcast id>" \
  --title "中文播客名" \
  --description "一句话简介"

# 跑流水线（在生产里请放到后台托管，别用 nohup，见"已知坑"）
python3 scripts/worker.py <video_id>

# 失败后断点重跑（复用 notebook，不重复消耗生成配额）
python3 scripts/worker.py <video_id> --rerun

# 只补发通知
python3 scripts/worker.py <video_id> --notify-only

# 离线自检状态机
python3 scripts/worker.py <video_id> --dry-run
```

## 配置（环境变量）

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `YT2PODCAST_ROOT` | `~/.openclaw/workspace/yt2podcast` | job 数据根目录 |
| `YT2PODCAST_PODCAST_ID` | 空（必填） | 小宇宙节目 id，或被 `--podcast` 覆盖 |
| `YT2PODCAST_PROXY` | 空（读系统代理） | 访问 Google 的 HTTP 代理 |
| `YT2PODCAST_FFMPEG` / `YT2PODCAST_FFPROBE` | `which` 结果 | 自定义 ffmpeg 路径 |
| `YT2PODCAST_TIMEOUT_*` | 见 worker.py | 各阶段超时（秒），排障时可调小 |

## 安全说明

执行的外部命令、网络访问、文件写入范围、发布授权门槛、进程生命周期（**不自行 detach、不装
cron/systemd**）与"无遥测"承诺，都写在 [SECURITY.md](./SECURITY.md)。

## 已知坑（都已修，留档避免回归）

1. **worker 启动即被杀**：OpenClaw 的 exec 在回合结束时会 kill 整个进程组（`treeOwnership: process-group`），`nohup ... &` 不顶用，job 会永远停在第一阶段且**没有任何通知**。
   → 用 exec 的 `background: true` 托管；`new-job.sh` 的内部启动也加了 setsid 兜底。
2. **AddSources RPC 静默失败**：`youtu.be/xxx?si=...` 带追踪参数会让 NotebookLM 加源返回 no source id。
   → `canonical_youtube_url()` 统一成 `https://www.youtube.com/watch?v=<id>`。
3. **下载音频 `fetch failed`**：音频在 `lh3.googleusercontent.com`，国内直连超时；opencli 用 Node fetch，不读 macOS 系统代理。
   → `system_proxy()` + `child_env()` 注入 `HTTP(S)_PROXY` 和 `NODE_USE_ENV_PROXY=1`。

## 实测数据

源视频 2 小时 14 分（Cheeky Pint，Zuckerberg 访谈）：

| 阶段 | 耗时 |
| --- | --- |
| sourcing（建本 + 加源 + 摘要） | 约 25 秒 |
| generating（生成 + 下载 194MB wav） | 约 8 分钟（代理慢时下载约 25 KB/s） |
| postprocess（转 128k m4a，17.8 MB） | 14 秒 |
| uploading（小宇宙草稿） | 18 秒 |
| **成片** | 19 分 15 秒 / 17.8 MB |

## 目录结构

```
yt2podcast/
├── SKILL.md            # agent 读的流程说明（核心）
├── scripts/
│   ├── new-job.sh      # 建 job +（可选）启动 worker
│   └── worker.py       # 五阶段流水线（不依赖 LLM）
├── CHANGELOG.md
└── LICENSE
```

## 发布到 ClawHub

这是一个 **skill**（流程说明 + 脚本），不是 plugin（不注册工具/渠道）。

```bash
npm i -g clawhub
clawhub login
clawhub skill publish ./yt2podcast --version 0.1.0
```

## License

MIT
