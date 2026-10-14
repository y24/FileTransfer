// FileTransfer.exe: starts FileTransfer.ps1 with Windows PowerShell without showing a console window.
// (powershell.exe -WindowStyle Hidden still flashes a window, and does not hide it when
//  Windows Terminal is the default terminal.)
// Build: tools\Build-Launcher.ps1   Keep this file ASCII-only.
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

static class Launcher
{
    [STAThread]
    static int Main()
    {
        string appDir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(appDir, "FileTransfer.ps1");
        string powershell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
        string logDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"FileTransfer\logs");

        ProcessStartInfo info = new ProcessStartInfo(powershell,
            "-NoProfile -NoLogo -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"");
        info.UseShellExecute = false;
        info.CreateNoWindow = true;
        info.WorkingDirectory = appDir;

        try
        {
            Process process = Process.Start(info);
            // If the script stops right away (execution policy, broken files, ...), tell the user.
            if (process.WaitForExit(8000) && process.ExitCode != 0)
            {
                // "Could not start FileTransfer. See the log for details:" (Japanese)
                MessageBox.Show(
                    "FileTransfer \u3092\u8D77\u52D5\u3067\u304D\u307E\u305B\u3093\u3067\u3057\u305F\u3002\n" +
                    "\u8A73\u3057\u304F\u306F\u30ED\u30B0\u3092\u78BA\u8A8D\u3057\u3066\u304F\u3060\u3055\u3044:\n" + logDir,
                    "FileTransfer", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return process.ExitCode;
            }
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "FileTransfer", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
