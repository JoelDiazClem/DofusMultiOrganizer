using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

// Minimal launcher: extracts the bundled PowerShell script (embedded resource)
// to %TEMP% and runs it with the Windows built-in powershell.exe, without a console window.
static class Launcher {
    [STAThread]
    static int Main() {
        try {
            string script;
            using (Stream res = Assembly.GetExecutingAssembly().GetManifestResourceStream("dofus-multi.bundle.ps1"))
            using (StreamReader reader = new StreamReader(res, Encoding.UTF8)) {
                script = reader.ReadToEnd();
            }

            string dir = Path.Combine(Path.GetTempPath(), "DofusMulti");
            Directory.CreateDirectory(dir);
            string scriptPath = Path.Combine(dir, "dofus-multi.ps1");
            // UTF-8 with BOM so Windows PowerShell 5.1 reads accented characters correctly
            File.WriteAllText(scriptPath, script, new UTF8Encoding(true));

            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                                             @"WindowsPowerShell\v1.0\powershell.exe");

            ProcessStartInfo psi = new ProcessStartInfo(powershell,
                "-NoProfile -NoLogo -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + scriptPath + "\"");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WorkingDirectory = dir;
            Process.Start(psi);
            return 0;
        } catch (Exception ex) {
            MessageBox.Show("No se pudo iniciar Dofus Multi-switcher:\n\n" + ex.Message, "Dofus Multi-switcher",
                            MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
