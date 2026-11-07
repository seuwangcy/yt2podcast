---
name: yt2podcast
description: 把 YouTube 视频变成中文音频播客，用 NotebookLM Audio Overview 生成、ffmpeg 转码，再上传小宇宙；默认只存草稿，用户明确要求时才公开发布；完成后回推一条结果通知。用户从微信/聊天里发来 YouTube 链接时使用。
metadata:
  openclaw:
    requires:
      bins: ["opencli", "ffmpeg", "ffprobe"]
---

# yt2podcast：YouTube → 中文播客 → 小宇宙

把一个 YouTube 视频用 NotebookLM 的 Audio Overview 做成中文对谈播客，
再上传到小宇宙（默认**草稿**，不公开发布）。

## 能力与风险声明（Capabilities & Safety）

ClawHub 的自动扫描会检查"行为是否超出描述"。本 skill 的行为范围如下，全部为明示能力，没有隐藏动作：

**会执行的外部命令**
- `opencli youtube video`（只读，取标题/时长）
- `opencli notebooklm create / add-source / source-guide / open / download-audio`（建本、加源、生成并下载音频）
- `opencli xiaoyuzhou upload`（上传节目）
- `ffmpeg` / `ffprobe`（转码与取时长）
- `openclaw system event`（跑完唤醒发起会话，发一条中文通知）

**网络访问**：YouTube（元数据）、notebook.google.com（生成）、lh3.googleusercontent.com（下载音频，可能需要代理）、xiaoyuzhoufm.com（上传）。

**文件写入**：只写 `${YT2PODCAST_ROOT}`（默认 `~/.openclaw/workspace/yt2podcast`）下的 `jobs/`。不读不写用户其它目录，不上传任何本地文件到第三方（唯一上传目标是小宇宙，内容是本次生成的音频）。

**公开发布能力（重要）**：默认 `--draft`，只存草稿。公开发布需要**双重显式授权**：
`--publish` 且环境变量 `YT2PODCAST_ALLOW_PUBLISH=1`，缺一个就直接报错拒绝
（`PUBLISH_NOT_ALLOWED`）。公开发布不可撤销，只有在用户明确要求时才可用。

**进程生命周期**：本 skill 不自行 detach 进程——worker 由调用方（agent 的宿主、
用户终端、或宿主托管的后台任务）启动，随宿主结束而结束；不安装 systemd/cron/开机项。

**通知行为**：任务结束（成功或失败）会主动唤醒发起会话并推送一条中文消息，这是用户预期内的结果回执，不是营销推送。

**无遥测**：本 skill 不含任何统计、上报、埋点。

## 依赖（缺一样都跑不通）

| 依赖 | 用途 | 检查 |
| --- | --- | --- |
| `opencli` + `notebooklm` adapter | 建 notebook、加源、生成/下载音频 | `opencli notebooklm list` |
| `opencli` + `xiaoyuzhou` adapter | 上传节目到小宇宙 | `opencli xiaoyuzhou --help` |
| `ffmpeg` / `ffprobe` | 转码 m4a、取时长 | `ffmpeg -version` |
| Chrome 登录态（persistent session） | notebook.google.com + podcaster.xiaoyuzhoufm.com | 出错会报 `NEED_LOGIN` |
| Google 可达的网络 | 音频文件在 `lh3.googleusercontent.com`，国内直连会失败 | 见"网络代理" |
| `openclaw` CLI | worker 跑完后唤醒会话 | `openclaw --version` |

**小宇宙节目 id 必须自己提供**（`--podcast` 或环境变量 `YT2PODCAST_PODCAST_ID`），代码里没有默认值。

## 目录约定

| 东西 | 路径 |
| --- | --- |
| skill 根目录 | `{baseDir}`（本 SKILL.md 所在目录） |
| 运行数据根目录 | `${YT2PODCAST_ROOT:-$HOME/.openclaw/workspace/yt2podcast}` |
| job 文件 | `<root>/jobs/<video_id>.json` |
| job 目录 | `<root>/jobs/<video_id>/`（worker.log / audio.wav / cover.jpg / episode.m4a / notify.json） |

## 第一步：收到链接时

1. 从消息里挑出 YouTube 链接（`youtu.be/`、`watch?v=`、`/shorts/`、`/live/` 都行；`?si=` 之类的追踪参数由脚本自动去掉）。
2. 读标题和时长（只读，不耗配额）：

   ```bash
   opencli youtube video "<url>" -f json      # data 是 [{field,value}]，取 title / duration
   ```

3. 建 job（只落文件，不启动）：

   ```bash
   bash {baseDir}/scripts/new-job.sh "<url>" \
     --podcast "<小宇宙节目id>" \
     --title "<中文播客名>" \
     --description "<一句话中文简介>" \
     --session-key "<当前会话 key>"
   ```

   - 本脚本**只建 job 文件，从不启动 worker**（不会 fork、不会 nohup、不会 setsid）。
   - `"existing": true` → 这个视频已在跑，别重复起，直接回执。
   - `stage: failed` → 先按"排障"处理，重跑加 `--retry`。
   - 默认草稿；用户明确要求公开发布才加 `--publish`。

4. **启动 worker —— 必须用后台托管，不要用 nohup**：

   用 exec 工具以 `background: true` 运行：

   ```bash
   python3 {baseDir}/scripts/worker.py <video_id>
   ```

   > ⚠️ 关键坑：OpenClaw 的 exec 在回合结束时会 kill 整个进程组（日志里能看到
   > `treeOwnership: process-group`）。普通 `nohup ... &` 起的 worker 会被立刻杀掉，
   > job 永远停在第一个阶段，而且**不会**有失败通知。所以必须用宿主的 background 托管能力，
   > 不要自己 detach。

5. **秒回执**（一条消息，然后结束本回合）：

   ```
   ✅ 已收到《<中文播客名>》，原视频 <时长>，正在生成音频，大约 10–20 分钟。
   完成后我把播客链接发你。
   ```

   不要 sleep、不要轮询 job 文件；worker 结束时自己唤醒。

## 第二步：收到唤醒时

worker 结束时执行 `openclaw system event --text "yt2podcast {...}" --mode now` 唤醒原会话。
最稳的做法是先读 `jobs/<video_id>/notify.json`（同一个 JSON 的落盘版）。

### 成功

```
✅ 播客已生成
名称：<中文播客名>
简介：<一两句中文简介>
时长：<duration_text>
大小：<size_text>
状态：<已发布 / 草稿>
链接：<episode_url>
```

- 名称/简介要**二次润色**：读 `source_summary`（NotebookLM 的中文摘要）后用自己的话写，
  不要照抄 Markdown 标记（`**`）。
- `draft: true` → 说"已存为草稿，确认后我再发布"。

### 失败

```
❌ 播客生成失败
视频：<原视频标题>
原因：<error.message>
建议：<error.suggestion>
```

`error.suggestion` 已按错误类型给好，直接用，别自己编。常见：

| error.code | 含义 | 处理 |
| --- | --- | --- |
| `NEED_LOGIN` | NotebookLM / 小宇宙掉登录 | 重新登录 Chrome 后 `--rerun` |
| `QUOTA_EXHAUSTED` | NotebookLM 每日生成配额用完 | 等第二天 |
| `ADAPTER_MISSING` | opencli adapter 没装 | 先装 adapter |
| `COMMAND_EXEC` + `fetch failed` | 下载音频时 Google 存储不可达 | 配代理后重跑（见下） |
| `SOURCE_PROCESS_TIMEOUT` | 源抽取超时 | 确认视频可访问后重跑 |
| `PODCAST_ID_MISSING` | 没给小宇宙节目 id | `--podcast` 或 `YT2PODCAST_PODCAST_ID` |
| `FFMPEG_FAILED` | 转码失败，已降级用 wav 上传 | 想听 m4a 就重跑一次 |

失败后**不要自动重试**（白耗配额），先按建议处理再 `--rerun`。

## 网络代理（国内必看）

NotebookLM 的音频挂在 `lh3.googleusercontent.com`，直连会 `fetch failed`。
opencli 内部用 Node 的 `fetch`，**不读 macOS 系统代理**，所以 worker 会自动：

1. 读 `scutil --proxy`（或环境变量 `YT2PODCAST_PROXY` / `HTTPS_PROXY`）拿代理地址；
2. 给所有 opencli 子进程注入 `HTTP(S)_PROXY` + `NODE_USE_ENV_PROXY=1`。

启动时日志会打印一行 `代理: http://127.0.0.1:xxxx` 或 `代理: 未检测到(直连)`，先看这行。

## 排障

**查状态**

```bash
cat <root>/jobs/<video_id>.json                # stage / error / episode_url
tail -n 50 <root>/jobs/<video_id>/worker.log   # 详细日志（含每条 opencli 命令）
ls -la <root>/jobs/<video_id>/                 # audio.wav / cover.jpg / episode.m4a
```

stage：`pending → sourcing → generating → postprocess → uploading → done / failed`

**重跑失败 job**（复用 notebook，不重复建本、不重复消耗生成配额）

```bash
python3 {baseDir}/scripts/worker.py <video_id> --rerun
```

**只补通知**（结果已就绪，只是没发出去）

```bash
python3 {baseDir}/scripts/worker.py <video_id> --notify-only
```

**断点续跑**：如果 `audio.wav` / `episode.m4a` 已经拿到，可以手工把 job 的
`stages_done` 补上已完成阶段、`stage` 改成下一阶段，再直接 `python3 worker.py <video_id>`。

**卡住判断**：`stage` 不是 done/failed 且 `updated_at` 超过 20 分钟 → 看 worker.log 最后一行再决定是否重跑。

**干扰排查**：`--dry-run` 只跑状态机不调外部命令，可用来验证 job/状态流转。

## 边界

- worker 不依赖 LLM：标题/简介的中文提炼由被唤醒的 agent 用 `source_summary` 二次润色。
- **串行执行**：一个 `jobs/.worker.lock`（flock），抢不到就退出，不要并发重试。
- **草稿优先**：小宇宙公开发布不可撤销，默认永远是草稿。
- **配额**：一次真实生成就消耗一次 NotebookLM 每日额度，不要为了"试一下"反复起 job。
- `adapters/` 不归本 skill 管，本 skill 只调用 `opencli` 命令。

## 安装

```bash
git clone <repo> ~/.openclaw/workspace/coding/yt2podcast
ln -sfn ~/.openclaw/workspace/coding/yt2podcast ~/.openclaw/skills/yt2podcast
openclaw skills list        # 看到 yt2podcast 即装好
export YT2PODCAST_PODCAST_ID="<你的小宇宙节目id>"
```

改完 SKILL.md 需要 `/new` 或 `openclaw gateway restart` 才能让 agent 读到新版本。
