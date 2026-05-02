#!/bin/bash

set -euo pipefail

BASE_DIR="$HOME"
CONFIG_FILE="${CONFIG_FILE:-$HOME/.config/openwrt_autobuild.env}"
RUN_DATE="${RUN_DATE:-$(date +%Y%m%d)}"
WORK_ROOT="${GCT_WORK_ROOT:-${WORK_ROOT:-$BASE_DIR/gct_workspace}}"
AUTOBUILD_ROOT="${AUTOBUILD_ROOT:-$WORK_ROOT/autobuild}"
AUTOBUILD_LOG_ROOT="${AUTOBUILD_LOG_ROOT:-$AUTOBUILD_ROOT/logs}"
AUTOBUILD_TMP_ROOT="${AUTOBUILD_TMP_ROOT:-$AUTOBUILD_ROOT/tmp}"
AUTOBUILD_STATE_ROOT="${AUTOBUILD_STATE_ROOT:-$AUTOBUILD_ROOT/state}"
DAILY_STATUS_FILE="${DAILY_STATUS_FILE:-$AUTOBUILD_STATE_ROOT/daily_autobuild_status_${RUN_DATE}.txt}"
SENT_FLAG_FILE="${SENT_FLAG_FILE:-$AUTOBUILD_STATE_ROOT/.daily_autobuild_mail_sent_${RUN_DATE}.flag}"
LOCK_DIR="${LOCK_DIR:-$AUTOBUILD_TMP_ROOT/daily_autobuild_mail_notifier_${RUN_DATE}.lock}"
V100_SUMMARY_FILE="${V100_SUMMARY_FILE:-$AUTOBUILD_LOG_ROOT/openwrt/v1.00/latest_summary.env}"
MASTER_SUMMARY_FILE="${MASTER_SUMMARY_FILE:-$AUTOBUILD_LOG_ROOT/openwrt/master/latest_summary.env}"
ZEPHYROS_SUMMARY_FILE="${ZEPHYROS_SUMMARY_FILE:-$AUTOBUILD_LOG_ROOT/zephyros/latest_summary.env}"

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

EMAIL_NOTI_ENABLED="${EMAIL_NOTI_ENABLED:-0}"
GMAIL_SMTP_USER="${GMAIL_SMTP_USER:-}"
GMAIL_SMTP_APP_PASSWORD="${GMAIL_SMTP_APP_PASSWORD:-}"
MAIL_TO="${MAIL_TO:-jamesahn@gctsemi.com,kaihan@gctsemi.com}"
GMAIL_SMTP_INSECURE_TLS="${GMAIL_SMTP_INSECURE_TLS:-1}"
MAIL_FROM_NAME="${MAIL_FROM_NAME:-GCT-CS AutoBuild}"
MAIL_REPLY_TO="${MAIL_REPLY_TO:-jamesahn@gctsemi.com}"

mkdir -p "$AUTOBUILD_TMP_ROOT" "$AUTOBUILD_STATE_ROOT"

cleanup_lock() {
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

summary_ready_for_today() {
    local summary_file=$1

    if [ ! -f "$summary_file" ]; then
        return 1
    fi

    unset RUN_TS BUILD_RESULT BUILD_ENDED_AT
    # shellcheck disable=SC1090
    . "$summary_file"

    if [ -z "${RUN_TS:-}" ] || [ "${RUN_TS%%_*}" != "$RUN_DATE" ]; then
        return 1
    fi

    if [ -z "${BUILD_RESULT:-}" ] || [ -z "${BUILD_ENDED_AT:-}" ]; then
        return 1
    fi

    return 0
}

if [ "$EMAIL_NOTI_ENABLED" != "1" ]; then
    echo "[INFO] Daily mail notifier skipped: EMAIL_NOTI_ENABLED=$EMAIL_NOTI_ENABLED"
    exit 0
fi

if [ -z "$GMAIL_SMTP_USER" ] || [ -z "$GMAIL_SMTP_APP_PASSWORD" ]; then
    echo "[WARN] Daily mail notifier skipped: GMAIL_SMTP_USER or GMAIL_SMTP_APP_PASSWORD is not set"
    exit 0
fi

if [ ! -f "$DAILY_STATUS_FILE" ]; then
    echo "[WARN] Daily mail notifier skipped: daily status file not found: $DAILY_STATUS_FILE"
    exit 0
fi

if [ -f "$SENT_FLAG_FILE" ]; then
    echo "[INFO] Daily mail notifier skipped: already sent for RUN_DATE=$RUN_DATE"
    exit 0
fi

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "[INFO] Daily mail notifier skipped: another notifier run is in progress"
    exit 0
fi

trap cleanup_lock EXIT

if ! summary_ready_for_today "$V100_SUMMARY_FILE"; then
    echo "[INFO] Daily mail notifier waiting: v1.00 summary is not ready for $RUN_DATE"
    exit 0
fi

if ! summary_ready_for_today "$MASTER_SUMMARY_FILE"; then
    echo "[INFO] Daily mail notifier waiting: master summary is not ready for $RUN_DATE"
    exit 0
fi

if ! summary_ready_for_today "$ZEPHYROS_SUMMARY_FILE"; then
    echo "[INFO] Daily mail notifier waiting: Zephyros summary is not ready for $RUN_DATE"
    exit 0
fi

GMAIL_SMTP_USER="$GMAIL_SMTP_USER" \
GMAIL_SMTP_APP_PASSWORD="$GMAIL_SMTP_APP_PASSWORD" \
MAIL_TO="$MAIL_TO" \
GMAIL_MAIL_SUBJECT="GCT-CS Daily Automated Build Report - $(date '+%m/%d/%Y')" \
DAILY_STATUS_FILE="$DAILY_STATUS_FILE" \
GMAIL_SMTP_INSECURE_TLS="$GMAIL_SMTP_INSECURE_TLS" \
MAIL_FROM_NAME="$MAIL_FROM_NAME" \
MAIL_REPLY_TO="$MAIL_REPLY_TO" \
python3 - <<'PY'
import os
import smtplib
import ssl
from html import escape
from email.message import EmailMessage

user = os.environ["GMAIL_SMTP_USER"]
password = os.environ["GMAIL_SMTP_APP_PASSWORD"]
subject = os.environ["GMAIL_MAIL_SUBJECT"]
daily_status_file = os.environ["DAILY_STATUS_FILE"]
recipients = [addr.strip() for addr in os.environ["MAIL_TO"].split(",") if addr.strip()]
insecure_tls = os.environ.get("GMAIL_SMTP_INSECURE_TLS", "1") == "1"
from_name = os.environ.get("MAIL_FROM_NAME", "").strip()
reply_to = os.environ.get("MAIL_REPLY_TO", "").strip()

if not recipients:
    raise SystemExit("MAIL_TO is empty")

with open(daily_status_file, "r", encoding="utf-8") as fp:
    body = fp.read()


def parse_sections(text):
    sections = []
    current = None

    for raw_line in text.splitlines():
        line = raw_line.rstrip("\n")
        stripped = line.strip()

        if stripped.startswith("[") and stripped.endswith("]"):
            if current is not None:
                sections.append(current)
            current = {"name": stripped[1:-1], "lines": []}
            continue

        if current is not None:
            current["lines"].append(line)

    if current is not None:
        sections.append(current)

    return sections


def extract_value(lines, prefix):
    for line in lines:
        if line.startswith(prefix):
            return line.split(":", 1)[1].strip()
    return ""


sections = parse_sections(body)
summary_cards = []

for section in sections:
    lines = section["lines"]
    result = extract_value(lines, "Result")
    duration = extract_value(lines, "Duration")
    stage = extract_value(lines, "Current stage")
    fail_reason = extract_value(lines, "Fail reason")
    failure_analysis = extract_value(lines, "Failure analysis")
    log_path = extract_value(lines, "Log path")
    git_subject = extract_value(lines, "  subject")
    status_color = "#177245" if result == "SUCCESS" else "#b42318" if result == "FAIL" else "#475467"
    status_bg = "#ecfdf3" if result == "SUCCESS" else "#fef3f2" if result == "FAIL" else "#f2f4f7"

    card_lines = [
        "<div style='border:1px solid #d0d5dd;border-radius:12px;padding:16px;background:#ffffff;margin-bottom:12px;'>",
        "<div style='display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:10px;'>",
        f"<div style='font-size:16px;font-weight:700;color:#101828;'>{escape(section['name'])}</div>",
        f"<div style='padding:4px 10px;border-radius:999px;background:{status_bg};color:{status_color};font-size:12px;font-weight:700;'>{escape(result or 'UNKNOWN')}</div>",
        "</div>",
        "<div style='font-size:13px;line-height:1.6;color:#344054;'>",
    ]

    if duration:
        card_lines.append(f"<div><strong>Duration:</strong> {escape(duration)}</div>")
    if stage:
        card_lines.append(f"<div><strong>Stage:</strong> {escape(stage)}</div>")
    if git_subject:
        card_lines.append(f"<div><strong>Last commit:</strong> {escape(git_subject)}</div>")
    if fail_reason:
        card_lines.append(f"<div><strong>Fail reason:</strong> {escape(fail_reason)}</div>")
    if failure_analysis:
        card_lines.append(f"<div><strong>Failure analysis:</strong> {escape(failure_analysis)}</div>")
    if log_path:
        card_lines.append(f"<div><strong>Log path:</strong> <span style='font-family:monospace;color:#0b63ce;'>{escape(log_path)}</span></div>")

    card_lines.append("</div></div>")
    summary_cards.append("".join(card_lines))

summary_html = "".join(summary_cards) if summary_cards else "<div style='color:#475467;'>No parsed sections found.</div>"
html_body = f"""\
<html>
  <body style="margin:0;padding:24px;background:#f8fafc;font-family:'Segoe UI',Arial,sans-serif;color:#101828;">
    <div style="max-width:860px;margin:0 auto;">
      <div style="background:linear-gradient(135deg,#0f172a 0%,#1d4ed8 100%);border-radius:16px;padding:24px 28px;color:#ffffff;margin-bottom:16px;">
        <div style="font-size:13px;font-weight:700;letter-spacing:0.08em;text-transform:uppercase;opacity:0.88;">GCT-CS</div>
        <div style="font-size:28px;font-weight:800;margin-top:6px;">Daily automated build report</div>
        <div style="font-size:14px;opacity:0.9;margin-top:8px;">Generated from the CS-buildserver</div>
      </div>
      <div style="background:#ffffff;border:1px solid #eaecf0;border-radius:16px;padding:20px 20px 8px;margin-bottom:16px;">
        <div style="font-size:18px;font-weight:700;margin-bottom:14px;">{escape(subject.replace('GCT-CS Daily Automated Build Report - ', ''))} - Build Test Summary</div>
        {summary_html}
      </div>
      <div style="background:#ffffff;border:1px solid #eaecf0;border-radius:16px;padding:20px;">
        <div style="font-size:18px;font-weight:700;margin-bottom:14px;">Raw Daily Report</div>
        <pre style="margin:0;white-space:pre-wrap;word-break:break-word;font-family:Consolas,'Courier New',monospace;font-size:12px;line-height:1.6;color:#101828;background:#f8fafc;border-radius:12px;padding:16px;border:1px solid #eaecf0;">{escape(body)}</pre>
      </div>
    </div>
  </body>
</html>
"""

msg = EmailMessage()
msg["Subject"] = subject
msg["From"] = f"{from_name} <{user}>" if from_name else user
msg["To"] = ", ".join(recipients)
if reply_to:
    msg["Reply-To"] = reply_to
msg.set_content(body)
msg.add_alternative(html_body, subtype="html")

ctx = ssl.create_default_context()
if insecure_tls:
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

with smtplib.SMTP("smtp.gmail.com", 587, timeout=30) as smtp:
    smtp.ehlo()
    smtp.starttls(context=ctx)
    smtp.ehlo()
    smtp.login(user, password)
    smtp.send_message(msg)

print("MAIL_SENT")
PY

printf 'sent_at=%s\nrun_date=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RUN_DATE" > "$SENT_FLAG_FILE"
echo "[INFO] Daily mail notifier sent to: $MAIL_TO"
