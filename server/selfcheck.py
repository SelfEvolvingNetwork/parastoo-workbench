#!/usr/bin/env python3
"""خودآزمایی کارگاه پرستو روی سرور — سلامت ابزارها و محیط.

خروجی پیش‌فرض JSON تک‌خطی (برای کلاینت wb)؛ با --human گزارش خوانا.
کد خروج: ۰ اگر همهٔ چک‌های حیاتی سبز، ۱ در غیر این صورت.
"""
import json
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

SB = Path(__import__("os").environ.get("PST_SANDBOX", "/opt/parastoo-sandbox"))


def run(cmd: list, timeout: int = 20) -> tuple:
    """(ok, output) — خروجی first-line از فرمان."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode == 0, (r.stdout or r.stderr).strip().splitlines()[0] if (r.stdout or r.stderr).strip() else ""
    except (subprocess.TimeoutExpired, OSError) as e:
        return False, str(e)[:80]


def main() -> int:
    human = "--human" in sys.argv
    checks: dict = {}
    tools: dict = {}

    # ۱) دایرکتوری‌ها
    for name in ("tmp", "results", "logs", "tools/bin"):
        checks[f"dir:{name}"] = (SB / name).is_dir()

    # ۲) اسکریپت‌های نصب‌شده + سینتکس
    for s in ("gate.sh", "cleanup.sh"):
        p = SB / s
        ok = p.is_file()
        if ok:
            ok, _ = run(["bash", "-n", str(p)])
        checks[f"script:{s}"] = ok

    # ۳) ابزارها
    for t, cmd in (("docker", ["docker", "--version"]),
                   ("git", ["git", "--version"]),
                   ("jq", ["jq", "--version"]),
                   ("python3", ["python3", "--version"])):
        ok, out = run(cmd)
        tools[t] = out if ok else None
    for ruff_path in (SB / "tools/bin/ruff", SB / "venv/bin/ruff"):
        if ruff_path.is_file() and ruff_path.stat().st_mode & 0o111:
            ok, out = run([str(ruff_path), "--version"])
            if ok:
                tools["ruff"] = out
                break
    else:
        tools["ruff"] = None
    checks["tools:ruff"] = tools["ruff"] is not None

    # ۴) داکر و ایمیج پرستو
    ok, _ = run(["docker", "info"], timeout=30)
    checks["docker:reachable"] = ok
    if ok:
        ok_img, _ = run(["docker", "image", "inspect", "parastoo/core:latest"], timeout=20)
        checks["docker:image-core"] = ok_img

    # ۵) مخزن‌ها
    for key, p in (("repo:parastoo", SB / "parastoo"), ("repo:workbench", SB / "workbench")):
        ok = (p / ".git").is_dir()
        head = None
        if ok:
            hok, head = run(["git", "-C", str(p), "rev-parse", "--short=8", "HEAD"])
            ok = ok and hok
        checks[key] = ok
        tools[key.split(":")[1] + "_head"] = head

    # ۶) آزمون نوشتن در tmp
    try:
        (SB / "tmp/.selfcheck").write_text("ok")
        (SB / "tmp/.selfcheck").unlink()
        checks["tmp:writable"] = True
    except OSError:
        checks["tmp:writable"] = False

    # ۷) منابع
    du, _ = shutil.disk_usage("/")
    mem = None
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith("MemAvailable:"):
                mem = int(line.split()[1]) // 1024
                break
    except OSError:
        pass

    critical = [v for k, v in checks.items() if not k.startswith("tools:")]
    ok_all = all(critical) and checks["tools:ruff"]

    out = {
        "ok": ok_all,
        "when": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
        "sandbox": str(SB),
        "checks": checks,
        "tools": tools,
        "resources": {"disk_free_gb": round(du.free / 2**30, 1), "mem_avail_mb": mem},
        "gate_history_lines": sum(1 for _ in open(SB / "results/gate-history.log")) if (SB / "results/gate-history.log").is_file() else 0,
    }
    if human:
        print(f"کارگاه: {SB}  ({'سبز ✓' if ok_all else 'ناقص ✗'})")
        for k, v in checks.items():
            print(f"  {'✓' if v else '✗'} {k}")
        for k, v in tools.items():
            print(f"  · {k}: {v or '—'}")
        print(f"  · دیسک آزاد: {out['resources']['disk_free_gb']}GB · حافظه آزاد: {mem}MB · تاریخچه دروازه: {out['gate_history_lines']} ردیف")
    else:
        print(json.dumps(out, ensure_ascii=False))
    return 0 if ok_all else 1


if __name__ == "__main__":
    sys.exit(main())
