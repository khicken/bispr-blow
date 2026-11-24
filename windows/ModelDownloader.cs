using System.IO;
using System.Net.Http;
using System.Text.Json;

namespace BisprBlow;

// Fetches the weights a fresh machine needs: both cleanup models and the speech model, none of which
// ship in the zip (about 1.3 GB between them).
//
// Staging is a dot-prefixed directory because `LocalEngine.InstalledModels` skips dot-prefixed
// entries: a partly-written model stays invisible to the scanner, so llama.cpp can never be handed a
// truncated GGUF. Each file is size-checked against the Hugging Face listing before it is moved into
// place.
public static class ModelDownloader
{
    public record Item(string Name, string Repo, string[] Files, long SizeBytes, string Directory);

    // Q8_0, not Q4_K_M: GGUF Q4 lost quality on the bench (77% against 78-81% for Q8_0; see CLAUDE.md).
    // Fast and Accurate are the same two Qwen3 sizes the Mac runs.
    public static readonly Item Fast = new("Qwen3-0.6B-Q8_0", "Qwen/Qwen3-0.6B-GGUF",
        ["Qwen3-0.6B-Q8_0.gguf"], 639_446_688, AppPaths.Models);
    public static readonly Item Accurate = new("Qwen3-1.7B-Q8_0", "Qwen/Qwen3-1.7B-GGUF",
        ["Qwen3-1.7B-Q8_0.gguf"], 1_834_426_016, AppPaths.Models);
    // Parakeet TDT 0.6b v2, int8, in the layout sherpa-onnx's transducer config reads.
    public static readonly Item Speech = new("parakeet-tdt-0.6b-v2-int8",
        "csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8",
        ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"],
        661_288_526, Path.Combine(AppPaths.Models, "parakeet-tdt-0.6b-v2-int8"));

    static readonly HttpClient Http = new() { Timeout = Timeout.InfiniteTimeSpan };

    // A model hand-placed in any scanned root counts for the cleanup ones; the speech one has no such
    // second home, so only its own files do.
    public static bool IsInstalled(Item item) =>
        item.Files.All(f => File.Exists(Path.Combine(item.Directory, f)))
        || LocalEngine.InstalledModels().Any(m => m.Id.Equals(item.Name, StringComparison.OrdinalIgnoreCase));

    public static async Task DownloadAsync(Item item, IProgress<double>? progress = null,
                                           CancellationToken ct = default)
    {
        var staging = Path.Combine(AppPaths.Models, $".incoming-{item.Name}");
        try
        {
            if (Directory.Exists(staging)) Directory.Delete(staging, true);
            Directory.CreateDirectory(staging);

            var listing = await ListingAsync(item.Repo, ct);
            var sizes = item.Files.Select(f => listing.TryGetValue(f, out var size)
                ? size : throw new InvalidOperationException("Could not reach the model download.")).ToArray();
            var total = sizes.Sum();
            long carried = 0;
            for (var i = 0; i < item.Files.Length; i++)
            {
                var name = item.Files[i];
                var written = await FetchAsync($"https://huggingface.co/{item.Repo}/resolve/main/{name}",
                    Path.Combine(staging, name), got => progress?.Report((double)(carried + got) / Math.Max(total, 1)), ct);
                // The truncation CLAUDE.md warns is invisible until first dictation, caught here instead.
                if (written != sizes[i])
                    throw new InvalidOperationException($"{name} arrived short ({written} of {sizes[i]} bytes).");
                carried += written;
            }

            ct.ThrowIfCancellationRequested();
            Directory.CreateDirectory(item.Directory);
            foreach (var name in item.Files)
                File.Move(Path.Combine(staging, name), Path.Combine(item.Directory, name), overwrite: true);
            progress?.Report(1);
        }
        finally
        {
            try { Directory.Delete(staging, true); } catch (IOException) { }
        }
    }

    // `--download-fast`, `-accurate` and `-speech`: the real downloader with progress on stdout, because
    // the path is load-bearing and was otherwise only ever read.
    public static async Task<int> DownloadCliAsync(Item item)
    {
        Console.WriteLine($"downloading {item.Name}…");
        var next = 0;
        try
        {
            await DownloadAsync(item, new Inline(fraction =>
            {
                var percent = (int)(fraction * 100);
                if (percent < next) return;
                next = percent + 5;
                Console.WriteLine($"{percent}%");
            }));
            Console.WriteLine("done");
            return 0;
        }
        catch (Exception e)
        {
            Console.WriteLine($"failed: {e.Message}");
            return 1;
        }
    }

    // `Progress<T>` posts to the thread pool, so lines could print after "done".
    sealed class Inline(Action<double> report) : IProgress<double>
    {
        public void Report(double value) => report(value);
    }

    // path → size for the repo's top level, from the same listing the web page shows.
    static async Task<Dictionary<string, long>> ListingAsync(string repo, CancellationToken ct)
    {
        using var response = await Http.GetAsync($"https://huggingface.co/api/models/{repo}/tree/main", ct);
        if (!response.IsSuccessStatusCode) throw new InvalidOperationException("Could not reach the model download.");
        using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync(ct));
        return json.RootElement.EnumerateArray()
            .Where(e => e.GetProperty("type").GetString() == "file")
            .ToDictionary(e => e.GetProperty("path").GetString()!, e => e.GetProperty("size").GetInt64());
    }

    // One file to one path, reporting bytes as they land.
    static async Task<long> FetchAsync(string url, string path, Action<long> progress, CancellationToken ct)
    {
        using var response = await Http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct);
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"The download failed (HTTP {(int)response.StatusCode}).");
        await using var source = await response.Content.ReadAsStreamAsync(ct);
        await using var target = File.Create(path);
        var buffer = new byte[1 << 20];
        long got = 0;
        int read;
        while ((read = await source.ReadAsync(buffer, ct)) > 0)
        {
            await target.WriteAsync(buffer.AsMemory(0, read), ct);
            got += read;
            progress(got);
        }
        return got;
    }
}
