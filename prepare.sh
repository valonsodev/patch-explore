#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORKING_DIR=$PWD
DEFCON_TEMPLATE="$SCRIPT_DIR/DEFCON.md"
PLAN_TEMPLATE="$SCRIPT_DIR/PLAN.md"
REPO_README="$SCRIPT_DIR/README.md"
OUTPUT_DIR="$WORKING_DIR/decompiled"
MORPHE_API_URL="https://api.morphe.software"
MORPHE_PATCHES_REPO_RAW="https://raw.githubusercontent.com/MorpheApp/morphe-patches/main"
DEFAULT_VERSION="any"
DEFAULT_ABI="arm64-v8a"

declare -a CLEANUP_PATHS=()

cleanup() {
    local path
    (( ${#CLEANUP_PATHS[@]} > 0 )) || return 0
    for path in "${CLEANUP_PATHS[@]}"; do
        [[ -e "$path" ]] && rm -rf -- "$path"
    done
}

trap cleanup EXIT

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

notice() {
    gum style --border rounded --padding '1 2' --margin '1 0' "$1"
}

pick_artifact() {
    local -a artifacts labels
    local candidate selection

    mapfile -d '' artifacts < <(
        find "$WORKING_DIR" -maxdepth 1 -type f \( \
            -iname '*.apk' -o \
            -iname '*.apks' -o \
            -iname '*.xapk' -o \
            -iname '*.apkm' \
        \) -print0 | sort -z
    )

    case ${#artifacts[@]} in
        0) fail "No .apk, .apks, .xapk, or .apkm files found in $WORKING_DIR" ;;
        1) printf '%s\n' "${artifacts[0]}"; return ;;
    esac

    for candidate in "${artifacts[@]}"; do
        labels+=("$(basename -- "$candidate")")
    done

    selection=$(printf '%s\n' "${labels[@]}" | gum choose --header "Select the Android artifact to inspect")
    [[ -n "$selection" ]] || fail "No artifact selected"
    printf '%s\n' "$WORKING_DIR/$selection"
}

read_package_id() {
    local raw
    raw=$(apkeditor info -package -i "$1" 2>/dev/null \
        | sed -n 's/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d; p; q')
    raw=${raw#package=}
    raw=${raw#\"}
    raw=${raw%\"}
    printf '%s\n' "$raw"
}

merge_to_plain_apk() {
    local input_path=$1
    local temp_dir merged_apk

    temp_dir=$(mktemp -d)
    CLEANUP_PATHS+=("$temp_dir")
    merged_apk="$temp_dir/merged.apk"

    apkeditor m -i "$input_path" -o "$merged_apk" -f >/dev/null 2>&1 \
        || fail "APKEditor failed to merge $(basename -- "$input_path")"

    printf '%s\n' "$merged_apk"
}

resolve_package_id() {
    local input_path=$1
    local package_id merged_apk

    package_id=$(read_package_id "$input_path" || true)
    if [[ -n "$package_id" ]]; then
        printf '%s\n' "$package_id"
        return
    fi

    merged_apk=$(merge_to_plain_apk "$input_path")
    package_id=$(read_package_id "$merged_apk" || true)
    [[ -n "$package_id" ]] || fail "Unable to resolve a package ID from $(basename -- "$input_path")"

    printf '%s\n' "$package_id"
}

url_encode_path() {
    local input=$1 encoded= char hex
    local i

    for ((i = 0; i < ${#input}; i++)); do
        char=${input:i:1}
        case "$char" in
            [a-zA-Z0-9._~-]) encoded+="$char" ;;
            *) printf -v hex '%%%02X' "'${char}"; encoded+="$hex" ;;
        esac
    done

    printf '%s\n' "$encoded"
}

fetch_latest_supported_version() {
    local package_id=$1
    local source_url response version
    local -a sources=(
        "${MORPHE_PATCHES_REPO_RAW}/patches/src/main/kotlin/app/morphe/patches/youtube/shared/Constants.kt"
        "${MORPHE_PATCHES_REPO_RAW}/patches/src/main/kotlin/app/morphe/patches/music/shared/Constants.kt"
        "${MORPHE_PATCHES_REPO_RAW}/patches/src/main/kotlin/app/morphe/patches/reddit/shared/Constants.kt"
    )

    for source_url in "${sources[@]}"; do
        response=$(curl --silent --show-error --fail "$source_url") || continue
        version=$(awk -v pkg="$package_id" '
            $0 ~ "packageName = \"" pkg "\"" { in_pkg = 1; next }
            in_pkg && $0 ~ /version = "/ {
                sub(/^.*version = "/, "")
                sub(/".*$/, "")
                print; exit
            }
        ' <<<"$response")

        if [[ -n "$version" ]]; then
            printf '%s\n' "$version"
            return 0
        fi
    done

    return 1
}

resolve_download_page_url() {
    local package_id=$1
    local version query endpoint final_url

    version=$(fetch_latest_supported_version "$package_id" || true)
    version=${version:-$DEFAULT_VERSION}

    query=$(url_encode_path "${package_id}~${version}~${DEFAULT_ABI}")
    endpoint="${MORPHE_API_URL}/v2/web-search/${query}"
    final_url=$(curl --silent --show-error --location \
        --output /dev/null --write-out '%{url_effective}' "$endpoint")

    [[ -n "$final_url" ]] || fail "Failed to resolve URL from $endpoint"

    if [[ "$final_url" == https://www.google.* || "$final_url" == https://google.* ]]; then
        printf 'Warning: Morphe returned a Google fallback search instead of a direct APK page.\n' >&2
    fi

    printf '%s\n' "$final_url"
}

prepare_download_page() {
    local package_id=$1
    local url

    url=$(resolve_download_page_url "$package_id")
    [[ -n "$url" ]] || fail "Failed to resolve download page for $package_id"

    notice "Latest stock APK page: $url"

    command -v xdg-open >/dev/null 2>&1 || return 0
    gum confirm "Open the latest stock APK page in your browser?" || return 0
    xdg-open "$url" >/dev/null 2>&1 &
}

require_placeholders() {
    grep -q '<APP_ID>' "$DEFCON_TEMPLATE" || fail "DEFCON.md template does not contain <APP_ID>"
    grep -q '<TASKS>'  "$DEFCON_TEMPLATE" || fail "DEFCON.md template does not contain <TASKS>"
    grep -q '<TASKS>'  "$PLAN_TEMPLATE"   || fail "PLAN.md template does not contain <TASKS>"
}

prompt_for_tasks() {
    local tasks
    tasks=$(gum write --placeholder "Describe the analysis goals, one per line. Press Ctrl+D when finished.")
    [[ -n "${tasks//[[:space:]]/}" ]] || fail "Task description cannot be empty"
    printf '%s' "$tasks"
}

normalize_tasks() {
    local tasks=$1

    awk '
        /^[[:space:]]*$/ { next }
        {
            line = $0
            sub(/^[[:space:]]*[-*][[:space:]]+/, "", line)
            sub(/^[[:space:]]*[0-9]+[.)][[:space:]]+/, "", line)
            print "- " line
        }
    ' <<<"$tasks"
}

render_template() {
    local template=$1 output=$2 app_id=$3 tasks=$4

    awk -v app_id="$app_id" -v tasks="$tasks" '
        {
            gsub(/<APP_ID>/, app_id)
            if ($0 == "<TASKS>") print tasks
            else print
        }
    ' "$template" >"$output"
}

remove_repo_readme() {
    [[ -f "$REPO_README" ]] || return 0
    rm -f -- "$REPO_README"
}

main() {
    local app_id=${1:-}
    local artifact_path artifact_name tasks

    require_command gum
    require_command apkeditor
    require_command jadx
    require_command curl
    require_placeholders

    if [[ -n "$app_id" ]]; then
        notice "Using provided package ID: $app_id"
        prepare_download_page "$app_id"
    fi

    artifact_path=$(pick_artifact)
    artifact_name=$(basename -- "$artifact_path")

    if [[ -z "$app_id" ]]; then
        app_id=$(resolve_package_id "$artifact_path")
        [[ -n "$app_id" ]] || fail "Resolved package ID was empty"
        notice "Detected package ID: $app_id"
    fi

    tasks=$(prompt_for_tasks)
    tasks=$(normalize_tasks "$tasks")

    gum format -- "# Workspace Plan\n\n- Artifact: ${artifact_name}\n- Package ID: ${app_id}\n- Decompile to: ${OUTPUT_DIR}\n\n## Tasks\n\n${tasks}"
    gum confirm "Decompile ${artifact_name} into ${OUTPUT_DIR} and write planning docs?" || fail "Cancelled"

    notice "Decompiling with jadx → $OUTPUT_DIR"
    jadx -d "$OUTPUT_DIR" "$artifact_path" || true

    render_template "$DEFCON_TEMPLATE" "$OUTPUT_DIR/DEFCON.md" "$app_id" "$tasks"
    render_template "$PLAN_TEMPLATE"   "$OUTPUT_DIR/PLAN.md"   "$app_id" "$tasks"
    remove_repo_readme

    gum style --border normal --padding '1 2' --margin '1 0' \
        "Decompiled $artifact_name into $OUTPUT_DIR and wrote DEFCON.md + PLAN.md for $app_id"
}

main "$@"
