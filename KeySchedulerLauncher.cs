using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

namespace KeyScheduler
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            try
            {
                string scriptPath = ExtractScript();
                StartPowerShell(scriptPath);
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    "Could not start Key Scheduler.\r\n\r\n" + ex.Message,
                    "Key Scheduler",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
            }
        }

        private static string ExtractScript()
        {
            Assembly assembly = Assembly.GetExecutingAssembly();
            using (Stream stream = assembly.GetManifestResourceStream("KeyScheduler.ps1"))
            {
                if (stream == null)
                {
                    throw new InvalidOperationException("Embedded app script was not found.");
                }

                string tempDir = Path.Combine(Path.GetTempPath(), "KeyScheduler", Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(tempDir);

                string scriptPath = Path.Combine(tempDir, "KeyScheduler.ps1");
                using (FileStream output = File.Create(scriptPath))
                {
                    stream.CopyTo(output);
                }

                return scriptPath;
            }
        }

        private static void StartPowerShell(string scriptPath)
        {
            string powerShellPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe");

            if (!File.Exists(powerShellPath))
            {
                powerShellPath = "powershell.exe";
            }

            ProcessStartInfo startInfo = new ProcessStartInfo
            {
                FileName = powerShellPath,
                Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + scriptPath + "\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = Path.GetDirectoryName(scriptPath)
            };

            Process.Start(startInfo);
        }
    }
}
