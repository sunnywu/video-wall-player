#!/usr/bin/env bash
#
# Verify the repository whitespace rule for human-maintained source files.
#
set -euo pipefail

files=(
    AGENTS.md
    Info.plist
    run.sh
    scripts/check_whitespace.sh
    scripts/package_app.sh
    sixplayer.m
)

LC_ALL=C awk '
    /\t/ {
        printf "%s:%d contains a tab\n", FILENAME, FNR > "/dev/stderr"
        status = 1
    }

    /[^ -~]/ {
        printf "%s:%d contains non-ASCII or hidden characters\n", FILENAME, FNR > "/dev/stderr"
        status = 1
    }

    {
        match($0, /^ +/)
        if (RLENGTH > 0 && RLENGTH % 4 != 0) {
            printf "%s:%d has %d leading spaces; use a multiple of 4\n", FILENAME, FNR, RLENGTH > "/dev/stderr"
            status = 1
        }
    }

    END {
        exit status
    }
' "${files[@]}"
