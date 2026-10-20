using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;

namespace PCL.DL.RestorePatch.GUI {
    public partial class MainWindow : Window {
        private static readonly Brush AccentBrush = new SolidColorBrush(Color.FromRgb(0x25, 0x63, 0xEB));
        private static readonly Brush MutedBrush = new SolidColorBrush(Color.FromRgb(0x64, 0x74, 0x8B));
        private static readonly Brush SuccessBrush = new SolidColorBrush(Color.FromRgb(0x16, 0xA3, 0x4A));
        private static readonly Brush ErrorBrush = new SolidColorBrush(Color.FromRgb(0xDC, 0x26, 0x26));
        private static readonly Brush CardBorderBrush = new SolidColorBrush(Color.FromRgb(0xE2, 0xE8, 0xF0));

        private readonly PatchRunner _runner = new PatchRunner();
        private bool _running;
        private string _targetPath;
        private string _lastOutputPath;

        public MainWindow() {
            InitializeComponent();
        }

        private void BrowseButton_Click(object sender, RoutedEventArgs e) {
            var dialog = new Microsoft.Win32.OpenFileDialog {
                Title = "选择 PCL exe",
                Filter = "可执行文件 (*.exe)|*.exe",
                CheckFileExists = true
            };

            if (dialog.ShowDialog(this) == true) {
                SetTarget(dialog.FileName);
            }
        }

        private void SetTarget(string path) {
            if (!File.Exists(path) || !IsExe(path)) {
                SetStatus("请选择 .exe 文件", ErrorBrush);
                return;
            }

            string version;
            try {
                version = FileVersionInfo.GetVersionInfo(path).FileVersion;
            }
            catch (Exception ex) {
                SetStatus("无法读取文件版本：" + ex.Message, ErrorBrush);
                return;
            }
            if (string.IsNullOrEmpty(version) || !version.StartsWith("2.99.", StringComparison.Ordinal)) {
                SetStatus("仅支持 PCL 2.99.x，当前版本：" + (string.IsNullOrEmpty(version) ? "未知" : version), ErrorBrush);
                return;
            }

            _targetPath = Path.GetFullPath(path);
            TargetFileName.Text = Path.GetFileName(_targetPath);
            TargetDirectory.Text = Path.GetDirectoryName(_targetPath);
            TargetDisplayBorder.ToolTip = _targetPath;
            TargetDisplay.Visibility = Visibility.Visible;
            TargetPlaceholder.Visibility = Visibility.Collapsed;
            OpenOutputButton.Visibility = Visibility.Collapsed;
            _lastOutputPath = null;
            StartButton.IsEnabled = !_running;
            LogBox.Clear();
            SetStatus("已选择 " + Path.GetFileName(path) + "（PCL " + version + "）", AccentBrush);
        }

        private async void StartButton_Click(object sender, RoutedEventArgs e) {
            if (_running) {
                return;
            }

            var target = _targetPath;
            if (string.IsNullOrEmpty(target) || !File.Exists(target)) {
                SetStatus("文件不存在", ErrorBrush);
                return;
            }

            _running = true;
            SetRunningState(true);
            LogBox.Clear();
            OpenOutputButton.Visibility = Visibility.Collapsed;
            _lastOutputPath = null;
            SetStatus("正在处理，请稍候…", AccentBrush);

            try {
                var result = await _runner.RunAsync(target, AppendLog);
                if (result.ExitCode == 0 && File.Exists(result.OutputPath)) {
                    AppendLog("输出：" + result.OutputPath);
                    _lastOutputPath = result.OutputPath;
                    OpenOutputButton.Visibility = Visibility.Visible;
                    SetStatus("补丁完成", SuccessBrush);
                }
                else {
                    if (result.ExitCode == 0) {
                        AppendLog("没有找到输出文件：" + result.OutputPath);
                    }
                    SetStatus("补丁失败，请查看日志", ErrorBrush);
                }
            }
            catch (Exception ex) {
                AppendLog("[GUI] " + ex.Message);
                SetStatus("运行失败：" + ex.Message, ErrorBrush);
            }
            finally {
                _running = false;
                SetRunningState(false);
            }
        }

        private void OpenOutputButton_Click(object sender, RoutedEventArgs e) {
            if (string.IsNullOrEmpty(_lastOutputPath) || !File.Exists(_lastOutputPath)) {
                OpenOutputButton.Visibility = Visibility.Collapsed;
                SetStatus("输出文件不存在", ErrorBrush);
                return;
            }

            try {
                Process.Start("explorer.exe", "/select,\"" + _lastOutputPath + "\"");
            }
            catch (Exception ex) {
                SetStatus("无法打开输出目录：" + ex.Message, ErrorBrush);
            }
        }

        private void SetRunningState(bool running) {
            StartButton.IsEnabled = !running && !string.IsNullOrEmpty(_targetPath);
            OpenOutputButton.IsEnabled = !running;
            BrowseButton.IsEnabled = !running;
            RunProgress.Visibility = running ? Visibility.Visible : Visibility.Collapsed;
            Cursor = running ? Cursors.Wait : Cursors.Arrow;
        }

        private void AppendLog(string line) {
            if (!Dispatcher.CheckAccess()) {
                Dispatcher.BeginInvoke(new Action(delegate { AppendLog(line); }));
                return;
            }

            LogBox.AppendText(line + Environment.NewLine);
            LogBox.ScrollToEnd();
            LogPlaceholder.Visibility = Visibility.Collapsed;
        }

        private void SetStatus(string message, Brush brush) {
            StatusText.Text = message;
            StatusText.Foreground = brush;
            StatusDot.Fill = brush;
        }

        private void Window_DragOver(object sender, DragEventArgs e) {
            var valid = !_running && HasExeFile(e.Data);
            e.Effects = valid ? DragDropEffects.Copy : DragDropEffects.None;
            DropCard.BorderBrush = valid ? AccentBrush : CardBorderBrush;
            e.Handled = true;
        }

        private void Window_DragLeave(object sender, DragEventArgs e) {
            DropCard.BorderBrush = CardBorderBrush;
        }

        private void Window_Drop(object sender, DragEventArgs e) {
            e.Handled = true;
            DropCard.BorderBrush = CardBorderBrush;
            if (_running) {
                return;
            }

            var file = GetFiles(e.Data).FirstOrDefault(IsExe);
            if (file == null) {
                SetStatus("只能拖入 .exe 文件", ErrorBrush);
                return;
            }

            SetTarget(file);
        }

        private static bool HasExeFile(IDataObject data) {
            return GetFiles(data).Any(IsExe);
        }

        private static string[] GetFiles(IDataObject data) {
            if (data == null || !data.GetDataPresent(DataFormats.FileDrop)) {
                return new string[0];
            }

            return data.GetData(DataFormats.FileDrop) as string[] ?? new string[0];
        }

        private static bool IsExe(string file) {
            return string.Equals(Path.GetExtension(file), ".exe", StringComparison.OrdinalIgnoreCase);
        }

        private void Window_Closing(object sender, CancelEventArgs e) {
            if (!_running) {
                return;
            }

            if (MessageBox.Show(this, "补丁正在运行，确定退出吗？", "确认退出", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes) {
                _runner.Cancel();
            }
            else {
                e.Cancel = true;
            }
        }
    }
}