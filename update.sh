#!/usr/bin/env bash
set -euo pipefail

set -x

THRESHOLD=64 #MiB

trace_dir="${1?usage: update.sh TRACE-DIRECTORY}"
report_path="$trace_dir/report"

# Ensure that we have the expected version of buildozer.
buildozer_url="https://github.com/bazelbuild/buildtools/releases/download/v6.3.3/buildozer-linux-amd64"
buildozer_hash="1dcdc668d7c775e5bca2d43ac37e036468ca4d139a78fe48ae207d41411c5100"
buildozer_path="$(dirname $(mktemp -du))/buildozer.$buildozer_hash"
buildozer() {
    checksum="$buildozer_hash $buildozer_path"

    sha256sum -c --quiet <<<"$checksum" || {
        rm -f "$buildozer_path"
        curl -L "$buildozer_url" --output "$buildozer_path"

        sha256sum -c --quiet <<<"$checksum" || {
            printf '\e[31mchecksum does not match!\e[0m\n'
            exit 1
        }
    }

    chmod +x "$buildozer_path"
    (set -x; "$buildozer_path" "$@" 1>/dev/null 2>&1)
}

buildozer --version

rg -Io '"memory:[^"]*M"' | sort -u | sed 's#.*#remove tags &|//...:*#' | buildozer -f - || true

declare -A generator_peakrss

while IFS=, read peakrss _ target _; do
    test "${peakrss%MiB}" -lt "$THRESHOLD" && continue
    #peakrss="$((((${peakrss%MiB} / 1024) + 1) * 1024))MiB"  # Round up to nearest GiB
    generator_name="$(
        bazel query "$target" --output build 2>/dev/null |
        grep -Po '(?<=generator_name = ")[^"]+'
    )" || continue
    generator_label="${target%:*}:$generator_name"
    existing_peakrss="${generator_peakrss[$generator_label]:-0}"
    if [[ "${peakrss%MiB}" -gt "${existing_peakrss%MiB}" ]]; then
        generator_peakrss[$generator_label]="$peakrss"
    fi
done < <(tail -n+2 "$report_path")

for label in "${!generator_peakrss[@]}"; do
    printf "add tags 'memory:${generator_peakrss[$label]%iB}'|$label\n"
done | buildozer -f -
