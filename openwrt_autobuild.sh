#!/bin/bash

set -euo pipefail

RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DATE="$(date +%Y%m%d)"
START_EPOCH="$(date +%s)"

BASE_DIR="$HOME"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AUTOBUILD_CONFIG_ROOT="${AUTOBUILD_CONFIG_ROOT:-$SCRIPT_DIR/config}"
CONFIG_FILE="${CONFIG_FILE:-$AUTOBUILD_CONFIG_ROOT/autobuild_common.env}"
RUN_USER="${USER:-${LOGNAME:-$(id -un)}}"

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

SMTP_HOST="${SMTP_HOST:-}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
SMTP_USE_STARTTLS="${SMTP_USE_STARTTLS:-1}"
SMTP_INSECURE_TLS="${SMTP_INSECURE_TLS:-0}"
MAIL_FROM="${MAIL_FROM:-${SMTP_USER:-}}"

OPENWRT_BRANCH="${OPENWRT_BRANCH:-v1.00}"
PKG_VERSION="${PKG_VERSION:-0.0.0}"
BRANCH_SLUG="${OPENWRT_BRANCH//[^A-Za-z0-9._-]/_}"
MODEL_LINEUP="${MODEL_LINEUP:-GDM7275X}"
OPENWRT_SOURCE_REPO_URL="${OPENWRT_SOURCE_REPO_URL:-https://release.gctsemi.com/openwrt}"
GDM_SOURCE_DISPLAY="${GDM_SOURCE_DISPLAY:-linuxos master}"
GDM_SOURCE_REPO_URL="${GDM_SOURCE_REPO_URL:-https://release.gctsemi.com/linuxos}"
GDM_SOURCE_BRANCH="${GDM_SOURCE_BRANCH:-master}"
GDM_SOURCE_CLONE_DIR="${GDM_SOURCE_CLONE_DIR:-linuxos_autobuild}"
SBL_SOURCE_DISPLAY="${SBL_SOURCE_DISPLAY:-7275X SBL}"
SBL_SOURCE_REPO_URL="${SBL_SOURCE_REPO_URL:-https://release.gctsemi.com/sbl/7275x}"
SBL_SOURCE_BRANCH="${SBL_SOURCE_BRANCH:-}"
SBL_SOURCE_CLONE_DIR="${SBL_SOURCE_CLONE_DIR:-7275X_sbl_autobuild}"
UBOOT_SOURCE_DISPLAY="${UBOOT_SOURCE_DISPLAY:-7275X U-Boot}"
UBOOT_SOURCE_REPO_URL="${UBOOT_SOURCE_REPO_URL:-https://release.gctsemi.com/u-boot/7275x}"
UBOOT_SOURCE_BRANCH="${UBOOT_SOURCE_BRANCH:-}"
UBOOT_SOURCE_CLONE_DIR="${UBOOT_SOURCE_CLONE_DIR:-7275X_uboot_autobuild}"

WORK_ROOT="${GCT_WORK_ROOT:-${WORK_ROOT:-$BASE_DIR/gct_workspace}}"
AUTOBUILD_ROOT="${AUTOBUILD_ROOT:-$WORK_ROOT/autobuild}"
AUTOBUILD_REPO_ROOT="${AUTOBUILD_REPO_ROOT:-$AUTOBUILD_ROOT/repos}"
AUTOBUILD_LOG_ROOT="${AUTOBUILD_LOG_ROOT:-$AUTOBUILD_ROOT/logs}"
AUTOBUILD_TMP_ROOT="${AUTOBUILD_TMP_ROOT:-$AUTOBUILD_ROOT/tmp}"
AUTOBUILD_STATE_ROOT="${AUTOBUILD_STATE_ROOT:-$AUTOBUILD_ROOT/state}"

WORK_DIR="${WORK_DIR:-$AUTOBUILD_TMP_ROOT/openwrt_${RUN_USER}_${BRANCH_SLUG}}"
CLONE_ROOT="${CLONE_ROOT:-$AUTOBUILD_REPO_ROOT/openwrt/deps}"
OPENWRT_DIR="${OPENWRT_DIR:-$AUTOBUILD_REPO_ROOT/openwrt/builds/${OPENWRT_BRANCH}}"
LOG_ROOT="${LOG_ROOT:-$AUTOBUILD_LOG_ROOT/openwrt/${OPENWRT_BRANCH}}"
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
ARTIFACT_ROOT="${ARTIFACT_ROOT:-$OPENWRT_DIR}"
ARTIFACT_PATHS="${ARTIFACT_PATHS:-bin/targets/gdm7275x/generic/owrt*.*}"
mkdir -p "$WORK_DIR" "$CLONE_ROOT" "$RUN_DIR" "$AUTOBUILD_STATE_ROOT"
touch "$BUILD_LOG"
exec > >(tee -a "$BUILD_LOG") 2>&1

CURRENT_STAGE="init"
BUILD_RESULT="FAIL"
FAIL_REASON=""
FAILURE_ANALYSIS=""
TARGET_NAME="${MODEL_LINEUP} OpenWrt ${OPENWRT_BRANCH}"
MAIN_REPO_URL="$OPENWRT_SOURCE_REPO_URL"
MAIN_REPO_DIR="$OPENWRT_DIR"
MAIN_REPO_COMMIT=""
MAIN_REPO_LAST_COMMIT=""
MAIN_REPO_LAST_AUTHOR=""
MAIN_REPO_LAST_DATE=""
MAIN_REPO_LAST_SUBJECT=""
MANIFEST_GDM_COMMIT=""
MANIFEST_SBL_COMMIT=""
MANIFEST_UBOOT_COMMIT=""

REPOS=(
    "GDM|$GDM_SOURCE_DISPLAY|$GDM_SOURCE_CLONE_DIR|$GDM_SOURCE_REPO_URL|$GDM_SOURCE_BRANCH"
    "SBL|$SBL_SOURCE_DISPLAY|$SBL_SOURCE_CLONE_DIR|$SBL_SOURCE_REPO_URL|$SBL_SOURCE_BRANCH"
    "UBOOT|$UBOOT_SOURCE_DISPLAY|$UBOOT_SOURCE_CLONE_DIR|$UBOOT_SOURCE_REPO_URL|$UBOOT_SOURCE_BRANCH"
)

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

    if [ "$MAIL_NOTIFY_SEND_ON" != "all" ] && [ "$MAIL_NOTIFY_SEND_ON" != "openwrt" ]; then
        echo "[INFO] Email notification skipped on openwrt_autobuild.sh: MAIL_NOTIFY_SEND_ON=$MAIL_NOTIFY_SEND_ON"
        return
    fi

    if [ -z "$SMTP_HOST" ] || [ -z "$SMTP_PORT" ] || [ -z "$MAIL_FROM" ]; then
        echo "[WARN] Email notification skipped: SMTP_HOST, SMTP_PORT, or MAIL_FROM is not set"
        return
    fi

    if [ ! -f "$DAILY_STATUS_FILE" ]; then
        echo "[WARN] Email notification skipped: daily status file not found: $DAILY_STATUS_FILE"
        return
    fi

    subject="GCT-CS Daily Build Report - $(date '+%m/%d/%Y')"

    if ! SMTP_HOST="$SMTP_HOST" \
        SMTP_PORT="$SMTP_PORT" \
        SMTP_USER="$SMTP_USER" \
        SMTP_PASSWORD="$SMTP_PASSWORD" \
        SMTP_USE_STARTTLS="$SMTP_USE_STARTTLS" \
        SMTP_INSECURE_TLS="$SMTP_INSECURE_TLS" \
        MAIL_FROM="$MAIL_FROM" \
        MAIL_TO="$MAIL_TO" \
        MAIL_SUBJECT="$subject" \
        DAILY_STATUS_FILE="$DAILY_STATUS_FILE" \
        python3 - <<'PY'
import os
import smtplib
import ssl
import sys
from html import escape
from email.message import EmailMessage

smtp_host = os.environ["SMTP_HOST"]
smtp_port = int(os.environ.get("SMTP_PORT", "587"))
smtp_user = os.environ.get("SMTP_USER", "").strip()
smtp_password = os.environ.get("SMTP_PASSWORD", "")
smtp_use_starttls = os.environ.get("SMTP_USE_STARTTLS", "1") == "1"
smtp_insecure_tls = os.environ.get("SMTP_INSECURE_TLS", "0") == "1"
mail_from = os.environ["MAIL_FROM"].strip()
subject = os.environ["MAIL_SUBJECT"]
daily_status_file = os.environ["DAILY_STATUS_FILE"]
recipients = [addr.strip() for addr in os.environ["MAIL_TO"].split(",") if addr.strip()]
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
        f"<div style='border:1px solid #d0d5dd;border-radius:12px;padding:16px;background:#ffffff;margin-bottom:12px;'>",
        f"<div style='display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:10px;'>",
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
        <div style="font-size:28px;font-weight:800;margin-top:6px;">Daily build report</div>
        <div style="font-size:14px;opacity:0.9;margin-top:8px;">Generated from the CS-buildserver</div>
      </div>
      <div style="background:#ffffff;border:1px solid #eaecf0;border-radius:16px;padding:20px 20px 8px;margin-bottom:16px;">
        <div style="font-size:18px;font-weight:700;margin-bottom:14px;">{escape(subject.replace('GCT-CS Daily Build Report - ', ''))} - Build Test Summary</div>
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
msg["From"] = f"{from_name} <{mail_from}>" if from_name else mail_from
msg["To"] = ", ".join(recipients)
if reply_to:
    msg["Reply-To"] = reply_to
msg.set_content(body)
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

append_git_commit_details() {
    local repo_dir=$1
    local count=$2
    shift 2
    local commit

    while IFS= read -r commit; do
        [ -n "$commit" ] || continue
        {
            echo "commit $commit"
            git -C "$repo_dir" show --stat --summary --date=iso-strict --format='Author: %an <%ae>%nDate:   %ad%nSubject: %s' --no-patch "$commit" || true
            echo
            git -C "$repo_dir" show --stat --summary --date=iso-strict --format='' "$commit" | sed '/^$/d' || true
            echo
        } >> "$FAILURE_REPORT"
    done < <(git -C "$repo_dir" log --format='%H' -n "$count" -- "$@" 2>/dev/null || true)
}

extract_failure_analysis() {
    local source_log=$1
    local final_make_error=""
    local root_error=""
    local package_error=""
    local source_location=""
    local source_path=""
    local source_line=""
    local source_rel=""
    local repo_hint=""
    local message=""

    if [ ! -f "$source_log" ]; then
        FAILURE_ANALYSIS=""
        return
    fi

    final_make_error="$(grep -aEn 'make(\[[0-9]+\])?: \*\*\* \[[^]]+\] Error [0-9]+' "$source_log" 2>/dev/null \
        | grep -aF "$OPENWRT_DIR" \
        | grep -avE 'Error [0-9]+ \(ignored\)|include/toplevel\.mk|target/Makefile|package/Makefile|tools/Makefile' \
        | tail -n 1 | tr -d '\r' || true)"
    if [ -z "$final_make_error" ]; then
        final_make_error="$(grep -aEn 'make(\[[0-9]+\])?: \*\*\* \[[^]]+\] Error [0-9]+' "$source_log" 2>/dev/null \
        | grep -avE 'Error [0-9]+ \(ignored\)|include/toplevel\.mk|target/Makefile|package/Makefile|tools/Makefile' \
        | tail -n 1 | tr -d '\r' || true)"
    fi
    if [ -z "$final_make_error" ]; then
        final_make_error="$(grep -aEn 'make(\[[0-9]+\])?: \*\*\* \[[^]]+\] Error [0-9]+' "$source_log" 2>/dev/null \
            | grep -avE 'Error [0-9]+ \(ignored\)' \
            | tail -n 1 | tr -d '\r' || true)"
    fi
    root_error="$(grep -aEn 'fatal error:|[[:space:]]error:|undefined reference|cannot find|No such file or directory|[[:space:]]\*\*\* .*Stop\.|[[:space:]]\*\*\* .*Error' "$source_log" 2>/dev/null \
        | grep -avE 'ERROR: package/|fatal: not a git repository|/bin/find:|/find:|grep: .*binary file matches|error: .#.+comment at start of rule is unportable' \
        | tail -n 1 | tr -d '\r' || true)"
    package_error="$(grep -aE 'ERROR: package/.*failed to build' "$source_log" 2>/dev/null | tail -n 1 | tr -d '\r' | sed -E 's/\x1B\[[0-9;]*[mK]//g; s/^[[:space:]]*//' || true)"

    if [ -z "$final_make_error" ] && [ -z "$root_error" ] && [ -z "$package_error" ]; then
        FAILURE_ANALYSIS=""
        return
    fi

    if [ -n "$final_make_error" ]; then
        message="$(printf '%s\n' "$final_make_error" | sed -E 's#^[0-9]+:[[:space:]]*##')"
        source_path="$(printf '%s\n' "$final_make_error" | sed -nE 's#^[0-9]+:.*\[[^]]*: ([^]]+)\] Error [0-9]+.*#\1#p')"
        if [ -n "$source_path" ]; then
            if [ -f "$source_path" ]; then
                source_path="$(realpath "$source_path" 2>/dev/null || printf '%s' "$source_path")"
            fi
            source_location="$source_path"
            source_rel="${source_path#$OPENWRT_DIR/}"
            case "$source_rel" in
                build_dir/*/component/*|gdm/component/*)
                    repo_hint="linuxos component"
                    ;;
                build_dir/*/image-*|target/*)
                    repo_hint="OpenWrt target"
                    ;;
                package/*)
                    repo_hint="OpenWrt package"
                    ;;
            esac
        fi
    fi

    if [ -n "$root_error" ]; then
        if [ -z "$message" ]; then
            message="$(printf '%s\n' "$root_error" | sed -E 's#^[0-9]+:([^:]+:)?([0-9]+:)?([0-9]+:)?[[:space:]]*##')"
        fi

        if [ -z "$source_location" ]; then
            source_path="$(printf '%s\n' "$root_error" | sed -E 's#^[0-9]+:([^:]+):[0-9]+:.*#\1#')"
            source_line="$(printf '%s\n' "$root_error" | sed -E 's#^[0-9]+:[^:]+:([0-9]+):.*#\1#')"

            if [ -n "$source_path" ] && [ "$source_path" != "$root_error" ]; then
                if [ -f "$source_path" ]; then
                    source_path="$(realpath "$source_path" 2>/dev/null || printf '%s' "$source_path")"
                fi
                source_location="$source_path"
                if [ -n "$source_line" ] && [ "$source_line" != "$root_error" ]; then
                    source_location="$source_location:$source_line"
                fi
                source_rel="${source_path#$OPENWRT_DIR/}"
                case "$source_rel" in
                    build_dir/*/component/*|gdm/component/*)
                        repo_hint="linuxos component"
                        ;;
                    package/*)
                        repo_hint="OpenWrt package"
                        ;;
                    target/*)
                        repo_hint="OpenWrt target"
                        ;;
                esac
            fi
        fi
    fi

    if [ -n "$package_error" ] && [ -z "$final_make_error" ]; then
        FAILURE_ANALYSIS="$package_error"
    fi
    if [ -n "$message" ]; then
        if [ -n "$FAILURE_ANALYSIS" ]; then
            FAILURE_ANALYSIS="$FAILURE_ANALYSIS; $message"
        else
            FAILURE_ANALYSIS="$message"
        fi
    fi
    if [ -n "$source_location" ]; then
        FAILURE_ANALYSIS="$FAILURE_ANALYSIS at $source_location"
    fi
    if [ -n "$repo_hint" ]; then
        FAILURE_ANALYSIS="$FAILURE_ANALYSIS (likely source: $repo_hint)"
    fi
}

analyze_failure() {
    local source_log
    local first_fatal
    local source_path
    local resolved_source_path
    local rel_path
    local header_path

    source_log="$VERBOSE_LOG"
    if [ ! -f "$source_log" ] || [ ! -s "$source_log" ]; then
        source_log="$BUILD_LOG"
    fi

    {
        echo "=========================================="
        echo "OpenWrt Build Failure Report"
        echo "=========================================="
        echo "Repo path      : $OPENWRT_DIR"
        echo "Build log      : $BUILD_LOG"
        echo "Verbose log    : $VERBOSE_LOG"
        echo "Hash log       : $HASH_LOG"
        echo "Source log     : $source_log"
        echo "Generated at   : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Current stage  : $CURRENT_STAGE"
        echo "Fail reason    : $FAIL_REASON"
        extract_failure_analysis "$source_log"
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
        grep -aEn 'fatal error:|error:|No such file or directory|cannot find|undefined reference|[[:space:]]\*\*\* .*Stop\.|[[:space:]]\*\*\* .*Error|make(\[[0-9]+\])?: \*\*\*' "$source_log" | tail -n 40 || true
        echo
    } > "$FAILURE_REPORT"

    first_fatal="$(grep -a -m 1 'fatal error:' "$source_log" || true)"
    if [ -n "$first_fatal" ]; then
        source_path="$(printf '%s\n' "$first_fatal" | sed -E 's#^([^:]+):[0-9]+:.*#\1#')"
        header_path="$(printf '%s\n' "$first_fatal" | sed -E 's#^.*fatal error: ([^:]+):.*#\1#')"
        resolved_source_path=""

        {
            echo "[First fatal error]"
            echo "$first_fatal"
            echo
        } >> "$FAILURE_REPORT"

        if [ -n "$source_path" ]; then
            if [ -f "$source_path" ]; then
                resolved_source_path="$(realpath "$source_path" 2>/dev/null || printf '%s' "$source_path")"
            elif [ -f "$OPENWRT_DIR/$source_path" ]; then
                resolved_source_path="$OPENWRT_DIR/$source_path"
            fi
        fi

        if [ -n "$resolved_source_path" ] && [ -f "$resolved_source_path" ]; then
            rel_path="${resolved_source_path#$OPENWRT_DIR/}"
            {
                echo "[Resolved source path]"
                echo "$resolved_source_path"
                echo
                echo "[Git log: $rel_path]"
                git -C "$OPENWRT_DIR" log --oneline -n 15 -- "$rel_path" || true
                echo
                echo "[Recent commit details: $rel_path]"
            } >> "$FAILURE_REPORT"
            append_git_commit_details "$OPENWRT_DIR" 5 "$rel_path"
            {
                echo "[Git blame: $rel_path]"
                git -C "$OPENWRT_DIR" blame -L 1,80 -- "$rel_path" || true
                echo
            } >> "$FAILURE_REPORT"
        else
            {
                echo "[Resolved source path]"
                echo "Unable to resolve source path from fatal line: $source_path"
                echo
            } >> "$FAILURE_REPORT"
        fi

        if [ -n "$header_path" ]; then
            {
                echo "[Missing header search: $header_path]"
                find "$OPENWRT_DIR" -path "$OPENWRT_DIR/.git" -prune -o -type f \( -path "*/$header_path" -o -name "$(basename "$header_path")" \) -print 2>/dev/null || true
                echo
                echo "[Header references]"
                grep -Rsn --include='*.c' --include='*.h' --include='*.mk' --include='Makefile*' "$header_path" "$OPENWRT_DIR" 2>/dev/null | head -n 40 || true
                echo
            } >> "$FAILURE_REPORT"
        fi
    fi

    {
        echo "[Recent commits touching packages/target/toolchain/feed paths]"
        git -C "$OPENWRT_DIR" log --oneline -n 20 -- package target toolchain feeds 2>/dev/null || true
        echo
        echo "[Detailed recent commits touching packages/target/toolchain/feed paths]"
    } >> "$FAILURE_REPORT"
    append_git_commit_details "$OPENWRT_DIR" 5 package target toolchain feeds
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
        echo "OPENWRT_BRANCH=$OPENWRT_BRANCH"
        echo "MODEL_LINEUP=$(printf '%q' "$MODEL_LINEUP")"
        echo "OPENWRT_SOURCE_REPO_URL=$(printf '%q' "$OPENWRT_SOURCE_REPO_URL")"
        echo "GDM_SOURCE_DISPLAY=$(printf '%q' "$GDM_SOURCE_DISPLAY")"
        echo "GDM_SOURCE_REPO_URL=$(printf '%q' "$GDM_SOURCE_REPO_URL")"
        echo "GDM_SOURCE_BRANCH=$(printf '%q' "$GDM_SOURCE_BRANCH")"
        echo "GDM_SOURCE_CLONE_DIR=$(printf '%q' "$GDM_SOURCE_CLONE_DIR")"
        echo "SBL_SOURCE_DISPLAY=$(printf '%q' "$SBL_SOURCE_DISPLAY")"
        echo "SBL_SOURCE_REPO_URL=$(printf '%q' "$SBL_SOURCE_REPO_URL")"
        echo "SBL_SOURCE_BRANCH=$(printf '%q' "$SBL_SOURCE_BRANCH")"
        echo "SBL_SOURCE_CLONE_DIR=$(printf '%q' "$SBL_SOURCE_CLONE_DIR")"
        echo "UBOOT_SOURCE_DISPLAY=$(printf '%q' "$UBOOT_SOURCE_DISPLAY")"
        echo "UBOOT_SOURCE_REPO_URL=$(printf '%q' "$UBOOT_SOURCE_REPO_URL")"
        echo "UBOOT_SOURCE_BRANCH=$(printf '%q' "$UBOOT_SOURCE_BRANCH")"
        echo "UBOOT_SOURCE_CLONE_DIR=$(printf '%q' "$UBOOT_SOURCE_CLONE_DIR")"
        echo "PKG_VERSION=$PKG_VERSION"
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
        echo "ARTIFACT_ROOT=$(printf '%q' "$ARTIFACT_ROOT")"
        echo "ARTIFACT_PATHS=$(printf '%q' "$ARTIFACT_PATHS")"
        echo "FAIL_REASON=$(printf '%q' "$FAIL_REASON")"
        echo "FAILURE_ANALYSIS=$(printf '%q' "$FAILURE_ANALYSIS")"
        echo "MAIN_REPO_URL=$(printf '%q' "$MAIN_REPO_URL")"
        echo "MAIN_REPO_DIR=$(printf '%q' "$MAIN_REPO_DIR")"
        echo "MAIN_REPO_COMMIT=$(printf '%q' "$MAIN_REPO_COMMIT")"
        echo "MAIN_REPO_LAST_COMMIT=$(printf '%q' "$MAIN_REPO_LAST_COMMIT")"
        echo "MAIN_REPO_LAST_AUTHOR=$(printf '%q' "$MAIN_REPO_LAST_AUTHOR")"
        echo "MAIN_REPO_LAST_DATE=$(printf '%q' "$MAIN_REPO_LAST_DATE")"
        echo "MAIN_REPO_LAST_SUBJECT=$(printf '%q' "$MAIN_REPO_LAST_SUBJECT")"
        echo "MANIFEST_GDM_COMMIT=$(printf '%q' "$MANIFEST_GDM_COMMIT")"
        echo "MANIFEST_SBL_COMMIT=$(printf '%q' "$MANIFEST_SBL_COMMIT")"
        echo "MANIFEST_UBOOT_COMMIT=$(printf '%q' "$MANIFEST_UBOOT_COMMIT")"
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
        if [ -n "$ARTIFACT_PATHS" ]; then
            echo "Artifact root: $ARTIFACT_ROOT"
            echo "Artifacts    : $ARTIFACT_PATHS"
        fi
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

ensure_repo_ready() {
    local key=$1
    local display=$2
    local dir_name=$3
    local url=$4
    local check_branch=$5
    local repo_dir="$CLONE_ROOT/$dir_name"
    local branch hash current_url

    CURRENT_STAGE="sync_${key,,}"
    echo
    echo "[$display]"
    echo "------------------------------------------"

    if [ ! -d "$repo_dir/.git" ]; then
        echo "[INFO] Clone missing repo into $repo_dir"
        if [ -n "$check_branch" ]; then
            git clone -b "$check_branch" --single-branch "$url" "$repo_dir"
        else
            git clone "$url" "$repo_dir"
        fi
    else
        current_url="$(git -C "$repo_dir" config --get remote.origin.url 2>/dev/null || true)"
        if [ "$current_url" != "$url" ]; then
            echo "[INFO] Update origin URL: $repo_dir"
            echo "[INFO]   old: ${current_url:-none}"
            echo "[INFO]   new: $url"
            git -C "$repo_dir" remote set-url origin "$url"
        fi
    fi

    if [ -n "$check_branch" ]; then
        git -C "$repo_dir" fetch origin "+refs/heads/$check_branch:refs/remotes/origin/$check_branch"
        branch="origin/$check_branch"
        hash="$(git -C "$repo_dir" rev-parse "$branch")"
    else
        branch="$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD)"
        git -C "$repo_dir" pull --ff-only origin "$branch"
        hash="$(git -C "$repo_dir" rev-parse HEAD)"
    fi

    echo "$key|$branch|$hash|$repo_dir|$url" | tee -a "$HASH_LOG"
    eval "${key}_REPO=\"$url\""
    eval "${key}_COMMIT=\"$hash\""
}

run_build_expect() {
    local expect_script="$WORK_DIR/openwrt_dirty_build_${BRANCH_SLUG}_autobuild.exp"

    cat > "$expect_script" <<'EXP'
#!/usr/bin/expect -f
set timeout -1
log_user 1

set build_dir [lindex $argv 0]
set verbose_log [lindex $argv 1]

spawn bash

expect -re {[$#] $}
send "cd -- \"$build_dir\"\r"

expect -re {[$#] $}
send "cd -- \"$build_dir\" && bash ./ext-toolchain.sh; printf '\\n__EXT_RC__:%s\\n' \$?\r"

set timeout 60
expect {
    -re {Select target system:} {}
    -re {default.*1} {}
    -re {Press[[:space:]]+Enter} {}
    -re {\[1\]} {}
    timeout {
        send_user "\n===== EXT-TOOLCHAIN PROMPT NOT FOUND =====\n"
        exit 1
    }
}
after 5000
send "\r"
set timeout -1

expect {
    -re {__EXT_RC__:0} {
        send_user "\n===== EXT-TOOLCHAIN SUCCESS =====\n"
    }
    -re {__EXT_RC__:[1-9][0-9]*} {
        send_user "\n===== EXT-TOOLCHAIN FAIL =====\n"
        exit 1
    }
    timeout {
        send_user "\n===== EXT-TOOLCHAIN TIMEOUT =====\n"
        exit 1
    }
}

expect -re {[$#] $}
send "cd -- \"$build_dir\" && set -o pipefail; make; printf '\\n__BUILD_RC__:%s\\n' \$?\r"

expect {
    -re {__BUILD_RC__:0} {
        send_user "\n===== OPENWRT DIRTY BUILD SUCCESS =====\n"
        exit 0
    }
    -re {__BUILD_RC__:[1-9][0-9]*} {
        send_user "\n===== OPENWRT DIRTY BUILD FAIL =====\n"
    }
    timeout {
        send_user "\n===== OPENWRT DIRTY BUILD TIMEOUT =====\n"
        exit 1
    }
}

expect -re {[$#] $}
send "cd -- \"$build_dir\" && set -o pipefail; echo '===== RETRY WITH V=sc ====='; make V=sc 2>&1 | tee -a \"$verbose_log\"; printf '\\n__BUILD_RC__:%s\\n' \$?\r"

expect {
    -re {__BUILD_RC__:0} {
        send_user "\n===== OPENWRT DIRTY BUILD SUCCESS (V=sc) =====\n"
        exit 0
    }
    -re {__BUILD_RC__:[1-9][0-9]*} {
        send_user "\n===== OPENWRT DIRTY BUILD FAIL (V=sc) =====\n"
        exit 1
    }
    timeout {
        send_user "\n===== OPENWRT DIRTY BUILD TIMEOUT (V=sc) =====\n"
        exit 1
    }
}
EXP

    chmod +x "$expect_script"
    "$expect_script" "$OPENWRT_DIR" "$VERBOSE_LOG"
}

echo "[INFO] OpenWrt ${OPENWRT_BRANCH} autobuild started"
echo "[INFO] Workspace root: $WORK_ROOT"
echo "[INFO] Autobuild root: $AUTOBUILD_ROOT"
echo "[INFO] Run directory : $RUN_DIR"
echo "[INFO] Config file    : $CONFIG_FILE"
echo "[INFO] Model lineup   : $MODEL_LINEUP"
echo "[INFO] Work directory: $WORK_DIR"
echo "[INFO] Package ver   : $PKG_VERSION"
echo "[INFO] OpenWrt dir   : $OPENWRT_DIR"
echo "[INFO] OpenWrt repo  : $OPENWRT_SOURCE_REPO_URL"
echo "[INFO] GDM repo      : $GDM_SOURCE_REPO_URL (${GDM_SOURCE_BRANCH:-current})"
echo "[INFO] SBL repo      : $SBL_SOURCE_REPO_URL (${SBL_SOURCE_BRANCH:-current})"
echo "[INFO] U-Boot repo   : $UBOOT_SOURCE_REPO_URL (${UBOOT_SOURCE_BRANCH:-current})"
echo "[INFO] Clone root    : $CLONE_ROOT"
echo "[INFO] Failure rpt  : $FAILURE_REPORT"
echo

: > "$HASH_LOG"

require_command git
require_command python3
require_command expect

for entry in "${REPOS[@]}"; do
    IFS='|' read -r key display dir_name url check_branch <<< "$entry"
    ensure_repo_ready "$key" "$display" "$dir_name" "$url" "$check_branch"
done

MANIFEST_GDM_COMMIT="${GDM_COMMIT:-}"
MANIFEST_SBL_COMMIT="${SBL_COMMIT:-}"
MANIFEST_UBOOT_COMMIT="${UBOOT_COMMIT:-}"

CURRENT_STAGE="clone_openwrt"
echo
echo "[OpenWrt clone]"
echo "------------------------------------------"
rm -rf "$OPENWRT_DIR"
git clone -b "$OPENWRT_BRANCH" --single-branch "$OPENWRT_SOURCE_REPO_URL" "$OPENWRT_DIR"
OPENWRT_COMMIT="$(git -C "$OPENWRT_DIR" rev-parse HEAD)"
MAIN_REPO_COMMIT="$OPENWRT_COMMIT"
echo "OPENWRT|$OPENWRT_BRANCH|$OPENWRT_COMMIT|$OPENWRT_DIR|$OPENWRT_SOURCE_REPO_URL" | tee -a "$HASH_LOG"

CURRENT_STAGE="update_manifest"
echo
echo "[Manifest update]"
echo "------------------------------------------"
MANIFEST_FILE="$OPENWRT_DIR/include/manifest.mk"
python3 - "$MANIFEST_FILE" "$PKG_VERSION" "$GDM_REPO" "$GDM_COMMIT" "$SBL_REPO" "$SBL_COMMIT" "$UBOOT_REPO" "$UBOOT_COMMIT" <<'PY'
import re
import sys
from pathlib import Path

manifest_file = Path(sys.argv[1])
text = manifest_file.read_text()

pairs = {
    r'^GCT_PKG_VERSION:=.*$': f'GCT_PKG_VERSION:={sys.argv[2]}',
    r'^GDM_REPO:=.*$': f'GDM_REPO:="{sys.argv[3]}"',
    r'^GDM_COMMIT:=.*$': f'GDM_COMMIT:="{sys.argv[4]}"',
    r'^SBL_REPO:=.*$': f'SBL_REPO:="{sys.argv[5]}"',
    r'^SBL_COMMIT:=.*$': f'SBL_COMMIT:="{sys.argv[6]}"',
    r'^UBOOT_REPO:=.*$': f'UBOOT_REPO:="{sys.argv[7]}"',
    r'^UBOOT_COMMIT:=.*$': f'UBOOT_COMMIT:="{sys.argv[8]}"',
}

for pattern, replacement in pairs.items():
    text = re.sub(pattern, replacement, text, flags=re.MULTILINE)

manifest_file.write_text(text)
PY

CURRENT_STAGE="validate_branch"
CURRENT_BRANCH="$(git -C "$OPENWRT_DIR" rev-parse --abbrev-ref HEAD)"
if [ "$CURRENT_BRANCH" != "$OPENWRT_BRANCH" ]; then
    FAIL_REASON="OpenWrt current branch is $CURRENT_BRANCH, expected $OPENWRT_BRANCH"
    echo "[ERROR] $FAIL_REASON"
    exit 1
fi

CURRENT_STAGE="build_openwrt"
echo
echo "[OpenWrt build]"
echo "------------------------------------------"
if [ ! -f "$OPENWRT_DIR/ext-toolchain.sh" ]; then
    FAIL_REASON="ext-toolchain.sh not found: $OPENWRT_DIR/ext-toolchain.sh"
    echo "[ERROR] $FAIL_REASON"
    exit 1
fi

run_build_expect

echo
echo "[INFO] OpenWrt ${OPENWRT_BRANCH} autobuild completed successfully"
