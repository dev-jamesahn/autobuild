#!/bin/bash

set -euo pipefail

BASE_DIR="$HOME"
RUN_DATE="${RUN_DATE:-$(date +%Y%m%d)}"
WORK_ROOT="${GCT_WORK_ROOT:-${WORK_ROOT:-$BASE_DIR/gct_workspace}}"
AUTOBUILD_ROOT="${AUTOBUILD_ROOT:-$WORK_ROOT/autobuild}"
AUTOBUILD_LOG_ROOT="${AUTOBUILD_LOG_ROOT:-$AUTOBUILD_ROOT/logs}"
AUTOBUILD_STATE_ROOT="${AUTOBUILD_STATE_ROOT:-$AUTOBUILD_ROOT/state}"
DAILY_STATUS_FILE="${DAILY_STATUS_FILE:-$AUTOBUILD_STATE_ROOT/daily_autobuild_status_${RUN_DATE}.txt}"
UPLOAD_FLAG_FILE="${UPLOAD_FLAG_FILE:-$AUTOBUILD_STATE_ROOT/.daily_autobuild_logs_uploaded_${RUN_DATE}.flag}"
SAMBA_UPLOAD_CONFIG="${SAMBA_UPLOAD_CONFIG:-$BASE_DIR/.config/autobuild_samba_upload.env}"

SAMBA_UPLOAD_ENABLED="${SAMBA_UPLOAD_ENABLED:-1}"
SAMBA_UPLOAD_URI="${SAMBA_UPLOAD_URI:-smb://gctsemi.com/NetK/ENG/ENG05/CS/Test%20Log/Daily_build}"
SAMBA_UPLOAD_LOCAL_DIR="${SAMBA_UPLOAD_LOCAL_DIR:-}"

if [ -f "$SAMBA_UPLOAD_CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$SAMBA_UPLOAD_CONFIG"
fi

USER_RUNTIME_DIR="/run/user/$(id -u)"
if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -d "$USER_RUNTIME_DIR" ]; then
    export XDG_RUNTIME_DIR="$USER_RUNTIME_DIR"
fi
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -S "$XDG_RUNTIME_DIR/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
fi

if [ "$SAMBA_UPLOAD_ENABLED" != "1" ]; then
    echo "[INFO] Daily log upload skipped: SAMBA_UPLOAD_ENABLED=$SAMBA_UPLOAD_ENABLED"
    exit 0
fi

if [ ! -f "$DAILY_STATUS_FILE" ]; then
    echo "[WARN] Daily log upload skipped: daily status file not found: $DAILY_STATUS_FILE"
    exit 0
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/daily_autobuild_upload.XXXXXX")"
PACKAGE_DIR="$TMP_ROOT/$RUN_DATE"
MANIFEST_FILE="$PACKAGE_DIR/upload_manifest.txt"

cleanup() {
    rm -rf "$TMP_ROOT"
}

trap cleanup EXIT

mkdir -p "$PACKAGE_DIR"
cp "$DAILY_STATUS_FILE" "$PACKAGE_DIR/"

{
    echo "run_date=$RUN_DATE"
    echo "generated_at=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "daily_status_file=$DAILY_STATUS_FILE"
    echo
    echo "[uploaded_log_dirs]"
} > "$MANIFEST_FILE"

safe_name() {
    local value=$1
    value="${value//[^A-Za-z0-9._-]/_}"
    value="${value##_}"
    value="${value%%_}"
    printf '%s' "${value:-unknown}"
}

copy_artifact_path() {
    local artifact_path=$1
    local artifact_root=$2
    local target_dir=$3
    local rel_path
    local dest_path

    if [ -d "$artifact_path" ]; then
        if [[ "$artifact_path" == "$artifact_root"/* ]]; then
            rel_path="${artifact_path#"$artifact_root"/}"
        else
            rel_path="external/${artifact_path#/}"
        fi
        mkdir -p "$target_dir/$rel_path"
        rsync -a "$artifact_path/" "$target_dir/$rel_path/"
        printf '  %s -> %s/\n' "$artifact_path" "$rel_path" >> "$MANIFEST_FILE"
        return
    fi

    if [ ! -f "$artifact_path" ]; then
        return
    fi

    if [[ "$artifact_path" == "$artifact_root"/* ]]; then
        rel_path="${artifact_path#"$artifact_root"/}"
    else
        rel_path="external/${artifact_path#/}"
    fi

    dest_path="$target_dir/$rel_path"
    mkdir -p "$(dirname "$dest_path")"
    rsync -a "$artifact_path" "$dest_path"
    printf '  %s -> %s\n' "$artifact_path" "$rel_path" >> "$MANIFEST_FILE"
}

copy_artifacts_for_log_dir() {
    local log_dir=$1
    local summary_file="$log_dir/summary.env"
    local target_name=""
    local build_result=""
    local artifact_root=""
    local artifact_paths=""
    local main_repo_dir=""
    local os_project_name=""
    local os_build_variant=""
    local zephyros_config_name=""
    local openwrt_branch=""
    local safe_target
    local artifact_target_dir
    local artifact_spec
    local artifact_path
    local matched

    if [ ! -f "$summary_file" ]; then
        return
    fi

    unset TARGET_NAME BUILD_RESULT ARTIFACT_ROOT ARTIFACT_PATHS MAIN_REPO_DIR
    unset OS_PROJECT_NAME OS_BUILD_VARIANT ZEPHYROS_CONFIG_NAME OPENWRT_BRANCH
    # shellcheck disable=SC1090
    . "$summary_file"

    target_name="${TARGET_NAME:-$(basename "$log_dir")}"
    build_result="${BUILD_RESULT:-}"
    artifact_root="${ARTIFACT_ROOT:-}"
    artifact_paths="${ARTIFACT_PATHS:-}"
    main_repo_dir="${MAIN_REPO_DIR:-}"
    os_project_name="${OS_PROJECT_NAME:-}"
    os_build_variant="${OS_BUILD_VARIANT:-}"
    zephyros_config_name="${ZEPHYROS_CONFIG_NAME:-}"
    openwrt_branch="${OPENWRT_BRANCH:-}"

    if [ -z "$artifact_root" ] && [ -n "$main_repo_dir" ]; then
        artifact_root="$main_repo_dir"
    fi
    if [ -z "$artifact_paths" ]; then
        if [ -n "$openwrt_branch" ]; then
            artifact_paths="bin/targets/gdm7275x/generic/owrt*.*"
        elif [ "$os_project_name" = "Linuxos" ]; then
            artifact_paths="images/*"
        elif [ "$os_project_name" = "uTKernel" ]; then
            artifact_paths="tk.gz disa"
        elif [ "$os_project_name" = "zephyr-v2.3" ] && [ -n "$os_build_variant" ]; then
            artifact_paths="images/build/$os_build_variant/zephyr/zephyr.bin images/build/$os_build_variant/zephyr/zephyr.elf"
        elif [ -n "$zephyros_config_name" ]; then
            artifact_paths="images/build/$zephyros_config_name/zephyr/tk.gz images/build/$zephyros_config_name/zephyr/zephyr.elf"
        fi
    fi

    if [ "$build_result" != "SUCCESS" ] || [ -z "$artifact_root" ] || [ -z "$artifact_paths" ]; then
        return
    fi

    safe_target="$(safe_name "$target_name")"
    artifact_target_dir="$PACKAGE_DIR/artifacts/$safe_target"
    mkdir -p "$artifact_target_dir"

    {
        echo
        echo "[$target_name artifacts]"
        echo "artifact_root=$artifact_root"
    } >> "$MANIFEST_FILE"

    for artifact_spec in $artifact_paths; do
        matched=0
        while IFS= read -r artifact_path; do
            [ -n "$artifact_path" ] || continue
            matched=1
            copy_artifact_path "$artifact_path" "$artifact_root" "$artifact_target_dir"
        done < <(compgen -G "$artifact_root/$artifact_spec" || true)

        if [ "$matched" -eq 0 ] && [ -e "$artifact_root/$artifact_spec" ]; then
            copy_artifact_path "$artifact_root/$artifact_spec" "$artifact_root" "$artifact_target_dir"
            matched=1
        fi

        if [ "$matched" -eq 0 ]; then
            printf '  [missing] %s\n' "$artifact_root/$artifact_spec" >> "$MANIFEST_FILE"
        fi
    done
}

while IFS= read -r log_path; do
    [ -n "$log_path" ] || continue

    log_dir="$(dirname "$log_path")"
    if [ ! -d "$log_dir" ]; then
        echo "[WARN] Daily log upload: log dir not found: $log_dir" | tee -a "$MANIFEST_FILE"
        continue
    fi

    case "$log_dir" in
        "$AUTOBUILD_LOG_ROOT"/*)
            rel_dir="${log_dir#"$AUTOBUILD_LOG_ROOT"/}"
            ;;
        *)
            rel_dir="external/${log_dir#/}"
            ;;
    esac

    mkdir -p "$PACKAGE_DIR/$(dirname "$rel_dir")"
    rsync -a "$log_dir/" "$PACKAGE_DIR/$rel_dir/"
    echo "$log_dir -> $rel_dir" >> "$MANIFEST_FILE"
    copy_artifacts_for_log_dir "$log_dir"
done < <(awk -F: '/^Log path[[:space:]]*:/ {sub(/^[[:space:]]+/, "", $2); print $2}' "$DAILY_STATUS_FILE")

copy_to_local_dir() {
    local target_root=$1
    local target_dir="$target_root/$RUN_DATE"

    mkdir -p "$target_dir"
    rsync -a --delete "$PACKAGE_DIR/" "$target_dir/"
    printf 'uploaded_at=%s\nrun_date=%s\ntarget=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RUN_DATE" "$target_dir" > "$UPLOAD_FLAG_FILE"
    echo "[INFO] Daily log upload completed: $target_dir"
}

copy_to_gio_uri() {
    local target_uri=${1%/}
    local rel_path
    local dest_uri

    if ! command -v gio >/dev/null 2>&1; then
        echo "[WARN] Daily log upload skipped: gio command is not available"
        return 0
    fi

    if ! gio info "$target_uri" >/dev/null 2>&1; then
        echo "[WARN] Daily log upload skipped: Samba URI is not mounted or accessible: $target_uri"
        return 0
    fi

    gio mkdir "$target_uri/$RUN_DATE" >/dev/null 2>&1 || true
    if ! gio info "$target_uri/$RUN_DATE" >/dev/null 2>&1; then
        echo "[WARN] Daily log upload skipped: cannot create date folder: $target_uri/$RUN_DATE"
        return 0
    fi

    while IFS= read -r dir_path; do
        [ "$dir_path" != "$PACKAGE_DIR" ] || continue
        rel_path="${dir_path#"$PACKAGE_DIR"/}"
        gio mkdir "$target_uri/$RUN_DATE/$rel_path" >/dev/null 2>&1 || true
    done < <(find "$PACKAGE_DIR" -type d | sort)

    while IFS= read -r file_path; do
        rel_path="${file_path#"$PACKAGE_DIR"/}"
        dest_uri="$target_uri/$RUN_DATE/$rel_path"
        gio remove "$dest_uri" >/dev/null 2>&1 || true
        gio copy "$file_path" "$dest_uri"
    done < <(find "$PACKAGE_DIR" -type f | sort)

    printf 'uploaded_at=%s\nrun_date=%s\ntarget=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$RUN_DATE" "$target_uri/$RUN_DATE" > "$UPLOAD_FLAG_FILE"
    echo "[INFO] Daily log upload completed: $target_uri/$RUN_DATE"
}

if [ -n "$SAMBA_UPLOAD_LOCAL_DIR" ]; then
    copy_to_local_dir "$SAMBA_UPLOAD_LOCAL_DIR"
else
    copy_to_gio_uri "$SAMBA_UPLOAD_URI"
fi
