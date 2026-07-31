<#
.SYNOPSIS
    Package ParakeetDictate.exe and everything it needs into a versioned release zip.

.DESCRIPTION
    Produces a distributable zip under .\release\. Two flavours:

      * DEFAULT (offline / "all requirements"): the exe PLUS both models
        (the ~640 MB INT8 speech model and the ~2 MB Silero VAD model) and a
        run-ParakeetDictate.bat launcher that points the app at the bundled
        models. The result needs ZERO network on the target machine.

      * -NoModel (lean): just the exe + docs. ~50 MB. The exe downloads the
        model from Hugging Face on first run, then runs offline.

    Both flavours also include README.md, LICENSE, and docs\.

    The exe itself is already self-contained (PyInstaller bundles Python, every
    pip dependency, and the MSVC runtime), so "requirements" here means the model
    weights that normally download on first launch.

.PARAMETER Build
    (Re)build the exe with build.bat before packaging. Without this, an existing
    dist\ParakeetDictate.exe is used (and the script errors if none exists).

.PARAMETER NoModel
    Produce the lean package (exe + docs only); the model downloads on first run.

.PARAMETER OutDir
    Where to write the release folder + zip. Default: .\release

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File release.ps1 -Build
    # Full offline package: build, then bundle exe + models + docs.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File release.ps1 -NoModel
    # Lean package from the already-built exe.
#>
[CmdletBinding()]
param(
    [switch]$Build,
    [switch]$NoModel,
    [string]$OutDir
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $ProjectRoot
if (-not $OutDir) { $OutDir = Join-Path $ProjectRoot "release" }

function Info($m) { Write-Host "[release] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[release] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[release] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "[release] ERROR: $m" -ForegroundColor Red; exit 1 }

if (-not $IsWindows -and $env:OS -ne "Windows_NT") { Die "Run this on Windows." }

$exe   = Join-Path $ProjectRoot "dist\ParakeetDictate.exe"
$venvPy = Join-Path $ProjectRoot ".venv\Scripts\python.exe"

# --------------------------------------------------------------------------
# 1) Build the exe if asked, or if it's missing.
# --------------------------------------------------------------------------
if ($Build -or -not (Test-Path $exe)) {
    if (-not (Test-Path (Join-Path $ProjectRoot "build.bat"))) { Die "build.bat not found." }
    Info "Building the exe via build.bat ..."
    # Feed stdin from NUL so build.bat's trailing 'pause' returns immediately
    # instead of hanging this non-interactive script. cd /d inside cmd so the
    # build's relative paths resolve, and use .\ since some environments disable
    # current-directory command search.
    & cmd /c "cd /d `"$ProjectRoot`" && .\build.bat < nul"
    if (-not (Test-Path $exe)) { Die "Build did not produce dist\ParakeetDictate.exe." }
}
Ok "Using exe: $exe"

# --------------------------------------------------------------------------
# 2) Resolve the version from the exe's embedded VERSIONINFO.
# --------------------------------------------------------------------------
$fv = (Get-Item $exe).VersionInfo.FileVersion
if ($fv) {
    $parts = ($fv.Trim() -split '[.,]') | Where-Object { $_ -ne "" }
    $version = ($parts[0..([Math]::Min(2, $parts.Count - 1))]) -join "."
}
if (-not $version) { $version = "0.0.0" ; Warn "Could not read version from exe; using $version." }
$flavour = if ($NoModel) { "" } else { "-offline" }
$pkgName = "ParakeetDictate-v$version-win64$flavour"
Info "Release version: $version   ->   $pkgName"

# --------------------------------------------------------------------------
# 3) Stage the package folder.
# --------------------------------------------------------------------------
$stage = Join-Path $OutDir $pkgName
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force $stage | Out-Null

Copy-Item $exe (Join-Path $stage "ParakeetDictate.exe") -Force
foreach ($f in @("README.md", "LICENSE")) {
    $p = Join-Path $ProjectRoot $f
    if (Test-Path $p) { Copy-Item $p $stage -Force }
}
if (Test-Path (Join-Path $ProjectRoot "docs")) {
    Copy-Item (Join-Path $ProjectRoot "docs") (Join-Path $stage "docs") -Recurse -Force
}
Info "Staged exe + README + LICENSE + docs."

# --------------------------------------------------------------------------
# 4) Bundle the models (default) for a zero-network package.
# --------------------------------------------------------------------------
if (-not $NoModel) {
    if (-not (Test-Path $venvPy)) {
        Die "The model bundle needs the project venv (run bootstrap.ps1 or build.bat first), or pass -NoModel."
    }

    # Seed both models into the machine-wide shared cache (same location the app
    # uses), then copy that cache into the package.
    $modelBase = Join-Path $env:ProgramData "ParakeetDictate\models"
    Info "Ensuring both models are cached in $modelBase (downloads ~640 MB once if absent) ..."
    New-Item -ItemType Directory -Force (Join-Path $modelBase "huggingface") | Out-Null
    $env:PARAKEET_MODEL_DIR = $modelBase
    $env:HF_HOME            = Join-Path $modelBase "huggingface"
    & $venvPy -c @"
import onnx_asr, vad
onnx_asr.load_model('nemo-parakeet-tdt-0.6b-v3', quantization='int8', providers=['CPUExecutionProvider'])
p = vad.resolve_model()
print('speech model + VAD ready:', p)
"@
    if ($LASTEXITCODE -ne 0) { Die "Model download/verify failed." }

    Info "Copying models into the package ..."
    $pkgModels = Join-Path $stage "models"
    New-Item -ItemType Directory -Force $pkgModels | Out-Null
    # Speech model (Hugging Face hub cache) + VAD onnx.
    Copy-Item (Join-Path $modelBase "huggingface") (Join-Path $pkgModels "huggingface") -Recurse -Force
    $vadSrc = Join-Path $modelBase "silero_vad.onnx"
    if (Test-Path $vadSrc) { Copy-Item $vadSrc $pkgModels -Force } else { Warn "silero_vad.onnx not found to bundle." }

    # Launcher: point the app at the bundled models and force offline mode.
    $launcher = @"
@echo off
REM Launch Parakeet Dictate fully offline using the models bundled in this folder.
REM (Alternatively, copy the 'models' folder to %ProgramData%\ParakeetDictate\models
REM  and the bare exe will find them with no launcher.)
set "PARAKEET_MODEL_DIR=%~dp0models"
set "HF_HUB_OFFLINE=1"
start "" "%~dp0ParakeetDictate.exe"
"@
    Set-Content -Path (Join-Path $stage "run-ParakeetDictate.bat") -Value $launcher -Encoding ASCII
    Ok "Bundled models + offline launcher."
}

# --------------------------------------------------------------------------
# 5) Short read-me for whoever unzips it.
# --------------------------------------------------------------------------
$runLine = if ($NoModel) {
    "Run ParakeetDictate.exe. On first launch it downloads the ~640 MB speech`r`nmodel from Hugging Face, then runs fully offline."
} else {
    "Run run-ParakeetDictate.bat (recommended) to start fully offline using the`r`nbundled models. ParakeetDictate.exe also works but would re-download the model`r`nunless you first copy the 'models' folder to %ProgramData%\ParakeetDictate\models."
}
$howto = @"
Parakeet Dictate $version
=========================

$runLine

Then put your cursor in any text field, HOLD Right Ctrl, speak, release.
The transcript pastes at the cursor. Open Edit Settings to change the trigger,
microphone, macros, and formatting.

Builds are unsigned, so Windows SmartScreen may warn on first launch:
  More info -> Run anyway.

See docs\USER_GUIDE.md and docs\PRIVACY.md for details.
"@
Set-Content -Path (Join-Path $stage "HOW-TO-RUN.txt") -Value $howto -Encoding ASCII

# --------------------------------------------------------------------------
# 6) Zip it, with size + SHA256.
# --------------------------------------------------------------------------
$zip = Join-Path $OutDir "$pkgName.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Info "Compressing to $zip ..."
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zip -CompressionLevel Optimal
$zipSize = "{0:N1} MB" -f ((Get-Item $zip).Length / 1MB)
$sha = (Get-FileHash $zip -Algorithm SHA256).Hash

Write-Host ""
Ok "Release ready:"
Write-Host "  Folder : $stage"
Write-Host "  Zip    : $zip  ($zipSize)"
Write-Host "  SHA256 : $sha"
if ($NoModel) {
    Write-Host "[release] (Lean package: model downloads on first run. Drop -NoModel for a zero-network bundle.)" -ForegroundColor DarkGray
}
