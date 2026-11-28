// SPDX-License-Identifier: GPL-3.0-or-later
// Windows image worker. Builds with the in-box .NET Framework compiler and WIC.
using System;
using System.Diagnostics;
using System.IO;
using System.IO.MemoryMappedFiles;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.System32)]

internal static class NeoGitImage
{
    const int MaxWidth = 1200, MaxHeight = 900;

    static void CheckSize(int w, int h)
    {
        if (w <= 0 || h <= 0 || w > 300000 || h > 300000 || (long)w * h > 80000000)
            throw new InvalidDataException("Canvas exceeds the 80 megapixel preview limit");
    }

    static long Number(BinaryReader r, int bytes)
    {
        long n = 0;
        while (bytes-- > 0) n = checked(n * 256 + r.ReadByte());
        return n;
    }

    static void Skip(BinaryReader r, long bytes)
    {
        if (bytes > r.BaseStream.Length - r.BaseStream.Position) throw new EndOfStreamException();
        r.BaseStream.Seek(bytes, SeekOrigin.Current);
    }

    static void ReadExactly(BinaryReader r, byte[] buffer, int count)
    {
        int pos = 0;
        while (pos < count)
        {
            int n = r.Read(buffer, pos, count - pos);
            if (n == 0) throw new EndOfStreamException();
            pos += n;
        }
    }

    // Adobe Photoshop File Formats Specification, Image Data Section:
    // https://www.adobe.com/devnet-apps/photoshop/fileformatashtml/
    // Seek past layers and read the saved RGB composite.
    // Other color models and compression types use the fallback decoder.
    static BitmapSource Photoshop(BinaryReader r)
    {
        int version = (int)Number(r, 2);
        if (version != 1 && version != 2) throw new InvalidDataException("Unknown Photoshop version");
        Skip(r, 6);
        int channels = (int)Number(r, 2);
        int h = checked((int)Number(r, 4)), w = checked((int)Number(r, 4));
        CheckSize(w, h);
        if ((channels != 3 && channels != 4) || Number(r, 2) != 8 || Number(r, 2) != 3)
            throw new NotSupportedException("This Photoshop color format needs ImageMagick");
        Skip(r, Number(r, 4)); // Color mode data.
        long resourceLength = Number(r, 4);
        long resourceEnd = checked(r.BaseStream.Position + resourceLength);
        if (resourceEnd > r.BaseStream.Length) throw new EndOfStreamException();
        byte[] profile = null;
        while (r.BaseStream.Position < resourceEnd)
        {
            if (Number(r, 4) != 0x3842494d) throw new InvalidDataException("Unknown Photoshop resource");
            int id = (int)Number(r, 2), name = r.ReadByte();
            Skip(r, name + ((name + 1) & 1));
            long size = Number(r, 4);
            if (size > resourceEnd - r.BaseStream.Position) throw new EndOfStreamException();
            if (id == 1039 && size > 0)
            {
                if (size > 4 * 1024 * 1024) throw new InvalidDataException("Oversized ICC profile");
                profile = new byte[(int)size];
                ReadExactly(r, profile, profile.Length);
            }
            else if (id == 1057 && size >= 5)
            {
                Skip(r, 4);
                if (r.ReadByte() == 0) throw new NotSupportedException("No saved Photoshop composite");
                Skip(r, size - 5);
            }
            else Skip(r, size);
            Skip(r, size & 1);
        }
        int lengthBytes = version == 2 ? 8 : 4;
        long layers = Number(r, lengthBytes), layerStart = r.BaseStream.Position;
        if (channels == 4)
        {
            // A negative layer count identifies merged transparency. Other extra
            // channels may be spot colors and must not be interpreted as opacity.
            if (layers < lengthBytes + 2 || Number(r, lengthBytes) < 2 || (short)Number(r, 2) >= 0)
                throw new NotSupportedException("This Photoshop extra channel needs ImageMagick");
        }
        Skip(r, layers - (r.BaseStream.Position - layerStart));
        int compression = (int)Number(r, 2);
        if (compression > 1) throw new NotSupportedException("This Photoshop compression needs ImageMagick");
        var lengths = new int[compression == 1 ? h * channels : 0];
        for (int i = 0; i < lengths.Length; i++) lengths[i] = checked((int)Number(r, version == 2 ? 4 : 2));
        var rgb = new byte[w * h * channels];
        var row = new byte[w];
        var packed = new byte[w * 2 + 128];
        for (int ch = 0; ch < channels; ch++)
        for (int y = 0; y < h; y++)
        {
            if (compression == 0) ReadExactly(r, row, w);
            else
            {
                int size = lengths[ch * h + y];
                if (size > packed.Length) throw new InvalidDataException("Invalid Photoshop row length");
                ReadExactly(r, packed, size);
                int dst = 0;
                for (int src = 0; src < size;)
                {
                    int cmd = (sbyte)packed[src++];
                    if (cmd == -128) continue;
                    int n = cmd >= 0 ? cmd + 1 : 1 - cmd;
                    if (n > w - dst || (cmd >= 0 ? n : 1) > size - src)
                        throw new InvalidDataException("Invalid Photoshop RLE");
                    if (cmd >= 0) { Buffer.BlockCopy(packed, src, row, dst, n); src += n; dst += n; }
                    else { byte value = packed[src++]; while (n-- > 0) row[dst++] = value; }
                }
                if (dst != w) throw new InvalidDataException("Incomplete Photoshop row");
            }
            int offset = channels == 4 && ch < 3 ? 2 - ch : ch; // WIC accepts BGRA32 or RGB24.
            for (int x = 0, i = y * w * channels + offset; x < w; x++, i += channels) rgb[i] = row[x];
        }
        if (channels == 4)
        {
            // Photoshop's saved composite stores semitransparent RGB matted against white.
            for (int p = 0; p < rgb.Length; p += 4)
            {
                int alpha = rgb[p + 3];
                if (alpha == 0 || alpha == 255) continue;
                for (int c = p; c < p + 3; c++)
                    rgb[c] = (byte)Math.Max(0, 255 - ((255 - rgb[c]) * 255 + alpha / 2) / alpha);
            }
        }
        var format = channels == 4 ? PixelFormats.Bgra32 : PixelFormats.Rgb24;
        var image = BitmapSource.Create(w, h, 96, 96, format, null, rgb, w * channels);
        if (profile == null) return image;
        string icc = Path.GetFullPath(Guid.NewGuid().ToString("N") + ".icc");
        // WPF can keep the profile open for the worker's lifetime. The caller
        // removes the request directory after the worker exits.
        File.WriteAllBytes(icc, profile);
        return new CachedBitmap(new ColorConvertedBitmap(image, new ColorContext(new Uri(icc)),
            new ColorContext(PixelFormats.Bgra32), PixelFormats.Rgba64),
            BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
    }

    // SQLite borrows this read-only view until the connection closes. Only database
    // pages needed by CanvasPreview are paged in, including non-page-aligned chunks.
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_open(string path, out IntPtr db);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_deserialize(IntPtr db, string schema, IntPtr data, long length, long capacity, uint flags);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_exec(IntPtr db, string sql, IntPtr callback, IntPtr context, IntPtr error);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_prepare_v2(IntPtr db, string sql, int bytes, out IntPtr statement, IntPtr tail);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_step(IntPtr statement);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr sqlite3_column_blob(IntPtr statement, int column);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_column_bytes(IntPtr statement, int column);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_finalize(IntPtr statement);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int sqlite3_close(IntPtr db);

    static unsafe byte[] CanvasPreview(FileStream file, long offset, long size)
    {
        if (size < 100) throw new InvalidDataException("Incomplete CLIP database");
        using (var map = MemoryMappedFile.CreateFromFile(file, null, 0, MemoryMappedFileAccess.Read,
                                                          null, HandleInheritability.None, true))
        using (var view = map.CreateViewAccessor(offset, size, MemoryMappedFileAccess.Read))
        {
            byte* start = null;
            view.SafeMemoryMappedViewHandle.AcquirePointer(ref start);
            IntPtr db = IntPtr.Zero, stmt = IntPtr.Zero;
            try
            {
                const string query = "SELECT ImageData FROM CanvasPreview WHERE length(ImageData) BETWEEN 1 AND 16777216 LIMIT 1";
                if (sqlite3_open(":memory:", out db) != 0 ||
                    sqlite3_deserialize(db, "main", (IntPtr)(start + view.PointerOffset), size, size, 4) != 0 ||
                    sqlite3_exec(db, "PRAGMA trusted_schema=OFF; PRAGMA query_only=ON", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero) != 0 ||
                    sqlite3_prepare_v2(db, query, -1, out stmt, IntPtr.Zero) != 0 || sqlite3_step(stmt) != 100)
                    throw new InvalidDataException("Cannot read saved CLIP canvas preview");
                IntPtr blob = sqlite3_column_blob(stmt, 0);
                int n = sqlite3_column_bytes(stmt, 0);
                if (blob == IntPtr.Zero || n < 1 || n > 16777216) throw new InvalidDataException("Invalid CLIP preview");
                var data = new byte[n];
                Marshal.Copy(blob, data, 0, n);
                return data;
            }
            finally
            {
                if (stmt != IntPtr.Zero) sqlite3_finalize(stmt);
                if (db != IntPtr.Zero) sqlite3_close(db);
                view.SafeMemoryMappedViewHandle.ReleasePointer();
            }
        }
    }

    static byte[] Clip(BinaryReader reader, FileStream file)
    {
        file.Position = 24;
        while (file.Length - file.Position >= 16)
        {
            long type = Number(reader, 8), size = Number(reader, 8);
            if (size > file.Length - file.Position) throw new InvalidDataException("Truncated CLIP chunk");
            if (type == 0x43484e4b53514c69L) return CanvasPreview(file, file.Position, size); // CHNKSQLi
            Skip(reader, size);
        }
        throw new InvalidDataException("Missing CLIP database");
    }

    static BitmapSource Open(string path)
    {
        using (var input = File.OpenRead(path))
        {
            using (var r = new BinaryReader(input, System.Text.Encoding.ASCII, true))
            {
                long type = Number(r, 4);
                if (type == 0x38425053) return Photoshop(r);
                if (type == 0x43534643 && Number(r, 4) == 0x48554e4b) // CSFCHUNK
                    using (var canvas = new MemoryStream(Clip(r, input), false))
                        return Decode(canvas, true);
            }
            input.Position = 0;
            return Decode(input);
        }
    }

    static BitmapSource Decode(Stream input, bool clip = false)
    {
        var decoder = BitmapDecoder.Create(input, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnDemand);
        if (clip && !(decoder is PngBitmapDecoder) && !(decoder is JpegBitmapDecoder))
            throw new InvalidDataException("Unsupported CLIP canvas image");
        var frame = decoder.Frames[0];
        CheckSize(frame.PixelWidth, frame.PixelHeight);
        BitmapSource pixels = frame;
        if (frame.ColorContexts != null && frame.ColorContexts.Count > 0)
            pixels = new ColorConvertedBitmap(frame, frame.ColorContexts[0],
                new ColorContext(PixelFormats.Bgra32), PixelFormats.Rgba64);
        var metadata = frame.Metadata as BitmapMetadata;
        if (metadata != null && (metadata.Format == "jpg" || metadata.Format == "tiff"))
        {
            string tag = metadata.Format == "jpg" ? "/app1/ifd/{ushort=274}" : "/ifd/{ushort=274}";
            int orientation = Convert.ToInt32(metadata.GetQuery(tag));
            var transform = new TransformGroup();
            if (orientation == 2 || orientation == 5 || orientation == 7)
                transform.Children.Add(new ScaleTransform(-1, 1));
            if (orientation == 4) transform.Children.Add(new ScaleTransform(1, -1));
            if (orientation == 3) transform.Children.Add(new RotateTransform(180));
            if (orientation == 5 || orientation == 8) transform.Children.Add(new RotateTransform(270));
            if (orientation == 6 || orientation == 7) transform.Children.Add(new RotateTransform(90));
            if (transform.Children.Count > 0) pixels = new TransformedBitmap(pixels, transform);
        }
        return new CachedBitmap(pixels, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
    }

    static double Scale(int w, int h)
    {
        return Math.Min(1.0, Math.Min((double)MaxWidth / w, (double)MaxHeight / h));
    }

    static void Save(BitmapSource image, string path)
    {
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(image));
        using (var output = File.Create(path)) encoder.Save(output);
    }

    static void Preview(BitmapSource image, string path)
    {
        double scale = Scale(image.PixelWidth, image.PixelHeight);
        if (scale < 1) image = new TransformedBitmap(image, new ScaleTransform(scale, scale));
        Save(image, path);
    }

    // Convert in strips so two full-size 64-bit comparison buffers are never needed.
    // RGBA64 preserves 16-bit samples. RGB under a fully transparent pixel is invisible.
    static void ReadStrip(BitmapSource image, byte[] strip, int y, int rows, int width, int pixelBytes)
    {
        if (image.PixelWidth != width || y + rows > image.PixelHeight) Array.Clear(strip, 0, strip.Length);
        int height = Math.Min(rows, image.PixelHeight - y);
        if (height > 0)
            image.CopyPixels(new Int32Rect(0, y, image.PixelWidth, height), strip, width * pixelBytes, 0);
    }

    static bool IsByteRgb(PixelFormat format)
    {
        return format == PixelFormats.Rgb24 || format == PixelFormats.Bgr24 ||
               format == PixelFormats.Bgr32 || format == PixelFormats.Bgra32;
    }

    static unsafe long Compare(BitmapSource before, BitmapSource after, string output)
    {
        bool compact = IsByteRgb(before.Format) && IsByteRgb(after.Format);
        var format = compact ? PixelFormats.Bgra32 : PixelFormats.Rgba64;
        int pixelBytes = compact ? 4 : 8;
        if (before.Format != format) before = new FormatConvertedBitmap(before, format, null, 0);
        if (after.Format != format) after = new FormatConvertedBitmap(after, format, null, 0);
        int w = Math.Max(before.PixelWidth, after.PixelWidth), h = Math.Max(before.PixelHeight, after.PixelHeight);
        CheckSize(w, h);
        double scale = Scale(w, h);
        int mw = Math.Max(1, (int)Math.Round(w * scale)), mh = Math.Max(1, (int)Math.Round(h * scale));
        var rgb = new byte[mw * mh * 3];
        for (int i = 0; i < rgb.Length; i += 3) { rgb[i] = 0x25; rgb[i+1] = 0x29; rgb[i+2] = 0x32; }
        var column = new int[w];
        for (int x = 0; x < w; x++) column[x] = (int)((long)x * mw / w) * 3;
        int rows = Math.Min(h, Math.Max(1, Math.Min(32, 262144 / w)));
        var a = new byte[w * rows * pixelBytes];
        var b = new byte[w * rows * pixelBytes];
        long count = 0;
        fixed (byte* bytesA = a, bytesB = b)
        for (int y = 0; y < h; y += rows)
        {
            int height = Math.Min(rows, h - y);
            ReadStrip(before, a, y, height, w, pixelBytes);
            ReadStrip(after, b, y, height, w, pixelBytes);
            for (int row = 0; row < height; row++)
            {
                int line = (int)((long)(row + y) * mh / h) * mw * 3;
                for (int x = 0, i = row * w; x < w; x++, i++)
                {
                    if (compact)
                    {
                        uint left = ((uint*)bytesA)[i], right = ((uint*)bytesB)[i];
                        if (left == right || ((left | right) >> 24) == 0) continue;
                    }
                    else
                    {
                        ulong left = ((ulong*)bytesA)[i], right = ((ulong*)bytesB)[i];
                        if (left == right || ((left | right) >> 48) == 0) continue;
                    }
                    count++;
                    int p = line + column[x];
                    rgb[p] = 0xff; rgb[p+1] = 0x37; rgb[p+2] = 0x5f;
                }
            }
        }
        Save(BitmapSource.Create(mw, mh, 96, 96, PixelFormats.Rgb24, null, rgb, mw * 3), output);
        return count;
    }

    [DllImport("kernel32.dll")]
    static extern bool DeviceIoControl(SafeFileHandle file, uint control, byte[] input, int inputSize,
        byte[] output, int outputSize, out int returned, IntPtr overlapped);

    [DllImport("kernel32.dll")]
    static extern bool GetFileInformationByHandleEx(SafeFileHandle file, int infoClass, byte[] info, int size);

    static string Version(string path)
    {
        // Editors can restore timestamps or replace a file. Read the filesystem
        // change sequence and file identity together while excluding active writers.
        using (var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete))
        {
            if (file.Length > 1048576)
            {
                byte[] record = new byte[1024], id = new byte[24], basic = new byte[40];
                const uint ReadFileUsnData = 0x900eb; // FSCTL_READ_FILE_USN_DATA
                byte[] versions = { 2, 0, 3, 0 }; // READ_FILE_USN_DATA accepts USN_RECORD_V2 through V3.
                int used;
                if (DeviceIoControl(file.SafeFileHandle, ReadFileUsnData, versions, versions.Length,
                                    record, record.Length, out used, IntPtr.Zero) && used >= 48 &&
                    GetFileInformationByHandleEx(file.SafeFileHandle, 18, id, id.Length) && // FileIdInfo
                    GetFileInformationByHandleEx(file.SafeFileHandle, 0, basic, basic.Length)) // FileBasicInfo
                {
                    int major = BitConverter.ToUInt16(record, 4);
                    long usn = major == 2 ? BitConverter.ToInt64(record, 24) :
                               major == 3 ? BitConverter.ToInt64(record, 40) : 0;
                    if (usn > 0)
                        return String.Format("usn {0} {1} {2} {3}", Convert.ToBase64String(id),
                                             usn, BitConverter.ToInt64(basic, 24), file.Length);
                }
            }
            using (var hash = SHA256.Create()) return Convert.ToBase64String(hash.ComputeHash(file));
        }
    }

    // Handle the default LFS object directory here. The portable reader handles
    // other stores, including linked worktrees, and reports missing objects.
    static string LocalArt(string root, string file, string name)
    {
        if ((File.GetAttributes(file) & FileAttributes.ReparsePoint) != 0)
            throw new NotSupportedException("Linked artwork");
        if (new FileInfo(file).Length <= 1024)
        {
            string pointer = File.ReadAllText(file);
            if (pointer.StartsWith("version https://git-lfs.github.com/spec/v1", StringComparison.Ordinal))
            {
                var oid = System.Text.RegularExpressions.Regex.Match(pointer, @"(?m)^oid sha256:([a-f0-9]{64})\r?$");
                if (!oid.Success || Environment.GetEnvironmentVariable("GIT_COMMON_DIR") != null ||
                    Environment.GetEnvironmentVariable("GIT_DIR") != null)
                    throw new InvalidDataException("Nonstandard local LFS storage");
                string hash = oid.Groups[1].Value;
                file = Path.Combine(root, ".git/lfs/objects", hash.Substring(0, 2), hash.Substring(2, 2), hash);
            }
        }
        string ext = Path.GetExtension(name).ToLowerInvariant();
        if (ext == ".clip" || ext == ".clpi")
            using (var reader = new BinaryReader(File.OpenRead(file)))
                if (Number(reader, 8) != 0x4353464348554e4bL) throw new InvalidDataException("Invalid CLIP document");
        return file;
    }

    static string RevisionFile(string root, string git, string revision, string name, string directory)
    {
        if (revision == "worktree") return LocalArt(root, Path.Combine(root, name), name);
        string spec = (revision.Length == 0 ? ":0" : revision) + ":" + name;
        if (spec.IndexOf('"') >= 0 || spec.EndsWith("\\") || spec.StartsWith("-"))
            throw new NotSupportedException("Unrepresentable Windows path");
        string blob = Path.GetFullPath(Path.Combine(directory, "blob"));
        var info = new ProcessStartInfo(git, "cat-file blob \"" + spec + "\"");
        info.WorkingDirectory = root;
        info.UseShellExecute = false;
        info.CreateNoWindow = true;
        info.RedirectStandardOutput = true;
        using (var child = Process.Start(info))
        {
            using (var output = File.Create(blob)) child.StandardOutput.BaseStream.CopyTo(output);
            child.WaitForExit();
            if (child.ExitCode != 0) throw new IOException("Cannot read image from Git");
        }
        return LocalArt(root, blob, name);
    }

    static string[] GitArt(string[] args)
    {
        string root = args[1], git = args[2];
        // Capture identities before reading either input. The GUI rechecks after rendering.
        if (args.Length > 7)
        {
            try
            {
                var ids = new string[args.Length - 7];
                for (int i = 7; i < args.Length; i++) ids[i - 7] = Version(Path.Combine(root, args[i]));
                File.WriteAllText("versions", String.Join("\n", ids) + "\n");
            }
            catch (IOException) { } // A missing/locked index disables caching only.
        }
        if (args[6].Length == 0) return new string[] { RevisionFile(root, git, args[3], args[4], ".") };
        Directory.CreateDirectory("before");
        Directory.CreateDirectory("after");
        return new string[] { RevisionFile(root, git, args[3], args[4], "after"),
                              RevisionFile(root, git, args[5], args[6], "before") };
    }

    [STAThread]
    static int Main(string[] args)
    {
        try
        {
            if (args[0] == "--stamp")
            {
                for (int i = 1; i < args.Length; i++) Console.WriteLine(Version(args[i]));
                return 0;
            }
            if (args[0] == "--git-art") args = GitArt(args);
            var after = Open(args[0]);
            if (args.Length == 1) Preview(after, "preview");
            else
            {
                var before = Open(args[1]);
                long count = Compare(before, after, "difference");
                Console.WriteLine("{0} changed pixel{1}  |  {2}x{3} -> {4}x{5}", count,
                    count == 1 ? "" : "s", before.PixelWidth, before.PixelHeight,
                    after.PixelWidth, after.PixelHeight);
                Console.Out.Flush();
                Preview(before, "before/preview");
                Preview(after, "after/preview");
            }
            return 0;
        }
        catch (Exception e) { Console.Error.Write(e.Message); return 1; }
    }
}
