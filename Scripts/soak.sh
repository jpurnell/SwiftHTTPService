#!/bin/sh
# Scripts/soak.sh [SECONDS]
#
# Runs the soak test for SECONDS (default 60): many connections that open, are abused (a head dribbled and dropped, a
# body cut off, a streaming response abandoned, a half-close, malformed bytes, a stalled reader, an HTTP/2 stream
# abandoned) and close, against a plaintext and a TLS server in this process. At a quiet point after every cycle it
# samples the process's resident memory and open descriptors, and fails if either grows past the limits stated in
# Tests/SwiftHTTPServiceNIOTests/SoakTests.swift after the first three cycles (warm-up).
#
# The samples are printed as RIG-MEASURE lines. For days, not a minute, run it with a large SECONDS under nohup.
set -eu
cd "$(git rev-parse --show-toplevel)"
SECONDS_TO_RUN="${1:-60}"
case "$SECONDS_TO_RUN" in ''|*[!0-9]*) echo "usage: $0 [seconds]" >&2; exit 2 ;; esac
SOAK_SECONDS="$SECONDS_TO_RUN" swift test --filter SoakTests 2>&1 | grep -E "RIG-MEASURE|error:|passed|failed|Expectation|✘"
