# Sourced by the build scripts. Reads KEY=value from release.local.conf, then release.conf.
#   config_value KEY [default]
config_value() {
    local key=$1 file value
    for file in release.local.conf release.conf; do
        [[ -f "$file" ]] || continue
        value=$(sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$/\1/p" "$file" | tail -n 1)
        [[ -n "$value" ]] && { printf "%s\n" "$value"; return; }
    done
    printf "%s\n" "${2:-}"
}
