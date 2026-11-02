// Ripple Drive tray app for Windows (beta). build.ps1 compiles it on the PC with the C# compiler that ships with
// Windows (.NET Framework 4.x, so C# 5: no string interpolation, no ?. operator).
// Mirrors the Mac menu-bar app (app/main.swift): status, upload progress with pause and cancel, the folder chooser,
// Ctrl+Alt+F search, share links, sign-in and reconnect. The drive itself is ripple-drive-mount.ps1, which this
// app starts hidden and starts again whenever it stops. Uploads and search are the shared Python scripts in bin/.
//   RippleDrive.exe                    start (one copy runs; starting it again opens the drive)
//   RippleDrive.exe --upload PATH...   File Explorer right-click: upload (asks for the Drive folder)
//   RippleDrive.exe --move PATH...     the same, then the originals go to the Recycle Bin once Drive confirms them
//   RippleDrive.exe --link PATH        copy a share link for a file inside the drive
//   RippleDrive.exe --selftest FILE    checks run by the GitHub Windows test; writes the results to FILE
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

namespace RippleDrive
{
    static class Program
    {
        [STAThread]
        static int Main(string[] args)
        {
            if (args.Length > 0 && args[0] == "--selftest") return SelfTest.Run(args.Length > 1 ? args[1] : null);
            bool first;
            var mutex = new Mutex(true, "Local\\RippleDrive.Tray", out first);
            if (!first)
            {
                Requests.Send(args);       // the running copy picks it up
                return 0;
            }
            // Explorer starts one copy per selected file: this copy's own job joins the others' in the request
            // folder, so a multi-file right-click becomes one folder question.
            if (args.Length > 0) Requests.Send(args);
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new TrayApp(false));
            GC.KeepAlive(mutex);
            return 0;
        }
    }

    // ---- Paths and small helpers -----------------------------------------------------------------------------

    static class P
    {
        public static readonly string Base = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RippleDrive");
        public static readonly string Bin = Path.Combine(Base, "bin");
        public static readonly string Rclone = Path.Combine(Bin, "rclone.exe");
        public static readonly string Uploader = Path.Combine(Bin, "ripple-drive-upload");
        public static readonly string Finder = Path.Combine(Bin, "ripple-drive-find");
        public static readonly string MountScript = Path.Combine(Bin, "ripple-drive-mount.ps1");
        public static readonly string SigninScript = Path.Combine(Bin, "ripple-drive-signin.ps1");
        public static readonly string State = Path.Combine(Base, "uploads");
        public static readonly string Logs = Path.Combine(Base, "logs");
        public static readonly string UploadsLog = Path.Combine(Logs, "uploads.log");
        public static readonly string Cache = Path.Combine(Base, "cache");
        public static readonly string Settings = Path.Combine(Base, "settings.json");
        public static readonly string Prefs = Path.Combine(Base, "app.json");
        public static readonly string Requests = Path.Combine(Base, "requests");
        public static readonly string PowerShell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
        public const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    }

    static class Util
    {
        public static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 64 * 1024 * 1024 };

        public static Dictionary<string, object> ReadJson(string path)
        {
            try { return Json.DeserializeObject(File.ReadAllText(path, Encoding.UTF8)) as Dictionary<string, object>; }
            catch { return null; }
        }

        public static string Str(Dictionary<string, object> d, string key)
        {
            object v;
            return d != null && d.TryGetValue(key, out v) && v != null ? v.ToString() : null;
        }

        public static double Num(Dictionary<string, object> d, string key)
        {
            object v;
            if (d == null || !d.TryGetValue(key, out v) || v == null) return 0;
            try { return Convert.ToDouble(v); } catch { return 0; }
        }

        public static bool Bool(Dictionary<string, object> d, string key)
        {
            object v;
            return d != null && d.TryGetValue(key, out v) && v is bool && (bool)v;
        }

        public static string Human(double bytes)
        {
            string[] units = { "B", "KB", "MB", "GB", "TB" };
            int i = 0;
            while (bytes >= 1024 && i < units.Length - 1) { bytes /= 1024; i++; }
            return i < 2 ? string.Format("{0:0} {1}", bytes, units[i]) : string.Format("{0:0.0} {1}", bytes, units[i]);
        }

        /// One Windows command-line argument, quoted the way Python, rclone and PowerShell read it back.
        public static string Quote(string a)
        {
            if (a.Length > 0 && a.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return a;
            var sb = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in a)
            {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') { sb.Append('\\', slashes * 2 + 1); sb.Append('"'); slashes = 0; continue; }
                sb.Append('\\', slashes); slashes = 0;
                sb.Append(c);
            }
            sb.Append('\\', slashes * 2);
            sb.Append('"');
            return sb.ToString();
        }

        static ProcessStartInfo Info(string file, IEnumerable<string> args)
        {
            var psi = new ProcessStartInfo(file, string.Join(" ", args.Select(Quote).ToArray()));
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WorkingDirectory = P.Base;
            psi.EnvironmentVariables["PYTHONUTF8"] = "1";
            psi.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8";
            return psi;
        }

        /// Starts a program hidden and leaves it running (uploads, the drive).
        public static Process Start(string file, IEnumerable<string> args)
        {
            return Process.Start(Info(file, args));
        }

        /// Runs a program hidden and returns (exit code, stdout + stderr); -1 if it can't start or times out.
        public static KeyValuePair<int, string> Run(string file, IEnumerable<string> args, int timeoutMs)
        {
            try
            {
                var psi = Info(file, args);
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                psi.StandardOutputEncoding = Encoding.UTF8;
                psi.StandardErrorEncoding = Encoding.UTF8;
                using (var p = Process.Start(psi))
                {
                    var err = new StringBuilder();
                    p.ErrorDataReceived += (s, e) => { if (e.Data != null) lock (err) err.AppendLine(e.Data); };
                    p.BeginErrorReadLine();
                    var outTask = p.StandardOutput.ReadToEndAsync();
                    if (!p.WaitForExit(timeoutMs))
                    {
                        try { p.Kill(); } catch { }
                        return new KeyValuePair<int, string>(-1, "timed out");
                    }
                    p.WaitForExit();
                    string text = outTask.Result;
                    lock (err) text += err.ToString();
                    return new KeyValuePair<int, string>(p.ExitCode, text);
                }
            }
            catch (Exception e) { return new KeyValuePair<int, string>(-1, e.Message); }
        }

        public static void KillTree(int pid)
        {
            Run(Path.Combine(Environment.SystemDirectory, "taskkill.exe"), new[] { "/PID", pid.ToString(), "/T", "/F" }, 15000);
        }

        public static void Log(string msg)
        {
            try
            {
                Directory.CreateDirectory(P.Logs);
                File.AppendAllText(Path.Combine(P.Logs, "app.log"),
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + msg + "\r\n", Encoding.UTF8);
            }
            catch { }
        }

        public static void Open(string target)
        {
            try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); }
            catch (Exception e) { Log("open " + target + ": " + e.Message); }
        }
    }

    static class Native
    {
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint vk);
        [DllImport("user32.dll")]
        public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
        [DllImport("user32.dll")]
        public static extern bool DestroyIcon(IntPtr handle);
        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern uint GetCompressedFileSizeW(string path, out uint high);
        public const int WM_HOTKEY = 0x0312;
        public const uint MOD_ALT = 0x1, MOD_CONTROL = 0x2, MOD_NOREPEAT = 0x4000;

        /// Bytes a file really takes on disk (the cache's files are sparse: their length overstates it).
        public static double Allocated(string path)
        {
            uint high;
            uint low = GetCompressedFileSizeW(path, out high);
            if (low == 0xFFFFFFFF && Marshal.GetLastWin32Error() != 0) return 0;
            return ((double)high * 4294967296.0) + low;
        }
    }

    // ---- Settings ----------------------------------------------------------------------------------------------

    /// settings.json is written by install.ps1 (drive letter, Python); app.json holds this app's own choices.
    class Settings
    {
        public string Drive = "R:", Python = "python.exe";
        public bool Notifications = true;
        public List<string> Recent = new List<string>();

        public static Settings Load()
        {
            var s = new Settings();
            var d = Util.ReadJson(P.Settings);
            if (Util.Str(d, "drive") != null) s.Drive = Util.Str(d, "drive").TrimEnd('\\');
            if (Util.Str(d, "python") != null) s.Python = Util.Str(d, "python");
            var a = Util.ReadJson(P.Prefs);
            if (a != null)
            {
                object v;
                if (a.TryGetValue("notifications", out v) && v is bool) s.Notifications = (bool)v;
                if (a.TryGetValue("recent", out v) && v is object[]) s.Recent = ((object[])v).Select(x => x.ToString()).ToList();
            }
            return s;
        }

        public void Save()
        {
            try
            {
                var d = new Dictionary<string, object>();
                d["notifications"] = Notifications;
                d["recent"] = Recent.ToArray();
                d["startAtLogin"] = StartAtLogin;
                File.WriteAllText(P.Prefs, Util.Json.Serialize(d), new UTF8Encoding(false));
            }
            catch (Exception e) { Util.Log("saving app.json: " + e.Message); }
        }

        public bool StartAtLogin
        {
            get
            {
                using (var k = Registry.CurrentUser.OpenSubKey(P.RunKey))
                    return k != null && k.GetValue("Ripple Drive") != null;
            }
            set
            {
                using (var k = Registry.CurrentUser.CreateSubKey(P.RunKey))
                {
                    if (value) k.SetValue("Ripple Drive", "\"" + Application.ExecutablePath + "\"");
                    else k.DeleteValue("Ripple Drive", false);
                }
            }
        }
    }

    // ---- Requests from File Explorer (a second copy of the app hands its job to the running one) --------------

    class Request
    {
        public string Verb = "show";               // show, upload, move, link
        public List<string> Paths = new List<string>();
    }

    static class Requests
    {
        public static Request Parse(string[] args)
        {
            var r = new Request();
            int i = 0;
            if (args.Length > 0 && args[0].StartsWith("--"))
            {
                r.Verb = args[0].Substring(2).ToLowerInvariant();
                i = 1;
            }
            for (; i < args.Length; i++) if (args[i].Length > 0) r.Paths.Add(args[i]);
            return r;
        }

        public static void Send(string[] args)
        {
            try
            {
                var r = Parse(args);
                Directory.CreateDirectory(P.Requests);
                var d = new Dictionary<string, object>();
                d["verb"] = r.Verb;
                d["paths"] = r.Paths.ToArray();
                string name = DateTime.UtcNow.Ticks.ToString("D19") + "-" + Guid.NewGuid().ToString("N");
                string tmp = Path.Combine(P.Requests, name + ".tmp");
                File.WriteAllText(tmp, Util.Json.Serialize(d), new UTF8Encoding(false));
                File.Move(tmp, Path.Combine(P.Requests, name + ".json"));
            }
            catch (Exception e) { Util.Log("request: " + e.Message); }
        }

        /// Every waiting request, oldest first, removed from the folder.
        public static List<Request> Take()
        {
            var list = new List<Request>();
            if (!Directory.Exists(P.Requests)) return list;
            foreach (var f in Directory.GetFiles(P.Requests, "*.json").OrderBy(x => x))
            {
                var d = Util.ReadJson(f);
                try { File.Delete(f); } catch { }
                if (d == null) continue;
                var r = new Request { Verb = Util.Str(d, "verb") ?? "show" };
                object v;
                if (d.TryGetValue("paths", out v) && v is object[]) r.Paths = ((object[])v).Select(x => x.ToString()).ToList();
                list.Add(r);
            }
            return list;
        }
    }

    // ---- Uploads (the uploader's queue files) ------------------------------------------------------------------

    class Upload
    {
        public string Id, Name, Dest, Source, Error;
        public double Size, Offset, Created;
        public bool Failed, Paused;
        public double Fraction { get { return Size > 0 ? Offset / Size : 1; } }
    }

    static class Queue
    {
        public static List<Upload> Read()
        {
            var list = new List<Upload>();
            if (!Directory.Exists(P.State)) return list;
            bool pauseAll = File.Exists(Path.Combine(P.State, ".pause-all"));
            foreach (var f in Directory.GetFiles(P.State, "*.json"))
            {
                var d = Util.ReadJson(f);
                if (d == null || Util.Str(d, "id") == null) continue;
                string id = Util.Str(d, "id");
                list.Add(new Upload
                {
                    Id = id, Name = Util.Str(d, "name") ?? Path.GetFileName(f), Dest = Util.Str(d, "dest") ?? "",
                    Source = Util.Str(d, "source") ?? "", Error = Util.Str(d, "error"),
                    Size = Util.Num(d, "size"), Offset = Util.Num(d, "offset"), Created = Util.Num(d, "created"),
                    Failed = Util.Bool(d, "failed"),
                    Paused = pauseAll || File.Exists(Path.Combine(P.State, id + ".pause"))
                });
            }
            return list.OrderBy(u => u.Created).ToList();
        }

        /// True while an uploader holds the queue's lock (the same lock ripple-drive-upload takes).
        public static bool UploaderRunning()
        {
            try
            {
                Directory.CreateDirectory(P.State);
                using (var fs = new FileStream(Path.Combine(P.State, ".lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.ReadWrite))
                {
                    fs.Lock(0, 1);
                    fs.Unlock(0, 1);
                    return false;
                }
            }
            catch (IOException) { return true; }
            catch { return false; }
        }

        /// "HH:mm  NAME to DEST" for uploads finished in the last 24 hours, newest first (from uploads.log).
        public static List<string> FinishedToday()
        {
            var outList = new List<string>();
            try
            {
                if (!File.Exists(P.UploadsLog)) return outList;
                var lines = File.ReadAllLines(P.UploadsLog, Encoding.UTF8);
                var since = DateTime.Now.AddDays(-1);
                foreach (var line in lines.Skip(Math.Max(0, lines.Length - 400)))
                {
                    DateTime t;
                    if (line.Length < 21 || !DateTime.TryParseExact(line.Substring(0, 19), "yyyy-MM-dd HH:mm:ss", null,
                        System.Globalization.DateTimeStyles.None, out t) || t < since) continue;
                    string msg = line.Substring(20);
                    int paren = msg.LastIndexOf(" (");
                    if (msg.StartsWith("uploaded ") && paren > 9) outList.Add(line.Substring(11, 5) + "  " + msg.Substring(9, paren - 9));
                }
            }
            catch { }
            outList.Reverse();
            return outList.Take(15).ToList();
        }
    }

    // ---- The Ripple mark (tray icon), drawn like the Mac's -----------------------------------------------------

    static class Mark
    {
        struct Dot { public float X, Y, A; public int Ring; public Dot(float x, float y, float a, int r) { X = x; Y = y; A = a; Ring = r; } }
        static readonly float[] Radius = { 1.9f, 1.0f, 0.75f, 0.6f };    // per ring, in 18-unit icon space
        static readonly List<Dot> Dots = MakeDots();

        static List<Dot> MakeDots()
        {
            float[,] outer = { { 148.5f, 11.8f, .28f }, { 187.0f, 25.8f, .27f }, { 218.4f, 52.2f, .24f }, { 238.9f, 87.6f, .22f },
                { 246.0f, 128.0f, .21f }, { 238.9f, 168.4f, .20f }, { 218.4f, 203.8f, .19f }, { 187.0f, 230.2f, .19f },
                { 148.5f, 244.2f, .20f }, { 107.5f, 244.2f, .22f }, { 69.0f, 230.2f, .23f }, { 37.6f, 203.8f, .26f },
                { 17.1f, 168.4f, .28f }, { 10.0f, 128.0f, .29f }, { 17.1f, 87.6f, .30f }, { 37.6f, 52.2f, .31f },
                { 69.0f, 25.8f, .31f }, { 107.5f, 11.8f, .30f } };
            float[,] middle = { { 148.5f, 44.5f, .57f }, { 185.0f, 63.6f, .53f }, { 208.4f, 97.4f, .48f }, { 213.4f, 138.3f, .44f },
                { 198.8f, 176.8f, .42f }, { 168.0f, 204.1f, .42f }, { 128.1f, 214.0f, .45f }, { 88.1f, 204.2f, .49f },
                { 57.3f, 176.9f, .54f }, { 42.6f, 138.4f, .58f }, { 47.6f, 97.6f, .61f }, { 70.9f, 63.7f, .62f }, { 107.4f, 44.5f, .61f } };
            float[,] inner = { { 128.0f, 78.0f, .98f }, { 163.4f, 92.6f, .92f }, { 178.0f, 128.0f, .86f }, { 163.4f, 163.4f, .84f },
                { 128.0f, 178.0f, .86f }, { 92.6f, 163.4f, .92f }, { 78.0f, 128.0f, .98f }, { 92.6f, 92.6f, 1.00f } };
            var dots = new List<Dot> { new Dot(128, 128, 1, 0) };
            for (int i = 0; i < inner.GetLength(0); i++) dots.Add(new Dot(inner[i, 0], inner[i, 1], inner[i, 2], 1));
            for (int i = 0; i < middle.GetLength(0); i++) dots.Add(new Dot(middle[i, 0], middle[i, 1], Math.Min(1, middle[i, 2] + .25f), 2));
            for (int i = 0; i < outer.GetLength(0); i++) dots.Add(new Dot(outer[i, 0], outer[i, 1], Math.Min(1, outer[i, 2] + .35f), 3));
            return dots;
        }

        /// How much ring `ring` swells at time t (0..1) of one pulse: core first, then each ring outwards.
        static float Pulse(float t, int ring)
        {
            float u = (t - (0.04f + 0.13f * ring)) / 0.22f;
            return u > 0 && u < 1 ? (float)Math.Sin(Math.PI * u) : 0;
        }

        /// One frame of the mark at `size` px. pulse < 0 = still.
        public static Icon Draw(int size, Color color, float alpha, float pulse)
        {
            using (var bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb))
            {
                using (var g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.Clear(Color.Transparent);
                    float s = size / 256f, k = size / 18f;
                    foreach (var d in Dots)
                    {
                        float scale = 1, op = d.A;
                        if (pulse >= 0)
                        {
                            float p = Pulse(pulse, d.Ring);
                            scale += (d.Ring <= 1 ? 0.25f : 0.4f) * p;
                            op = Math.Min(1, op + 0.35f * p);
                        }
                        float r = Radius[d.Ring] * k * scale;
                        using (var b = new SolidBrush(Color.FromArgb((int)(255 * op * alpha), color)))
                            g.FillEllipse(b, d.X * s - r, d.Y * s - r, 2 * r, 2 * r);
                    }
                }
                IntPtr h = bmp.GetHicon();
                var icon = (Icon)Icon.FromHandle(h).Clone();
                Native.DestroyIcon(h);
                return icon;
            }
        }

        /// The taskbar's own colour scheme: dark dots on a light taskbar, white on a dark one.
        public static Color Ink()
        {
            try
            {
                using (var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                {
                    object v = k == null ? null : k.GetValue("SystemUsesLightTheme");
                    if (v is int && (int)v == 1) return Color.FromArgb(28, 28, 28);
                }
            }
            catch { }
            return Color.White;
        }
    }

    // ---- Folder chooser: Windows' own "Select Folder" dialog (paste, New folder, address bar) ------------------

    static class FolderPicker
    {
        [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")]
        class FileOpenDialogCom { }

        [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        public interface IFileDialog
        {
            [PreserveSig] int Show(IntPtr parent);
            void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
            void SetFileTypeIndex(uint iFileType);
            void GetFileTypeIndex(out uint piFileType);
            void Advise(IntPtr pfde, out uint pdwCookie);
            void Unadvise(uint dwCookie);
            void SetOptions(uint fos);
            void GetOptions(out uint pfos);
            void SetDefaultFolder(IShellItem psi);
            void SetFolder(IShellItem psi);
            void GetFolder(out IShellItem ppsi);
            void GetCurrentSelection(out IShellItem ppsi);
            void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
            void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string pszName);
            void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
            void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
            void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
            void GetResult(out IShellItem ppsi);
            void AddPlace(IShellItem psi, int fdap);
            void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string pszDefaultExtension);
            void Close(int hr);
            void SetClientGuid(ref Guid guid);
            void ClearClientData();
            void SetFilter(IntPtr pFilter);
        }

        [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        public interface IShellItem
        {
            void BindToHandler(IntPtr pbc, [MarshalAs(UnmanagedType.LPStruct)] Guid bhid, [MarshalAs(UnmanagedType.LPStruct)] Guid riid, out IntPtr ppv);
            void GetParent(out IShellItem ppsi);
            void GetDisplayName(uint sigdnName, [MarshalAs(UnmanagedType.LPWStr)] out string ppszName);
            void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
            void Compare(IShellItem psi, uint hint, out int piOrder);
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        static extern void SHCreateItemFromParsingName(string pszPath, IntPtr pbc,
            [MarshalAs(UnmanagedType.LPStruct)] Guid riid, out IShellItem ppv);

        const uint FOS_PICKFOLDERS = 0x20, FOS_FORCEFILESYSTEM = 0x40, FOS_PATHMUSTEXIST = 0x800;
        const uint SIGDN_FILESYSPATH = 0x80058000;
        const int FDAP_TOP = 1;
        static readonly Guid ShellItemId = new Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE");

        public static IShellItem Item(string path)
        {
            try
            {
                IShellItem item;
                SHCreateItemFromParsingName(path, IntPtr.Zero, ShellItemId, out item);
                return item;
            }
            catch { return null; }
        }

        public static string PathOf(IShellItem item)
        {
            string path;
            item.GetDisplayName(SIGDN_FILESYSPATH, out path);
            return path;
        }

        /// The dialog with its options set, not shown (also used by the self-test).
        public static IFileDialog Make(string title, string okLabel, string start, IEnumerable<string> places)
        {
            var dlg = (IFileDialog)new FileOpenDialogCom();
            uint opts;
            dlg.GetOptions(out opts);
            dlg.SetOptions(opts | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST);
            dlg.SetTitle(title);
            dlg.SetOkButtonLabel(okLabel);
            var startItem = Item(start);
            if (startItem != null) dlg.SetFolder(startItem);
            foreach (var p in places.Reverse())
            {
                var it = Item(p);
                if (it != null) dlg.AddPlace(it, FDAP_TOP);
            }
            return dlg;
        }

        /// The chosen folder, or null if cancelled.
        public static string Pick(IWin32Window owner, string title, string okLabel, string start, IEnumerable<string> places)
        {
            try
            {
                var dlg = Make(title, okLabel, start, places);
                if (dlg.Show(owner == null ? IntPtr.Zero : owner.Handle) != 0) return null;
                IShellItem result;
                dlg.GetResult(out result);
                return PathOf(result);
            }
            catch (Exception e)
            {
                Util.Log("folder dialog: " + e.Message + "; using the classic one");
                using (var f = new FolderBrowserDialog { Description = title, SelectedPath = start, ShowNewFolderButton = true })
                    return f.ShowDialog(owner) == DialogResult.OK ? f.SelectedPath : null;
            }
        }
    }

    // ---- Search window (Ctrl+Alt+F) ---------------------------------------------------------------------------

    class SearchForm : Form
    {
        readonly TrayApp app;
        readonly TextBox box = new TextBox();
        readonly ListView list = new ListView();
        readonly Label status = new Label();
        readonly System.Windows.Forms.Timer debounce = new System.Windows.Forms.Timer { Interval = 350 };
        int generation;

        public SearchForm(TrayApp app)
        {
            this.app = app;
            Text = "Search Ripple Drive";
            Icon = Mark.Draw(32, Color.FromArgb(40, 103, 232), 1, -1);
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(720, 420);
            MinimumSize = new Size(480, 280);
            TopMost = true;
            KeyPreview = true;
            Font = new Font("Segoe UI", 10f);

            box.Dock = DockStyle.Top;
            box.Font = new Font("Segoe UI", 14f);
            box.TextChanged += (s, e) => { debounce.Stop(); debounce.Start(); };
            list.Dock = DockStyle.Fill;
            list.View = View.Details;
            list.FullRowSelect = true;
            list.MultiSelect = false;
            list.HideSelection = false;
            list.Columns.Add("Name", 280);
            list.Columns.Add("Where", 260);
            list.Columns.Add("Size", 80, HorizontalAlignment.Right);
            list.Columns.Add("Modified", 90);
            list.DoubleClick += (s, e) => OpenSelected(false);
            status.Dock = DockStyle.Bottom;
            status.Height = 26;
            status.Padding = new Padding(6, 4, 6, 0);
            status.ForeColor = SystemColors.GrayText;
            status.Text = "Type a file name.  Enter opens · Ctrl+Enter shows in File Explorer · Ctrl+Shift+C copies a share link";
            Controls.Add(list);
            Controls.Add(status);
            Controls.Add(box);
            debounce.Tick += (s, e) => { debounce.Stop(); Search(); };
            FormClosing += (s, e) => { if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); } };
        }

        public void ShowSearch()
        {
            Show();
            WindowState = FormWindowState.Normal;
            Activate();
            Native.SetForegroundWindow(Handle);
            box.Focus();
            box.SelectAll();
        }

        protected override bool ProcessCmdKey(ref Message msg, Keys keys)
        {
            if (keys == Keys.Escape) { Hide(); return true; }
            if (keys == Keys.Enter) { OpenSelected(false); return true; }
            if (keys == (Keys.Control | Keys.Enter)) { OpenSelected(true); return true; }
            if (keys == (Keys.Control | Keys.Shift | Keys.C)) { CopyLink(); return true; }
            if ((keys == Keys.Down || keys == Keys.Up) && box.Focused && list.Items.Count > 0)
            {
                int i = list.SelectedIndices.Count > 0 ? list.SelectedIndices[0] : -1;
                i = Math.Max(0, Math.Min(list.Items.Count - 1, i + (keys == Keys.Down ? 1 : -1)));
                list.Items[i].Selected = true;
                list.EnsureVisible(i);
                return true;
            }
            return base.ProcessCmdKey(ref msg, keys);
        }

        void Search()
        {
            string q = box.Text.Trim();
            int gen = ++generation;
            if (q.Length < 2) { list.Items.Clear(); return; }
            status.Text = "Searching your Drive...";
            ThreadPool.QueueUserWorkItem(_ =>
            {
                var args = new List<string> { P.Finder, "search" };
                args.AddRange(q.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries));
                args.Add("--limit"); args.Add("20");
                var r = Util.Run(app.Settings.Python, args, 60000);
                object parsed = null;
                try { parsed = Util.Json.DeserializeObject(r.Value.Trim()); } catch { }
                BeginInvoke((Action)(() => { if (gen == generation) ShowResults(parsed, r.Value); }));
            });
        }

        void ShowResults(object parsed, string raw)
        {
            list.Items.Clear();
            var err = parsed as Dictionary<string, object>;
            if (err != null) { status.Text = "Search didn't work: " + Util.Str(err, "error"); return; }
            var rows = parsed as object[];
            if (rows == null) { status.Text = "Search didn't work: " + raw.Split('\n').FirstOrDefault(); return; }
            foreach (Dictionary<string, object> f in rows.OfType<Dictionary<string, object>>())
            {
                string path = Util.Str(f, "path");
                string where = path == null ? (Util.Bool(f, "googleDoc") ? "Google Docs (opens in the browser)" : "Shared drive")
                                            : path.Contains('/') ? path.Substring(0, path.LastIndexOf('/')) : path;
                double size = Util.Num(f, "size");
                string mod = Util.Str(f, "modified") ?? "";
                var item = new ListViewItem(new[] { Util.Str(f, "name"), where, size > 0 ? Util.Human(size) : "", mod.Length >= 10 ? mod.Substring(0, 10) : mod });
                item.Tag = f;
                list.Items.Add(item);
            }
            if (list.Items.Count > 0) list.Items[0].Selected = true;
            status.Text = list.Items.Count == 0 ? "No files match."
                : "Enter opens · Ctrl+Enter shows in File Explorer · Ctrl+Shift+C copies a share link";
        }

        Dictionary<string, object> Selected()
        {
            return list.SelectedItems.Count > 0 ? list.SelectedItems[0].Tag as Dictionary<string, object> : null;
        }

        void OpenSelected(bool reveal)
        {
            var f = Selected();
            if (f == null) return;
            string path = Util.Str(f, "path");
            if (path == null) { Util.Open(Util.Str(f, "web")); Hide(); return; }
            string local = app.Settings.Drive + "\\" + path.Replace('/', '\\');
            if (reveal) Process.Start("explorer.exe", "/select," + Util.Quote(local));
            else Util.Open(local);
            Hide();
        }

        void CopyLink()
        {
            var f = Selected();
            if (f == null) return;
            status.Text = "Making a share link...";
            string id = Util.Str(f, "id");
            ThreadPool.QueueUserWorkItem(_ =>
            {
                var r = Util.Run(app.Settings.Python, new[] { P.Finder, "link", id }, 60000);
                BeginInvoke((Action)(() => status.Text = app.TakeLink(r.Value)));
            });
        }
    }

    // ---- Drop window ---------------------------------------------------------------------------------------------

    class DropForm : Form
    {
        readonly CheckBox move = new CheckBox();

        public DropForm(TrayApp app)
        {
            Text = "Upload to Ripple Drive";
            Icon = Mark.Draw(32, Color.FromArgb(40, 103, 232), 1, -1);
            FormBorderStyle = FormBorderStyle.FixedToolWindow;
            StartPosition = FormStartPosition.Manual;
            var area = Screen.PrimaryScreen.WorkingArea;
            ClientSize = new Size(300, 170);
            Location = new Point(area.Right - Width - 16, area.Bottom - Height - 16);
            TopMost = true;
            AllowDrop = true;
            Font = new Font("Segoe UI", 10f);
            var label = new Label
            {
                Text = "Drop files or folders here\r\n\r\nThen pick the Drive folder. Files are read where they are, never copied first.",
                Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter, ForeColor = Color.FromArgb(40, 103, 232)
            };
            move.Text = "Move: Recycle Bin once Drive confirms each file";
            move.Dock = DockStyle.Bottom;
            move.Height = 30;
            move.Padding = new Padding(8, 0, 0, 0);
            Controls.Add(label);
            Controls.Add(move);
            DragEnter += (s, e) => { e.Effect = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None; };
            DragDrop += (s, e) =>
            {
                var files = e.Data.GetData(DataFormats.FileDrop) as string[];
                if (files != null && files.Length > 0)
                {
                    bool m = move.Checked;
                    BeginInvoke((Action)(() => app.StartUpload(files.ToList(), m)));
                }
            };
            FormClosing += (s, e) => { if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); } };
        }
    }

    // ---- Hidden window that receives the Ctrl+Alt+F hotkey --------------------------------------------------

    class HotkeyWindow : NativeWindow, IDisposable
    {
        public event Action Pressed;
        public bool Registered;

        public HotkeyWindow()
        {
            CreateHandle(new CreateParams { Parent = new IntPtr(-3) });     // HWND_MESSAGE: a message-only window
            Registered = Native.RegisterHotKey(Handle, 1, Native.MOD_CONTROL | Native.MOD_ALT | Native.MOD_NOREPEAT, (uint)Keys.F);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == Native.WM_HOTKEY && Pressed != null) Pressed();
            base.WndProc(ref m);
        }

        public void Dispose()
        {
            if (Registered) Native.UnregisterHotKey(Handle, 1);
            DestroyHandle();
        }
    }

    // ---- The tray app ---------------------------------------------------------------------------------------------

    class TrayApp : ApplicationContext
    {
        public readonly Settings Settings = Settings.Load();
        readonly NotifyIcon tray = new NotifyIcon();
        readonly ContextMenuStrip menu = new ContextMenuStrip();
        readonly Form owner = new Form();             // invisible parent that brings dialogs to the front
        readonly System.Windows.Forms.Timer refreshTimer = new System.Windows.Forms.Timer { Interval = 2000 };
        readonly System.Windows.Forms.Timer animTimer = new System.Windows.Forms.Timer { Interval = 50 };
        readonly System.Windows.Forms.Timer requestTimer = new System.Windows.Forms.Timer { Interval = 700 };
        readonly object sync = new object();
        readonly AutoResetEvent mountWake = new AutoResetEvent(false);
        readonly Dictionary<string, KeyValuePair<double, DateTime>> lastOffsets = new Dictionary<string, KeyValuePair<double, DateTime>>();
        readonly Dictionary<string, double> speeds = new Dictionary<string, double>();
        HashSet<string> knownIds = new HashSet<string>(), knownFailed = new HashSet<string>();
        FileSystemWatcher watcher;
        HotkeyWindow hotkey;
        SearchForm search;
        DropForm drop;
        Process mountProc;
        volatile bool quitting, mounted, signedIn = true, signInExpired, online = true;
        List<Upload> uploads = new List<Upload>();
        double cacheBytes;
        double? driveUsed, driveTotal;
        DateTime lastAbout = DateTime.MinValue, lastCache = DateTime.MinValue, lastResume = DateTime.MinValue, animStart;
        bool pulsing, refreshing, busy;
        Icon currentIcon;

        public TrayApp(bool selfTest)
        {
            owner.ShowInTaskbar = false;
            owner.FormBorderStyle = FormBorderStyle.None;
            owner.StartPosition = FormStartPosition.Manual;
            owner.Location = new Point(-32000, -32000);
            owner.Size = new Size(1, 1);
            owner.Opacity = 0;
            menu.Opening += (s, e) => { Rebuild(); e.Cancel = false; };
            tray.ContextMenuStrip = menu;
            tray.Text = "Ripple Drive";
            tray.MouseUp += (s, e) =>
            {
                if (e.Button != MouseButtons.Left) return;
                var show = typeof(NotifyIcon).GetMethod("ShowContextMenu",
                    System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
                if (show != null) show.Invoke(tray, null);
            };
            tray.DoubleClick += (s, e) => OpenDrive();
            SetIcon();
            if (selfTest) return;

            tray.Visible = true;
            Directory.CreateDirectory(P.State);
            Directory.CreateDirectory(P.Requests);
            hotkey = new HotkeyWindow();
            hotkey.Pressed += ShowSearch;
            if (!hotkey.Registered) Util.Log("Ctrl+Alt+F is taken by another app; search stays in the menu");
            online = NetworkInterface.GetIsNetworkAvailable();
            NetworkChange.NetworkAvailabilityChanged += (s, e) => { online = e.IsAvailable; };
            refreshTimer.Tick += (s, e) => Refresh();
            refreshTimer.Start();
            animTimer.Tick += (s, e) => SetIcon();
            requestTimer.Tick += (s, e) => { requestTimer.Stop(); HandleWaiting(); };
            watcher = new FileSystemWatcher(P.Requests, "*.json");
            watcher.Created += (s, e) => owner.BeginInvoke((Action)(() => { requestTimer.Stop(); requestTimer.Start(); }));
            watcher.Renamed += (s, e) => owner.BeginInvoke((Action)(() => { requestTimer.Stop(); requestTimer.Start(); }));
            watcher.EnableRaisingEvents = true;
            var forceHandle = owner.Handle;            // BeginInvoke needs the window to exist
            new Thread(MountLoop) { IsBackground = true, Name = "mount" }.Start();
            Util.Log("app started");
            Refresh();
            requestTimer.Start();                      // anything that arrived before this copy was ready
        }

        // -- Requests ---------------------------------------------------------------------------------------------

        void HandleWaiting()
        {
            if (busy) { requestTimer.Start(); return; }   // a dialog is open: ask again once it closes
            var waiting = Requests.Take();
            foreach (var verb in new[] { "upload", "move" })
            {
                var paths = waiting.Where(r => r.Verb == verb).SelectMany(r => r.Paths).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
                if (paths.Count > 0) StartUpload(paths, verb == "move");
            }
            foreach (var r in waiting.Where(r => r.Verb == "link")) foreach (var p in r.Paths) CopyLink(p);
            if (waiting.Any(r => r.Verb == "show")) OpenDrive();
        }

        // -- The drive ----------------------------------------------------------------------------------------------

        bool InDrive(string path)
        {
            string d = Settings.Drive + "\\";
            return path.StartsWith(d, StringComparison.OrdinalIgnoreCase) || path.TrimEnd('\\').Equals(Settings.Drive, StringComparison.OrdinalIgnoreCase);
        }

        bool IsMounted() { return Directory.Exists(Settings.Drive + "\\"); }

        /// Keeps ripple-drive-mount.ps1 running: starts it, waits for it to end, starts it again (sooner after
        /// Reconnect). Without a Google sign-in there is nothing to mount, so it waits.
        void MountLoop()
        {
            while (!quitting)
            {
                var remotes = Util.Run(P.Rclone, new[] { "listremotes" }, 30000).Value;
                signedIn = remotes.Contains("ripple-drive:") && remotes.Contains("rd-my:");
                if (!signedIn) { mountWake.WaitOne(30000); continue; }
                Process p;
                try
                {
                    p = Util.Start(P.PowerShell, new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                                                         "-WindowStyle", "Hidden", "-File", P.MountScript });
                }
                catch (Exception e) { Util.Log("starting the drive: " + e.Message); mountWake.WaitOne(30000); continue; }
                lock (sync) mountProc = p;
                p.WaitForExit();
                lock (sync) mountProc = null;
                if (quitting) break;
                Util.Log("drive script ended (" + p.ExitCode + "); starting it again");
                mountWake.WaitOne(15000);
            }
        }

        void StopMount()
        {
            Process p;
            lock (sync) p = mountProc;
            if (p != null) { try { if (!p.HasExited) Util.KillTree(p.Id); } catch { } }
        }

        void Reconnect()
        {
            ThreadPool.QueueUserWorkItem(_ => { StopMount(); mountWake.Set(); });
            Notify("Ripple Drive", "Reconnecting the drive (about 10 seconds).");
        }

        // -- State ------------------------------------------------------------------------------------------------

        void Refresh()
        {
            if (refreshing) return;
            refreshing = true;
            bool doAbout = (DateTime.Now - lastAbout).TotalMinutes > 15;
            bool doCache = (DateTime.Now - lastCache).TotalSeconds > 20 || menu.Visible;
            bool doResume = (DateTime.Now - lastResume).TotalMinutes > 10;
            if (doAbout) lastAbout = DateTime.Now;
            if (doCache) lastCache = DateTime.Now;
            if (doResume) lastResume = DateTime.Now;
            ThreadPool.QueueUserWorkItem(_ =>
            {
                bool m = IsMounted();
                var ups = Queue.Read();
                double? cache = null;
                if (doCache) cache = CacheSize();
                if (doAbout) CheckAbout();
                // Like the Mac's login item: carry on with unfinished uploads every 10 minutes.
                if (doResume && ups.Any(u => !u.Failed && !u.Paused) && !Queue.UploaderRunning()) RunUploader(new[] { "--resume" });
                owner.BeginInvoke((Action)(() =>
                {
                    mounted = m;
                    if (cache.HasValue) cacheBytes = cache.Value;
                    Update(ups);
                    refreshing = false;
                }));
            });
        }

        static double CacheSize()
        {
            double total = 0;
            try
            {
                if (Directory.Exists(P.Cache))
                    foreach (var f in Directory.EnumerateFiles(P.Cache, "*", SearchOption.AllDirectories)) total += Native.Allocated(f);
            }
            catch { }
            return total;
        }

        /// rclone about: Drive usage, and whether Google still accepts the sign-in.
        void CheckAbout()
        {
            var r = Util.Run(P.Rclone, new[] { "about", "rd-my:", "--json" }, 60000);
            if (r.Key != 0)
            {
                string t = r.Value;
                signInExpired = t.Contains("invalid_grant") || t.Contains("token expired") || t.Contains("unauthorized");
                return;
            }
            signInExpired = false;
            try
            {
                int start = r.Value.IndexOf('{');
                var d = Util.Json.DeserializeObject(r.Value.Substring(Math.Max(0, start))) as Dictionary<string, object>;
                // Google's "used" is the whole account (Drive + Gmail + Photos): rclone splits it into used + other.
                driveUsed = Util.Num(d, "used") + Util.Num(d, "other");
                double total = Util.Num(d, "total");
                driveTotal = total > 0 ? (double?)total : null;
            }
            catch { }
        }

        void Update(List<Upload> ups)
        {
            var now = DateTime.Now;
            foreach (var u in ups)
            {
                KeyValuePair<double, DateTime> last;
                if (lastOffsets.TryGetValue(u.Id, out last))
                {
                    if (u.Offset > last.Key)
                    {
                        double s = (u.Offset - last.Key) / Math.Max(0.1, (now - last.Value).TotalSeconds);
                        double old;
                        speeds[u.Id] = speeds.TryGetValue(u.Id, out old) ? old * 0.6 + s * 0.4 : s;
                        lastOffsets[u.Id] = new KeyValuePair<double, DateTime>(u.Offset, now);
                    }
                    else if ((now - last.Value).TotalSeconds > 20) speeds[u.Id] = 0;
                }
                else lastOffsets[u.Id] = new KeyValuePair<double, DateTime>(u.Offset, now);
            }
            // Notifications: an id that vanished finished (or was cancelled); a new failure failed.
            var ids = new HashSet<string>(ups.Select(u => u.Id));
            var gone = knownIds.Where(i => !ids.Contains(i)).ToList();
            if (gone.Count > 0 && Settings.Notifications)
            {
                var done = Queue.FinishedToday();
                if (done.Count > 0) Notify("Uploaded to Ripple Drive", gone.Count == 1 ? done[0].Substring(7) : gone.Count + " files");
            }
            foreach (var u in ups.Where(x => x.Failed && !knownFailed.Contains(x.Id)))
                if (Settings.Notifications) Notify("Upload failed: " + u.Name, u.Error ?? "");
            knownIds = ids;
            knownFailed = new HashSet<string>(ups.Where(x => x.Failed).Select(x => x.Id));
            uploads = ups;
            SetIcon();
        }

        void SetIcon()
        {
            Color ink = Mark.Ink();
            float alpha = 1, pulse = -1;
            string tip = "Ripple Drive";
            var active = uploads.Where(u => !u.Failed).ToList();
            bool wasPulsing = pulsing;
            pulsing = false;
            if (!signedIn || signInExpired) { ink = Color.FromArgb(229, 72, 77); tip = "Ripple Drive: sign in to Google again"; }
            else if (!online || !mounted) { alpha = 0.4f; tip = online ? "Ripple Drive: not connected" : "Ripple Drive: no internet"; }
            else if (active.Any(u => u.Error != null && !u.Paused)) { ink = Color.FromArgb(245, 158, 11); tip = "Ripple Drive: Google is slow or limiting; retrying"; }
            else if (active.Any(u => !u.Paused))
            {
                double size = active.Sum(u => u.Size), done = active.Sum(u => u.Offset);
                int pct = (int)(100 * done / Math.Max(size, 1));
                pulsing = true;
                tip = string.Format("Ripple Drive: uploading {0} file{1}, {2}%", active.Count, active.Count == 1 ? "" : "s", pct);
            }
            else if (active.Count > 0) tip = "Ripple Drive: uploads paused";
            if (pulsing && !wasPulsing) animStart = DateTime.Now;
            if (pulsing) { pulse = (float)(((DateTime.Now - animStart).TotalSeconds % 1.8) / 1.8); if (!animTimer.Enabled) animTimer.Start(); }
            else animTimer.Stop();
            var icon = Mark.Draw(32, ink, alpha, pulse);
            tray.Icon = icon;
            if (currentIcon != null) currentIcon.Dispose();
            currentIcon = icon;
            tray.Text = tip.Length > 63 ? tip.Substring(0, 63) : tip;   // Windows' limit for tray tips
        }

        // -- Menu ---------------------------------------------------------------------------------------------------

        ToolStripMenuItem Add(ToolStripItemCollection to, string title, Action action)
        {
            var item = new ToolStripMenuItem(title);
            if (action == null) item.Enabled = false;
            else item.Click += (s, e) => action();
            to.Add(item);
            return item;
        }

        void Rebuild()
        {
            menu.Items.Clear();
            string status = "On this PC: " + Util.Human(cacheBytes);
            if (driveUsed.HasValue) status += "  ·  In your Drive: " + Util.Human(driveUsed.Value) + (driveTotal.HasValue ? " of " + Util.Human(driveTotal.Value) : "");
            Add(menu.Items, status, null);
            string state;
            if (!signedIn) state = "Not signed in to Google — choose Sign In";
            else if (signInExpired) state = "Google sign-in expired — choose Sign In Again";
            else if (!online) state = "No internet: files open again when you're back online";
            else if (!mounted) state = "Drive not connected — choose Reconnect Drive";
            else state = "Connected as " + Settings.Drive + "\\";
            Add(menu.Items, state, null);
            menu.Items.Add(new ToolStripSeparator());

            if (uploads.Count == 0) Add(menu.Items, "No uploads in progress", null);
            else
            {
                Add(menu.Items, "Uploads", null);
                foreach (var u in uploads)
                {
                    double speed;
                    speeds.TryGetValue(u.Id, out speed);
                    string line = u.Name + "   " + (int)(100 * u.Fraction) + "%";
                    if (u.Failed) line += "  ·  failed";
                    else if (u.Paused) line += "  ·  paused";
                    else if (u.Error != null) line += "  ·  retrying";
                    else if (speed > 0) line += "  ·  " + Util.Human(speed) + "/s";
                    var row = new ToolStripMenuItem(line);
                    Add(row.DropDownItems, "To " + u.Dest, null);
                    if (u.Error != null) Add(row.DropDownItems, u.Error.Length > 90 ? u.Error.Substring(0, 90) + "…" : u.Error, null);
                    string id = u.Id;
                    if (!u.Failed) Add(row.DropDownItems, u.Paused ? "Resume" : "Pause", () => TogglePause(id));
                    Add(row.DropDownItems, "Cancel Upload…", () => CancelUpload(id));
                    menu.Items.Add(row);
                }
                if (uploads.Any(u => u.Failed)) Add(menu.Items, "Retry Failed Uploads", () => { RunUploader(new[] { "--resume", "--retry-failed" }); Refresh(); });
            }
            var done = Queue.FinishedToday();
            if (done.Count > 0)
            {
                var sub = new ToolStripMenuItem("Uploaded in the Last 24 Hours");
                foreach (var d in done) Add(sub.DropDownItems, d, null);
                menu.Items.Add(sub);
            }
            menu.Items.Add(new ToolStripSeparator());
            Add(menu.Items, "Open Ripple Drive", OpenDrive);
            Add(menu.Items, "Search Drive…" + (hotkey != null && hotkey.Registered ? "\tCtrl+Alt+F" : ""), ShowSearch);
            Add(menu.Items, "Upload Files…", () => PickAndUpload(false));
            Add(menu.Items, "Upload Window (drag and drop)", ShowDrop);
            bool pausedAll = File.Exists(Path.Combine(P.State, ".pause-all"));
            Add(menu.Items, pausedAll ? "Resume All Uploads" : "Pause All Uploads", TogglePauseAll);
            menu.Items.Add(new ToolStripSeparator());
            Add(menu.Items, "Reconnect Drive", Reconnect);
            Add(menu.Items, signedIn ? "Sign In Again…" : "Sign In…", SignIn);
            var settings = new ToolStripMenuItem("Settings");
            var login = Add(settings.DropDownItems, "Start at Login", () => { Settings.StartAtLogin = !Settings.StartAtLogin; Settings.Save(); });
            login.Checked = Settings.StartAtLogin;
            var notes = Add(settings.DropDownItems, "Notifications", () => { Settings.Notifications = !Settings.Notifications; Settings.Save(); });
            notes.Checked = Settings.Notifications;
            menu.Items.Add(settings);
            Add(menu.Items, "Show Logs", () => Util.Open(P.Logs));
            menu.Items.Add(new ToolStripSeparator());
            Add(menu.Items, "Quit Ripple Drive (disconnects the drive)", Quit);
        }

        // -- Actions --------------------------------------------------------------------------------------------------

        void OpenDrive()
        {
            if (IsMounted()) Util.Open(Settings.Drive + "\\");
            else Notify("Ripple Drive isn't connected", signedIn ? "Choose Reconnect Drive in the menu." : "Choose Sign In in the menu.");
        }

        void ShowSearch()
        {
            if (search == null) search = new SearchForm(this);
            search.ShowSearch();
        }

        void ShowDrop()
        {
            if (drop == null) drop = new DropForm(this);
            drop.Show();
            drop.Activate();
        }

        void PickAndUpload(bool move)
        {
            using (var dlg = new OpenFileDialog { Multiselect = true, Title = "Pick files to upload (they are read where they are, never copied first)" })
            {
                BringOwnerForward();
                if (dlg.ShowDialog(owner) == DialogResult.OK && dlg.FileNames.Length > 0) StartUpload(dlg.FileNames.ToList(), move);
            }
        }

        void BringOwnerForward()
        {
            owner.Show();
            owner.Activate();
            Native.SetForegroundWindow(owner.Handle);
        }

        /// Asks where in the drive the files go (the dialog opens at My Drive, recent folders on the left),
        /// then hands them to the uploader.
        public void StartUpload(List<string> paths, bool move)
        {
            var outside = paths.Where(p => !InDrive(p)).ToList();
            if (outside.Count == 0) { Alert("These are already in Ripple Drive."); return; }
            if (!IsMounted()) { Alert("Ripple Drive isn't connected. Choose Reconnect Drive in its menu, then try again."); return; }
            string what = outside.Count == 1 ? "\u201C" + Path.GetFileName(outside[0].TrimEnd('\\')) + "\u201D" : outside.Count + " items";
            string start = Path.Combine(Settings.Drive + "\\", "My Drive");
            var recent = Settings.Recent.Where(Directory.Exists).Take(6).ToList();
            string dest;
            busy = true;
            try
            {
                BringOwnerForward();
                dest = FolderPicker.Pick(owner, "Choose the Ripple Drive folder for " + what + (move ? " (moved: originals go to the Recycle Bin)" : ""),
                                         move ? "Move Here" : "Upload Here", start, recent);
                owner.Hide();
            }
            finally { busy = false; }
            if (dest == null) return;
            dest = dest.TrimEnd('\\');
            string rel = InDrive(dest) ? dest.Substring(Settings.Drive.Length).Trim('\\') : "";
            string top = rel.Split('\\')[0];
            if (!InDrive(dest) || (top != "My Drive" && top != "Shared with me") || (top == "Shared with me" && !rel.Contains('\\')))
            {
                Alert("Pick a folder inside Ripple Drive (My Drive, or a folder in Shared with me).");
                return;
            }
            Settings.Recent = new[] { dest }.Concat(Settings.Recent.Where(r => !r.Equals(dest, StringComparison.OrdinalIgnoreCase))).Take(6).ToList();
            Settings.Save();
            var args = new List<string>(outside) { "--to", dest };
            if (move) args.Add("--move");
            RunUploader(args);
            Notify("Uploading " + (outside.Count == 1 ? Path.GetFileName(outside[0].TrimEnd('\\')) : outside.Count + " items"), "to " + rel.Replace('\\', '/'));
            owner.BeginInvoke((Action)(() => Refresh()));
        }

        void RunUploader(IEnumerable<string> args)
        {
            try { Util.Start(Settings.Python, new[] { P.Uploader }.Concat(args)); }
            catch (Exception e) { Util.Log("uploader: " + e.Message); Notify("Upload didn't start", "Python wasn't found. Run install.ps1 again."); }
        }

        void TogglePause(string id)
        {
            string marker = Path.Combine(P.State, id + ".pause");
            if (File.Exists(marker)) { File.Delete(marker); RunUploader(new[] { "--resume" }); }
            else File.WriteAllText(marker, "");
            Refresh();
        }

        void TogglePauseAll()
        {
            string marker = Path.Combine(P.State, ".pause-all");
            if (File.Exists(marker)) { File.Delete(marker); RunUploader(new[] { "--resume" }); }
            else File.WriteAllText(marker, "");
            Refresh();
        }

        void CancelUpload(string id)
        {
            var u = uploads.FirstOrDefault(x => x.Id == id);
            if (u == null) return;
            BringOwnerForward();
            var answer = MessageBox.Show(owner, "Cancel uploading \u201C" + u.Name + "\u201D?\r\n\r\nThe original stays where it is. What already reached Google is discarded.",
                                         "Ripple Drive", MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2);
            owner.Hide();
            if (answer != DialogResult.Yes) return;
            // A running uploader picks the marker up before its next piece; with none running, clear it here.
            File.WriteAllText(Path.Combine(P.State, id + ".cancel"), "");
            if (!Queue.UploaderRunning())
                foreach (var ext in new[] { ".json", ".cancel", ".pause" })
                    try { File.Delete(Path.Combine(P.State, id + ext)); } catch { }
            Refresh();
        }

        void SignIn()
        {
            if (!signedIn)
            {
                // The first sign-in needs the client ID and secret typed in: a visible PowerShell window. The drive
                // starts by itself within 30 seconds of it finishing.
                try
                {
                    Process.Start(new ProcessStartInfo(P.PowerShell, "-NoProfile -ExecutionPolicy Bypass -NoExit -File " + Util.Quote(P.SigninScript))
                                  { UseShellExecute = true });
                }
                catch (Exception e) { Alert("Couldn't open the sign-in window: " + e.Message); }
                return;
            }
            Notify("Ripple Drive", "Google's sign-in page is opening in your browser.");
            ThreadPool.QueueUserWorkItem(_ =>
            {
                var r = Util.Run(P.Rclone, new[] { "config", "reconnect", "rd-my:", "--auto-confirm" }, 10 * 60000);
                owner.BeginInvoke((Action)(() =>
                {
                    lastAbout = DateTime.MinValue;
                    if (r.Key == 0) { signInExpired = false; Notify("Signed in to Google again", "Ripple Drive is reconnecting."); Reconnect(); }
                    else Notify("Sign-in didn't finish", "Try Sign In Again from the menu.");
                    Refresh();
                }));
            });
        }

        void CopyLink(string path)
        {
            if (!InDrive(path)) { Notify("Ripple Drive", "Only files inside Ripple Drive have Drive links."); return; }
            ThreadPool.QueueUserWorkItem(_ =>
            {
                var r = Util.Run(Settings.Python, new[] { P.Finder, "link", "--path", path }, 60000);
                owner.BeginInvoke((Action)(() => Notify("Ripple Drive", TakeLink(r.Value))));
            });
        }

        /// Puts a link from ripple-drive-find's answer on the clipboard; returns what to tell the user.
        public string TakeLink(string answer)
        {
            Dictionary<string, object> d = null;
            try { d = Util.Json.DeserializeObject(answer.Trim()) as Dictionary<string, object>; } catch { }
            if (d == null || Util.Str(d, "link") == null)
                return "Couldn't make a link: " + (d != null && Util.Str(d, "error") != null ? Util.Str(d, "error") : answer.Split('\n').FirstOrDefault());
            try { Clipboard.SetText(Util.Str(d, "link")); } catch (Exception e) { return "Couldn't use the clipboard: " + e.Message; }
            return "Link copied: " + Util.Str(d, "name") + (Util.Bool(d, "restricted") ? " (only people with access can open it)" : "");
        }

        void Quit()
        {
            quitting = true;
            refreshTimer.Stop();
            animTimer.Stop();
            tray.Visible = false;
            if (hotkey != null) hotkey.Dispose();
            StopMount();
            mountWake.Set();
            Util.Log("app quit");
            ExitThread();
        }

        void Alert(string text)
        {
            BringOwnerForward();
            MessageBox.Show(owner, text, "Ripple Drive", MessageBoxButtons.OK, MessageBoxIcon.Information);
            owner.Hide();
        }

        void Notify(string title, string body)
        {
            try { tray.ShowBalloonTip(5000, title, string.IsNullOrEmpty(body) ? " " : body, ToolTipIcon.None); }
            catch (Exception e) { Util.Log("notify: " + e.Message); }
        }

        // -- Self-test (GitHub's Windows test machine) ----------------------------------------------------------

        public string SelfTestMenu()
        {
            uploads = Queue.Read();
            Rebuild();
            return string.Join(" | ", menu.Items.OfType<ToolStripItem>().Select(i => i.Text).Where(t => !string.IsNullOrEmpty(t)).ToArray());
        }
    }

    static class SelfTest
    {
        public static int Run(string outFile)
        {
            var lines = new List<string>();
            int failures = 0;
            Action<string, Func<string>> check = (name, test) =>
            {
                try { lines.Add("ok   " + name + ": " + test()); }
                catch (Exception e) { failures++; lines.Add("FAIL " + name + ": " + e.GetType().Name + ": " + e.Message); }
            };
            check("quote", () =>
            {
                var cases = new Dictionary<string, string> { { "plain", "plain" }, { "two words", "\"two words\"" },
                    { @"C:\a b\", "\"C:\\a b\\\\\"" }, { "say \"hi\"", "\"say \\\"hi\\\"\"" }, { "", "\"\"" } };
                foreach (var c in cases) if (Util.Quote(c.Key) != c.Value) throw new Exception(c.Key + " -> " + Util.Quote(c.Key));
                return cases.Count + " cases";
            });
            check("icons", () =>
            {
                foreach (var c in new[] { Color.White, Color.Black, Color.Red })
                    foreach (var pulse in new[] { -1f, 0.3f, 0.7f }) using (var i = Mark.Draw(32, c, 0.5f, pulse)) if (i.Width != 32) throw new Exception("size");
                return "9 drawn";
            });
            check("settings", () => { var s = Settings.Load(); return "drive " + s.Drive + ", python " + s.Python; });
            check("queue", () => Queue.Read().Count + " uploads, uploader running: " + Queue.UploaderRunning());
            check("finished", () => Queue.FinishedToday().Count + " in the last day");
            check("requests", () =>
            {
                Requests.Send(new[] { "--upload", @"C:\a b\c.txt", @"D:\x" });
                var got = Requests.Take();
                var r = got.LastOrDefault();
                if (r == null || r.Verb != "upload" || r.Paths.Count != 2 || r.Paths[0] != @"C:\a b\c.txt") throw new Exception("round trip");
                return "round trip";
            });
            check("folder dialog", () =>
            {
                string win = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
                var item = FolderPicker.Item(win);
                if (item == null) throw new Exception("no shell item for " + win);
                string back = FolderPicker.PathOf(item);
                if (!back.Equals(win, StringComparison.OrdinalIgnoreCase)) throw new Exception(back);
                var dlg = FolderPicker.Make("Test", "Upload Here", win, new[] { win });
                Marshal.ReleaseComObject(dlg);
                return "IFileOpenDialog and IShellItem work (" + back + ")";
            });
            check("hotkey", () => { using (var h = new HotkeyWindow()) return h.Registered ? "Ctrl+Alt+F registered" : "Ctrl+Alt+F taken (menu still works)"; });
            check("menu", () => { var app = new TrayApp(true); return app.SelfTestMenu(); });
            check("forms", () => { var app = new TrayApp(true); using (new SearchForm(app)) using (new DropForm(app)) return "search and drop windows build"; });
            lines.Add(failures == 0 ? "selftest passed" : "selftest FAILED: " + failures);
            string text = string.Join("\r\n", lines.ToArray()) + "\r\n";
            if (outFile != null) File.WriteAllText(outFile, text, new UTF8Encoding(false));
            return failures == 0 ? 0 : 1;
        }
    }
}
