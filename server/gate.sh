#!/usr/bin/env bash
# دروازهٔ سبز پرستو — اجرا روی سرور مالک، روی یک درخت کاری مشخص.
# Usage: gate.sh <worktree-path>
#
# استراتژی صرفه‌جویی: ایستای سبک (ruff سندباکس + bash -n)؛ سوئیت‌های اسموک
# داخل ایمیج parastoo/core:latest با mount درخت کاری — بدون pip تازه
# (DNS خروجی سرور بسته است؛ وابستگی‌های پین‌شده از قبل در ایمیج‌اند).
#
# خروجی: خط پایانی GATE_RESULT=PASS|FAIL + ثبت در results/gate-history.log
# کد خروج: ۰ فقط اگر همه سبز.
set -uo pipefail
SB="${PST_SANDBOX:-/opt/parastoo-sandbox}"
WT="${1:?Usage: gate.sh <worktree-path>}"
WT=$(readlink -f "$WT")
T0=$(date +%s)

if [ ! -d "$WT/core" ]; then
  echo "GATE_RESULT=FAIL (درخت کاری بدون core/: $WT)"
  printf '%s\tsha=?\tresult=FAIL\tnote=no-core\ttree=%s\n' "$(date -Is)" "$WT" >> "$SB/results/gate-history.log"
  exit 1
fi
SHA=$(git -C "$WT" rev-parse --short=8 HEAD 2>/dev/null || echo "?")
echo "=== دروازهٔ سبز — $WT — sha:$SHA — $(date -Is) ==="
FAIL=0

# ۱) ایستای سبک — ruff سندباکس (اگر نصب است)
RUFF="$SB/tools/bin/ruff"
[ -x "$RUFF" ] || RUFF="$SB/venv/bin/ruff"
if [ -x "$RUFF" ]; then
  "$RUFF" check "$WT/core" --select F401,F811,F841 || FAIL=1
else
  echo "[هشدار] ruff نصب نیست — ایستای ruff رد شد (فقط دودی و bash -n)"
fi
for f in install.sh setup.sh bootstrap.sh uninstall.sh; do
  bash -n "$WT/$f" || FAIL=1
done
bash -n "$WT/scripts/factory-reset.sh" "$WT/scripts/check-mirrors.sh" \
      "$WT/scripts/fetch-images.sh" "$WT/bin/parastoo" || FAIL=1
echo "static ✓"

# ۲) سوئیت‌های اسموک — داخل ایمیج پرستو (آفلاین، بدون شبکه)
DOCKER=$(command -v docker || true)
if [ -z "$DOCKER" ]; then
  echo "[خطا] docker در دسترس نیست — اسموک ممکن نیست"
  FAIL=1
elif [ "$FAIL" -eq 0 ]; then
  for suite in smoke_test smoke_tickets smoke_sanctions smoke_wizard; do
    echo "--- $suite ---"
    if ! "$DOCKER" run --rm --entrypoint python3 -v "$WT:/wt" -w /wt \
         -e PARASTOO_SMOKE_OFFLINE=1 --network none \
         parastoo/core:latest "tests/$suite.py"; then
      FAIL=1
    fi
  done
fi

DUR=$(( $(date +%s) - T0 ))
if [ "$FAIL" -eq 0 ]; then RES=PASS; else RES=FAIL; fi
echo "=== دروازهٔ سبز $RES (sha:$SHA، ${DUR}s) ==="
echo "GATE_RESULT=$RES"
printf '%s\tsha=%s\tresult=%s\tdur=%ss\ttree=%s\n' "$(date -Is)" "$SHA" "$RES" "$DUR" "$WT" >> "$SB/results/gate-history.log"
[ "$RES" = PASS ]
