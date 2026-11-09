#!/usr/bin/env bash
# نصب/ارتقای کارگاه پرستو روی سرور — از داخل کلون مخزن اجرا می‌شود.
# (کلون: /opt/parastoo-sandbox/workbench) — idempotent: هر بار اجراsafe است.
#
# پیش‌نیاز: دسترسی گیت‌هاب (برای ruff و کلون پرستو) — DNS خروجی سرور به
# گیت‌هاب باز است؛ pip سودمند نیست (آینه‌ها فایل نمی‌دهند).
set -euo pipefail
SB="${PST_SANDBOX:-/opt/parastoo-sandbox}"
HERE=$(cd "$(dirname "$0")" && pwd)              # …/workbench/server
PARASTOO_URL="${PST_PARASTOO_URL:-https://github.com/SelfEvolvingNetwork/parastoo}"
RUFF_VER="${PST_RUFF_VER:-0.17.4}"
LOG="$SB/logs/bootstrap.log"

mkdir -p "$SB" "$SB/tmp" "$SB/results" "$SB/logs" "$SB/tools/bin"
chmod 700 "$SB" 2>/dev/null || true
log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }

log "bootstrap شروع — منبع: $HERE"

# ۱) همگام‌سازی اسکریپت‌ها از مخزن به ریشهٔ سندباکس (مسیرهای ثابت می‌مانند)
install -m 755 "$HERE/gate.sh" "$HERE/cleanup.sh" "$SB/"
install -m 644 "$HERE/SANDBOX_README.fa.md" "$SB/README.fa.md"
log "اسکریپت‌ها همگام شد (gate.sh, cleanup.sh, README.fa.md)"

# ۲) ruff از ریلیز گیت‌هاب — غیرمرگبار (دروازه بدون آن هم اجرا می‌شود، با هشدار)
if [ -x "$SB/tools/bin/ruff" ]; then
  log "ruff از قبل هست: $("$SB/tools/bin/ruff" --version 2>&1)"
else
  URL="https://github.com/astral-sh/ruff/releases/download/$RUFF_VER/ruff-x86_64-unknown-linux-gnu.tar.gz"
  if curl -fsSL --max-time 120 -o "$SB/tmp/ruff.tar.gz" "$URL" 2>>"$LOG"; then
    tar -xzf "$SB/tmp/ruff.tar.gz" -C "$SB/tmp"
    RUFFBIN=$(find "$SB/tmp" -maxdepth 2 -type f -name ruff | head -1)
    if [ -n "$RUFFBIN" ]; then
      install -m 755 "$RUFFBIN" "$SB/tools/bin/ruff"
      log "ruff نصب شد: $("$SB/tools/bin/ruff" --version 2>&1)"
    else
      log "باینری ruff در آرشیو یافت نشد — غیرمرگبار"
    fi
    rm -rf "$SB/tmp/ruff.tar.gz" "$SB/tmp/ruff-x86_64-unknown-linux-gnu"
  else
    log "دانلود ruff ناموفق (شبکه/گیت‌هاب) — غیرمرگبار؛ بعداً دوباره bootstrap بزن"
  fi
fi

# ۳) کلون مخزن پرستو برای دروازهٔ سبز (کامل، نه shallow — تا هر کامیتِ پوش‌شده در دسترس باشد)
if [ ! -d "$SB/parastoo/.git" ]; then
  if git clone --quiet "$PARASTOO_URL" "$SB/parastoo" 2>>"$LOG"; then
    log "مخزن پرستو کلون شد: $SB/parastoo"
  else
    log "کلون پرستو ناموفق — غیرمرگبار؛ wb gate بعداً دوباره تلاش می‌کند"
  fi
else
  git -C "$SB/parastoo" fetch --all --prune --quiet 2>>"$LOG" || log "fetch پرستو ناموفق"
  log "مخزن پرستو موجود است (fetch انجام شد)"
fi

# ۴) خودآزمایی پایانی
if python3 "$HERE/selfcheck.py" --human 2>&1 | tee -a "$LOG"; then
  log "bootstrap پایان ✓"
else
  log "خودآزمایی ناقص — جزئیات بالا"
  exit 1
fi
