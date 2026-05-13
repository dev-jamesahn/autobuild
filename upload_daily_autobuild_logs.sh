#!/bin/bash

set -euo pipefail

BASE_DIR="$HOME"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AUTOBUILD_CONFIG_ROOT="${AUTOBUILD_CONFIG_ROOT:-$SCRIPT_DIR/config}"
RUN_DATE="${RUN_DATE:-$(date +%Y%m%d)}"
WORK_ROOT="${GCT_WORK_ROOT:-${WORK_ROOT:-$BASE_DIR/gct_workspace}}"
AUTOBUILD_ROOT="${AUTOBUILD_ROOT:-$WORK_ROOT/autobuild}"
AUTOBUILD_LOG_ROOT="${AUTOBUILD_LOG_ROOT:-$AUTOBUILD_ROOT/logs}"
AUTOBUILD_STATE_ROOT="${AUTOBUILD_STATE_ROOT:-$AUTOBUILD_ROOT/state}"
DAILY_STATUS_FILE="${DAILY_STATUS_FILE:-$AUTOBUILD_STATE_ROOT/daily_autobuild_status_${RUN_DATE}.txt}"
UPLOAD_FLAG_FILE="${UPLOAD_FLAG_FILE:-$AUTOBUILD_STATE_ROOT/.daily_autobuild_logs_uploaded_${RUN_DATE}.flag}"
SAMBA_UPLOAD_CONFIG="${SAMBA_UPLOAD_CONFIG:-$AUTOBUILD_CONFIG_ROOT/autobuild_common.env}"

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
MANIFEST_FILE="$TMP_ROOT/upload_manifest.txt"
FW_BUILD_INFO_FILE="$PACKAGE_DIR/FW_build_info_${RUN_DATE}.txt"

cleanup() {
    rm -rf "$TMP_ROOT"
}

trap cleanup EXIT

mkdir -p "$PACKAGE_DIR"

{
    echo "run_date=$RUN_DATE"
    echo "generated_at=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "daily_status_file=$DAILY_STATUS_FILE"
    echo
    echo "[uploaded_log_dirs]"
} > "$MANIFEST_FILE"

generate_fw_build_info() {
    awk '
        function flush_section() {
            if (section == "") {
                return
            }
            git_info[section] = git
            section = ""
            git = ""
            in_git = 0
        }

        /^\[/ && /\]$/ {
            flush_section()
            section = substr($0, 2, length($0) - 2)
            next
        }

        /^Git log[[:space:]]*:/ {
            in_git = 1
            next
        }

        in_git && /^  / {
            git = git $0 "\n"
            next
        }

        in_git && /^[^[:space:]]/ {
            in_git = 0
        }

        END {
            flush_section()

            print "[GDM7275X]"
            print ""
            print_entry("OpenWRT v1.00", "GDM7275X OpenWrt v1.00")
            print_entry("OpenWRT master", "GDM7275X OpenWrt master")
            print_entry("Linuxos master", "GDM7275X Linuxos master")
            print_entry("Zephyros", "GDM7275X Zephyros")
            print ""

            print "[GDM7243A]"
            print ""
            print_entry("uTKernel - gdm7243a_no_l2", "GDM7243A uTKernel - gdm7243a_no_l2")
            print ""

            print "[GDM7243ST]"
            print ""
            print_entry("uTKernel - gdm7243mt_32mb_no_l2_vport14", "GDM7243ST uTKernel - gdm7243mt_32mb_no_l2_vport14")
            print ""

            print "[GDM7243i]"
            print ""
            print_entry("zephyr-v2.3 - gdm7243i_nbiot_ntn_quad", "GDM7243i zephyr-v2.3 - gdm7243i_nbiot_ntn_quad")
        }

        function print_entry(title, key) {
            print "  - " title
            if (git_info[key] != "") {
                formatted = git_info[key]
                gsub(/^  /, "    ", formatted)
                gsub(/\n  /, "\n    ", formatted)
                printf "%s", formatted
            } else {
                print "    commit : N/A"
                print "    author : N/A"
                print "    date   : N/A"
                print "    subject: N/A"
            }
            print ""
        }
    ' "$DAILY_STATUS_FILE" > "$FW_BUILD_INFO_FILE"
}

generate_fw_build_info

safe_name() {
    local value=$1
    value="${value//[^A-Za-z0-9._-]/_}"
    value="${value##_}"
    value="${value%%_}"
    printf '%s' "${value:-unknown}"
}

upload_dir_name() {
    local target_name=$1
    local openwrt_branch=$2
    local os_project_name=$3
    local os_build_variant=$4
    local zephyros_config_name=$5
    local lowered

    if [ -n "$openwrt_branch" ]; then
        case "$openwrt_branch" in
            v1.00) printf 'GDM7275X/openwrt_v100' ;;
            master) printf 'GDM7275X/openwrt_master' ;;
            *) printf 'GDM7275X/openwrt_%s' "$openwrt_branch" ;;
        esac
        return
    fi

    if [ -n "$zephyros_config_name" ] || [ "$target_name" = "GDM7275X Zephyros" ]; then
        printf 'GDM7275X/Zephyros'
        return
    fi

    case "$os_project_name" in
        Linuxos)
            printf 'GDM7275X/linuxos_master'
            return
            ;;
        uTKernel)
            lowered="$(printf '%s' "$target_name" | tr '[:upper:]' '[:lower:]')"
            case "$lowered" in
                *gdm7243st*) printf 'GDM7243ST/uTKernel' ;;
                *gdm7243a*) printf 'GDM7243A/uTKernel' ;;
                *) safe_name "$target_name" ;;
            esac
            return
            ;;
        zephyr-v2.3)
            lowered="$(printf '%s' "$target_name" | tr '[:upper:]' '[:lower:]')"
            case "$lowered" in
                *gdm7243i*) printf 'GDM7243i/zephyr_v2.3' ;;
                *) safe_name "$target_name" ;;
            esac
            return
            ;;
    esac

    safe_name "$target_name"
}

copy_artifact_path() {
    local artifact_path=$1
    local target_dir=$2
    local dest_path

    if [ -d "$artifact_path" ]; then
        find -L "$artifact_path" -type f | sort | while IFS= read -r nested_file; do
            dest_path="$target_dir/$(basename "$nested_file")"
            rsync -aL "$nested_file" "$dest_path"
            printf '  %s -> Image/%s\n' "$nested_file" "$(basename "$nested_file")" >> "$MANIFEST_FILE"
        done
        return
    fi

    if [ ! -f "$artifact_path" ]; then
        return
    fi

    dest_path="$target_dir/$(basename "$artifact_path")"
    rsync -aL "$artifact_path" "$dest_path"
    printf '  %s -> Image/%s\n' "$artifact_path" "$(basename "$artifact_path")" >> "$MANIFEST_FILE"
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

    artifact_target_dir="$PACKAGE_DIR/$(upload_dir_name "$target_name" "$openwrt_branch" "$os_project_name" "$os_build_variant" "$zephyros_config_name")/Image"
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
            copy_artifact_path "$artifact_path" "$artifact_target_dir"
        done < <(compgen -G "$artifact_root/$artifact_spec" || true)

        if [ "$matched" -eq 0 ] && [ -e "$artifact_root/$artifact_spec" ]; then
            copy_artifact_path "$artifact_root/$artifact_spec" "$artifact_target_dir"
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

    summary_file="$log_dir/summary.env"
    target_name="$(basename "$log_dir")"
    openwrt_branch=""
    os_project_name=""
    os_build_variant=""
    zephyros_config_name=""

    if [ -f "$summary_file" ]; then
        unset TARGET_NAME OPENWRT_BRANCH OS_PROJECT_NAME OS_BUILD_VARIANT ZEPHYROS_CONFIG_NAME
        # shellcheck disable=SC1090
        . "$summary_file"
        target_name="${TARGET_NAME:-$target_name}"
        openwrt_branch="${OPENWRT_BRANCH:-}"
        os_project_name="${OS_PROJECT_NAME:-}"
        os_build_variant="${OS_BUILD_VARIANT:-}"
        zephyros_config_name="${ZEPHYROS_CONFIG_NAME:-}"
    fi

    rel_dir="$(upload_dir_name "$target_name" "$openwrt_branch" "$os_project_name" "$os_build_variant" "$zephyros_config_name")/Log"
    mkdir -p "$PACKAGE_DIR/$rel_dir"
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

    remove_gio_uri_tree() {
        local uri=$1
        local child

        if ! gio info "$uri" >/dev/null 2>&1; then
            return
        fi

        if gio remove "$uri" >/dev/null 2>&1; then
            return
        fi

        while IFS= read -r child; do
            [ -n "$child" ] || continue
            child="${child%/}"
            remove_gio_uri_tree "$uri/$child"
        done < <(gio list "$uri" 2>/dev/null || true)

        gio remove "$uri" >/dev/null 2>&1 || true
    }

    for rel_path in artifacts openwrt uTKernel zephyr_v2_3 openwrt_v1.00 openwrt_master linuxos zephyros gdm7243a_utkernel gdm7243st_utkernel gdm7243i_zephyr_v2.3; do
        remove_gio_uri_tree "$target_uri/$RUN_DATE/$rel_path"
    done
    gio remove "$target_uri/$RUN_DATE/daily_autobuild_status_${RUN_DATE}.txt" >/dev/null 2>&1 || true
    gio remove "$target_uri/$RUN_DATE/upload_manifest.txt" >/dev/null 2>&1 || true

    while IFS= read -r dir_path; do
        [ "$dir_path" != "$PACKAGE_DIR" ] || continue
        [ "$(dirname "$dir_path")" = "$PACKAGE_DIR" ] || continue
        rel_path="${dir_path#"$PACKAGE_DIR"/}"
        remove_gio_uri_tree "$target_uri/$RUN_DATE/$rel_path"
    done < <(find "$PACKAGE_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

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
