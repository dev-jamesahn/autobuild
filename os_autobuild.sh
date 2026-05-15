#!/bin/bash

set -euo pipefail

RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_DATE="$(date +%Y%m%d)"
START_EPOCH="$(date +%s)"

BASE_DIR="$HOME"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AUTOBUILD_CONFIG_ROOT="${AUTOBUILD_CONFIG_ROOT:-$SCRIPT_DIR/config}"
CONFIG_FILE="${CONFIG_FILE:-$AUTOBUILD_CONFIG_ROOT/os_autobuild.env}"
RUN_USER="${USER:-${LOGNAME:-$(id -un)}}"

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

MODEL_LINEUP="${MODEL_LINEUP:?MODEL_LINEUP is required}"
OS_PROJECT_NAME="${OS_PROJECT_NAME:?OS_PROJECT_NAME is required}"
OS_REPO_URL="${OS_REPO_URL:?OS_REPO_URL is required}"
OS_REPO_BRANCH="${OS_REPO_BRANCH:-}"
OS_PRODUCT_CONFIG="${OS_PRODUCT_CONFIG:-}"
OS_BUILD_VARIANT="${OS_BUILD_VARIANT:-}"
OS_CONFIG_CMD="${OS_CONFIG_CMD:-}"
OS_CONFIG_EXPECT_CHOICES="${OS_CONFIG_EXPECT_CHOICES:-}"
OS_BUILD_CMD="${OS_BUILD_CMD:-make}"
OS_REQUIRED_COMMANDS="${OS_REQUIRED_COMMANDS:-git}"
OS_PATH_PREPEND="${OS_PATH_PREPEND:-}"
OS_LD_LIBRARY_PATH_PREPEND="${OS_LD_LIBRARY_PATH_PREPEND:-}"
OS_TARGET_NAME="${OS_TARGET_NAME:-}"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-}"
ARTIFACT_PATHS="${ARTIFACT_PATHS:-}"

if [ -n "$OS_PATH_PREPEND" ]; then
    PATH="$OS_PATH_PREPEND:$PATH"
    export PATH
fi

if [ -n "$OS_LD_LIBRARY_PATH_PREPEND" ]; then
    LD_LIBRARY_PATH="$OS_LD_LIBRARY_PATH_PREPEND${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export LD_LIBRARY_PATH
fi

MODEL_SLUG="${MODEL_LINEUP//[^A-Za-z0-9]/_}"
MODEL_SLUG="${MODEL_SLUG,,}"
OS_PROJECT_SLUG="${OS_PROJECT_NAME//[^A-Za-z0-9]/_}"
case "$OS_PROJECT_NAME" in
    uTKernel)
        OS_PROJECT_SLUG="uTKernel"
        ;;
    *)
        OS_PROJECT_SLUG="${OS_PROJECT_SLUG,,}"
        ;;
esac

WORK_ROOT="${GCT_WORK_ROOT:-${WORK_ROOT:-$BASE_DIR/gct_workspace}}"
AUTOBUILD_ROOT="${AUTOBUILD_ROOT:-$WORK_ROOT/autobuild}"
AUTOBUILD_REPO_ROOT="${AUTOBUILD_REPO_ROOT:-$AUTOBUILD_ROOT/repos}"
AUTOBUILD_LOG_ROOT="${AUTOBUILD_LOG_ROOT:-$AUTOBUILD_ROOT/logs}"
AUTOBUILD_TMP_ROOT="${AUTOBUILD_TMP_ROOT:-$AUTOBUILD_ROOT/tmp}"
AUTOBUILD_STATE_ROOT="${AUTOBUILD_STATE_ROOT:-$AUTOBUILD_ROOT/state}"

WORK_DIR="${WORK_DIR:-$AUTOBUILD_TMP_ROOT/${OS_PROJECT_SLUG}_${RUN_USER}_${MODEL_SLUG}}"
REPO_DIR="${REPO_DIR:-$AUTOBUILD_REPO_ROOT/$OS_PROJECT_SLUG/$MODEL_SLUG}"
LOG_ROOT="${LOG_ROOT:-$AUTOBUILD_LOG_ROOT/$OS_PROJECT_SLUG/$MODEL_SLUG}"
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

if [ -z "$ARTIFACT_ROOT" ]; then
    ARTIFACT_ROOT="$REPO_DIR"
fi
if [ -z "$ARTIFACT_PATHS" ]; then
    case "$OS_PROJECT_NAME" in
        Linuxos)
            ARTIFACT_PATHS="images/*"
            ;;
        uTKernel)
            ARTIFACT_PATHS="tk.gz disa"
            ;;
        zephyr-v2.3)
            ARTIFACT_PATHS="images/build/$OS_BUILD_VARIANT/zephyr/zephyr.bin images/build/$OS_BUILD_VARIANT/zephyr/zephyr.elf"
            ;;
    esac
fi

mkdir -p "$WORK_DIR" "$RUN_DIR" "$AUTOBUILD_STATE_ROOT"
touch "$BUILD_LOG"
exec > >(tee -a "$BUILD_LOG") 2>&1

CURRENT_STAGE="init"
BUILD_RESULT="FAIL"
FAIL_REASON=""
FAILURE_ANALYSIS=""
TARGET_NAME="${MODEL_LINEUP} ${OS_PROJECT_NAME}"
if [ -n "$OS_BUILD_VARIANT" ]; then
    TARGET_NAME="$TARGET_NAME - $OS_BUILD_VARIANT"
fi
if [ -n "$OS_TARGET_NAME" ]; then
    TARGET_NAME="$OS_TARGET_NAME"
fi
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

collect_repo_metadata() {
    if [ ! -d "$REPO_DIR/.git" ]; then
        return
    fi

    MAIN_REPO_COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)"
    MAIN_REPO_LAST_COMMIT="$MAIN_REPO_COMMIT"
    MAIN_REPO_LAST_AUTHOR="$(git -C "$REPO_DIR" log -1 --format='%an <%ae>' 2>/dev/null || true)"
    MAIN_REPO_LAST_DATE="$(git -C "$REPO_DIR" log -1 --date=iso-strict --format='%ad' 2>/dev/null || true)"
    MAIN_REPO_LAST_SUBJECT="$(git -C "$REPO_DIR" log -1 --format='%s' 2>/dev/null || true)"
}

append_daily_target_status() {
    local label=$1
    local summary_path=$2
    local summary_target_name=$label

    if [ ! -f "$summary_path" ]; then
        return
    fi

    unset TARGET_NAME BUILD_RESULT CURRENT_STAGE BUILD_STARTED_AT BUILD_ENDED_AT
    unset BUILD_DURATION_FMT RUN_TS BUILD_LOG FAIL_REASON FAILURE_ANALYSIS
    unset MAIN_REPO_LAST_COMMIT MAIN_REPO_LAST_AUTHOR MAIN_REPO_LAST_DATE MAIN_REPO_LAST_SUBJECT

    # shellcheck disable=SC1090
    . "$summary_path"

    if [ -n "${TARGET_NAME:-}" ]; then
        summary_target_name="$TARGET_NAME"
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
    local package_error=""
    local source_path=""
    local source_line=""
    local source_location=""
    local message=""

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
    package_error="$(grep -aE 'ERROR: package/.*failed to build' "$source_log" 2>/dev/null | tail -n 1 | tr -d '\r' | sed -E 's/\x1B\[[0-9;]*[mK]//g; s/^[[:space:]]*//' || true)"

    if [ -z "$root_error" ] && [ -z "$package_error" ]; then
        FAILURE_ANALYSIS=""
        return
    fi

    if [ -n "$root_error" ]; then
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
    fi

    if [ -n "$package_error" ]; then
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
}

analyze_failure() {
    local source_log="$VERBOSE_LOG"

    if [ ! -s "$source_log" ]; then
        source_log="$BUILD_LOG"
    fi

    extract_failure_analysis "$source_log"
    {
        echo "=========================================="
        echo "$TARGET_NAME Build Failure Report"
        echo "=========================================="
        echo "Repo path      : $REPO_DIR"
        echo "Build log      : $BUILD_LOG"
        echo "Verbose log    : $VERBOSE_LOG"
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
        grep -aEn 'fatal error:|[[:space:]]error:|No such file or directory|cannot find|undefined reference|make(\[[0-9]+\])?: \*\*\*' "$source_log" | tail -n 40 || true
        echo
        echo "[Recent commits]"
        git -C "$REPO_DIR" log --oneline -n 20 2>/dev/null || true
    } > "$FAILURE_REPORT"
}

finalize() {
    local rc=$1
    local end_epoch build_started_at build_ended_at

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
        if [ -z "$FAILURE_ANALYSIS" ]; then
            FAILURE_ANALYSIS="$FAIL_REASON"
        fi
    fi

    collect_repo_metadata

    {
        echo "TARGET_NAME=$(printf '%q' "$TARGET_NAME")"
        echo "RUN_TS=$RUN_TS"
        echo "MODEL_LINEUP=$(printf '%q' "$MODEL_LINEUP")"
        echo "OS_PROJECT_NAME=$(printf '%q' "$OS_PROJECT_NAME")"
        echo "OS_REPO_URL=$(printf '%q' "$OS_REPO_URL")"
        echo "OS_REPO_BRANCH=$(printf '%q' "$OS_REPO_BRANCH")"
        echo "OS_PRODUCT_CONFIG=$(printf '%q' "$OS_PRODUCT_CONFIG")"
        echo "OS_BUILD_VARIANT=$(printf '%q' "$OS_BUILD_VARIANT")"
        echo "OS_CONFIG_CMD=$(printf '%q' "$OS_CONFIG_CMD")"
        echo "OS_CONFIG_EXPECT_CHOICES=$(printf '%q' "$OS_CONFIG_EXPECT_CHOICES")"
        echo "OS_BUILD_CMD=$(printf '%q' "$OS_BUILD_CMD")"
        echo "OS_REQUIRED_COMMANDS=$(printf '%q' "$OS_REQUIRED_COMMANDS")"
        echo "OS_PATH_PREPEND=$(printf '%q' "$OS_PATH_PREPEND")"
        echo "OS_LD_LIBRARY_PATH_PREPEND=$(printf '%q' "$OS_LD_LIBRARY_PATH_PREPEND")"
        echo "OS_TARGET_NAME=$(printf '%q' "$OS_TARGET_NAME")"
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
        echo "MAIN_REPO_URL=$(printf '%q' "$OS_REPO_URL")"
        echo "MAIN_REPO_DIR=$(printf '%q' "$REPO_DIR")"
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

run_expect_config() {
    local choices=$1
    local expect_script="$WORK_DIR/${OS_PROJECT_SLUG}_${MODEL_SLUG}_make_config.exp"

    require_command expect
    cat > "$expect_script" <<'EXP'
#!/usr/bin/expect -f
set timeout -1
log_user 1

set repo_dir [lindex $argv 0]
set choices [split [lindex $argv 1] " "]
set choice_index 0

proc next_choice {choicesVar indexVar} {
    upvar $choicesVar choices
    upvar $indexVar index

    if {$index >= [llength $choices]} {
        send_user "\n===== UNEXPECTED CHOICE PROMPT =====\n"
        exit 1
    }

    set answer [lindex $choices $index]
    incr index
    send -- "$answer\r"
}

spawn bash

expect -re {[$#] $}
send -- "cd -- \"$repo_dir\"\r"

expect -re {[$#] $}
send -- "set -o pipefail; make config; printf '\\n__CONFIG_RC__:%s\\n' \$?\r"

expect_before {
    -re {Default all settings .*([:]|\(NEW\))\s*$} { send -- "y\r"; exp_continue }
    -re {Customize Kernel Settings .*([:]|\(NEW\))\s*$} { send -- "n\r"; exp_continue }
    -re {Customize Application/Library Settings .*([:]|\(NEW\))\s*$} { send -- "n\r"; exp_continue }
    -re {Update Default Vendor Settings .*([:]|\(NEW\))\s*$} { send -- "n\r"; exp_continue }
    -re {choice\[[0-9\-?]+\]:\s*$} { next_choice choices choice_index; exp_continue }
    -re {\[[^]]+\]\s*$} { send -- "\r"; exp_continue }
}

expect {
    -re {__CONFIG_RC__:0} {
        send_user "\n===== CONFIG SUCCESS =====\n"
        exit 0
    }
    -re {__CONFIG_RC__:[1-9][0-9]*} {
        send_user "\n===== CONFIG FAIL =====\n"
        exit 1
    }
    timeout {
        send_user "\n===== CONFIG TIMEOUT =====\n"
        exit 1
    }
}
EXP

    chmod +x "$expect_script"
    "$expect_script" "$REPO_DIR" "$choices"
}

echo "[INFO] $TARGET_NAME autobuild started"
echo "[INFO] Workspace root: $WORK_ROOT"
echo "[INFO] Autobuild root: $AUTOBUILD_ROOT"
echo "[INFO] Run directory : $RUN_DIR"
echo "[INFO] Config file   : $CONFIG_FILE"
echo "[INFO] Model lineup  : $MODEL_LINEUP"
echo "[INFO] OS project    : $OS_PROJECT_NAME"
echo "[INFO] Repo URL      : $OS_REPO_URL"
echo "[INFO] Repo branch   : ${OS_REPO_BRANCH:-default}"
echo "[INFO] Product config: ${OS_PRODUCT_CONFIG:-none}"
echo "[INFO] Build variant : ${OS_BUILD_VARIANT:-none}"
echo "[INFO] Config command: ${OS_CONFIG_CMD:-none}"
echo "[INFO] Config choices: ${OS_CONFIG_EXPECT_CHOICES:-none}"
echo "[INFO] Build command : $OS_BUILD_CMD"
echo "[INFO] Required cmds : $OS_REQUIRED_COMMANDS"
echo "[INFO] PATH prepend  : ${OS_PATH_PREPEND:-none}"
echo "[INFO] LD lib prepend: ${OS_LD_LIBRARY_PATH_PREPEND:-none}"
echo "[INFO] Repo dir      : $REPO_DIR"
echo "[INFO] Failure rpt   : $FAILURE_REPORT"
echo

: > "$HASH_LOG"

for required_cmd in $OS_REQUIRED_COMMANDS; do
    require_command "$required_cmd"
done

CURRENT_STAGE="clone_repo"
echo "[$OS_PROJECT_NAME clone]"
echo "------------------------------------------"
rm -rf "$REPO_DIR"
mkdir -p "$(dirname "$REPO_DIR")"
if [ -n "$OS_REPO_BRANCH" ]; then
    git clone -b "$OS_REPO_BRANCH" --single-branch "$OS_REPO_URL" "$REPO_DIR"
else
    git clone "$OS_REPO_URL" "$REPO_DIR"
fi

REPO_COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD)"
echo "$OS_PROJECT_NAME|${OS_REPO_BRANCH:-$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)}|$REPO_COMMIT|$REPO_DIR|$OS_REPO_URL" | tee -a "$HASH_LOG"

if [ -n "$OS_PRODUCT_CONFIG" ]; then
    CURRENT_STAGE="apply_product_config"
    echo
    echo "[Product config]"
    echo "------------------------------------------"
    if [ ! -f "$REPO_DIR/products/$OS_PRODUCT_CONFIG" ]; then
        FAIL_REASON="Product config not found: $REPO_DIR/products/$OS_PRODUCT_CONFIG"
        echo "[ERROR] $FAIL_REASON"
        exit 1
    fi
    cp "$REPO_DIR/products/$OS_PRODUCT_CONFIG" "$REPO_DIR/.config"
fi

if [ -n "$OS_CONFIG_CMD" ]; then
    CURRENT_STAGE="configure"
    echo
    echo "[$OS_PROJECT_NAME configure]"
    echo "------------------------------------------"
    (
        cd "$REPO_DIR"
        set -o pipefail
        bash -lc "$OS_CONFIG_CMD"
    ) 2>&1 | tee -a "$VERBOSE_LOG"
fi

if [ -n "$OS_CONFIG_EXPECT_CHOICES" ]; then
    CURRENT_STAGE="configure"
    echo
    echo "[$OS_PROJECT_NAME expect configure]"
    echo "------------------------------------------"
    run_expect_config "$OS_CONFIG_EXPECT_CHOICES" 2>&1 | tee -a "$VERBOSE_LOG"
fi

CURRENT_STAGE="build"
echo
echo "[$OS_PROJECT_NAME build]"
echo "------------------------------------------"
(
    cd "$REPO_DIR"
    set -o pipefail
    bash -lc "$OS_BUILD_CMD"
) 2>&1 | tee -a "$VERBOSE_LOG"

echo
echo "[INFO] $TARGET_NAME autobuild completed successfully"
