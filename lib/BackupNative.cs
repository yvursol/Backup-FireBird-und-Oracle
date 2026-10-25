// Native helpers for BackupCommon.psm1, compiled at module load with Add-Type.
// Written for C# 5 so that Windows PowerShell 5.1 (.NET Framework 4.x) can compile it.
//
// Encrypted file format (all integers little-endian):
//
//   offset  size  field
//   0       8     magic "BKAENC01"
//   8       4     PBKDF2 iteration count
//   12      16    salt
//   28      16    AES-CBC IV
//   44      16    key check  = HMAC-SHA256(macKey, "BKAENC01-keycheck" || bytes 0..43)[0..15]
//   60      n     AES-256-CBC ciphertext, PKCS#7 padding
//   60+n    32    tag        = HMAC-SHA256(macKey, bytes 0..59+n)
//
//   encKey || macKey = PBKDF2-HMAC-SHA256(UTF-8 passphrase, salt, iterations, 64 bytes)
//
// Encrypt-then-MAC: the tag covers header and ciphertext, so any modification is detected
// before the plaintext is trusted. The key check only exists to report a wrong passphrase
// immediately instead of after reading the whole file.

using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace BackupAutomation
{
    public static class NativeDisk
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetDiskFreeSpaceEx(string directoryName, out ulong freeBytesAvailable,
            out ulong totalNumberOfBytes, out ulong totalNumberOfFreeBytes);

        // Works for local folders and UNC paths (\\server\share\), unlike System.IO.DriveInfo.
        public static ulong GetAvailableBytes(string directory)
        {
            ulong available, total, totalFree;
            if (!directory.EndsWith("\\")) { directory += "\\"; }
            if (!GetDiskFreeSpaceEx(directory, out available, out total, out totalFree))
            {
                throw new IOException("GetDiskFreeSpaceEx failed for " + directory + " (Win32 error " +
                    Marshal.GetLastWin32Error() + ")");
            }
            return available;
        }
    }

    public static class FileCrypto
    {
        public const int DefaultIterations = 600000;
        public const int MinIterations = 1000;
        public const int MaxIterations = 10000000;

        private static readonly byte[] Magic = Encoding.ASCII.GetBytes("BKAENC01");
        private static readonly byte[] KeyCheckLabel = Encoding.ASCII.GetBytes("BKAENC01-keycheck");
        private const int PrefixSize = 44;   // magic + iterations + salt + IV
        private const int CheckSize = 16;
        private const int TagSize = 32;
        private const int BufferSize = 1024 * 1024;

        public static void EncryptFile(string inputPath, string outputPath, string passphrase, int iterations)
        {
            if (iterations < MinIterations || iterations > MaxIterations)
            {
                throw new ArgumentOutOfRangeException("iterations");
            }
            if (string.IsNullOrEmpty(passphrase)) { throw new ArgumentException("The passphrase must not be empty."); }

            byte[] salt = RandomBytes(16);
            byte[] iv = RandomBytes(16);
            byte[] encKey, macKey;
            DeriveKeys(passphrase, salt, iterations, out encKey, out macKey);

            byte[] prefix = new byte[PrefixSize];
            Buffer.BlockCopy(Magic, 0, prefix, 0, 8);
            WriteInt32(prefix, 8, iterations);
            Buffer.BlockCopy(salt, 0, prefix, 12, 16);
            Buffer.BlockCopy(iv, 0, prefix, 28, 16);
            byte[] check = KeyCheck(macKey, prefix);

            using (FileStream input = new FileStream(inputPath, FileMode.Open, FileAccess.Read, FileShare.Read, BufferSize))
            using (FileStream output = new FileStream(outputPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, BufferSize))
            using (HMACSHA256 mac = new HMACSHA256(macKey))
            using (Aes aes = CreateAes(encKey, iv))
            using (ICryptoTransform encryptor = aes.CreateEncryptor())
            {
                MacStream tee = new MacStream(output, mac);
                tee.Write(prefix, 0, prefix.Length);
                tee.Write(check, 0, check.Length);
                using (CryptoStream crypto = new CryptoStream(tee, encryptor, CryptoStreamMode.Write))
                {
                    input.CopyTo(crypto, BufferSize);
                    crypto.FlushFinalBlock();
                }
                mac.TransformFinalBlock(new byte[0], 0, 0);
                output.Write(mac.Hash, 0, TagSize);
                output.Flush(true);
            }
        }

        public static void DecryptFile(string inputPath, string outputPath, string passphrase)
        {
            using (FileStream output = new FileStream(outputPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, BufferSize))
            {
                DecryptToStream(inputPath, output, passphrase);
                output.Flush(true);
            }
        }

        // Decrypts and authenticates the whole file without writing the plaintext anywhere.
        public static void VerifyFile(string inputPath, string passphrase)
        {
            DecryptToStream(inputPath, Stream.Null, passphrase);
        }

        public static bool IsEncryptedFile(string path)
        {
            using (FileStream input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                if (input.Length < PrefixSize + CheckSize + 16 + TagSize) { return false; }
                byte[] magic = ReadExactly(input, 8);
                return FixedTimeEquals(magic, Magic);
            }
        }

        private static void DecryptToStream(string inputPath, Stream output, string passphrase)
        {
            using (FileStream input = new FileStream(inputPath, FileMode.Open, FileAccess.Read, FileShare.Read, BufferSize))
            {
                long cipherLength = input.Length - PrefixSize - CheckSize - TagSize;
                if (cipherLength < 16 || cipherLength % 16 != 0)
                {
                    throw new InvalidDataException("Not an encrypted backup file, or the file is truncated.");
                }
                byte[] prefix = ReadExactly(input, PrefixSize);
                byte[] magic = new byte[8];
                Buffer.BlockCopy(prefix, 0, magic, 0, 8);
                if (!FixedTimeEquals(magic, Magic))
                {
                    throw new InvalidDataException("Not a file encrypted by BackupAutomation (unknown header).");
                }
                int iterations = ReadInt32(prefix, 8);
                if (iterations < MinIterations || iterations > MaxIterations)
                {
                    throw new InvalidDataException("Invalid iteration count in header: " + iterations);
                }
                byte[] salt = new byte[16];
                byte[] iv = new byte[16];
                Buffer.BlockCopy(prefix, 12, salt, 0, 16);
                Buffer.BlockCopy(prefix, 28, iv, 0, 16);
                byte[] check = ReadExactly(input, CheckSize);

                byte[] encKey, macKey;
                DeriveKeys(passphrase, salt, iterations, out encKey, out macKey);
                if (!FixedTimeEquals(check, KeyCheck(macKey, prefix)))
                {
                    throw new CryptographicException("Wrong passphrase (key check failed).");
                }

                using (HMACSHA256 mac = new HMACSHA256(macKey))
                using (Aes aes = CreateAes(encKey, iv))
                using (ICryptoTransform decryptor = aes.CreateDecryptor())
                {
                    mac.TransformBlock(prefix, 0, prefix.Length, null, 0);
                    mac.TransformBlock(check, 0, check.Length, null, 0);
                    MacStream source = new MacStream(input, mac, cipherLength);
                    try
                    {
                        using (CryptoStream crypto = new CryptoStream(source, decryptor, CryptoStreamMode.Read))
                        {
                            crypto.CopyTo(output, BufferSize);
                        }
                    }
                    catch (CryptographicException)
                    {
                        throw new CryptographicException("Integrity check failed: the file is corrupted or was modified.");
                    }
                    mac.TransformFinalBlock(new byte[0], 0, 0);
                    byte[] tag = ReadExactly(input, TagSize);
                    if (!FixedTimeEquals(tag, mac.Hash))
                    {
                        throw new CryptographicException("Integrity check failed: the file is corrupted or was modified.");
                    }
                }
            }
        }

        // PBKDF2-HMAC-SHA256 (RFC 8018). Implemented here because the .NET Framework 4.6
        // Rfc2898DeriveBytes only supports SHA-1.
        public static byte[] Pbkdf2Sha256(byte[] password, byte[] salt, int iterations, int length)
        {
            byte[] result = new byte[length];
            using (HMACSHA256 hmac = new HMACSHA256(password))
            {
                int blocks = (length + 31) / 32;
                for (int block = 1; block <= blocks; block++)
                {
                    byte[] first = new byte[salt.Length + 4];
                    Buffer.BlockCopy(salt, 0, first, 0, salt.Length);
                    first[salt.Length] = (byte)(block >> 24);
                    first[salt.Length + 1] = (byte)(block >> 16);
                    first[salt.Length + 2] = (byte)(block >> 8);
                    first[salt.Length + 3] = (byte)block;
                    byte[] u = hmac.ComputeHash(first);
                    byte[] t = (byte[])u.Clone();
                    for (int i = 1; i < iterations; i++)
                    {
                        u = hmac.ComputeHash(u);
                        for (int j = 0; j < t.Length; j++) { t[j] ^= u[j]; }
                    }
                    int offset = (block - 1) * 32;
                    Buffer.BlockCopy(t, 0, result, offset, Math.Min(32, length - offset));
                }
            }
            return result;
        }

        private static void DeriveKeys(string passphrase, byte[] salt, int iterations, out byte[] encKey, out byte[] macKey)
        {
            byte[] keys = Pbkdf2Sha256(Encoding.UTF8.GetBytes(passphrase), salt, iterations, 64);
            encKey = new byte[32];
            macKey = new byte[32];
            Buffer.BlockCopy(keys, 0, encKey, 0, 32);
            Buffer.BlockCopy(keys, 32, macKey, 0, 32);
            Array.Clear(keys, 0, keys.Length);
        }

        private static byte[] KeyCheck(byte[] macKey, byte[] prefix)
        {
            using (HMACSHA256 hmac = new HMACSHA256(macKey))
            {
                hmac.TransformBlock(KeyCheckLabel, 0, KeyCheckLabel.Length, null, 0);
                hmac.TransformFinalBlock(prefix, 0, prefix.Length);
                byte[] check = new byte[CheckSize];
                Buffer.BlockCopy(hmac.Hash, 0, check, 0, CheckSize);
                return check;
            }
        }

        private static Aes CreateAes(byte[] key, byte[] iv)
        {
            Aes aes = Aes.Create();
            aes.KeySize = 256;
            aes.Mode = CipherMode.CBC;
            aes.Padding = PaddingMode.PKCS7;
            aes.Key = key;
            aes.IV = iv;
            return aes;
        }

        private static byte[] RandomBytes(int count)
        {
            byte[] bytes = new byte[count];
            using (RandomNumberGenerator rng = RandomNumberGenerator.Create()) { rng.GetBytes(bytes); }
            return bytes;
        }

        private static byte[] ReadExactly(Stream stream, int count)
        {
            byte[] buffer = new byte[count];
            int read = 0;
            while (read < count)
            {
                int n = stream.Read(buffer, read, count - read);
                if (n == 0) { throw new InvalidDataException("Unexpected end of file."); }
                read += n;
            }
            return buffer;
        }

        private static void WriteInt32(byte[] buffer, int offset, int value)
        {
            buffer[offset] = (byte)value;
            buffer[offset + 1] = (byte)(value >> 8);
            buffer[offset + 2] = (byte)(value >> 16);
            buffer[offset + 3] = (byte)(value >> 24);
        }

        private static int ReadInt32(byte[] buffer, int offset)
        {
            return buffer[offset] | (buffer[offset + 1] << 8) | (buffer[offset + 2] << 16) | (buffer[offset + 3] << 24);
        }

        private static bool FixedTimeEquals(byte[] a, byte[] b)
        {
            if (a.Length != b.Length) { return false; }
            int diff = 0;
            for (int i = 0; i < a.Length; i++) { diff |= a[i] ^ b[i]; }
            return diff == 0;
        }
    }

    // Passes data through to an inner stream and feeds every byte into an HMAC.
    // Write mode: for encryption. Read mode: reads at most `length` bytes (the ciphertext).
    // Disposing it never closes the inner stream.
    internal sealed class MacStream : Stream
    {
        private readonly Stream inner;
        private readonly HashAlgorithm mac;
        private readonly bool reading;
        private long remaining;

        public MacStream(Stream inner, HashAlgorithm mac)
        {
            this.inner = inner;
            this.mac = mac;
            this.reading = false;
        }

        public MacStream(Stream inner, HashAlgorithm mac, long length)
        {
            this.inner = inner;
            this.mac = mac;
            this.reading = true;
            this.remaining = length;
        }

        public override bool CanRead { get { return reading; } }
        public override bool CanWrite { get { return !reading; } }
        public override bool CanSeek { get { return false; } }
        public override long Length { get { throw new NotSupportedException(); } }
        public override long Position
        {
            get { throw new NotSupportedException(); }
            set { throw new NotSupportedException(); }
        }

        public override void Write(byte[] buffer, int offset, int count)
        {
            if (reading) { throw new NotSupportedException(); }
            mac.TransformBlock(buffer, offset, count, null, 0);
            inner.Write(buffer, offset, count);
        }

        public override int Read(byte[] buffer, int offset, int count)
        {
            if (!reading) { throw new NotSupportedException(); }
            if (remaining <= 0) { return 0; }
            int n = inner.Read(buffer, offset, (int)Math.Min(count, remaining));
            if (n > 0)
            {
                mac.TransformBlock(buffer, offset, n, null, 0);
                remaining -= n;
            }
            return n;
        }

        public override void Flush()
        {
            if (!reading) { inner.Flush(); }
        }

        public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
        public override void SetLength(long value) { throw new NotSupportedException(); }
    }
}
