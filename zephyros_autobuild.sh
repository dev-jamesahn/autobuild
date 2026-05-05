#!/bin/bash

set -euo pipefail

RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DATE="$(date +%Y%m%d)"
START_EPOCH="$(date +%s)"

BASE_DIR="$HOME"
CONFIG_FILE="${CONFIG_FILE:-$HOME/.config/zephyros_autobuild.env}"
RUN_USER="${USER:-${LOGNAME:-$(id -un)}}"

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

PKG_VERSION="${PKG_VERSION:-0.0.0}"
MODEL_LINEUP="${MODEL_LINEUP:-GDM7275X}"
ZEPHYROS_CONFIG_SELECT="${ZEPHYROS_CONFIG_SELECT:-7}"
ZEPHYROS_CONFIG_NAME="${ZEPHYROS_CONFIG_NAME:-gdm7259x_nsa}"
ZEPHYROS_REPO_URL="${ZEPHYROS_REPO_URL:-https://jamesahn@vcs.gctsemi.com/OS/Zephyros}"
WORK_ROOT="${GCT_WORK_ROOT:-${WORK_ROOT:-$BASE_DIR/gct_workspace}}"
AUTOBUILD_ROOT="${AUTOBUILD_ROOT:-$WORK_ROOT/autobuild}"
AUTOBUILD_REPO_ROOT="${AUTOBUILD_REPO_ROOT:-$AUTOBUILD_ROOT/repos}"
AUTOBUILD_LOG_ROOT="${AUTOBUILD_LOG_ROOT:-$AUTOBUILD_ROOT/logs}"
AUTOBUILD_TMP_ROOT="${AUTOBUILD_TMP_ROOT:-$AUTOBUILD_ROOT/tmp}"
AUTOBUILD_STATE_ROOT="${AUTOBUILD_STATE_ROOT:-$AUTOBUILD_ROOT/state}"
WORK_DIR="${WORK_DIR:-$AUTOBUILD_TMP_ROOT/zephyros_${RUN_USER}}"
REPO_DIR="${REPO_DIR:-$AUTOBUILD_REPO_ROOT/zephyros/build}"
LOG_ROOT="${LOG_ROOT:-$AUTOBUILD_LOG_ROOT/zephyros}"

RUN_DIR="$LOG_ROOT/$RUN_TS"
BUILD_LOG="$RUN_DIR/build.log"
VERBOSE_LOG="$RUN_DIR/build_verbose.log"
HASH_LOG="$RUN_DIR/hashes.log"
FAILURE_REPORT="$RUN_DIR/failure_report.log"
STATUS_FILE="$RUN_DIR/status.txt"
SUMMARY_FILE="$RUN_DIR/summary.env"
LATEST_LINK="$LOG_ROOT/latest"
LATEST_STATUS_FILE="$LOG_ROOT/latest_status.txt"
LATEST_SUMMARY_FILE="$LOG_ROOT/latest_summary.env"
DAILY_STATUS_FILE="${DAILY_STATUS_FILE:-$AUTOBUILD_STATE_ROOT/daily_autobuild_status_${RUN_DATE}.txt}"
EMAIL_NOTI_ENABLED="${EMAIL_NOTI_ENABLED:-0}"
GMAIL_SMTP_USER="${GMAIL_SMTP_USER:-}"
GMAIL_SMTP_APP_PASSWORD="${GMAIL_SMTP_APP_PASSWORD:-}"
MAIL_TO="${MAIL_TO:-jamesahn@gctsemi.com,kaihan@gctsemi.com}"
GMAIL_SMTP_INSECURE_TLS="${GMAIL_SMTP_INSECURE_TLS:-1}"
MAIL_FROM_NAME="${MAIL_FROM_NAME:-GCT-CS AutoBuild}"
MAIL_REPLY_TO="${MAIL_REPLY_TO:-jamesahn@gctsemi.com}"
MAIL_NOTIFY_SEND_ON="${MAIL_NOTIFY_SEND_ON:-notifier}"

mkdir -p "$WORK_DIR" "$RUN_DIR" "$AUTOBUILD_STATE_ROOT"
touch "$BUILD_LOG"
exec > >(tee -a "$BUILD_LOG") 2>&1

CURRENT_STAGE="init"
BUILD_RESULT="FAIL"
FAIL_REASON=""
FAILURE_ANALYSIS=""
TARGET_NAME="${MODEL_LINEUP} Zephyros"
MAIN_REPO_URL="$ZEPHYROS_REPO_URL"
MAIN_REPO_DIR="$REPO_DIR"
MAIN_REPO_COMMIT=""
MAIN_REPO_LAST_COMMIT=""
MAIN_REPO_LAST_AUTHOR=""
MAIN_REPO_LAST_DATE=""
MAIN_REPO_LAST_SUBJECT=""

format_duration() {
    local total_seconds=$1
    local hours=$((total_seconds / 3600))
    local minutes=$(((total_seconds % 3600) / 60))
    local seconds=$((total_seconds % 60))
    printf "%02d:%02d:%02d" "$hours" "$minutes" "$seconds"
}

send_daily_status_email() {
    local subject

    if [ "$EMAIL_NOTI_ENABLED" != "1" ]; then
        return
    fi

    if [ "$MAIL_NOTIFY_SEND_ON" != "all" ] && [ "$MAIL_NOTIFY_SEND_ON" != "zephyros" ]; then
        echo "[INFO] Email notification skipped on zephyros_autobuild.sh: MAIL_NOTIFY_SEND_ON=$MAIL_NOTIFY_SEND_ON"
        return
    fi

    if [ -z "$GMAIL_SMTP_USER" ] || [ -z "$GMAIL_SMTP_APP_PASSWORD" ]; then
        echo "[WARN] Email notification skipped: GMAIL_SMTP_USER or GMAIL_SMTP_APP_PASSWORD is not set"
        return
    fi

    if [ ! -f "$DAILY_STATUS_FILE" ]; then
        echo "[WARN] Email notification skipped: daily status file not found: $DAILY_STATUS_FILE"
        return
    fi

    subject="GCT-CS Daily Automated Build Report - $(date '+%m/%d/%Y')"

    if ! GMAIL_SMTP_USER="$GMAIL_SMTP_USER" \
        GMAIL_SMTP_APP_PASSWORD="$GMAIL_SMTP_APP_PASSWORD" \
        MAIL_TO="$MAIL_TO" \
        GMAIL_MAIL_SUBJECT="$subject" \
        DAILY_STATUS_FILE="$DAILY_STATUS_FILE" \
        GMAIL_SMTP_INSECURE_TLS="$GMAIL_SMTP_INSECURE_TLS" \
        MAIL_FROM_NAME="$MAIL_FROM_NAME" \
        MAIL_REPLY_TO="$MAIL_REPLY_TO" \
        python3 - <<'PY'
import os
import smtplib
import ssl
import sys
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

print("MAIL_SENT", file=sys.stdout)
PY
    then
        echo "[WARN] Email notification failed"
        return
    fi

    echo "[INFO] Email notification sent to: $MAIL_TO"
}

collect_main_repo_metadata() {
    if [ ! -d "$MAIN_REPO_DIR/.git" ]; then
        return
    fi

    MAIN_REPO_COMMIT="$(git -C "$MAIN_REPO_DIR" rev-parse HEAD 2>/dev/null || true)"
    MAIN_REPO_LAST_COMMIT="$MAIN_REPO_COMMIT"
    MAIN_REPO_LAST_AUTHOR="$(git -C "$MAIN_REPO_DIR" log -1 --format='%an <%ae>' 2>/dev/null || true)"
    MAIN_REPO_LAST_DATE="$(git -C "$MAIN_REPO_DIR" log -1 --date=iso-strict --format='%ad' 2>/dev/null || true)"
    MAIN_REPO_LAST_SUBJECT="$(git -C "$MAIN_REPO_DIR" log -1 --format='%s' 2>/dev/null || true)"
}

append_daily_target_status() {
    local label=$1
    local summary_path=$2
    local summary_target_name=$label
    local include_manifest_hashes=1
    local manifest_gdm_commit=""
    local manifest_sbl_commit=""
    local manifest_uboot_commit=""

    if [ ! -f "$summary_path" ]; then
        {
            echo "[$label]"
            echo "Status       : NOT_RUN"
            echo
        } >> "$DAILY_STATUS_FILE"
        return
    fi

    unset TARGET_NAME BUILD_RESULT CURRENT_STAGE BUILD_STARTED_AT BUILD_ENDED_AT
    unset BUILD_DURATION_FMT RUN_TS BUILD_LOG FAIL_REASON FAILURE_ANALYSIS
    unset MAIN_REPO_LAST_COMMIT MAIN_REPO_LAST_AUTHOR MAIN_REPO_LAST_DATE MAIN_REPO_LAST_SUBJECT
    unset MANIFEST_GDM_COMMIT MANIFEST_SBL_COMMIT MANIFEST_UBOOT_COMMIT HASH_LOG

    # shellcheck disable=SC1090
    . "$summary_path"

    if [ -n "${TARGET_NAME:-}" ]; then
        summary_target_name="$TARGET_NAME"
    fi

    if [ "${summary_target_name#*Zephyros}" != "$summary_target_name" ]; then
        include_manifest_hashes=0
    fi

    manifest_gdm_commit="${MANIFEST_GDM_COMMIT:-}"
    manifest_sbl_commit="${MANIFEST_SBL_COMMIT:-}"
    manifest_uboot_commit="${MANIFEST_UBOOT_COMMIT:-}"

    if [ "$include_manifest_hashes" -eq 1 ] && [ -z "$manifest_gdm_commit" ] && [ -f "${HASH_LOG:-}" ]; then
        manifest_gdm_commit="$(awk -F'|' '$1=="GDM"{print $3; exit}' "$HASH_LOG" 2>/dev/null || true)"
    fi
    if [ "$include_manifest_hashes" -eq 1 ] && [ -z "$manifest_sbl_commit" ] && [ -f "${HASH_LOG:-}" ]; then
        manifest_sbl_commit="$(awk -F'|' '$1=="SBL"{print $3; exit}' "$HASH_LOG" 2>/dev/null || true)"
    fi
    if [ "$include_manifest_hashes" -eq 1 ] && [ -z "$manifest_uboot_commit" ] && [ -f "${HASH_LOG:-}" ]; then
        manifest_uboot_commit="$(awk -F'|' '$1=="UBOOT"{print $3; exit}' "$HASH_LOG" 2>/dev/null || true)"
    fi

    {
        echo "[$summary_target_name]"
        echo "Result       : ${BUILD_RESULT:-UNKNOWN}"
        echo "Current stage: ${CURRENT_STAGE:-}"
        echo "Started      : ${BUILD_STARTED_AT:-}"
        echo "Ended        : ${BUILD_ENDED_AT:-}"
        echo "Duration     : ${BUILD_DURATION_FMT:-}"
        echo "Run ts       : ${RUN_TS:-}"
        echo "Log path     : ${BUILD_LOG:-}"
        if [ -n "${FAIL_REASON:-}" ]; then
            echo "Fail reason  : ${FAIL_REASON}"
        fi
        if [ -n "${FAILURE_ANALYSIS:-}" ]; then
            echo "Failure analysis: ${FAILURE_ANALYSIS}"
        fi
        if [ -n "${MAIN_REPO_LAST_COMMIT:-}" ] || [ -n "${MAIN_REPO_LAST_SUBJECT:-}" ]; then
            echo "Git log      :"
            echo "  commit : ${MAIN_REPO_LAST_COMMIT:-}"
            echo "  author : ${MAIN_REPO_LAST_AUTHOR:-}"
            echo "  date   : ${MAIN_REPO_LAST_DATE:-}"
            echo "  subject: ${MAIN_REPO_LAST_SUBJECT:-}"
        fi
        if [ "$include_manifest_hashes" -eq 1 ] && { [ -n "$manifest_gdm_commit" ] || [ -n "$manifest_sbl_commit" ] || [ -n "$manifest_uboot_commit" ]; }; then
            echo "Manifest hashes:"
            echo "  GDM   : $manifest_gdm_commit"
            echo "  SBL   : $manifest_sbl_commit"
            echo "  UBOOT : $manifest_uboot_commit"
        fi
        echo
    } >> "$DAILY_STATUS_FILE"
}

update_daily_status_file() {
    {
        echo "=========================================="
        echo "Daily Autobuild Status"
        echo "Generated at : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "=========================================="
        echo
    } > "$DAILY_STATUS_FILE"

    append_daily_target_status "OpenWrt v1.00" "$AUTOBUILD_LOG_ROOT/openwrt/v1.00/latest_summary.env"
    append_daily_target_status "OpenWrt master" "$AUTOBUILD_LOG_ROOT/openwrt/master/latest_summary.env"
    append_daily_target_status "Zephyros" "$AUTOBUILD_LOG_ROOT/zephyros/latest_summary.env"

    while IFS= read -r summary_path; do
        [ -n "$summary_path" ] || continue
        append_daily_target_status "OS Autobuild" "$summary_path"
    done < <(find "$AUTOBUILD_LOG_ROOT" -mindepth 3 -maxdepth 3 -type f -name latest_summary.env 2>/dev/null | sort | grep -Ev '/(openwrt|zephyros|utkernel)/')
}

extract_failure_analysis() {
    local source_log=$1
    local root_error=""
    local message=""
    local source_path=""
    local source_line=""
    local source_location=""

    if [ ! -f "$source_log" ]; then
        FAILURE_ANALYSIS=""
        return
    fi

    root_error="$(grep -aEn 'CMake Error|fatal error:|[[:space:]]error:|undefined reference|cannot find|No such file or directory|ninja: build stopped|make(\[[0-9]+\])?: \*\*\*' "$source_log" 2>/dev/null \
        | grep -avE 'warning:|grep: .*binary file matches' \
        | head -n 1 | tr -d '\r' || true)"
    if [ -z "$root_error" ]; then
        root_error="$(grep -aEn 'FAILED:' "$source_log" 2>/dev/null | head -n 1 | tr -d '\r' || true)"
    fi

    if [ -z "$root_error" ]; then
        FAILURE_ANALYSIS=""
        return
    fi

    source_path="$(printf '%s\n' "$root_error" | sed -E 's#^[0-9]+:([^:]+):[0-9]+:.*#\1#')"
    source_line="$(printf '%s\n' "$root_error" | sed -E 's#^[0-9]+:[^:]+:([0-9]+):.*#\1#')"
    message="$(printf '%s\n' "$root_error" | sed -E 's#^[0-9]+:([^:]+:)?([0-9]+:)?([0-9]+:)?[[:space:]]*##')"

    if [ -n "$source_path" ] && [ "$source_path" != "$root_error" ]; then
        if [ -f "$source_path" ]; then
            source_path="$(realpath "$source_path" 2>/dev/null || printf '%s' "$source_path")"
        elif [ -f "$REPO_DIR/$source_path" ]; then
            source_path="$REPO_DIR/$source_path"
        fi

        source_location="$source_path"
        if [ -n "$source_line" ] && [ "$source_line" != "$root_error" ]; then
            source_location="$source_location:$source_line"
        fi
    fi

    FAILURE_ANALYSIS="$message"
    if [ -n "$source_location" ]; then
        FAILURE_ANALYSIS="$FAILURE_ANALYSIS at $source_location"
    fi
}

analyze_failure() {
    local source_log
    source_log="$VERBOSE_LOG"
    if [ ! -f "$source_log" ] || [ ! -s "$source_log" ]; then
        source_log="$BUILD_LOG"
    fi

    extract_failure_analysis "$source_log"

    {
        echo "=========================================="
        echo "Zephyros Build Failure Report"
        echo "=========================================="
        echo "Repo path      : $REPO_DIR"
        echo "Build log      : $BUILD_LOG"
        echo "Verbose log    : $VERBOSE_LOG"
        echo "Hash log       : $HASH_LOG"
        echo "Source log     : $source_log"
        echo "Generated at   : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Current stage  : $CURRENT_STAGE"
        echo "Fail reason    : $FAIL_REASON"
        if [ -n "$FAILURE_ANALYSIS" ]; then
            echo "Failure analysis: $FAILURE_ANALYSIS"
        fi
        echo
        if [ -n "$FAILURE_ANALYSIS" ]; then
            echo "[Failure analysis]"
            echo "$FAILURE_ANALYSIS"
            echo
        fi
        echo "[Recent errors]"
        grep -nEi 'error:|failed|No such file or directory|cannot find|undefined reference|ninja: build stopped|CMake Error' "$source_log" | tail -n 60 || true
        echo
    } > "$FAILURE_REPORT"
}

finalize() {
    local rc=$1
    local end_epoch
    local build_started_at
    local build_ended_at

    end_epoch="$(date +%s)"
    BUILD_DURATION_SEC=$((end_epoch - START_EPOCH))
    BUILD_DURATION_FMT="$(format_duration "$BUILD_DURATION_SEC")"
    build_started_at="$(date -d "@$START_EPOCH" '+%Y-%m-%d %H:%M:%S')"
    build_ended_at="$(date -d "@$end_epoch" '+%Y-%m-%d %H:%M:%S')"

    if [ "$rc" -eq 0 ]; then
        BUILD_RESULT="SUCCESS"
    else
        BUILD_RESULT="FAIL"
        if [ -z "$FAIL_REASON" ]; then
            FAIL_REASON="Command failed during stage: $CURRENT_STAGE"
        fi
        analyze_failure
    fi

    collect_main_repo_metadata

    {
        echo "TARGET_NAME=$(printf '%q' "$TARGET_NAME")"
        echo "RUN_TS=$RUN_TS"
        echo "PKG_VERSION=$PKG_VERSION"
        echo "MODEL_LINEUP=$(printf '%q' "$MODEL_LINEUP")"
        echo "ZEPHYROS_CONFIG_SELECT=$ZEPHYROS_CONFIG_SELECT"
        echo "ZEPHYROS_CONFIG_NAME=$ZEPHYROS_CONFIG_NAME"
        echo "BUILD_RESULT=$BUILD_RESULT"
        echo "CURRENT_STAGE=$CURRENT_STAGE"
        echo "BUILD_STARTED_AT=$(printf '%q' "$build_started_at")"
        echo "BUILD_ENDED_AT=$(printf '%q' "$build_ended_at")"
        echo "BUILD_DURATION_SEC=$BUILD_DURATION_SEC"
        echo "BUILD_DURATION_FMT=$BUILD_DURATION_FMT"
        echo "BUILD_LOG=$BUILD_LOG"
        echo "VERBOSE_LOG=$VERBOSE_LOG"
        echo "HASH_LOG=$HASH_LOG"
        echo "FAILURE_REPORT=$FAILURE_REPORT"
        echo "FAIL_REASON=$(printf '%q' "$FAIL_REASON")"
        echo "FAILURE_ANALYSIS=$(printf '%q' "$FAILURE_ANALYSIS")"
        echo "MAIN_REPO_URL=$(printf '%q' "$MAIN_REPO_URL")"
        echo "MAIN_REPO_DIR=$(printf '%q' "$MAIN_REPO_DIR")"
        echo "MAIN_REPO_COMMIT=$(printf '%q' "$MAIN_REPO_COMMIT")"
        echo "MAIN_REPO_LAST_COMMIT=$(printf '%q' "$MAIN_REPO_LAST_COMMIT")"
        echo "MAIN_REPO_LAST_AUTHOR=$(printf '%q' "$MAIN_REPO_LAST_AUTHOR")"
        echo "MAIN_REPO_LAST_DATE=$(printf '%q' "$MAIN_REPO_LAST_DATE")"
        echo "MAIN_REPO_LAST_SUBJECT=$(printf '%q' "$MAIN_REPO_LAST_SUBJECT")"
    } > "$SUMMARY_FILE"

    {
        echo "=========================================="
        echo "Build result : $BUILD_RESULT"
        echo "Current stage: $CURRENT_STAGE"
        echo "Build started: $build_started_at"
        echo "Build ended  : $build_ended_at"
        echo "Duration     : $BUILD_DURATION_FMT"
        echo "Log path     : $BUILD_LOG"
        echo "Verbose log  : $VERBOSE_LOG"
        echo "Hash log     : $HASH_LOG"
        echo "Failure rpt  : $FAILURE_REPORT"
        if [ -n "$FAIL_REASON" ]; then
            echo "Fail reason  : $FAIL_REASON"
        fi
        if [ -n "$FAILURE_ANALYSIS" ]; then
            echo "Failure analysis: $FAILURE_ANALYSIS"
        fi
    } | tee "$STATUS_FILE"

    ln -sfn "$RUN_DIR" "$LATEST_LINK"
    cp "$STATUS_FILE" "$LATEST_STATUS_FILE"
    cp "$SUMMARY_FILE" "$LATEST_SUMMARY_FILE"
    update_daily_status_file
    send_daily_status_email

    echo "[INFO] Latest run link : $LATEST_LINK"
    echo "[INFO] Latest status   : $LATEST_STATUS_FILE"
    echo "[INFO] Daily status    : $DAILY_STATUS_FILE"
}

trap 'rc=$?; trap - EXIT; finalize "$rc"; exit "$rc"' EXIT

require_command() {
    local cmd=$1
    if ! command -v "$cmd" >/dev/null 2>&1; then
        FAIL_REASON="Required command not found: $cmd"
        echo "[ERROR] $FAIL_REASON"
        exit 1
    fi
}

run_build_expect() {
    local expect_script="$WORK_DIR/zephyros_build_autobuild.exp"

    cat > "$expect_script" <<'EXP'
#!/usr/bin/expect -f
set timeout -1
log_user 1

set repo_dir [lindex $argv 0]
set pkgver [lindex $argv 1]
set config_select [lindex $argv 2]
set verbose_log [lindex $argv 3]

spawn bash

expect -re {[$#] $}
send "cd -- \"$repo_dir\"\r"

expect -re {[$#] $}
send "source ./build_config.sh $pkgver\r"

set timeout 120
expect {
    -re {Select \[[0-9-]+\]>>} {}
    timeout {
        send_user "\n===== ZEPHYROS CONFIG PROMPT NOT FOUND =====\n"
        exit 1
    }
}
send "$config_select\r"
set timeout -1

expect -re {[$#] $}
send "set -o pipefail; ninja 2>&1 | tee -a \"$verbose_log\"; printf '\\n__BUILD_RC__:%s\\n' \$?\r"

expect {
    -re {__BUILD_RC__:0} {
        send_user "\n===== ZEPHYROS BUILD SUCCESS =====\n"
        exit 0
    }
    -re {__BUILD_RC__:[1-9][0-9]*} {
        send_user "\n===== ZEPHYROS BUILD FAIL =====\n"
        exit 1
    }
    timeout {
        send_user "\n===== ZEPHYROS BUILD TIMEOUT =====\n"
        exit 1
    }
}
EXP

    chmod +x "$expect_script"
    "$expect_script" "$REPO_DIR" "$PKG_VERSION" "$ZEPHYROS_CONFIG_SELECT" "$VERBOSE_LOG"
}

echo "[INFO] Zephyros autobuild started"
echo "[INFO] Run directory : $RUN_DIR"
echo "[INFO] Config file   : $CONFIG_FILE"
echo "[INFO] Model lineup  : $MODEL_LINEUP"
echo "[INFO] Package ver   : $PKG_VERSION"
echo "[INFO] Repo dir      : $REPO_DIR"
echo "[INFO] Config select : $ZEPHYROS_CONFIG_SELECT"
echo "[INFO] Config name   : $ZEPHYROS_CONFIG_NAME"
echo "[INFO] Failure rpt   : $FAILURE_REPORT"
echo

: > "$HASH_LOG"

require_command git
require_command expect

CURRENT_STAGE="clone_zephyros"
echo "[Zephyros clone]"
echo "------------------------------------------"
rm -rf "$REPO_DIR"
git clone "$ZEPHYROS_REPO_URL" "$REPO_DIR"
ZEPHYROS_COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD)"
MAIN_REPO_COMMIT="$ZEPHYROS_COMMIT"
echo "ZEPHYROS|$ZEPHYROS_COMMIT|$REPO_DIR|$ZEPHYROS_REPO_URL" | tee -a "$HASH_LOG"

CURRENT_STAGE="build_zephyros"
echo
echo "[Zephyros build]"
echo "------------------------------------------"
run_build_expect

echo
echo "[INFO] Zephyros autobuild completed successfully"
