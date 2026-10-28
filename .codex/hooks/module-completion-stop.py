#!/usr/bin/env python3
"""Codex Stop hook that advances one Legado alignment autopilot task.

The hook intentionally runs a detached Codex child process and exits quickly.
The child process resumes the most recent session for this repository instead
of starting a new one, which is the closest CLI-supported behavior to
continuing the current GUI thread. It is marked with CODEX_AUTOPILOT_CHILD=1 so
this Stop hook will not recursively trigger itself when the child finishes.
"""

from __future__ import annotations

import datetime as _dt
import os
import re
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
RUN_DIR = REPO_ROOT / "alignment" / "autopilot-runs"
NEXT_FILE = REPO_ROOT / "alignment" / "NEXT.md"
STEPS_FILE = RUN_DIR / "next-steps"
LOCK_FILE = RUN_DIR / ".autopilot.lock"
CODEX_BIN = "/Applications/Codex.app/Contents/Resources/codex"
DEFAULT_STEPS = 1
MAX_STEPS = 20
PROMPT_TEMPLATE = """按 AUTOPILOT 往后推进 {steps} 个对齐点

这是由 .codex Stop hook 自动触发的后台推进。请严格遵守 alignment/AUTOPILOT.md：
- 连续执行最多 {steps} 轮 AUTOPILOT。
- 每一轮都重新读取 alignment/NEXT.md，只处理当前最高优先级的一个非 aligned、非 blocked 任务。
- 如果某一轮任务不是 atomic，只做拆分和回填，不改业务代码，然后进入下一轮。
- 如果某一轮任务已 atomic，允许最小实现、验证并回填 record，然后进入下一轮。
- 如果没有待处理任务、遇到 blocked、构建/验证失败、或无法安全继续，立即停止并说明原因。
- 每轮完成后必须更新 NEXT.md 和对应 record。
- 不要创建提交，不要推送，不要改 unrelated 文件。
"""


def _log(message: str) -> None:
    RUN_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = _dt.datetime.now().isoformat(timespec="seconds")
    with (RUN_DIR / "hook.log").open("a", encoding="utf-8") as fh:
        fh.write(f"[{timestamp}] {message}\n")


def _is_child_run() -> bool:
    return os.environ.get("CODEX_AUTOPILOT_CHILD") == "1"


def _has_pending_task() -> bool:
    if not NEXT_FILE.exists():
        return False
    row_pattern = re.compile(r"^\|\s*\d+\s*\|.*\|\s*`([^`]+)`\s*\|")
    for line in NEXT_FILE.read_text(encoding="utf-8").splitlines():
        match = row_pattern.match(line)
        if not match:
            continue
        status = match.group(1)
        if status not in {"aligned", "blocked"}:
            return True
    return False


def _parse_steps(value: str | None) -> int:
    if value is None:
        return DEFAULT_STEPS
    try:
        steps = int(value.strip())
    except ValueError:
        return DEFAULT_STEPS
    return max(1, min(steps, MAX_STEPS))


def _read_step_count() -> int:
    env_steps = os.environ.get("CODEX_AUTOPILOT_STEPS")
    if env_steps is not None:
        return _parse_steps(env_steps)
    if not STEPS_FILE.exists():
        return DEFAULT_STEPS
    try:
        steps = _parse_steps(STEPS_FILE.read_text(encoding="utf-8"))
    finally:
        STEPS_FILE.unlink(missing_ok=True)
    return steps


def _pid_is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def _lock_is_active() -> bool:
    if not LOCK_FILE.exists():
        return False
    try:
        pid = int(LOCK_FILE.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return False
    return _pid_is_alive(pid)


def _acquire_lock() -> bool:
    RUN_DIR.mkdir(parents=True, exist_ok=True)
    if LOCK_FILE.exists() and not _lock_is_active():
        LOCK_FILE.unlink(missing_ok=True)
    try:
        fd = os.open(str(LOCK_FILE), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        return False
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(str(os.getpid()))
    return True


def _spawn_autopilot(steps: int) -> None:
    run_id = _dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    stdout_path = RUN_DIR / f"{run_id}.out.log"
    stderr_path = RUN_DIR / f"{run_id}.err.log"
    done_path = RUN_DIR / f"{run_id}.done"
    prompt = PROMPT_TEMPLATE.format(steps=steps)
    wrapper = (
        "set -o pipefail\n"
        f"cd {str(REPO_ROOT)!r}\n"
        "export CODEX_AUTOPILOT_CHILD=1\n"
        f"export CODEX_AUTOPILOT_STEPS={steps!r}\n"
        f"{CODEX_BIN!r} exec resume --last "
        "--dangerously-bypass-approvals-and-sandbox "
        f"{prompt!r}\n"
        "exit_status=$?\n"
        f"echo $exit_status > {str(done_path)!r}\n"
        f"rm -f {str(LOCK_FILE)!r}\n"
        "exit $exit_status\n"
    )
    with stdout_path.open("ab") as stdout, stderr_path.open("ab") as stderr:
        process = subprocess.Popen(
            ["/bin/zsh", "-lc", wrapper],
            cwd=str(REPO_ROOT),
            stdin=subprocess.DEVNULL,
            stdout=stdout,
            stderr=stderr,
            start_new_session=True,
            close_fds=True,
        )
    LOCK_FILE.write_text(str(process.pid), encoding="utf-8")
    _log(f"spawned autopilot run {run_id} steps={steps}")


def main() -> int:
    if _is_child_run():
        _log("skip: child run")
        return 0
    if os.environ.get("CODEX_AUTOPILOT_DISABLE") == "1":
        _log("skip: disabled by CODEX_AUTOPILOT_DISABLE=1")
        return 0
    if not _has_pending_task():
        _log("skip: no pending NEXT.md task")
        return 0
    if not _acquire_lock():
        _log("skip: lock already exists")
        return 0
    steps = _read_step_count()
    try:
        _spawn_autopilot(steps)
    except Exception as exc:  # keep Stop hook non-fatal
        _log(f"spawn failed: {exc!r}")
        try:
            LOCK_FILE.unlink(missing_ok=True)
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
