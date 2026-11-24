using System.Diagnostics;
using System.IO;
using NAudio.Dsp;
using SherpaOnnx;

namespace BisprBlow;

// NVIDIA Parakeet TDT 0.6b v2 (int8) through sherpa-onnx on the CPU. Why Parakeet and not another
// engine: CLAUDE.md, Speech recognition rules.
//
// Dictionary biasing is left out. Hotwords do work on this model (modified_beam_search, terms
// hand-tokenized into tokens.txt pieces, since there is no BPE model to encode them), and fixed
// "Versal" → "Vercel" in a test, but beam search took an 11 s clip from 0.5 s to 7.5 s after release.
// No CTC log-probs exist for a rescorer either. The dictionary reaches the text downstream
// instead, in `LLMCleaner.ApplyVocabulary` with each term's heard-as.
public sealed class Parakeet
{
    public static readonly Parakeet Shared = new();

    readonly object gate = new();
    OfflineRecognizer? recognizer;
    Task? loading;

    public bool IsReady => recognizer != null;

    // Loads the model off the UI thread. The weights are fetched by `ModelDownloader`; until they are
    // there this logs and returns, and `Transcriber` reports that Parakeet is not ready.
    public Task LoadAsync()
    {
        lock (gate) return loading ??= Task.Run(Load);
    }

    void Load()
    {
        try
        {
            var start = Stopwatch.GetTimestamp();
            var dir = ModelDownloader.Speech.Directory;
            var config = new OfflineRecognizerConfig();
            config.ModelConfig.Transducer.Encoder = Path.Combine(dir, "encoder.int8.onnx");
            config.ModelConfig.Transducer.Decoder = Path.Combine(dir, "decoder.int8.onnx");
            config.ModelConfig.Transducer.Joiner = Path.Combine(dir, "joiner.int8.onnx");
            config.ModelConfig.Tokens = Path.Combine(dir, "tokens.txt");
            config.ModelConfig.ModelType = "nemo_transducer";
            config.ModelConfig.NumThreads = Math.Clamp(Environment.ProcessorCount / 2, 2, 8);
            config.DecodingMethod = "greedy_search";
            var loaded = new OfflineRecognizer(config);
            lock (gate) recognizer = loaded;
            // The first decode pays for its own setup; a second of silence keeps that off the first
            // real dictation.
            Transcribe(new float[16_000]);
            Log.Line($"parakeet ready in {(int)Stopwatch.GetElapsedTime(start).TotalMilliseconds}ms");
        }
        catch (Exception e)
        {
            Log.Line($"parakeet unavailable: {e.Message}");
            lock (gate) { recognizer = null; loading = null; }
        }
    }

    // `samples` is 16kHz mono. Null is a failure; the words are lost, so the caller has to say so.
    public string? Transcribe(float[] samples)
    {
        if (recognizer is not { } r) return null;
        try
        {
            // One decode at a time: the recognizer is shared and a dictation never overlaps another.
            lock (gate)
            {
                using var stream = r.CreateStream();
                stream.AcceptWaveform(16_000, samples);
                r.Decode(stream);
                return stream.Result.Text.Trim();
            }
        }
        catch (Exception e)
        {
            Log.Line($"parakeet transcribe failed: {e.Message}");
            return null;
        }
    }
}

// The part of a Parakeet dictation that can run before release, run during speech: the resample to
// 16kHz, through one resampler per dictation that carries its filter state across buffers (one per
// buffer restarts the filter at every boundary). Release then only runs recognition. `Append` runs
// on the capture thread.
sealed class ParakeetStream
{
    readonly object gate = new();
    readonly List<float> audio = [];
    WdlResampler? resampler;
    int rate;
    bool failed;

    // Channel 0 only, as `AudioRecorder.Measure` does. A new sample rate (a device change
    // mid-dictation) starts another resampler, so no audio is resampled as if it were at the other rate.
    public void Append(float[] samples, int sampleRate, int channels)
    {
        lock (gate)
        {
            if (failed || samples.Length == 0) return;
            var frames = samples.Length / channels;
            if (sampleRate != rate)
            {
                rate = sampleRate;
                resampler = null;
                if (rate != 16_000)
                {
                    resampler = new WdlResampler();
                    resampler.SetMode(true, 2, false);
                    resampler.SetFilterParms();
                    resampler.SetFeedMode(true);
                    resampler.SetRates(rate, 16_000);
                }
            }
            var mono = frames == samples.Length ? samples : new float[frames];
            if (mono != samples) for (var i = 0; i < frames; i++) mono[i] = samples[i * channels];

            if (resampler == null) { audio.AddRange(mono); return; }
            try
            {
                var wanted = resampler.ResamplePrepare(frames, 1, out var input);
                mono.AsSpan(0, Math.Min(wanted, frames)).CopyTo(input);
                var output = new float[(int)((long)frames * 16_000 / rate) + 64];
                var produced = resampler.ResampleOut(output, wanted, output.Length, 1);
                audio.AddRange(output.AsSpan(0, produced).ToArray());
            }
            catch (Exception e)
            {
                Log.Line($"parakeet resample failed: {e.Message}");
                failed = true;
            }
        }
    }

    // The 16kHz audio. Null when resampling failed.
    public float[]? Finish()
    {
        lock (gate) return failed ? null : audio.ToArray();
    }
}
