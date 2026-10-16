Add-Type -AssemblyName System.Drawing

$dofusExeCandidates = @(
    "$env:LOCALAPPDATA\Ankama\Dofus-dofus3\Dofus.exe",
    "$env:LOCALAPPDATA\Ankama\Dofus-beta\Dofus.exe",
    "$env:LOCALAPPDATA\Ankama\Dofus-experimental\Dofus.exe"
)

$dofusExe = $dofusExeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $dofusExe) {
    Write-Error "No se encontro Dofus.exe en ninguna de las rutas esperadas (%LOCALAPPDATA%\Ankama\Dofus-*)."
    exit 1
}

$sourceIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($dofusExe)
$sourceBitmap = $sourceIcon.ToBitmap()

$invertedBitmap = New-Object System.Drawing.Bitmap($sourceBitmap.Width, $sourceBitmap.Height)
for ($x = 0; $x -lt $sourceBitmap.Width; $x++) {
    for ($y = 0; $y -lt $sourceBitmap.Height; $y++) {
        $pixel = $sourceBitmap.GetPixel($x, $y)
        $inverted = [System.Drawing.Color]::FromArgb($pixel.A, 255 - $pixel.R, 255 - $pixel.G, 255 - $pixel.B)
        $invertedBitmap.SetPixel($x, $y, $inverted)
    }
}

$assetsDir = Join-Path $PSScriptRoot "assets"
if (-not (Test-Path $assetsDir)) {
    New-Item -ItemType Directory -Path $assetsDir | Out-Null
}
$iconPath = Join-Path $assetsDir "dofus-tray.ico"

$hIcon = $invertedBitmap.GetHicon()
$finalIcon = [System.Drawing.Icon]::FromHandle($hIcon)
$fileStream = New-Object System.IO.FileStream($iconPath, [System.IO.FileMode]::Create)
$finalIcon.Save($fileStream)
$fileStream.Close()

$sourceIcon.Dispose()
$sourceBitmap.Dispose()
$invertedBitmap.Dispose()

Write-Host "Icono generado en: $iconPath (fuente: $dofusExe)"
