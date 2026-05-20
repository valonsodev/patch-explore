#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEFCON_FILE="$SCRIPT_DIR/DEFCON.md"
PLAN_FILE="$SCRIPT_DIR/PLAN.md"
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
        find "$SCRIPT_DIR" -maxdepth 1 -type f \( \
            -iname '*.apk' -o \
            -iname '*.apks' -o \
            -iname '*.xapk' -o \
            -iname '*.apkm' \
        \) -print0 | sort -z
    )

    case ${#artifacts[@]} in
        0) fail "No .apk, .apks, .xapk, or .apkm files found in $SCRIPT_DIR" ;;
        1) printf '%s\n' "${artifacts[0]}"; return ;;
    esac

    for candidate in "${artifacts[@]}"; do
        labels+=("$(basename -- "$candidate")")
    done

    selection=$(printf '%s\n' "${labels[@]}" | gum choose --header "Select the Android artifact to inspect")
    [[ -n "$selection" ]] || fail "No artifact selected"
    printf '%s\n' "$SCRIPT_DIR/$selection"
}

read_package_id() {
    apkeditor info -package -i "$1" 2>/dev/null \
        | sed -n 's/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d; p; q'
}

resolve_package_id() {
    local input_path=$1
    local package_id temp_dir merged_apk

    package_id=$(read_package_id "$input_path" || true)
    if [[ -n "$package_id" ]]; then
        printf '%s\n' "$package_id"
        return
    fi

    temp_dir=$(mktemp -d)
    CLEANUP_PATHS+=("$temp_dir")
    merged_apk="$temp_dir/merged.apk"

    apkeditor m -i "$input_path" -o "$merged_apk" -f >/dev/null 2>&1 \
        || fail "APKEditor failed to merge $(basename -- "$input_path")"

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
    grep -q '<APP_ID>' "$DEFCON_FILE" || fail "DEFCON.md does not contain <APP_ID>"
    grep -q '<TASKS>' "$DEFCON_FILE" || fail "DEFCON.md does not contain <TASKS>"
    grep -q '<TASKS>' "$PLAN_FILE" || fail "PLAN.md does not contain <TASKS>"
}

prompt_for_tasks() {
    local tasks
    tasks=$(gum write --placeholder "Describe the challenge tasks. Press Ctrl+D when finished.")
    [[ -n "${tasks//[[:space:]]/}" ]] || fail "Task description cannot be empty"
    printf '%s' "$tasks"
}

replace_placeholders_in_file() {
    local target=$1 app_id=$2 tasks=$3
    local temp_file

    temp_file=$(mktemp)
    CLEANUP_PATHS+=("$temp_file")

    awk -v app_id="$app_id" -v tasks="$tasks" '
        {
            gsub(/<APP_ID>/, app_id)
            if ($0 == "<TASKS>") print tasks
            else print
        }
    ' "$target" >"$temp_file"

    mv -- "$temp_file" "$target"
}

main() {
    local app_id=${1:-}
    local artifact_path artifact_name tasks

    require_command gum
    require_command apkeditor
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

    gum format -- "# Template Update\n\n- Artifact: ${artifact_name}\n- Package ID: ${app_id}\n\n## Tasks\n\n${tasks}"
    gum confirm "Replace placeholders in DEFCON.md and PLAN.md?" || fail "Cancelled"

    replace_placeholders_in_file "$DEFCON_FILE" "$app_id" "$tasks"
    replace_placeholders_in_file "$PLAN_FILE" "$app_id" "$tasks"

    gum style --border normal --padding '1 2' --margin '1 0' \
        "Updated DEFCON.md and PLAN.md for $app_id using $artifact_name"
}

main "$@"
