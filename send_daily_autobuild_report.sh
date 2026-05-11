#!/bin/bash

set -euo pipefail

BASE_DIR="$HOME"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$HOME/.config/openwrt_autobuild.env}"
RUN_DATE="${RUN_DATE:-$(date +%Y%m%d)}"
WORK_ROOT="${GCT_WORK_ROOT:-${WORK_ROOT:-$BASE_DIR/gct_workspace}}"
AUTOBUILD_ROOT="${AUTOBUILD_ROOT:-$WORK_ROOT/autobuild}"
AUTOBUILD_LOG_ROOT="${AUTOBUILD_LOG_ROOT:-$AUTOBUILD_ROOT/logs}"
AUTOBUILD_TMP_ROOT="${AUTOBUILD_TMP_ROOT:-$AUTOBUILD_ROOT/tmp}"
AUTOBUILD_STATE_ROOT="${AUTOBUILD_STATE_ROOT:-$AUTOBUILD_ROOT/state}"
DAILY_STATUS_FILE="${DAILY_STATUS_FILE:-$AUTOBUILD_STATE_ROOT/daily_autobuild_status_${RUN_DATE}.txt}"
SENT_FLAG_FILE="${SENT_FLAG_FILE:-$AUTOBUILD_STATE_ROOT/.daily_autobuild_mail_sent_${RUN_DATE}.flag}"
UPLOAD_FLAG_FILE="${UPLOAD_FLAG_FILE:-$AUTOBUILD_STATE_ROOT/.daily_autobuild_logs_uploaded_${RUN_DATE}.flag}"
LOCK_DIR="${LOCK_DIR:-$AUTOBUILD_TMP_ROOT/daily_autobuild_mail_notifier_${RUN_DATE}.lock}"
V100_SUMMARY_FILE="${V100_SUMMARY_FILE:-$AUTOBUILD_LOG_ROOT/openwrt/v1.00/latest_summary.env}"
MASTER_SUMMARY_FILE="${MASTER_SUMMARY_FILE:-$AUTOBUILD_LOG_ROOT/openwrt/master/latest_summary.env}"
ZEPHYROS_SUMMARY_FILE="${ZEPHYROS_SUMMARY_FILE:-$AUTOBUILD_LOG_ROOT/zephyros/latest_summary.env}"
GDM7275X_LINUXOS_SUMMARY_FILE="${GDM7275X_LINUXOS_SUMMARY_FILE:-$AUTOBUILD_LOG_ROOT/linuxos/gdm7275x/latest_summary.env}"
GDM7243A_UTKERNEL_SUMMARY_FILE="${GDM7243A_UTKERNEL_SUMMARY_FILE:-$AUTOBUILD_LOG_ROOT/uTKernel/gdm7243a/latest_summary.env}"
GDM7243ST_UTKERNEL_SUMMARY_FILE="${GDM7243ST_UTKERNEL_SUMMARY_FILE:-$AUTOBUILD_LOG_ROOT/uTKernel/gdm7243st/latest_summary.env}"
GDM7243I_ZEPHYR_SUMMARY_FILE="${GDM7243I_ZEPHYR_SUMMARY_FILE:-$AUTOBUILD_LOG_ROOT/zephyr_v2_3/gdm7243i/latest_summary.env}"

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
REPORT_SUBJECT_PREFIX="${REPORT_SUBJECT_PREFIX:-}"
SAMBA_UPLOAD_CONFIG="${SAMBA_UPLOAD_CONFIG:-$BASE_DIR/.config/autobuild_samba_upload.env}"
SAMBA_UPLOAD_UNC_ROOT="${SAMBA_UPLOAD_UNC_ROOT:-K:\\ENG\\ENG05\\CS\\Test Log\\Daily_build}"

if [ -f "$SAMBA_UPLOAD_CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$SAMBA_UPLOAD_CONFIG"
fi

mkdir -p "$AUTOBUILD_TMP_ROOT" "$AUTOBUILD_STATE_ROOT"

cleanup_lock() {
    rm -f "$LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

acquire_lock() {
    local lock_pid=""

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid"
        return 0
    fi

    if [ -f "$LOCK_DIR/pid" ]; then
        lock_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    fi

    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
        return 1
    fi

    rm -f "$LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid"
        return 0
    fi

    return 1
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

run_daily_log_upload() {
    local upload_script="${UPLOAD_SCRIPT:-$SCRIPT_DIR/upload_daily_autobuild_logs.sh}"

    if [ -x "$upload_script" ]; then
        if ! RUN_DATE="$RUN_DATE" DAILY_STATUS_FILE="$DAILY_STATUS_FILE" UPLOAD_FLAG_FILE="$UPLOAD_FLAG_FILE" "$upload_script"; then
            echo "[WARN] Daily log upload failed"
        fi
    else
        echo "[WARN] Daily log upload skipped: upload script is not executable: $upload_script"
    fi
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
    if [ ! -f "$UPLOAD_FLAG_FILE" ]; then
        run_daily_log_upload
    fi
    echo "[INFO] Daily mail notifier skipped: already sent for RUN_DATE=$RUN_DATE"
    exit 0
fi

if ! acquire_lock; then
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

if ! summary_ready_for_today "$GDM7275X_LINUXOS_SUMMARY_FILE"; then
    echo "[INFO] Daily mail notifier waiting: GDM7275X Linuxos master summary is not ready for $RUN_DATE"
    exit 0
fi

if ! summary_ready_for_today "$GDM7243A_UTKERNEL_SUMMARY_FILE"; then
    echo "[INFO] Daily mail notifier waiting: GDM7243A uTKernel summary is not ready for $RUN_DATE"
    exit 0
fi

if ! summary_ready_for_today "$GDM7243ST_UTKERNEL_SUMMARY_FILE"; then
    echo "[INFO] Daily mail notifier waiting: GDM7243ST uTKernel summary is not ready for $RUN_DATE"
    exit 0
fi

if ! summary_ready_for_today "$GDM7243I_ZEPHYR_SUMMARY_FILE"; then
    echo "[INFO] Daily mail notifier waiting: GDM7243i zephyr-v2.3 summary is not ready for $RUN_DATE"
    exit 0
fi

run_daily_log_upload

REPORT_SUBJECT="GCT-CS Daily Build Report - $(date '+%m/%d/%Y')"
if [ -n "$REPORT_SUBJECT_PREFIX" ]; then
    REPORT_SUBJECT="$REPORT_SUBJECT_PREFIX $REPORT_SUBJECT"
fi

GMAIL_SMTP_USER="$GMAIL_SMTP_USER" \
GMAIL_SMTP_APP_PASSWORD="$GMAIL_SMTP_APP_PASSWORD" \
MAIL_TO="$MAIL_TO" \
GMAIL_MAIL_SUBJECT="$REPORT_SUBJECT" \
DAILY_STATUS_FILE="$DAILY_STATUS_FILE" \
RUN_DATE="$RUN_DATE" \
AUTOBUILD_LOG_ROOT="$AUTOBUILD_LOG_ROOT" \
SAMBA_UPLOAD_UNC_ROOT="$SAMBA_UPLOAD_UNC_ROOT" \
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
run_date = os.environ.get("RUN_DATE", "").strip()
autobuild_log_root = os.environ.get("AUTOBUILD_LOG_ROOT", "").rstrip("/")
samba_unc_root = os.environ.get("SAMBA_UPLOAD_UNC_ROOT", "").rstrip("\\")

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


def extract_indented_block(lines, header):
    block = []
    in_block = False

    for line in lines:
        if line.startswith(header):
            in_block = True
            continue

        if not in_block:
            continue

        if line.startswith("  "):
            block.append(line.strip())
            continue

        if line.strip():
            break

    return block


def safe_name(value):
    safe = "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in value)
    safe = safe.strip("_")
    return safe or "unknown"


def upload_dir_name(section_name, item_name):
    if item_name == "OpenWrt v1.00":
        return "GDM7275X\\openwrt_v100"
    if item_name == "OpenWrt master":
        return "GDM7275X\\openwrt_master"
    if item_name == "Linuxos master":
        return "GDM7275X\\linuxos_master"
    if item_name == "Zephyros":
        return "GDM7275X\\Zephyros"

    lowered = section_name.lower()
    if "gdm7243st" in lowered:
        return "GDM7243ST\\uTKernel"
    if "gdm7243a" in lowered:
        return "GDM7243A\\uTKernel"
    if "gdm7243i" in lowered:
        return "GDM7243i\\zephyr_v2.3"

    return safe_name(section_name)


def display_upload_path(section_name, item_name, subdir):
    if not samba_unc_root or not run_date:
        return ""
    return samba_unc_root + "\\" + run_date + "\\" + upload_dir_name(section_name, item_name) + "\\" + subdir


sections = parse_sections(body)
model_groups = []
model_index = {}


def split_model_item(section_name):
    parts = section_name.split(maxsplit=1)
    if len(parts) == 2 and parts[0].startswith("GDM"):
        return parts[0], parts[1]
    if section_name.startswith("OpenWrt ") or section_name == "Zephyros":
        return "GDM7275X", section_name
    return "Other", section_name


def add_model_card(model_name, item_html):
    if model_name not in model_index:
        model_index[model_name] = {"name": model_name, "items": []}
        model_groups.append(model_index[model_name])
    model_index[model_name]["items"].append(item_html)


def model_sort_key(group):
    order = {
        "GDM7275X": 0,
        "GDM7243A": 1,
        "GDM7243ST": 2,
        "GDM7243i": 3,
    }
    return order.get(group["name"], 99), group["name"]


def item_sort_key(item):
    order = {
        "OpenWrt v1.00": 0,
        "OpenWrt master": 1,
        "Linuxos master": 2,
        "Zephyros": 3,
    }
    return order.get(item["name"], 99), item["name"]

for section in sections:
    lines = section["lines"]
    model_name, item_name = split_model_item(section["name"])
    display_item_name = item_name.replace("OpenWrt", "OpenWRT", 1)
    result = extract_value(lines, "Result")
    duration = extract_value(lines, "Duration")
    fail_reason = extract_value(lines, "Fail reason")
    failure_analysis = extract_value(lines, "Failure analysis")
    log_path = display_upload_path(section["name"], item_name, "Log")
    artifact_path = display_upload_path(section["name"], item_name, "Image") if result == "SUCCESS" else ""
    git_lines = extract_indented_block(lines, "Git log")
    status_color = "#177245" if result == "SUCCESS" else "#b42318" if result == "FAIL" else "#475467"
    status_bg = "#ecfdf3" if result == "SUCCESS" else "#fef3f2" if result == "FAIL" else "#f2f4f7"

    card_lines = [
        "<div style='border:1px solid #e4e7ec;border-radius:8px;padding:14px 16px;background:#ffffff;margin:10px 0 0 18px;'>",
        "<div style='display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:10px;'>",
        f"<div style='font-size:15px;font-weight:700;color:#101828;'>- {escape(display_item_name)}</div>",
        f"<div style='padding:4px 10px;border-radius:999px;background:{status_bg};color:{status_color};font-size:12px;font-weight:700;white-space:nowrap;'>{escape(result or 'UNKNOWN')}</div>",
        "</div>",
        "<div style='font-size:13px;line-height:1.6;color:#344054;'>",
    ]

    if duration:
        card_lines.append(f"<div><strong>Duration:</strong> {escape(duration)}</div>")
    if git_lines:
        git_block = "\n".join(escape(line) for line in git_lines)
        card_lines.append(
            "<div><strong>Last commit:</strong></div>"
            "<pre style='margin:4px 0 0 18px;padding:8px 10px;background:#f8fafc;border:1px solid #e4e7ec;border-radius:6px;"
            "font-family:Consolas,Menlo,monospace;font-size:12px;line-height:1.45;color:#344054;white-space:pre-wrap;'>"
            f"{git_block}</pre>"
        )
    if fail_reason:
        card_lines.append(f"<div><strong>Fail reason:</strong> {escape(fail_reason)}</div>")
    if failure_analysis:
        card_lines.append(f"<div><strong>Failure analysis:</strong> {escape(failure_analysis)}</div>")
    if log_path:
        card_lines.append(f"<div><strong>Log PATH:</strong> <span style='font-family:monospace;color:#0b63ce;'>{escape(log_path)}</span></div>")
    if artifact_path:
        card_lines.append(f"<div><strong>Image PATH:</strong> <span style='font-family:monospace;color:#0b63ce;'>{escape(artifact_path)}</span></div>")

    card_lines.append("</div></div>")
    if model_name not in model_index:
        model_index[model_name] = {"name": model_name, "items": []}
        model_groups.append(model_index[model_name])
    model_index[model_name]["items"].append({"name": item_name, "html": "".join(card_lines)})

model_cards = []
for group in sorted(model_groups, key=model_sort_key):
    group["items"].sort(key=item_sort_key)
    item_count = len(group["items"])
    model_cards.append(
        "<div style='border:1px solid #d0d5dd;border-radius:10px;background:#f8fafc;margin-bottom:14px;padding:16px;'>"
        "<div style='display:flex;align-items:center;justify-content:space-between;gap:12px;'>"
        f"<div style='font-size:18px;font-weight:800;color:#101828;'>{escape(group['name'])}</div>"
        f"<div style='font-size:12px;font-weight:700;color:#475467;background:#ffffff;border:1px solid #e4e7ec;border-radius:999px;padding:4px 10px;'>{item_count} item{'s' if item_count != 1 else ''}</div>"
        "</div>"
        "<div style='border-left:2px solid #d0d5dd;margin-top:12px;'>"
        + "".join(item["html"] for item in group["items"])
        + "</div></div>"
    )

summary_html = "".join(model_cards) if model_cards else "<div style='color:#475467;'>No parsed sections found.</div>"
plain_body = "GCT-CS Daily Build Report\n\nRaw daily report is omitted. Please view the HTML email for the model-grouped build summary."
html_body = f"""\
<html>
  <body style="margin:0;padding:24px;background:#f8fafc;font-family:'Segoe UI',Arial,sans-serif;color:#101828;">
    <div style="max-width:860px;margin:0 auto;">
      <div style="background:#0f172a;border-radius:16px;padding:24px 28px;color:#ffffff;margin-bottom:16px;">
        <div style="font-size:13px;font-weight:700;letter-spacing:0.08em;text-transform:uppercase;opacity:0.88;">GCT-CS</div>
        <div style="font-size:28px;font-weight:800;margin-top:6px;">Daily build report</div>
        <div style="font-size:14px;opacity:0.9;margin-top:8px;">Generated from the CS-buildserver</div>
      </div>
      <div style="background:#ffffff;border:1px solid #eaecf0;border-radius:16px;padding:20px 20px 8px;margin-bottom:16px;">
        <div style="font-size:18px;font-weight:700;margin-bottom:14px;">{escape(subject.replace('GCT-CS Daily Build Report - ', ''))} - Build Test Summary</div>
        {summary_html}
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
msg.set_content(plain_body)
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
