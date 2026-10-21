# Builds DofusMulti.exe: bundles every lib script + the entry point into one .ps1,
# embeds it in a tiny C# launcher and compiles it with the csc.exe that ships with
# .NET Framework 4 (present on every Windows 10/11), so no extra tools are needed.
$ErrorActionPreference = 'Stop'

$projectDir = Split-Path $PSScriptRoot -Parent
$outDir = Join-Path $projectDir "..\release"
$workDir = Join-Path $PSScriptRoot "obj"
New-Item -ItemType Directory -Force -Path $outDir, $workDir | Out-Null
$outDir = (Resolve-Path $outDir).Path

$libOrder = @(
    'WindowInterop', 'DofusWindows', 'ForegroundHelper', 'TaskbarOrder',
    'WindowCycle', 'WindowLayout', 'HotkeyListener', 'TrayIcon'
)

$utf8 = New-Object System.Text.UTF8Encoding($false)
$bundle = New-Object System.Text.StringBuilder

$iconPath = Join-Path $projectDir "assets\dofus-tray.ico"
$iconBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($iconPath))
[void]$bundle.AppendLine("`$global:DofusTrayIconBase64 = '$iconBase64'")

foreach ($lib in $libOrder) {
    $libPath = Join-Path $projectDir "lib\$lib.ps1"
    [void]$bundle.AppendLine("# ---- lib\$lib.ps1 ----")
    [void]$bundle.AppendLine([IO.File]::ReadAllText($libPath, $utf8))
}

# Entry point without its dot-source lines (the libs are already inlined above)
$main = [IO.File]::ReadAllLines((Join-Path $projectDir "dofus-multi.ps1"), $utf8) |
    Where-Object { $_ -notmatch '^\.\s+"\$PSScriptRoot\\lib\\' }
[void]$bundle.AppendLine("# ---- dofus-multi.ps1 ----")
[void]$bundle.AppendLine(($main -join "`r`n"))

$bundlePath = Join-Path $workDir "dofus-multi.bundle.ps1"
[IO.File]::WriteAllText($bundlePath, $bundle.ToString(), $utf8)

# Fail early if the bundle doesn't parse
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($bundlePath, [ref]$null, [ref]$parseErrors)
if ($parseErrors) { throw "El script combinado tiene errores de sintaxis: $($parseErrors -join '; ')" }

$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
$exePath = Join-Path $outDir "DofusMulti.exe"

& $csc /nologo /target:winexe /optimize+ `
    "/out:$exePath" `
    "/win32icon:$iconPath" `
    "/resource:$bundlePath,dofus-multi.bundle.ps1" `
    /reference:System.Windows.Forms.dll `
    (Join-Path $PSScriptRoot "Launcher.cs")
if ($LASTEXITCODE -ne 0) { throw "csc.exe fallo con codigo $LASTEXITCODE" }

Write-Host "Ejecutable generado en: $exePath"
