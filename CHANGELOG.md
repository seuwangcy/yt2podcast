# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 与语义化版本。

## [0.1.2] - 2026-11-07

### Changed
- **公开发布改为双重显式授权**：`--publish` 且 `YT2PODCAST_ALLOW_PUBLISH=1`，缺一即报
  `PUBLISH_NOT_ALLOWED`。回应安全扫描"public publishing can occur without explicit authorization"。
- **不再自行 detach 进程**：`new-job.sh` 只写 job 文件并打印下一步命令，移除了 setsid/nohup 启动路径。
  回应"a worker can outlive the host's process cleanup"。
- 新增 `SECURITY.md`，逐项说明执行命令、网络、写入范围、发布授权、进程生命周期、无遥测。

## [0.1.1] - 2026-11-07

### Changed
- `SKILL.md` 增加「能力与风险声明」：明示会执行的外部命令、网络访问、文件写入范围、
  **公开发布能力**（`--publish` 不可撤销、仅限用户明确要求）与完成通知行为。
- frontmatter description 明确"默认草稿、可显式公开发布、完成后回推通知"，
  与代码实际能力对齐（ClawHub 安全扫描此前判为 suspicious 的原因）。

## [0.1.0] - 2026-11-07

首个可发布版本。基于一次真实端到端实测（2 小时 14 分的 YouTube 访谈 → 19 分 15 秒中文播客）。

### Added
- 五阶段流水线 `pending → sourcing → generating → postprocess → uploading → done`，断点续跑。
- `new-job.sh`：建 job 文件（幂等，同一视频不会重复起），可选启动 worker。
- `worker.py`：不依赖 LLM 的流水线执行器，失败唤醒 + `notify.json` 落盘。
- `--rerun` / `--notify-only` / `--dry-run` 三种运维模式。
- 自动代理探测（`scutil --proxy`）与 `NODE_USE_ENV_PROXY` 注入，解决 Google 存储下载超时。
- YouTube URL 归一化，剥离 `?si=` 等追踪参数。

### Fixed
- worker 在 agent 回合结束时被连同进程组一起杀掉，job 永久卡在 sourcing 且无通知。
- 带追踪参数的短链导致 NotebookLM `AddSources` 返回 no source id。
- `lh3.googleusercontent.com` 直连超时导致的 `Downloading the NotebookLM audio failed: fetch failed`。
- 代码中硬编码的小宇宙节目 id 与节目名，改为必填配置；缺失时明确报 `PODCAST_ID_MISSING`。
- frontmatter 依赖声明由 `anyBins`（任一存在即可）改为 `bins`（全部必需）。
