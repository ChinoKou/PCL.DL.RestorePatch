using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace PCL.DL.RestorePatch.GUI {
    internal sealed class PatchRunner {
        internal const string PclExeName = "Plain Craft Launcher 2.exe";

        private const string Ps1ResourceName = "PCL.DL.RestorePatch.ps1";
        private const string CecilResourceName = "Mono.Cecil.dll";
        private const string CecilCompressedResourceName = "Mono.Cecil.dll.deflate";

        private readonly object _sync = new object();
        private Process _process;

        internal static string GetOutputPath(string exePath) {
            var fullPath = Path.GetFullPath(exePath);
            return Path.Combine(
                Path.GetDirectoryName(fullPath),
                Path.GetFileNameWithoutExtension(fullPath) + " (dl-restore).exe");
        }

        public Task<PatchResult> RunAsync(string exePath, Action<string> onLine) {
            if (exePath == null) {
                throw new ArgumentNullException("exePath");
            }

            var fullPath = Path.GetFullPath(exePath);
            return Task.Run(delegate { return RunCore(fullPath, onLine); });
        }

        private PatchResult RunCore(string exePath, Action<string> onLine) {
            try {
                File.Delete(GetOutputPath(exePath) + ".tmp");
            }
            catch (IOException) {
            }
            catch (UnauthorizedAccessException) {
            }

            var workDir = Path.Combine(Path.GetTempPath(), "pcl_dl_restore_gui_" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(workDir);

            try {
                var scriptPath = Path.Combine(workDir, Ps1ResourceName);
                ExtractResource(Ps1ResourceName, scriptPath);

#if BUNDLED_CECIL
                var cecilPath = Path.Combine(workDir, CecilResourceName);
                ExtractDeflateResource(CecilCompressedResourceName, cecilPath);
#endif

                var wrapperPath = Path.Combine(workDir, "run.ps1");
                var wrapper = new StringBuilder();
                wrapper.AppendLine("$ProgressPreference = 'SilentlyContinue'");
                wrapper.AppendLine("[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false");
                var invocation = "& '" + EscapeSingleQuoted(scriptPath) + "' -Path '" + EscapeSingleQuoted(exePath) + "'";
#if BUNDLED_CECIL
                invocation += " -CecilDll '" + EscapeSingleQuoted(cecilPath) + "'";
#endif
                wrapper.AppendLine("try {");
                wrapper.AppendLine("    " + invocation);
                wrapper.AppendLine("    exit $LASTEXITCODE");
                wrapper.AppendLine("}");
                wrapper.AppendLine("catch {");
                wrapper.AppendLine("    Write-Host $_");
                wrapper.AppendLine("    exit 1");
                wrapper.AppendLine("}");
                File.WriteAllText(wrapperPath, wrapper.ToString(), new UTF8Encoding(true));

                var startInfo = new ProcessStartInfo {
                    FileName = GetPowerShellPath(),
                    Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + wrapperPath + "\"",
                    WorkingDirectory = Path.GetDirectoryName(exePath),
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    StandardOutputEncoding = new UTF8Encoding(false),
                    StandardErrorEncoding = new UTF8Encoding(false)
                };

                var process = new Process { StartInfo = startInfo };
                process.OutputDataReceived += delegate (object sender, DataReceivedEventArgs e) {
                    if (e.Data != null) {
                        Emit(onLine, e.Data);
                    }
                };
                process.ErrorDataReceived += delegate (object sender, DataReceivedEventArgs e) {
                    if (e.Data != null) {
                        Emit(onLine, "[stderr] " + e.Data);
                    }
                };

                lock (_sync) {
                    _process = process;
                }

                try {
                    if (!process.Start()) {
                        throw new InvalidOperationException("无法启动 PowerShell。");
                    }

                    process.BeginOutputReadLine();
                    process.BeginErrorReadLine();
                    process.WaitForExit();
                    process.WaitForExit(1000);

                    return new PatchResult {
                        ExitCode = process.ExitCode,
                        OutputPath = GetOutputPath(exePath)
                    };
                }
                finally {
                    lock (_sync) {
                        if (ReferenceEquals(_process, process)) {
                            _process = null;
                        }
                    }
                    try {
                        process.Dispose();
                    }
                    catch (InvalidOperationException) {
                    }
                }
            }
            finally {
                TryDeleteDirectory(workDir);
            }
        }

        public void Cancel() {
            Process process;
            lock (_sync) {
                process = _process;
            }
            if (process == null) {
                return;
            }

            try {
                if (!process.HasExited) {
                    process.Kill();
                }
            }
            catch (InvalidOperationException) {
            }
            catch (System.ComponentModel.Win32Exception) {
            }
        }

        private static void Emit(Action<string> onLine, string line) {
            if (onLine == null) {
                return;
            }

            try {
                onLine(line);
            }
            catch (Exception) {
                // UI 已关闭时忽略回调异常
            }
        }

        private static void ExtractResource(string name, string destination) {
            var assembly = Assembly.GetExecutingAssembly();
            using (var stream = assembly.GetManifestResourceStream(name)) {
                if (stream == null) {
                    throw new InvalidOperationException("缺少嵌入资源：" + name);
                }

                using (var file = File.Create(destination)) {
                    stream.CopyTo(file);
                }
            }
        }

        private static void ExtractDeflateResource(string name, string destination) {
            using (var compressed = Assembly.GetExecutingAssembly().GetManifestResourceStream(name)) {
                if (compressed == null) {
                    throw new InvalidOperationException("缺少嵌入资源：" + name);
                }

                using (var deflate = new DeflateStream(compressed, CompressionMode.Decompress)) {
                    using (var file = File.Create(destination)) {
                        deflate.CopyTo(file);
                    }
                }
            }
        }

        private static string EscapeSingleQuoted(string value) {
            return value.Replace("'", "''");
        }

        private static string GetPowerShellPath() {
            var systemDirectory = Environment.GetFolderPath(Environment.SpecialFolder.System);
            var path = Path.Combine(systemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
            return File.Exists(path) ? path : "powershell.exe";
        }

        private static void TryDeleteDirectory(string directory) {
            for (var attempt = 0; attempt < 5; attempt++) {
                try {
                    if (Directory.Exists(directory)) {
                        Directory.Delete(directory, true);
                    }
                    return;
                }
                catch (IOException) {
                    Thread.Sleep(100);
                }
                catch (UnauthorizedAccessException) {
                    Thread.Sleep(100);
                }
            }
        }
    }
}