#!/bin/bash

set -u

RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DATE="$(date +%Y%m%d)"
BASE_DIR="$HOME"
WORK_ROOT="${GCT_WORK_ROOT:-${WORK_ROOT:-$BASE_DIR/gct_workspace}}"
AUTOBUILD_ROOT="${AUTOBUILD_ROOT:-$WORK_ROOT/autobuild}"
AUTOBUILD_LOG_ROOT="${AUTOBUILD_LOG_ROOT:-$AUTOBUILD_ROOT/logs}"
TEST_ROOT="$AUTOBUILD_LOG_ROOT/manual_test/new_models/$RUN_TS"
TEST_STATUS_FILE="$TEST_ROOT/new_model_test_status.txt"
TEST_MAIL_TO="${TEST_MAIL_TO:-jamesahn@gctsemi.com}"
OS_SCRIPT_PATH="$HOME/gct-build-tools/autobuild/os_autobuild.sh"
SHARED_CONFIG_FILE="$HOME/.config/autobuild_common.env"

mkdir -p "$TEST_ROOT"

if [ -f "$SHARED_CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$SHARED_CONFIG_FILE"
fi

run_item() {
    local item_name=$1
    local config_file=$2
    local log_file=$3
    local rc

    echo "[INFO] START $item_name at $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$TEST_ROOT/runner.log"
    CONFIG_FILE="$config_file" "$OS_SCRIPT_PATH" > "$TEST_ROOT/$log_file" 2>&1
    rc=$?
    echo "[INFO] END $item_name rc=$rc at $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$TEST_ROOT/runner.log"
    return 0
}

append_summary() {
    local label=$1
    local summary_path=$2

    if [ ! -f "$summary_path" ]; then
        {
            echo "[$label]"
            echo "Status       : NOT_RUN"
            echo "Summary path : $summary_path"
            echo
        } >> "$TEST_STATUS_FILE"
        return
    fi

    unset TARGET_NAME BUILD_RESULT CURRENT_STAGE BUILD_STARTED_AT BUILD_ENDED_AT
    unset BUILD_DURATION_FMT RUN_TS BUILD_LOG FAIL_REASON FAILURE_ANALYSIS
    unset MAIN_REPO_LAST_COMMIT MAIN_REPO_LAST_AUTHOR MAIN_REPO_LAST_DATE MAIN_REPO_LAST_SUBJECT
    # shellcheck disable=SC1090
    . "$summary_path"

    {
        echo "[${TARGET_NAME:-$label}]"
        echo "Result       : ${BUILD_RESULT:-UNKNOWN}"
        echo "Current stage: ${CURRENT_STAGE:-}"
        echo "Started      : ${BUILD_STARTED_AT:-}"
        echo "Ended        : ${BUILD_ENDED_AT:-}"
        echo "Duration     : ${BUILD_DURATION_FMT:-}"
        echo "Run ts       : ${RUN_TS:-}"
        echo "Log path     : ${BUILD_LOG:-}"
        if [ -n "${FAIL_REASON:-}" ]; then
            echo "Fail reason  : $FAIL_REASON"
        fi
        if [ -n "${FAILURE_ANALYSIS:-}" ]; then
            echo "Failure analysis: $FAILURE_ANALYSIS"
        fi
        if [ -n "${MAIN_REPO_LAST_COMMIT:-}" ] || [ -n "${MAIN_REPO_LAST_SUBJECT:-}" ]; then
            echo "Git log      :"
            echo "  commit : ${MAIN_REPO_LAST_COMMIT:-}"
            echo "  author : ${MAIN_REPO_LAST_AUTHOR:-}"
            echo "  date   : ${MAIN_REPO_LAST_DATE:-}"
            echo "  subject: ${MAIN_REPO_LAST_SUBJECT:-}"
        fi
        echo
    } >> "$TEST_STATUS_FILE"
}

send_test_mail() {
    if [ "${EMAIL_NOTI_ENABLED:-0}" != "1" ]; then
        echo "[WARN] Test mail skipped: EMAIL_NOTI_ENABLED=${EMAIL_NOTI_ENABLED:-0}" | tee -a "$TEST_ROOT/runner.log"
        return 0
    fi

    if [ -z "${SMTP_HOST:-}" ] || [ -z "${SMTP_PORT:-}" ] || [ -z "${MAIL_FROM:-}" ]; then
        echo "[WARN] Test mail skipped: SMTP_HOST, SMTP_PORT, or MAIL_FROM is not set" | tee -a "$TEST_ROOT/runner.log"
        return 0
    fi

    TEST_STATUS_FILE="$TEST_STATUS_FILE" \
    TEST_MAIL_TO="$TEST_MAIL_TO" \
    SMTP_HOST="$SMTP_HOST" \
    SMTP_PORT="$SMTP_PORT" \
    SMTP_USER="${SMTP_USER:-}" \
    SMTP_PASSWORD="${SMTP_PASSWORD:-}" \
    SMTP_USE_STARTTLS="${SMTP_USE_STARTTLS:-1}" \
    SMTP_INSECURE_TLS="${SMTP_INSECURE_TLS:-0}" \
    MAIL_FROM="$MAIL_FROM" \
    MAIL_FROM_NAME="${MAIL_FROM_NAME:-GCT-CS AutoBuild}" \
    MAIL_REPLY_TO="${MAIL_REPLY_TO:-jamesahn@gctsemi.com}" \
    python3 - <<'PY'
import os
import smtplib
import ssl
from email.message import EmailMessage
from html import escape

status_file = os.environ["TEST_STATUS_FILE"]
smtp_host = os.environ["SMTP_HOST"]
smtp_port = int(os.environ.get("SMTP_PORT", "587"))
smtp_user = os.environ.get("SMTP_USER", "").strip()
smtp_password = os.environ.get("SMTP_PASSWORD", "")
smtp_use_starttls = os.environ.get("SMTP_USE_STARTTLS", "1") == "1"
smtp_insecure_tls = os.environ.get("SMTP_INSECURE_TLS", "0") == "1"
mail_from = os.environ["MAIL_FROM"].strip()
recipients = [addr.strip() for addr in os.environ["TEST_MAIL_TO"].split(",") if addr.strip()]
from_name = os.environ.get("MAIL_FROM_NAME", "").strip()
reply_to = os.environ.get("MAIL_REPLY_TO", "").strip()

with open(status_file, "r", encoding="utf-8") as fp:
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

cards = []
for section in parse_sections(body):
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
    parts = [
        "<div style='border:1px solid #d0d5dd;border-radius:10px;background:#ffffff;margin-bottom:12px;padding:16px;'>",
        "<div style='display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:10px;'>",
        f"<div style='font-size:16px;font-weight:800;color:#101828;'>{escape(section['name'])}</div>",
        f"<div style='padding:4px 10px;border-radius:999px;background:{status_bg};color:{status_color};font-size:12px;font-weight:700;'>{escape(result or 'UNKNOWN')}</div>",
        "</div>",
        "<div style='font-size:13px;line-height:1.6;color:#344054;'>",
    ]
    if duration:
        parts.append(f"<div><strong>Duration:</strong> {escape(duration)}</div>")
    if stage:
        parts.append(f"<div><strong>Stage:</strong> {escape(stage)}</div>")
    if git_subject:
        parts.append(f"<div><strong>Last commit:</strong> {escape(git_subject)}</div>")
    if fail_reason:
        parts.append(f"<div><strong>Fail reason:</strong> {escape(fail_reason)}</div>")
    if failure_analysis:
        parts.append(f"<div><strong>Failure analysis:</strong> {escape(failure_analysis)}</div>")
    if log_path:
        parts.append(f"<div><strong>Log path:</strong> <span style='font-family:monospace;color:#0b63ce;'>{escape(log_path)}</span></div>")
    parts.append("</div></div>")
    cards.append("".join(parts))

html_body = f"""\
<html>
  <body style="margin:0;padding:24px;background:#f8fafc;font-family:'Segoe UI',Arial,sans-serif;color:#101828;">
    <div style="max-width:860px;margin:0 auto;">
      <div style="background:#0f172a;border-radius:16px;padding:24px 28px;color:#ffffff;margin-bottom:16px;">
        <div style="font-size:13px;font-weight:700;letter-spacing:0.08em;text-transform:uppercase;opacity:0.88;">GCT-CS</div>
        <div style="font-size:26px;font-weight:800;margin-top:6px;">New model autobuild test report</div>
        <div style="font-size:14px;opacity:0.9;margin-top:8px;">One-time test run for GDM7243A, GDM7243ST, and GDM7243i</div>
      </div>
      {''.join(cards)}
    </div>
  </body>
</html>
"""

msg = EmailMessage()
msg["Subject"] = "GCT-CS New Model Autobuild Test Report"
msg["From"] = f"{from_name} <{mail_from}>" if from_name else mail_from
msg["To"] = ", ".join(recipients)
if reply_to:
    msg["Reply-To"] = reply_to
msg.set_content("New model autobuild test report. Please view the HTML part for the summary.")
msg.add_alternative(html_body, subtype="html")

ctx = ssl.create_default_context()
if smtp_insecure_tls:
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

with smtplib.SMTP(smtp_host, smtp_port, timeout=30) as smtp:
    smtp.ehlo()
    if smtp_use_starttls:
        smtp.starttls(context=ctx)
        smtp.ehlo()
    if smtp_user or smtp_password:
        smtp.login(smtp_user, smtp_password)
    smtp.send_message(msg)

print("MAIL_SENT")
PY
}

echo "[INFO] New model autobuild one-time test started at $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$TEST_ROOT/runner.log"

run_item "GDM7243A uTKernel" "$HOME/.config/gdm7243a_utkernel_autobuild.env" "01_gdm7243a_utkernel.log"
run_item "GDM7243ST uTKernel" "$HOME/.config/gdm7243st_utkernel_autobuild.env" "02_gdm7243st_utkernel.log"
run_item "GDM7243i zephyr-v2.3" "$HOME/.config/gdm7243i_zephyr_v2.3_autobuild.env" "03_gdm7243i_zephyr_v2.3.log"

{
    echo "=========================================="
    echo "New Model Autobuild Test Status"
    echo "Generated at : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=========================================="
    echo
} > "$TEST_STATUS_FILE"

append_summary "GDM7243A uTKernel" "$AUTOBUILD_LOG_ROOT/uTKernel/gdm7243a/latest_summary.env"
append_summary "GDM7243ST uTKernel" "$AUTOBUILD_LOG_ROOT/uTKernel/gdm7243st/latest_summary.env"
append_summary "GDM7243i zephyr-v2.3" "$AUTOBUILD_LOG_ROOT/zephyr_v2_3/gdm7243i/latest_summary.env"

send_test_mail >> "$TEST_ROOT/test_mail.log" 2>&1

echo "[INFO] New model autobuild one-time test finished at $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$TEST_ROOT/runner.log"
echo "[INFO] Test root: $TEST_ROOT"
