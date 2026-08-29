#!/bin/bash
# Shared, monotonic CFBundleVersion mapping for public releases.

hypervibe_build_number() {
    local release_version="$1"
    if [ -n "${HYPERVIBE_BUILD_NUMBER:-}" ]; then
        [[ "$HYPERVIBE_BUILD_NUMBER" =~ ^[0-9]+$ ]] || {
            echo "invalid HYPERVIBE_BUILD_NUMBER: $HYPERVIBE_BUILD_NUMBER" >&2
            return 2
        }
        echo "$HYPERVIBE_BUILD_NUMBER"
        return 0
    fi

    [[ "$release_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-(alpha|beta|rc)\.([0-9]+))?$ ]] || {
        echo "release version must be X.Y.Z or X.Y.Z-(alpha|beta|rc).N: $release_version" >&2
        return 2
    }

    local major="${BASH_REMATCH[1]}"
    local minor="${BASH_REMATCH[2]}"
    local patch="${BASH_REMATCH[3]}"
    local kind="${BASH_REMATCH[5]:-stable}"
    local serial="${BASH_REMATCH[6]:-0}"
    local stage
    if [ "$minor" -gt 99 ] || [ "$patch" -gt 99 ]; then
        echo "minor and patch components must be <= 99 for monotonic build mapping: $release_version" >&2
        return 2
    fi
    case "$kind" in
        alpha)  stage=1 ;;
        beta)   stage=2 ;;
        rc)     stage=3 ;;
        stable) stage=9 ;;
    esac
    if [ "$serial" -gt 999 ]; then
        echo "prerelease serial must be <= 999: $release_version" >&2
        return 2
    fi

    # A stable X.Y.Z is newer than every prerelease of the same core version, while the next patch
    # starts above it. Example: 0.2.0-beta.6 → 2002006; 0.2.0 → 2009000.
    echo $((10#$major * 100000000 + 10#$minor * 1000000 + 10#$patch * 10000 \
        + stage * 1000 + 10#$serial))
}
