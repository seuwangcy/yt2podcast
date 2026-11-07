#!/usr/bin/env bash
# yt2podcast: 建 job + 起后台 worker
#
# 用法:
#   new-job.sh <youtube_url> [选项]
#
# 选项:
#   --title <标题>          中文播客名(给 agent 用);不给就用 YouTube 原标题
#   --description <简介>    中文简介;不给就用 NotebookLM 源摘要兜底
#   --session-key <key>     完成后唤醒哪个会话,例如 agent:main:openclaw-weixin:direct:xxx
#   --podcast <id>          小宇宙节目 id(必填,或设 YT2PODCAST_PODCAST_ID)
#   --publish               真正发布到小宇宙(默认是草稿,开发期禁止公开发布)
#   --draft                 显式指定草稿(默认行为)
#   --retry                 已有 job 是 failed 时,重置并重跑
#   --start                 建完 job 后立刻起 worker(默认只建 job 文件,不起 worker)
#                           注意:在 OpenClaw 的 exec 里必须用 background 托管跑 worker.py,
#                           脚本里的 setsid 只是兜底,agent 场景请保持默认 + 另起后台任务
#   --wait                  前台等 worker 跑完(需配合 --start),给脚本/CI 用
#   --timeout <秒>          --wait 的超时,默认 1800
#
# 输出:一行 JSON,便于 agent 解析。
#
# 环境变量:
#   YT2PODCAST_ROOT       根目录,默认 ~/.openclaw/workspace/yt2podcast
#   YT2PODCAST_PODCAST_ID 小宇宙节目 id(等价的 --podcast 默认值)
#   YT2PODCAST_PROXY      访问 Google 用的 HTTP 代理(worker 侧也会自动读系统代理)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER="$SCRIPT_DIR/worker.py"
ROOT="${YT2PODCAST_ROOT:-$HOME/.openclaw/workspace/yt2podcast}"
JOBS_DIR="$ROOT/jobs"
DEFAULT_PODCAST_ID="${YT2PODCAST_PODCAST_ID:-}"

URL=""
TITLE=""
DESCRIPTION=""
SESSION_KEY=""
PODCAST_ID="$DEFAULT_PODCAST_ID"
DRAFT=1
RETRY=0
START=0
WAIT=0
WAIT_TIMEOUT=1800

usage() {
  sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  printf '{"ok":false,"error":%s}\n' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$1")" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --title) TITLE="${2:-}"; shift 2 ;;
    --description) DESCRIPTION="${2:-}"; shift 2 ;;
    --session-key) SESSION_KEY="${2:-}"; shift 2 ;;
    --podcast) PODCAST_ID="${2:-}"; shift 2 ;;
    --publish) DRAFT=0; shift ;;
    --draft) DRAFT=1; shift ;;
    --retry) RETRY=1; shift ;;
    --no-start) START=0; shift ;;
    --start) START=1; shift ;;
    --wait) WAIT=1; shift ;;
    --timeout) WAIT_TIMEOUT="${2:-1800}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --*) die "unknown option: $1" ;;
    *) if [ -z "$URL" ]; then URL="$1"; shift; else die "unexpected argument: $1"; fi ;;
  esac
done

[ -n "$URL" ] || { usage >&2; die "missing youtube url"; }
[ -f "$WORKER" ] || die "worker not found: $WORKER"

# ---------------------------------------------------------------- 提取 video_id
extract_video_id() {
  local url="$1"
  local id=""
  case "$url" in
    *youtu.be/*)      id="${url#*youtu.be/}" ;;
    *watch?v=*)       id="${url#*watch?v=}" ;;
    */shorts/*)       id="${url#*/shorts/}" ;;
    */embed/*)        id="${url#*/embed/}" ;;
    */live/*)         id="${url#*/live/}" ;;
    *v=*)             id="${url#*v=}" ;;
    *)                id="$url" ;;
  esac
  # 去掉多余的查询串/片段
  id="${id%%[&?#]*}"
  id="${id%%/*}"
  printf '%s' "$id"
}

VIDEO_ID="$(extract_video_id "$URL")"
if ! printf '%s' "$VIDEO_ID" | grep -Eq '^[A-Za-z0-9_-]{11}$'; then
  die "cannot parse YouTube video id from: $URL"
fi

JOB_ID="$VIDEO_ID"
JOB_DIR="$JOBS_DIR/$JOB_ID"
JOB_FILE="$JOBS_DIR/$JOB_ID.json"
mkdir -p "$JOB_DIR"

# ---------------------------------------------------------------- 幂等
existing_stage=""
if [ -f "$JOB_FILE" ]; then
  existing_stage="$(python3 - "$JOB_FILE" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        print(json.load(handle).get("stage") or "pending")
except Exception:
    print("pending")
PY
)"
fi

if [ -n "$existing_stage" ] && [ "$existing_stage" != "failed" ]; then
  # 已存在且非 failed → 直接输出已有状态,不再起 worker
  python3 - "$JOB_FILE" "$existing_stage" "$JOB_ID" <<'PY'
import json, sys
path, stage, job_id = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as handle:
    job = json.load(handle)
print(json.dumps({
    "ok": True,
    "existing": True,
    "job_id": job.get("job_id"),
    "stage": stage,
    "job_file": path,
    "job_dir": path.rsplit("/", 1)[0] + "/" + job_id,
    "episode_url": job.get("episode_url"),
    "error": job.get("error"),
}, ensure_ascii=False))
PY
  exit 0
fi

if [ "$existing_stage" = "failed" ] && [ "$RETRY" -ne 1 ]; then
  # failed 的 job 只有显式 --retry 才重跑
  python3 - "$JOB_FILE" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    job = json.load(handle)
print(json.dumps({
    "ok": False,
    "existing": True,
    "stage": "failed",
    "job_id": job.get("job_id"),
    "job_file": sys.argv[1],
    "error": job.get("error"),
    "hint": "上次跑失败了;确认原因后用 --retry 重跑(会复用已有 notebook,不再消耗生成配额)",
}, ensure_ascii=False))
PY
  exit 3
fi

# ---------------------------------------------------------------- 串行约束检查
if [ "$START" -eq 1 ] && [ -f "$JOBS_DIR/.worker.lock" ]; then
  LOCK_PID="$(cat "$JOBS_DIR/.worker.lock" 2>/dev/null || echo "")"
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    die "another worker is running (pid=$LOCK_PID); wait for it to finish"
  fi
fi

# ---------------------------------------------------------------- 写 job 文件
YOUTUBE_URL="$URL" JOB_ID="$JOB_ID" JOB_FILE="$JOB_FILE" JOB_DIR="$JOB_DIR" \
TITLE="$TITLE" DESCRIPTION="$DESCRIPTION" SESSION_KEY="$SESSION_KEY" \
PODCAST_ID="$PODCAST_ID" DRAFT="$DRAFT" RETRY="$RETRY" \
python3 - <<'PY'
import json, os, time

def now():
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")

path = os.environ["JOB_FILE"]
job_id = os.environ["JOB_ID"]
job = {}
if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            job = json.load(handle)
    except Exception:
        job = {}

retry = os.environ.get("RETRY") == "1"
job.update({
    "job_id": job_id,
    "video_id": job_id,
    "youtube_url": os.environ["YOUTUBE_URL"],
    "stage": job.get("stage") if (retry and job.get("stage") not in (None, "failed")) else "pending",
    "title": os.environ.get("TITLE") or job.get("title") or "",
    "description": os.environ.get("DESCRIPTION") or job.get("description") or "",
    "session_key": os.environ.get("SESSION_KEY") or job.get("session_key") or "",
    "podcast_id": os.environ.get("PODCAST_ID") or job.get("podcast_id"),
    "draft": os.environ.get("DRAFT") == "1",
    "notebook_id": job.get("notebook_id"),
    "source_id": job.get("source_id"),
    "stages_done": job.get("stages_done") or [],
    "history": job.get("history") or [],
    "created_at": job.get("created_at") or now(),
    "updated_at": now(),
})
if job["stage"] == "pending":
    job.pop("error", None)
    job.pop("failed_stage", None)

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(job, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
os.replace(tmp, path)
print(json.dumps({"job_id": job_id, "job_file": path, "stage": job["stage"]}, ensure_ascii=False))
PY

# ---------------------------------------------------------------- 起 worker
WORKER_PID=""
if [ "$START" -eq 1 ]; then
  # 必须放进独立 session:OpenClaw exec host 在 agent 回合结束时会把整个 process group
  # (treeOwnership=process-group)一起 kill,普通 nohup 的 worker 会立刻被杀掉、job 永远卡在
  # sourcing。macOS 没有 setsid,用 perl 的 POSIX::setsid 兜底。
  if command -v setsid >/dev/null 2>&1; then
    nohup setsid python3 "$WORKER" "$JOB_ID" >>"$JOB_DIR/worker.out" 2>&1 </dev/null &
  elif command -v perl >/dev/null 2>&1; then
    nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die "exec failed: $!"' python3 "$WORKER" "$JOB_ID" >>"$JOB_DIR/worker.out" 2>&1 </dev/null &
  else
    nohup python3 "$WORKER" "$JOB_ID" >>"$JOB_DIR/worker.out" 2>&1 </dev/null &
  fi
  WORKER_PID=$!
  sleep 0.3
  if ! kill -0 "$WORKER_PID" 2>/dev/null; then
    die "worker failed to start; see $JOB_DIR/worker.out"
  fi
fi

# ---------------------------------------------------------------- 可选:等结果
FINAL_STAGE="pending"
if [ "$WAIT" -eq 1 ] && [ "$START" -eq 1 ]; then
  DEADLINE=$(( $(date +%s) + WAIT_TIMEOUT ))
  while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    FINAL_STAGE="$(python3 - "$JOB_FILE" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        print(json.load(handle).get("stage") or "pending")
except Exception:
    print("pending")
PY
)"
    case "$FINAL_STAGE" in
      done|failed) break ;;
    esac
    sleep 5
  done
fi

python3 - "$JOB_FILE" "$JOB_ID" "$WORKER_PID" "$FINAL_STAGE" "$START" <<'PY'
import json, sys
path, job_id, pid, stage, start = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
try:
    with open(path, "r", encoding="utf-8") as handle:
        job = json.load(handle)
except Exception:
    job = {}
print(json.dumps({
    "ok": True,
    "job_id": job_id,
    "stage": stage if start == "1" else job.get("stage"),
    "started": start == "1",
    "worker_pid": int(pid) if pid else None,
    "job_file": path,
    "job_dir": path.rsplit("/", 1)[0] + "/" + job_id,
    "log": path.rsplit("/", 1)[0] + "/" + job_id + "/worker.log",
    "episode_url": job.get("episode_url"),
    "error": job.get("error"),
}, ensure_ascii=False))
PY
