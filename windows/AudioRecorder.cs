using System.Globalization;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace BisprBlow;

// Mic capture through WASAPI shared mode. Streams interleaved float32 buffers to a consumer and
// publishes a level (0...1) for the waveform UI. Shared mode hands over the device's own mix format
// (rate and channel count vary per mic), so every buffer carries its format and nothing downstream
// may assume one. A denied privacy switch is not an error here, it is silence: see Permissions.
public sealed class AudioRecorder
{
    // An empty `id` means the system default capture endpoint, so a selection that has since been
    // unplugged falls back to it rather than failing.
    static MMDevice? Device(string id, MMDeviceEnumerator enumerator)
    {
        if (id.Length > 0)
        {
            try { return enumerator.GetDevice(id); }
            catch (Exception) { /* unplugged or renamed: use the default */ }
        }
        return enumerator.TryGetDefaultAudioEndpoint(DataFlow.Capture, Role.Console, out var device) ? device : null;
    }

    // Name of the device actually being recorded from: the selection if it exists, otherwise the
    // system default, which is a different device whenever a selection is in force.
    public static string CurrentInputDeviceName()
    {
        using var enumerator = new MMDeviceEnumerator();
        return Device(AppSettings.Shared.InputDeviceID, enumerator)?.FriendlyName ?? "";
    }

    // Selectable input devices; `Id` is the WASAPI endpoint id that `AppSettings.InputDeviceID` stores.
    public static IReadOnlyList<(string Id, string Name)> InputDevices()
    {
        using var enumerator = new MMDeviceEnumerator();
        return enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active)
            .Select(d => (d.ID, d.FriendlyName)).ToList();
    }

    // Some apps turn the endpoint volume down and never put it back, and a quiet capture comes back
    // as confident wrong words (measured on the Mac: 14/100 gain, -40 to -63 dBFS). Behind
    // `AppSettings.RestoreMicVolume`, off by default, and only ever raises.
    static void RestoreInputVolume(MMDevice device)
    {
        const float floor = 0.75f;
        var volume = device.AudioEndpointVolume;
        var was = volume.MasterVolumeLevelScalar;
        if (was >= floor) return;
        volume.MasterVolumeLevelScalar = floor;
        Log.Line($"audio input volume raised {(int)(was * 100)}% → {(int)(floor * 100)}%");
    }

    // How long the capture keeps running after a dictation ends. Opening a WASAPI stream is most of
    // the gap between the pill saying "recording" and the mic capturing. Not forever: a running
    // stream holds the mic, and Windows keeps its microphone-in-use icon lit for exactly as long.
    static readonly TimeSpan WarmWindow = TimeSpan.FromSeconds(30);

    public Action<float>? OnLevel;
    public Action<float[], int, int>? OnBuffer;

    // `gate` guards the capture and the warm state, `signal` the accumulators. Two locks because
    // the capture thread only ever needs the second, and `Stop` must not wait on it while holding
    // the first.
    readonly object gate = new();
    readonly object signal = new();
    WasapiCapture? capture;
    string? warmDeviceId;
    Timer? coolDown;
    volatile bool running;

    // Signal quality for the dictation in progress. Accumulated where the samples exist: nothing
    // downstream can recover gain or clipping from a transcript.
    long frames;
    double sumSquares;
    float peak;
    int clipped;
    int rate, channels;

    // Frames captured during the dictation that just ended. Zero means the words went nowhere, and
    // the caller must not go on to finalise a recognizer that was never fed.
    public long CapturedFrames { get { lock (signal) return frames; } }

    // Called as a dictation begins, so a release before `Start()` runs reads zero, not the last count.
    public void ResetCapturedFrames() { lock (signal) frames = 0; }

    public void Start()
    {
        lock (gate)
        {
            if (running) return;
            coolDown?.Dispose();
            coolDown = null;

            using var enumerator = new MMDeviceEnumerator();
            var device = Device(AppSettings.Shared.InputDeviceID, enumerator)
                ?? throw new InvalidOperationException("no input device available");
            if (AppSettings.Shared.RestoreMicVolume)
            {
                // Endpoints without volume control throw here; the device still opens without it.
                try { RestoreInputVolume(device); }
                catch (Exception e) { Log.Line($"audio input volume not restored: {e.Message}"); }
            }

            if (warmDeviceId != device.ID) Teardown();
            if (capture == null)
            {
                try
                {
                    capture = new WasapiCapture(device, true, 25);
                    capture.DataAvailable += OnData;
                    // The mic yanked mid-warm, or a format change under us: drop the warm capture so
                    // the next dictation rebuilds from scratch.
                    capture.RecordingStopped += (sender, e) =>
                    {
                        if (e.Exception != null) Log.Line($"audio capture stopped: {e.Exception.Message}");
                        // Off this thread: Teardown stops the capture, which can be waiting on it.
                        Task.Run(() =>
                        {
                            lock (gate) { if (ReferenceEquals(sender, capture)) { running = false; Teardown(); } }
                        });
                    };
                }
                catch (Exception e)
                {
                    Log.Line($"audio device open failed: {e.Message}");
                    Teardown();
                    throw new InvalidOperationException("the input device could not be opened", e);
                }
            }

            lock (signal)
            {
                frames = 0;
                sumSquares = 0;
                peak = 0;
                clipped = 0;
                rate = channels = 0;
            }

            // `running` gates delivery, so it is true before the first buffer can arrive: a warm
            // capture is already producing them and they are dropped on the floor until here.
            running = true;
            if (warmDeviceId == null)
            {
                try { capture.StartRecording(); }
                catch (Exception e)
                {
                    Log.Line($"audio device open failed: {e.Message}");
                    running = false;
                    Teardown();
                    throw new InvalidOperationException("the input device could not be opened", e);
                }
            }
            warmDeviceId = device.ID;
        }
    }

    // Ends capture but leaves the stream warm (see `WarmWindow`). `running` is what stops audio
    // reaching the consumer, so nothing is captured in the meantime.
    public void Stop()
    {
        lock (gate)
        {
            if (!running) return;
            running = false;
            // Let any in-flight buffer finish before the accumulators are read.
            lock (signal) { }
            LogSignal();
            coolDown = new Timer(_ =>
            {
                lock (gate) { if (!running) Teardown(); }
            }, null, WarmWindow, Timeout.InfiniteTimeSpan);
        }
    }

    void Teardown()
    {
        var old = capture;
        capture = null;
        warmDeviceId = null;
        if (old == null) return;
        try { old.StopRecording(); } catch (Exception) { }
        old.Dispose();
    }

    void OnData(object? sender, WaveInEventArgs e)
    {
        if (!running || e.BytesRecorded == 0 || sender is not WasapiCapture source) return;
        var format = source.WaveFormat;
        var samples = Floats(e.Buffer, e.BytesRecorded, format);
        if (samples == null) return;
        var level = Measure(samples, format.SampleRate, format.Channels);
        OnBuffer?.Invoke(samples, format.SampleRate, format.Channels);
        OnLevel?.Invoke(level);
    }

    // Shared mode delivers the mix format, which is float32 on nearly every device and PCM16/24/32
    // on the rest. Anything else reads as silence rather than noise.
    static float[]? Floats(byte[] data, int count, WaveFormat format)
    {
        var bits = format.BitsPerSample;
        var isFloat = format.Encoding == WaveFormatEncoding.IeeeFloat
            || (format is WaveFormatExtensible x && x.SubFormat == AudioMediaSubtypes.MEDIASUBTYPE_IEEE_FLOAT);
        if (isFloat && bits == 32)
        {
            var floats = new float[count / 4];
            Buffer.BlockCopy(data, 0, floats, 0, floats.Length * 4);
            return floats;
        }
        var step = bits / 8;
        if (step is < 2 or > 4) return null;
        var output = new float[count / step];
        for (var i = 0; i < output.Length; i++)
        {
            var at = i * step;
            output[i] = step switch
            {
                2 => BitConverter.ToInt16(data, at) / 32768f,
                3 => ((data[at] << 8 | data[at + 1] << 16 | data[at + 2] << 24) >> 8) / 8388608f,
                _ => BitConverter.ToInt32(data, at) / 2147483648f,
            };
        }
        return output;
    }

    // RMS level for the waveform, folded together with the per-dictation quality accumulators so the
    // samples are walked once. Channel 0 only, as the recognizer reads it.
    float Measure(float[] samples, int sampleRate, int channelCount)
    {
        var n = samples.Length / channelCount;
        if (n == 0) return 0;
        float sum = 0, localPeak = 0;
        var localClipped = 0;
        for (var i = 0; i < n; i++)
        {
            var s = samples[i * channelCount];
            sum += s * s;
            var mag = MathF.Abs(s);
            if (mag > localPeak) localPeak = mag;
            if (mag >= 0.999f) localClipped++;
        }
        lock (signal)
        {
            frames += n;
            sumSquares += sum;
            if (localPeak > peak) peak = localPeak;
            clipped += localClipped;
            rate = sampleRate;
            channels = channelCount;
        }
        // Map typical speech RMS (~0.005–0.2) onto 0...1; steeper curve = livelier bars.
        return Math.Clamp(MathF.Pow(MathF.Sqrt(sum / n) * 26, 0.6f), 0, 1);
    }

    // One line per dictation. A weak or clipped signal comes back as confident wrong words, not as
    // silence, so it is indistinguishable from a model problem without this. Speech wants roughly
    // -30 to -12 dBFS mean; under about -45 is a gain problem no model work will fix.
    void LogSignal()
    {
        lock (signal)
        {
            if (frames == 0) { Log.Line("audio no frames captured"); return; }
            string Db(double x) => x > 0 ? (20 * Math.Log10(x)).ToString("F1", CultureInfo.InvariantCulture) : "-inf";
            var rms = Math.Sqrt(sumSquares / frames);
            Log.Line($"audio {rate}Hz/{channels}ch secs={(frames / (double)rate).ToString("F1", CultureInfo.InvariantCulture)} "
                     + $"rms={Db(rms)}dBFS peak={Db(peak)}dBFS clipped={clipped}");
        }
    }

    // A WAV file as the recorder would have delivered it, for the `--transcribe` seam.
    public static (float[] Samples, int Rate, int Channels) ReadWav(string path)
    {
        using var reader = new WaveFileReader(path);
        var provider = reader.ToSampleProvider();
        var all = new List<float>();
        var chunk = new float[provider.WaveFormat.SampleRate * provider.WaveFormat.Channels];
        for (int read; (read = provider.Read(chunk)) > 0;) all.AddRange(chunk.AsSpan(0, read).ToArray());
        return (all.ToArray(), provider.WaveFormat.SampleRate, provider.WaveFormat.Channels);
    }
}
