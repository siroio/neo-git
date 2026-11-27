// SPDX-License-Identifier: GPL-3.0-or-later
// Windows image worker. Builds with the in-box .NET Framework compiler and WIC.
using System;
using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

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
        try
        {
            File.WriteAllBytes(icc, profile);
            return new CachedBitmap(new ColorConvertedBitmap(image, new ColorContext(new Uri(icc)),
                new ColorContext(PixelFormats.Bgra32), PixelFormats.Rgba64),
                BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
        }
        finally { File.Delete(icc); }
    }

    static BitmapSource Open(string path)
    {
        using (var input = File.OpenRead(path))
        {
            using (var r = new BinaryReader(input, System.Text.Encoding.ASCII, true))
                if (Number(r, 4) == 0x38425053) return Photoshop(r);
            input.Position = 0;
            var frame = BitmapDecoder.Create(input, BitmapCreateOptions.PreservePixelFormat,
                                             BitmapCacheOption.OnDemand).Frames[0];
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
    static void ReadStrip(BitmapSource image, byte[] strip, int y, int rows, int stride)
    {
        if (image.PixelWidth != stride || y + rows > image.PixelHeight) Array.Clear(strip, 0, strip.Length);
        int height = Math.Min(rows, image.PixelHeight - y);
        if (height > 0)
            image.CopyPixels(new Int32Rect(0, y, image.PixelWidth, height), strip, stride * 8, 0);
    }

    static unsafe long Compare(BitmapSource before, BitmapSource after, string output)
    {
        before = new FormatConvertedBitmap(before, PixelFormats.Rgba64, null, 0);
        after = new FormatConvertedBitmap(after, PixelFormats.Rgba64, null, 0);
        int w = Math.Max(before.PixelWidth, after.PixelWidth), h = Math.Max(before.PixelHeight, after.PixelHeight);
        CheckSize(w, h);
        double scale = Scale(w, h);
        int mw = Math.Max(1, (int)Math.Round(w * scale)), mh = Math.Max(1, (int)Math.Round(h * scale));
        var rgb = new byte[mw * mh * 3];
        for (int i = 0; i < rgb.Length; i += 3) { rgb[i] = 0x25; rgb[i+1] = 0x29; rgb[i+2] = 0x32; }
        var column = new int[w];
        for (int x = 0; x < w; x++) column[x] = (int)((long)x * mw / w) * 3;
        int rows = Math.Min(h, Math.Max(1, Math.Min(32, 262144 / w)));
        var a = new byte[w * rows * 8];
        var b = new byte[w * rows * 8];
        long count = 0;
        fixed (byte* bytesA = a, bytesB = b)
        for (int y = 0; y < h; y += rows)
        {
            int height = Math.Min(rows, h - y);
            ReadStrip(before, a, y, height, w);
            ReadStrip(after, b, y, height, w);
            for (int row = 0; row < height; row++)
            {
                int line = (int)((long)(row + y) * mh / h) * mw * 3;
                for (int x = 0, i = row * w; x < w; x++, i++)
                {
                    ulong oldPixel = ((ulong*)bytesA)[i], newPixel = ((ulong*)bytesB)[i];
                    if (oldPixel == newPixel || ((oldPixel | newPixel) >> 48) == 0) continue;
                    count++;
                    int p = line + column[x];
                    rgb[p] = 0xff; rgb[p+1] = 0x37; rgb[p+2] = 0x5f;
                }
            }
        }
        Save(BitmapSource.Create(mw, mh, 96, 96, PixelFormats.Rgb24, null, rgb, mw * 3), output);
        return count;
    }

    [STAThread]
    static int Main(string[] args)
    {
        try
        {
            var after = Open(args[0]);
            if (args.Length == 1) Preview(after, "preview");
            else
            {
                var before = Open(args[1]);
                long count = Compare(before, after, "difference");
                Preview(before, "before/preview");
                Preview(after, "after/preview");
                Console.Write("{0} changed pixel{1}  |  {2}x{3} -> {4}x{5}", count,
                    count == 1 ? "" : "s", before.PixelWidth, before.PixelHeight,
                    after.PixelWidth, after.PixelHeight);
            }
            return 0;
        }
        catch (Exception e) { Console.Error.Write(e.Message); return 1; }
    }
}
