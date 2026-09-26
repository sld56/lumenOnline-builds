using System;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Collections.Generic;

namespace LumenDistribution
{
    public sealed class FileRecord
    {
        public string path;
        public long length;
        public string sha256;
        public string[] blocks;
    }

    // Shared by the publisher and Windows PowerShell 5.1 launcher. No Unity dependency.
    public static class BlockTransfer
    {
        public const int BlockSize = 4 * 1024 * 1024;
        public static long DownloadedBytes;
        public static long ReusedBytes;
        public static string GitHubToken;
        public static void Commit(string temporary, string destination)
        { if (File.Exists(destination)) File.Replace(temporary, destination, null); else File.Move(temporary, destination); }
        static string Hex(byte[] bytes) { return BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant(); }
        static string Digest(byte[] bytes, int count)
        { using (var sha = SHA256.Create()) return Hex(sha.ComputeHash(bytes, 0, count)); }
        public static string Hash(string path)
        { using (var sha = SHA256.Create()) using (var file = File.OpenRead(path)) return Hex(sha.ComputeHash(file)); }
        static int Read(Stream stream, byte[] buffer, int count)
        {
            int total = 0, n;
            while (total < count && (n = stream.Read(buffer, total, count - total)) > 0) total += n;
            return total;
        }
        public static FileRecord Publish(string path, string relative, string feed)
        {
            var record = new FileRecord { path = relative };
            var hashes = new List<string>();
            var buffer = new byte[BlockSize];
            using (var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (var sha = SHA256.Create())
            {
                record.length = input.Length;
                int count;
                while ((count = Read(input, buffer, buffer.Length)) > 0)
                {
                    sha.TransformBlock(buffer, 0, count, buffer, 0);
                    string hash = Digest(buffer, count);
                    hashes.Add(hash);
                    string output = Path.Combine(feed, "chunks", hash.Substring(0, 2), hash + ".bin");
                    Directory.CreateDirectory(Path.GetDirectoryName(output));
                    if (!File.Exists(output) || new FileInfo(output).Length != count || Hash(output) != hash)
                    {
                        string temp = output + "." + Guid.NewGuid().ToString("N") + ".tmp";
                        try
                        {
                            using (var file = File.Create(temp)) file.Write(buffer, 0, count);
                            if (File.Exists(output)) File.Replace(temp, output, null); else File.Move(temp, output);
                        }
                        finally { if (File.Exists(temp)) File.Delete(temp); }
                    }
                }
                sha.TransformFinalBlock(new byte[0], 0, 0);
                record.sha256 = Hex(sha.Hash);
            }
            record.blocks = hashes.ToArray();
            return record;
        }

        public static byte[] Fetch(string source, string relative, int maximum)
        {
            byte[] data;
            if (source.StartsWith("https://", StringComparison.OrdinalIgnoreCase) || source.StartsWith("http://", StringComparison.OrdinalIgnoreCase))
            {
                var request = (HttpWebRequest)WebRequest.Create(source.TrimEnd('/') + "/" + relative);
                request.Timeout = 60000;
                request.ReadWriteTimeout = 60000;
                request.AutomaticDecompression = DecompressionMethods.None;
                request.UserAgent = "LumenOnline-Launcher/1";
                if (request.RequestUri.Host.Equals("api.github.com", StringComparison.OrdinalIgnoreCase))
                {
                    request.Accept = "application/vnd.github.raw+json";
                    request.Headers["X-GitHub-Api-Version"] = "2022-11-28";
                    if (!String.IsNullOrEmpty(GitHubToken)) request.Headers["Authorization"] = "Bearer " + GitHubToken;
                }
                request.CachePolicy = new System.Net.Cache.RequestCachePolicy(System.Net.Cache.RequestCacheLevel.NoCacheNoStore);
                using (var response = request.GetResponse())
                using (var input = response.GetResponseStream()) data = BoundedRead(input, maximum);
            }
            else
            {
                using (var input = File.OpenRead(Path.Combine(source, relative.Replace('/', Path.DirectorySeparatorChar))))
                    data = BoundedRead(input, maximum);
            }
            return data;
        }
        static byte[] BoundedRead(Stream input, int maximum)
        {
            using (var output = new MemoryStream())
            {
                byte[] buffer = new byte[65536];
                int count;
                while ((count = input.Read(buffer, 0, buffer.Length)) > 0)
                {
                    if (output.Length + count > maximum) throw new IOException("Download exceeds its expected size.");
                    output.Write(buffer, 0, count);
                }
                return output.ToArray();
            }
        }

        public static void Stage(FileRecord record, string installed, string staging, string source)
        {
            if (File.Exists(staging) && new FileInfo(staging).Length == record.length && Hash(staging) == record.sha256)
            { ReusedBytes += record.length; return; }
            Directory.CreateDirectory(Path.GetDirectoryName(staging));
            string partial = staging + "." + Guid.NewGuid().ToString("N") + ".partial";
            try
            {
            using (var old = File.Exists(installed) ? File.OpenRead(installed) : null)
            using (var output = new FileStream(partial, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                var buffer = new byte[BlockSize];
                long offset = 0;
                foreach (string hash in record.blocks)
                {
                    int size = (int)Math.Min(BlockSize, record.length - offset);
                    bool reused = false;
                    if (old != null && old.Length >= offset + size)
                    {
                        old.Position = offset;
                        reused = Read(old, buffer, size) == size && Digest(buffer, size) == hash;
                    }
                    if (reused) ReusedBytes += size;
                    else
                    {
                        byte[] download = null;
                        for (int attempt = 0; ; attempt++)
                        {
                            try
                            {
                                download = Fetch(source, "chunks/" + hash.Substring(0, 2) + "/" + hash + ".bin", size);
                                if (download.Length != size || Digest(download, download.Length) != hash)
                                    throw new IOException("Downloaded block failed SHA-256 verification: " + hash);
                                break;
                            }
                            catch (WebException) { if (attempt >= 2) throw; }
                        }
                        Buffer.BlockCopy(download, 0, buffer, 0, size);
                        DownloadedBytes += size;
                    }
                    output.Write(buffer, 0, size);
                    offset += size;
                }
            }
            if (new FileInfo(partial).Length != record.length || Hash(partial) != record.sha256)
                throw new IOException("File failed SHA-256 verification: " + record.path);
            if (File.Exists(staging)) File.Replace(partial, staging, null); else File.Move(partial, staging);
            }
            finally { if (File.Exists(partial)) File.Delete(partial); }
        }
    }
}
