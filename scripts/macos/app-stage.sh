# Stage a complete bundle before replacing an existing app. Callers use Bash with set -e.
begin_app_stage() {
    app_destination="$1"
    stage="$(mktemp -d "$2")"
    bundle="$stage/${app_destination##*/}"
    trap cleanup_app_stage EXIT
}

cleanup_app_stage() {
    if [[ -e "$stage/Previous.app" ]]; then
        if [[ ! -e "$app_destination" ]]; then
            if ! mv "$stage/Previous.app" "$app_destination"; then
                echo "Could not restore the previous app; kept $stage" >&2
                return 1
            fi
        elif [[ -e "$bundle" ]]; then
            echo "Destination changed during replacement; kept $stage for recovery." >&2
            return 1
        fi
    fi
    /bin/rm -rf "$stage"
}

publish_staged_app() {
    if [[ -e "$app_destination" ]]; then mv "$app_destination" "$stage/Previous.app"; fi
    mv "$bundle" "$app_destination"
}
