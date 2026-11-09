#!/usr/bin/env bash
# کارگاه پرستو — کلاینت محلی عامل. همهٔ ارتباط از راه پل access-agent.
#
# Usage: wb.sh <command> [args]
#   exec '<cmd>'            اجرای فرمان روی سرور (stdout + کد خروج واقعی)
#   sync <local> <remote>   آپلود فایل به سرور (base64 chunked + sha256)
#   fetch <remote> <local>  دانلود فایل از سرور (تا ۲۵۶KB)
#   gate [sha|branch]       دروازهٔ سبز کامل روی سرور، روی درخت کاریِ آن کامیت
#   publish [slug]          سیفِ انتشار: باندل origin/main..HEAD به سرور، پوش از سرور
#                           با توکن لحظه‌ای broker (هیچ رازی ذخیره/لاگ نمی‌شود)
#   deploy                  استقرار صریح پرستو: POST /api/admin/parastoo/update
#   verify [sha]            پول /api/version تا کامیت مستقر شود (+ e2e_live اگر هست)
#   status                  نسخهٔ مستقر پنل + وضعیت access-agent
#   doctor                  خودآزمایی کارگاه روی سرور
#   update                  ارتقای کارگاه روی سرور (git pull + bootstrap)
#
# متغیرهای محیطی (اختیاری): WB_BRIDGE، WB_ENV، WB_SANDBOX، WB_PANEL
set -uo pipefail

WB_BRIDGE="${WB_BRIDGE:-/home/z/my-project/scripts/access_agent_call.sh}"
WB_ENV="${WB_ENV:-/home/z/my-project/parastoo/.secrets/access-agent.env}"
WB_SANDBOX="${WB_SANDBOX:-/opt/parastoo-sandbox}"
WB_PANEL="${WB_PANEL:-https://panel.zeolitecenter.ir}"
WB_WORKBENCH_URL="https://github.com/SelfEvolvingNetwork/parastoo-workbench"
WB_PARASTOO_URL="https://github.com/SelfEvolvingNetwork/parastoo"

usage() { sed -n '2,16p' "$0"; exit "${1:-0}"; }
[ $# -ge 1 ] || usage 1
[ -r "$WB_ENV" ] || { echo "خطا: فایل اتصال پل یافت نشد: $WB_ENV" >&2; exit 2; }
command -v jq >/dev/null || { echo "خطا: jq لازم است" >&2; exit 2; }
set -a; . "$WB_ENV"; set +a

# ---------- لایهٔ پل ----------

rexec_json() {  # <cmd> → JSON خام پل
  local payload
  payload=$(python3 -c 'import json,sys; print(json.dumps({"cmd": sys.argv[1]}))' "$1")
  bash "$WB_BRIDGE" /api/exec -X POST \
    -H "Authorization: Bearer $ACCESS_AGENT_AGENT_TOKEN" \
    -H "Content-Type: application/json" -d "$payload"
}

rexec() {  # <cmd> → stdout روی خروجی استاندارد؛ stderr پل به stderr؛ کد خروج = کد سرور
  local j ok ec
  j=$(rexec_json "$1") || { echo "خطای پل (شبکه/احراز)" >&2; return 125; }
  ok=$(printf '%s' "$j" | jq -r '.ok // false')
  if [ "$ok" != "true" ]; then printf '%s\n' "$j" >&2; return 125; fi
  printf '%s' "$j" | jq -j '.stdout'
  printf '%s' "$j" | jq -r '.stderr // empty' >&2
  ec=$(printf '%s' "$j" | jq -r '.exit_code // 0')
  return "$ec"
}

cmd_exec() { rexec "$1"; }

# ---------- انتقال فایل ----------

cmd_sync() {  # <local> <remote-abs> — سقف فرمان پل ۸۰۰۰ کاراکتر است (اندازه‌گیری ۲۰۲۶-۱۱-۱۰)
  local local_f="$1" remote="$2" b64 len off chunk payload resp ok sha_r sha_l
  [ -f "$local_f" ] || { echo "فایل محلی نیست: $local_f" >&2; return 2; }
  len=$(stat -c%s "$local_f")
  [ "$len" -le 2097152 ] || { echo "سقف sync: ۲MB" >&2; return 2; }
  b64=$(base64 -w0 "$local_f")
  rexec "rm -f '$remote'" || true
  local ci=0
  for ((off=0; off<${#b64}; off+=7600)); do   # ۷۶۰۰ مضرب ۴ + جا برای wrapper زیر ۸۰۰۰
    ci=$((ci+1))
    chunk=${b64:off:7600}
    payload=$(python3 -c 'import json,sys; print(json.dumps({"cmd": sys.argv[1]}))' \
      "printf '%s' '${chunk}' | base64 -d >> '$remote'")
    resp=$(bash "$WB_BRIDGE" /api/exec -X POST \
      -H "Authorization: Bearer $ACCESS_AGENT_AGENT_TOKEN" \
      -H "Content-Type: application/json" -d "$payload") \
      || { echo "خطای پل در قطعهٔ $ci" >&2; return 125; }
    ok=$(printf '%s' "$resp" | jq -r '.ok // false')
    [ "$ok" = "true" ] || { echo "خطا: پل قطعهٔ $ci را رد کرد: $(printf '%s' "$resp" | head -c 200)" >&2; return 125; }
    printf '.' >&2
  done
  echo "" >&2
  sha_l=$(sha256sum "$local_f" | cut -d" " -f1)
  sha_r=$(rexec "sha256sum '$remote' | cut -d' ' -f1") || return 125
  if [ "$sha_l" = "$sha_r" ]; then
    echo "sync ✓ $local_f → $remote ($(numfmt --to=iec $len 2>/dev/null || echo ${len}B))"
  else
    echo "خطا: sha نامطابق (محلی $sha_l / سرور $sha_r)" >&2; return 1
  fi
}

cmd_fetch() {  # <remote-abs> <local> — پاسخ پل بزرگ است (≥۴۰KB تست‌شده)؛ فرمان کوچک می‌ماند
  local remote="$1" local_f="$2" size b64
  size=$(rexec "stat -c%s '$remote'") || return 125
  [ "$size" -le 65536 ] || { echo "سقف fetch: ۶۴KB (این فایل: ${size}B)" >&2; return 2; }
  b64=$(rexec "base64 -w0 '$remote'") || return 125
  printf '%s' "$b64" | base64 -d > "$local_f"
  local sha_r sha_l
  sha_r=$(rexec "sha256sum '$remote' | cut -d' ' -f1") || return 125
  sha_l=$(sha256sum "$local_f" | cut -d" " -f1)
  if [ "$sha_l" = "$sha_r" ]; then
    echo "fetch ✓ $remote → $local_f (${size}B)"
  else
    echo "خطا: sha نامطابق" >&2; return 1
  fi
}

# ---------- دروازهٔ سبز سرور ----------

cmd_gate() {
  local ref="${1:-origin/main}" sha wt logf pre
  pre=$(rexec "SB=$WB_SANDBOX; [ -d \$SB/parastoo/.git ] || git clone --quiet $WB_PARASTOO_URL \$SB/parastoo; git -C \$SB/parastoo fetch --all --prune --quiet; git -C \$SB/parastoo rev-parse --verify '${ref}^{commit}'") || { echo "خطا: کامیت $ref روی سرور در دسترس نیست (پوش شده؟)" >&2; return 2; }
  sha="$pre"
  wt="$WB_SANDBOX/tmp/gate-$(printf '%s' "$sha" | cut -c1-8)"
  logf="$WB_SANDBOX/logs/gate-$(printf '%s' "$sha" | cut -c1-8)-$(date +%s).log"
  echo "دروازهٔ سرور روی $sha (worktree: $wt)"
  rexec "nohup bash -c 'git -C $WB_SANDBOX/parastoo worktree remove --force $wt 2>/dev/null; git -C $WB_SANDBOX/parastoo worktree add --detach $wt $sha && bash $WB_SANDBOX/gate.sh $wt' > $logf 2>&1 & echo started" \
    || { echo "خطا: راه‌اندازی دروازه ناموفق" >&2; return 2; }
  # پولینگ — پل هر فرمان را ۶۰s می‌کشد؛ دروازه طولانی است
  local i marker
  for i in $(seq 1 40); do   # حداکثر ~۱۰ دقیقه
    sleep 15
    marker=$(rexec "grep -h '^GATE_RESULT=' '$logf' 2>/dev/null | tail -1") || marker=""
    if [ -n "$marker" ]; then break; fi
    echo "  … دروازه در حال اجرا ($((i*15))s)"
  done
  if [ -z "$marker" ]; then
    echo "خطا: دروازه در ۱۰ دقیقه تمام نشد — لاگ: $logf" >&2
    rexec "tail -5 '$logf'" >&2 || true
    return 124
  fi
  rexec "tail -30 '$logf'"
  # پاک‌سازی worktree (نتیجه در logs/ و results/ می‌ماند)
  rexec "git -C $WB_SANDBOX/parastoo worktree remove --force '$wt' 2>/dev/null" || true
  [ "$marker" = "GATE_RESULT=PASS" ] && echo "دروازهٔ سرور سبز ✓ ($sha)" || echo "دروازهٔ سرور قرمز ✗ ($sha)" >&2
  [ "$marker" = "GATE_RESULT=PASS" ]
}

# ---------- سیفِ انتشار (publish airlock) ----------

cmd_publish() {  # [slug=parastoo] — پوش از سرور، بدون توکن در دیسک/لاگ
  local slug="${1:-parastoo}"
  local repo_dir head_sha n bundle rb cred b64 tok sha_r push_out rc
  repo_dir=$(cd "$(dirname "$(dirname "$WB_ENV")")" && pwd)
  (
    cd "$repo_dir" || exit 2
    [ -z "$(git status --porcelain)" ] || { echo "خطا: درخت کاری ناپاک است — اول کامیت کن" >&2; exit 2; }
  ) || return 2
  git -C "$repo_dir" fetch --quiet origin main 2>/dev/null \
    || echo "[هشدار] fetch محلی ناموفق — از origin/main موجود استفاده می‌شود" >&2
  head_sha=$(git -C "$repo_dir" rev-parse HEAD)
  n=$(git -C "$repo_dir" rev-list --count "origin/main..HEAD" 2>/dev/null || echo 0)
  if [ "$n" -eq 0 ]; then
    echo "چیزی برای انتشار نیست (origin/main == HEAD: ${head_sha:0:8}) — همگامی سرور تازه می‌شود"
    rexec "git -C $WB_SANDBOX/parastoo fetch --quiet origin main" >/dev/null || true
    return 0
  fi
  echo "انتشار $n کامیت از راه سیفِ سرور (HEAD: ${head_sha:0:8}) …"
  bundle="/tmp/pst-publish-$(date +%s).bundle"
  ( cd "$repo_dir" && git bundle create "$bundle" "origin/main..HEAD" ) >/dev/null || return 2
  local bsize; bsize=$(stat -c%s "$bundle")
  [ "$bsize" -le 2097152 ] || { echo "باندل ${bsize}B از سقف ۲MB گذشت — این‌بار پوش محلی بزن" >&2; rm -f "$bundle"; return 2; }
  rb="$WB_SANDBOX/tmp/$(basename "$bundle")"
  # ۱) سرور اول origin/main را تازه کند (پیش‌نیازهای باندل)
  rexec "git -C $WB_SANDBOX/parastoo fetch --quiet origin main" >/dev/null \
    || { echo "خطا: fetch سرور ناموفق" >&2; rm -f "$bundle"; return 125; }
  # ۲) باندل → سرور
  cmd_sync "$bundle" "$rb" || { rm -f "$bundle"; rexec "rm -f $rb" >/dev/null || true; return 125; }
  rm -f "$bundle"
  # ۳) توکن لحظه‌ای از broker — هرگز در دیسک/لاگ ذخیره نمی‌شود
  tok=$(bash "$WB_BRIDGE" /api/github/token -X POST \
    -H "Authorization: Bearer $ACCESS_AGENT_AGENT_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"purpose":"workbench publish airlock"}' | jq -r '.token // empty')
  [ -n "$tok" ] || { echo "خطا: broker توکن نداد" >&2; rexec "rm -f $rb" >/dev/null || true; return 125; }
  b64=$(printf '%s' "$tok" | base64 -w0); unset tok
  cred="/tmp/pst-cred-$$-$RANDOM"
  rexec "printf '%s' '$b64' | base64 -d > $cred && chmod 600 $cred" >/dev/null \
    || { echo "خطا: نوشتن اعتبار موقت روی سرور" >&2; rexec "rm -f $rb $cred" >/dev/null || true; return 125; }
  unset b64
  # ۴) unbundle + پوش از سرور
  push_out=$(rexec "git -C $WB_SANDBOX/parastoo bundle unbundle $rb >/dev/null 2>&1 && git -C $WB_SANDBOX/parastoo -c credential.helper='store --file=$cred' push https://github.com/$slug ${head_sha}:refs/heads/main")
  rc=$?
  # ۵) راستی‌آزمایی + پاک‌سازی فوری اعتبار و باندل (همیشه)
  sha_r=$(rexec "git ls-remote https://github.com/$slug refs/heads/main | cut -f1; rm -f $cred $rb") || sha_r=""
  if [ "$rc" -eq 0 ] && [ "$sha_r" = "$head_sha" ]; then
    echo "publish ✓ — $slug@origin/main == ${head_sha:0:8} (پوش از سرور انجام شد)"
    return 0
  fi
  echo "خطا: پوش ناموفق (rc=$rc، ریموت=${sha_r:0:8}) — خروجی پوش:" >&2
  printf '%s\n' "$push_out" >&2
  return 1
}

# ---------- استقرار و راستی‌آزمایی ----------

cmd_deploy() {
  echo "استقرار صریح پرستو از راه پل …"
  bash "$WB_BRIDGE" /api/admin/parastoo/update -X POST \
    -H "Authorization: Bearer $ACCESS_AGENT_AGENT_TOKEN" \
    -H "Content-Type: application/json" -d '{}'
  echo ""
}

cmd_verify() {
  local sha="${1:-}" i v
  if [ -z "$sha" ]; then
    sha=$(git -C "$(dirname "$(dirname "$WB_ENV")")" rev-parse HEAD 2>/dev/null || true)
  fi
  [ -n "$sha" ] || { usage 1; return 2; }
  echo "انتظار برای استقرار $sha روی $WB_PANEL (حداکثر ۸ دقیقه) …"
  for i in $(seq 1 16); do
    v=$(curl -fsS --max-time 15 "$WB_PANEL/api/version" 2>/dev/null || true)
    if printf '%s' "$v" | grep -q "\"commit\":\"$sha\""; then
      echo "deployed ✓ $(printf '%s' "$v" | head -c 200)"
      local repo_dir
      repo_dir=$(cd "$(dirname "$(dirname "$WB_ENV")")" && pwd)
      if [ -f "$repo_dir/tests/e2e_live.py" ]; then
        echo "--- e2e_live ---"
        (cd "$repo_dir" && python3 tests/e2e_live.py --expect-commit "$sha")
        return $?
      fi
      return 0
    fi
    sleep 30
  done
  echo "خطا: پس از ۸ دقیقه کامیت $sha مستقر نشد — پروتکل stall در AI_AGENT_LOOP §M5" >&2
  return 1
}

# ---------- وضعیت و نگهداری ----------

cmd_status() {
  echo "=== پنل ==="
  curl -fsS --max-time 15 "$WB_PANEL/api/version" 2>/dev/null || echo "پنل پاسخ نمی‌دهد"
  echo ""
  echo "=== access-agent ==="
  bash "$WB_BRIDGE" /api/status -H "Authorization: Bearer $ACCESS_AGENT_AGENT_TOKEN" | head -c 600
  echo ""
}

cmd_doctor() {
  rexec "python3 $WB_SANDBOX/workbench/server/selfcheck.py --human"
}

cmd_update() {
  rexec "if [ -d $WB_SANDBOX/workbench/.git ]; then git -C $WB_SANDBOX/workbench pull --ff-only; else git clone --quiet $WB_WORKBENCH_URL $WB_SANDBOX/workbench; fi && bash $WB_SANDBOX/workbench/server/bootstrap.sh"
}

case "$1" in
  exec)   [ $# -ge 2 ] || usage 1; cmd_exec "$2" ;;
  sync)   [ $# -ge 3 ] || usage 1; cmd_sync "$2" "$3" ;;
  fetch)  [ $# -ge 3 ] || usage 1; cmd_fetch "$2" "$3" ;;
  gate)   shift; cmd_gate "${1:-origin/main}" ;;
  publish) shift; cmd_publish "${1:-parastoo}" ;;
  deploy) cmd_deploy ;;
  verify) shift; cmd_verify "${1:-}" ;;
  status) cmd_status ;;
  doctor) cmd_doctor ;;
  update) cmd_update ;;
  help|--help|-h) usage 0 ;;
  *) echo "فرمان ناشناخته: $1" >&2; usage 1 ;;
esac
