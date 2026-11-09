#!/usr/bin/env bash
# پاک‌سازی دوره‌ای کارگاه: tmp قدیمی‌تر از ۷ روز، worktreeهای دروازهٔ کهنه،
# ایمیج‌های آویزان داکر. بی‌خطر برای بقیهٔ سرور.
set -uo pipefail
SB="${PST_SANDBOX:-/opt/parastoo-sandbox}"

before=$(du -sh "$SB/tmp" 2>/dev/null | cut -f1)

# ۱) هر چیزی در tmp که بیش از ۷ روز دست نخورده
find "$SB/tmp" -mindepth 1 -maxdepth 1 -mtime +7 -exec rm -rf {} + 2>/dev/null || true
# ۲) worktreeهای دروازهٔ کهنه (بیش از ۱ روز) + هرجای مرده در متادیتای گیت
find "$SB/tmp" -mindepth 1 -maxdepth 1 -name 'gate-*' -mtime +1 -exec rm -rf {} + 2>/dev/null || true
if [ -d "$SB/parastoo/.git" ]; then
  git -C "$SB/parastoo" worktree prune >/dev/null 2>&1 || true
fi
# ۳) ایمیج‌های بدون تگ (فقط dangling — ایمیج‌های پرستو دست نمی‌خورند)
if command -v docker >/dev/null 2>&1; then
  docker image prune -f >/dev/null 2>&1 || true
fi

after=$(du -sh "$SB/tmp" 2>/dev/null | cut -f1)
echo "cleanup: tmp ${before:-?} → ${after:-?} ($(date -Is))"
