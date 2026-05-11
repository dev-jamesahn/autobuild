#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORK_ROOT="${GCT_WORK_ROOT:-$HOME/gct_workspace}"
AUTOBUILD_ROOT="${AUTOBUILD_ROOT:-$WORK_ROOT/autobuild}"
AUTOBUILD_LOG_ROOT="${AUTOBUILD_LOG_ROOT:-$AUTOBUILD_ROOT/logs}"
AUTOBUILD_STATE_ROOT="${AUTOBUILD_STATE_ROOT:-$AUTOBUILD_ROOT/state}"
RUN_DATE="${RUN_DATE:-$(date +%Y%m%d)}"

START_AFTER_MINUTES="${START_AFTER_MINUTES:-5}"
NOTIFIER_START_AFTER_MINUTES="${NOTIFIER_START_AFTER_MINUTES:-$((START_AFTER_MINUTES + 10))}"
NOTIFIER_INTERVAL_MINUTES="${NOTIFIER_INTERVAL_MINUTES:-10}"
NOTIFIER_REPEAT_COUNT="${NOTIFIER_REPEAT_COUNT:-72}"
TEST_REPORT_SUBJECT_PREFIX="${TEST_REPORT_SUBJECT_PREFIX:-[Test]}"
TEST_MAIL_TO="${TEST_MAIL_TO:-jamesahn@gctsemi.com}"
SCHEDULER="${SCHEDULER:-auto}"
SCHEDULER_LOG="$AUTOBUILD_LOG_ROOT/notifier/one_time_daily_test_scheduler.log"
TEST_SENT_FLAG_FILE="$AUTOBUILD_STATE_ROOT/.one_time_daily_autobuild_mail_sent_${RUN_DATE}.flag"
TEST_UPLOAD_FLAG_FILE="$AUTOBUILD_STATE_ROOT/.one_time_daily_autobuild_logs_uploaded_${RUN_DATE}.flag"

OPENWRT_SCRIPT_PATH="$SCRIPT_DIR/openwrt_autobuild.sh"
ZEPHYROS_SCRIPT_PATH="$SCRIPT_DIR/zephyros_autobuild.sh"
OS_SCRIPT_PATH="$SCRIPT_DIR/os_autobuild.sh"
NOTIFIER_SCRIPT_PATH="$SCRIPT_DIR/send_daily_autobuild_report.sh"

V100_CONFIG="$HOME/.config/openwrt_v1.00_autobuild.env"
MASTER_CONFIG="$HOME/.config/openwrt_master_autobuild.env"
GDM7275X_LINUXOS_CONFIG="$HOME/.config/gdm7275x_linuxos_master_autobuild.env"
ZEPHYROS_CONFIG="$HOME/.config/zephyros_autobuild.env"
GDM7243A_UTKERNEL_CONFIG="$HOME/.config/gdm7243a_utkernel_autobuild.env"
GDM7243ST_UTKERNEL_CONFIG="$HOME/.config/gdm7243st_utkernel_autobuild.env"
GDM7243I_ZEPHYR_CONFIG="$HOME/.config/gdm7243i_zephyr_v2.3_autobuild.env"

V100_CRON_LOG="$AUTOBUILD_LOG_ROOT/openwrt/v1.00/cron_runner.log"
MASTER_CRON_LOG="$AUTOBUILD_LOG_ROOT/openwrt/master/cron_runner.log"
GDM7275X_LINUXOS_CRON_LOG="$AUTOBUILD_LOG_ROOT/linuxos/gdm7275x/cron_runner.log"
ZEPHYROS_CRON_LOG="$AUTOBUILD_LOG_ROOT/zephyros/cron_runner.log"
GDM7243A_UTKERNEL_CRON_LOG="$AUTOBUILD_LOG_ROOT/uTKernel/gdm7243a/cron_runner.log"
GDM7243ST_UTKERNEL_CRON_LOG="$AUTOBUILD_LOG_ROOT/uTKernel/gdm7243st/cron_runner.log"
GDM7243I_ZEPHYR_CRON_LOG="$AUTOBUILD_LOG_ROOT/zephyr_v2_3/gdm7243i/cron_runner.log"
NOTIFIER_CRON_LOG="$AUTOBUILD_LOG_ROOT/notifier/daily_autobuild_mail_notifier.log"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run]

Schedules a one-time full Daily autobuild test with the same build order,
1-minute stagger, notifier, Samba upload, and report mail flow used by cron.

Environment overrides:
  START_AFTER_MINUTES             First build start offset. Default: 5
  NOTIFIER_START_AFTER_MINUTES    First notifier offset. Default: START_AFTER_MINUTES + 10
  NOTIFIER_INTERVAL_MINUTES       Notifier retry interval. Default: 10
  NOTIFIER_REPEAT_COUNT           Notifier retry count. Default: 72
  TEST_REPORT_SUBJECT_PREFIX      Report subject prefix. Default: [Test]
  TEST_MAIL_TO                    One-time test recipient. Default: jamesahn@gctsemi.com
  SCHEDULER                       auto, at, or nohup. Default: auto
EOF
}

DRY_RUN=0
case "${1:-}" in
    "")
        ;;
    --dry-run)
        DRY_RUN=1
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

require_file() {
    local path=$1
    if [ ! -f "$path" ]; then
        echo "Missing required file: $path" >&2
        exit 1
    fi
}

require_executable() {
    local path=$1
    if [ ! -x "$path" ]; then
        echo "Script not executable: $path" >&2
        exit 1
    fi
}

require_executable "$OPENWRT_SCRIPT_PATH"
require_executable "$ZEPHYROS_SCRIPT_PATH"
require_executable "$OS_SCRIPT_PATH"
require_executable "$NOTIFIER_SCRIPT_PATH"

require_file "$V100_CONFIG"
require_file "$MASTER_CONFIG"
require_file "$GDM7275X_LINUXOS_CONFIG"
require_file "$ZEPHYROS_CONFIG"
require_file "$GDM7243A_UTKERNEL_CONFIG"
require_file "$GDM7243ST_UTKERNEL_CONFIG"
require_file "$GDM7243I_ZEPHYR_CONFIG"

if [ "$SCHEDULER" = "auto" ]; then
    if command -v at >/dev/null 2>&1; then
        SCHEDULER="at"
    else
        SCHEDULER="nohup"
    fi
fi

case "$SCHEDULER" in
    at)
        if ! command -v at >/dev/null 2>&1; then
            echo "Required command not found for SCHEDULER=at: at" >&2
            exit 1
        fi
        ;;
    nohup)
        ;;
    *)
        echo "Invalid SCHEDULER=$SCHEDULER. Use auto, at, or nohup." >&2
        exit 2
        ;;
esac

if [ "$SCHEDULER" = "nohup" ]; then
    echo "[INFO] Using nohup scheduler because at is unavailable or not selected."
fi

mkdir -p \
    "$(dirname "$V100_CRON_LOG")" \
    "$(dirname "$MASTER_CRON_LOG")" \
    "$(dirname "$GDM7275X_LINUXOS_CRON_LOG")" \
    "$(dirname "$ZEPHYROS_CRON_LOG")" \
    "$(dirname "$GDM7243A_UTKERNEL_CRON_LOG")" \
    "$(dirname "$GDM7243ST_UTKERNEL_CRON_LOG")" \
    "$(dirname "$GDM7243I_ZEPHYR_CRON_LOG")" \
    "$(dirname "$NOTIFIER_CRON_LOG")" \
    "$(dirname "$SCHEDULER_LOG")" \
    "$AUTOBUILD_STATE_ROOT"

schedule_at() {
    local offset_minutes=$1
    local label=$2
    local command=$3

    echo "[SCHEDULE] +${offset_minutes} min: $label"
    echo "           $command"

    if [ "$DRY_RUN" = "1" ]; then
        return 0
    fi

    if [ "$SCHEDULER" = "at" ]; then
        printf '%s\n' "$command" | at "now + ${offset_minutes} minutes"
    else
        nohup /bin/bash -c 'sleep "$1"; shift; exec "$@"' \
            _ "${offset_minutes}m" /bin/bash -lc "$command" >> "$SCHEDULER_LOG" 2>&1 &
        echo "[INFO] nohup scheduler pid=$! label=$label offset=${offset_minutes}m" >> "$SCHEDULER_LOG"
    fi
}

schedule_at "$START_AFTER_MINUTES" \
    "GDM7275X OpenWrt v1.00" \
    "CONFIG_FILE=$V100_CONFIG /bin/bash -lc '$OPENWRT_SCRIPT_PATH >> \"$V100_CRON_LOG\" 2>&1'"

schedule_at "$((START_AFTER_MINUTES + 1))" \
    "GDM7275X OpenWrt master" \
    "CONFIG_FILE=$MASTER_CONFIG /bin/bash -lc '$OPENWRT_SCRIPT_PATH >> \"$MASTER_CRON_LOG\" 2>&1'"

schedule_at "$((START_AFTER_MINUTES + 2))" \
    "GDM7275X Linuxos master" \
    "CONFIG_FILE=$GDM7275X_LINUXOS_CONFIG /bin/bash -lc '$OS_SCRIPT_PATH >> \"$GDM7275X_LINUXOS_CRON_LOG\" 2>&1'"

schedule_at "$((START_AFTER_MINUTES + 3))" \
    "GDM7275X Zephyros" \
    "CONFIG_FILE=$ZEPHYROS_CONFIG /bin/bash -lc '$ZEPHYROS_SCRIPT_PATH >> \"$ZEPHYROS_CRON_LOG\" 2>&1'"

schedule_at "$((START_AFTER_MINUTES + 4))" \
    "GDM7243A uTKernel" \
    "CONFIG_FILE=$GDM7243A_UTKERNEL_CONFIG /bin/bash -lc '$OS_SCRIPT_PATH >> \"$GDM7243A_UTKERNEL_CRON_LOG\" 2>&1'"

schedule_at "$((START_AFTER_MINUTES + 5))" \
    "GDM7243ST uTKernel" \
    "CONFIG_FILE=$GDM7243ST_UTKERNEL_CONFIG /bin/bash -lc '$OS_SCRIPT_PATH >> \"$GDM7243ST_UTKERNEL_CRON_LOG\" 2>&1'"

schedule_at "$((START_AFTER_MINUTES + 6))" \
    "GDM7243i zephyr-v2.3" \
    "CONFIG_FILE=$GDM7243I_ZEPHYR_CONFIG /bin/bash -lc '$OS_SCRIPT_PATH >> \"$GDM7243I_ZEPHYR_CRON_LOG\" 2>&1'"

for ((idx = 0; idx < NOTIFIER_REPEAT_COUNT; idx++)); do
    offset=$((NOTIFIER_START_AFTER_MINUTES + idx * NOTIFIER_INTERVAL_MINUTES))
    schedule_at "$offset" \
        "Daily notifier attempt $((idx + 1))/$NOTIFIER_REPEAT_COUNT" \
        "RUN_DATE=$RUN_DATE MAIL_TO='$TEST_MAIL_TO' REPORT_SUBJECT_PREFIX='$TEST_REPORT_SUBJECT_PREFIX' SENT_FLAG_FILE='$TEST_SENT_FLAG_FILE' UPLOAD_FLAG_FILE='$TEST_UPLOAD_FLAG_FILE' /bin/bash -lc '$NOTIFIER_SCRIPT_PATH >> \"$NOTIFIER_CRON_LOG\" 2>&1'"
done

echo
if [ "$DRY_RUN" = "1" ]; then
    echo "Dry run complete. No jobs were scheduled."
else
    echo "One-time Daily autobuild test jobs were scheduled."
    if [ "$SCHEDULER" = "at" ]; then
        echo "Check pending jobs with: atq"
    else
        echo "Scheduler log: $SCHEDULER_LOG"
    fi
fi
