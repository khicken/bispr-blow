#!/bin/bash
# Runs every engine on clips/*.wav one at a time, then scores. Sequential on purpose: two models
# sharing the GPU or Neural Engine make both look slow. Expect ~20 minutes for the whole set.
set -u
cd "$(dirname "$0")"
CLIPS=("${CLIPS_DIR:-clips}"/*.wav)
RES="${RESULTS_DIR:-results}"
[ -e "${CLIPS[0]}" ] || { echo "No clips. Run ./record.sh first."; exit 1; }
mkdir -p "$RES" logs

run() {
  local name=$1; shift
  echo "== $name"
  "$@" "${CLIPS[@]}" > "$RES/$name.jsonl" 2> "logs/$name.log" || echo "   FAILED, see logs/$name.log"
}

# Streaming engines report the streamed transcript and the wait after the last chunk separately.
stream_variant() {
  python3 - "$RES" "$1" "$2" <<'PY'
import json, sys
with open(f"{sys.argv[1]}/{sys.argv[3]}.jsonl", "w") as out:
    for line in open(f"{sys.argv[1]}/{sys.argv[2]}.jsonl"):
        r = json.loads(line)
        out.write(json.dumps({"file": r["file"], "text": r["stream_text"], "ms": r["tail_ms"]}) + "\n")
PY
}

FLUID=fluid/.build/release/fluid-runner
run apple                swift apple_transcribe.swift --vocab vocab.txt
run app                  ../../.build/release/BisprBlow --transcribe
for m in v2 v3 ultra phonon2; do
  run parakeet-$m        $FLUID --model $m
  run parakeet-$m-vocab  $FLUID --model $m --vocab vocab.txt
done
run parakeet-mlx-v2        .venv-mlx/bin/python run_mlx_parakeet_whisper.py --engine parakeet-mlx-v2
run parakeet-mlx-v2-vocab  .venv-mlx/bin/python run_mlx_parakeet_whisper.py --engine parakeet-mlx-v2 --vocab vocab.txt
run whisper-turbo          .venv-mlx/bin/python run_mlx_parakeet_whisper.py --engine whisper-turbo
run whisper-turbo-vocab    .venv-mlx/bin/python run_mlx_parakeet_whisper.py --engine whisper-turbo --vocab vocab.txt
for m in qwen3-asr-0.6b qwen3-asr-1.7b; do
  run $m                 .venv-mlxaudio/bin/python run_mlx_audio.py --engine $m
  run $m-vocab           .venv-mlxaudio/bin/python run_mlx_audio.py --engine $m --vocab vocab.txt
done
run nemotron             .venv-mlxaudio/bin/python run_mlx_audio.py --engine nemotron-stream
stream_variant nemotron nemotron-stream
run phonon-2.5           .venv-phonon/bin/python run_phonon.py
run phonon-2.5-vocab     .venv-phonon/bin/python run_phonon.py --vocab vocab.txt
run moonshine-medium       .venv-moonshine/bin/python run_moonshine.py
run moonshine-medium-vocab .venv-moonshine/bin/python run_moonshine.py --vocab vocab.txt
stream_variant moonshine-medium moonshine-medium-stream
stream_variant moonshine-medium-vocab moonshine-medium-stream-vocab
for m in unified ultra; do
  run handy-parakeet-$m       .venv-handy/bin/python run_handy.py --model $m
  run handy-parakeet-$m-vocab .venv-handy/bin/python run_handy.py --model $m --vocab vocab.txt
done
HF_HUB_OFFLINE=1 run granite-4.1-2b       .venv-granite/bin/python run_granite.py
HF_HUB_OFFLINE=1 run granite-4.1-2b-vocab .venv-granite/bin/python run_granite.py --vocab vocab.txt

RESULTS_DIR="$RES" python3 score.py | tee "$RES/summary.md"
