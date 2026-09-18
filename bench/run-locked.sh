#!/bin/bash
# One bench run at a time. Five prompt variants are measured in parallel by five agents on one
# laptop, and two MLX models resident at once is what takes the machine down. `mkdir` is the lock
# because it is atomic on every filesystem and `flock` is not on macOS.
LOCK="${TMPDIR:-/tmp}/bispr-bench.lock"
for _ in $(seq 1 900); do
  if mkdir "$LOCK" 2>/dev/null; then
    trap 'rmdir "$LOCK" 2>/dev/null' EXIT
    python3 "$(dirname "$0")/bench.py" "$@"
    exit $?
  fi
  sleep 4
done
echo "gave up waiting for $LOCK after an hour" >&2
exit 1
