#!/bin/bash
# Records one 16 kHz mono WAV per line of prompts.txt into clips/. Press Enter to start, Enter to stop.
# Already-recorded clips are skipped, so it resumes. Delete clips/<id>.wav to redo one.
# List mics with: ffmpeg -f avfoundation -list_devices true -i ""   then: MIC=":2" ./record.sh
set -u
cd "$(dirname "$0")"
MIC="${MIC:-:default}"
mkdir -p clips
grep -v '^#' prompts.txt | grep -v '^$' | while IFS='|' read -r id text; do
  [ -f "clips/$id.wav" ] && continue
  while true; do
    printf '\n\033[1m%s\033[0m\n  %s\n\nEnter to start...' "$id" "$text"
    read -r </dev/tty
    ffmpeg -loglevel error -f avfoundation -i "$MIC" -ar 16000 -ac 1 -y "clips/$id.wav" </dev/null &
    pid=$!
    printf '  RECORDING. Enter to stop.'
    read -r </dev/tty
    kill -INT "$pid"; wait "$pid" 2>/dev/null
    printf '  saved. [Enter] next, [r] redo: '
    read -r answer </dev/tty
    [[ "$answer" == [rR]* ]] || break
  done
done
echo "Done: $(ls clips/*.wav 2>/dev/null | wc -l | tr -d ' ') clips."
