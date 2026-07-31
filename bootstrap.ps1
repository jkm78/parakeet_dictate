<#
.SYNOPSIS
    Download and install everything required to BUILD ParakeetDictate.exe on Windows.

.DESCRIPTION
    A fresh Windows machine needs several things before build.bat can run:
      1. Python 3.10+            (installed via winget, or the python.org installer)
      2. A project virtual env   (.venv)
      3. The pip dependencies     (requirements.txt + the pinned PyInstaller)
      4. A matched MSVC runtime   (vcruntime140 / vcruntime140_1 / msvcp140 / concrt140)
         staged in _vcredist\ so the packaged onnxruntime.dll loads. Without this
         the built exe dies with "onnxruntime_pybind11_state: A dynamic link
         library (DLL) initialization routine failed."

    After this finishes, run  build.bat  to produce dist\ParakeetDictate.exe.

    The script is idempotent: re-running it detects what is already present and
    only fills the gaps.

.PARAMETER PythonVersion
    Python feature version to install if none is found. Default 3.12
    (best-tested with onnxruntime / onnx-asr). Format: "3.12".

.PARAMETER PreloadModel
    Also download the ~670 MB INT8 speech model into the machine-wide cache
    (%ProgramData%\ParakeetDictate\models) so the built exe never needs network
    on first run. Without this switch, the model downloads on first launch.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File bootstrap.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File bootstrap.ps1 -PreloadModel
#>
[CmdletBinding()]
param(
    [string]$PythonVersion = "3.12",
    [switch]$PreloadModel
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $ProjectRoot

function Info($m)  { Write-Host "[bootstrap] $m" -ForegroundColor Cyan }
function Ok($m)    { Write-Host "[bootstrap] $m" -ForegroundColor Green }
function Warn($m)  { Write-Host "[bootstrap] $m" -ForegroundColor Yellow }
function Die($m)   { Write-Host "[bootstrap] ERROR: $m" -ForegroundColor Red; exit 1 }

if (-not $IsWindows -and $env:OS -ne "Windows_NT") {
    Die "This build must run on Windows (PyInstaller cannot cross-compile)."
}

# --------------------------------------------------------------------------
# 1) Find a usable Python 3.10+, installing one if necessary.
# --------------------------------------------------------------------------
function Test-Py310 {
    param([string]$Exe)
    if (-not $Exe -or -not (Test-Path $Exe)) { return $false }
    try {
        $v = & $Exe -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $v) { return $false }
        $parts = $v.Trim().Split(".")
        return ([int]$parts[0] -eq 3 -and [int]$parts[1] -ge 10)
    } catch { return $false }
}

function Find-Python {
    # Prefer an existing project venv.
    $venvPy = Join-Path $ProjectRoot ".venv\Scripts\python.exe"
    if (Test-Py310 $venvPy) { return $venvPy }

    # The py launcher (most reliable on Windows).
    $py = (Get-Command py -ErrorAction SilentlyContinue)
    if ($py) {
        foreach ($tag in @("-$PythonVersion", "-3")) {
            $exe = (& py $tag -c "import sys; print(sys.executable)" 2>$null)
            if ($LASTEXITCODE -eq 0 -and (Test-Py310 $exe)) { return $exe.Trim() }
        }
    }

    # Common per-user / all-users install locations.
    $candidates = @()
    foreach ($base in @("$env:LOCALAPPDATA\Programs\Python", "$env:ProgramFiles\Python", "${env:ProgramFiles(x86)}\Python")) {
        if (Test-Path $base) {
            $candidates += Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^Python3' } |
                ForEach-Object { Join-Path $_.FullName "python.exe" }
        }
    }
    # Whatever "python" resolves to (skip the Windows Store alias stub).
    $cmd = (Get-Command python -ErrorAction SilentlyContinue)
    if ($cmd -and $cmd.Source -notlike "*WindowsApps*") { $candidates += $cmd.Source }

    foreach ($c in ($candidates | Sort-Object -Unique -Descending)) {
        if (Test-Py310 $c) { return $c }
    }
    return $null
}

function Install-Python {
    Info "No Python 3.10+ found. Installing Python $PythonVersion ..."
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        Info "Using winget (Python.Python.$PythonVersion, user scope)."
        & winget install --id "Python.Python.$PythonVersion" -e --scope user --silent `
            --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { Warn "winget returned $LASTEXITCODE; will try the direct installer." }
    }
    if (-not (Find-Python)) {
        # Fallback: download the official installer from python.org and run it silently.
        $ver = if ($PythonVersion -eq "3.12") { "3.12.10" } else { "$PythonVersion.0" }
        $url = "https://www.python.org/ftp/python/$ver/python-$ver-amd64.exe"
        $out = Join-Path $env:TEMP "python-$ver-amd64.exe"
        Info "Downloading $url"
        Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
        Info "Running installer (per-user, silent)."
        Start-Process -FilePath $out -ArgumentList `
            "/quiet","InstallAllUsers=0","PrependPath=1","Include_pip=1","Include_launcher=1" -Wait
        Remove-Item $out -ErrorAction SilentlyContinue
    }
}

$python = Find-Python
if (-not $python) {
    Install-Python
    $python = Find-Python
}
if (-not $python) { Die "Could not find or install Python 3.10+." }
$pyver = (& $python -c "import platform; print(platform.python_version())").Trim()
Ok "Using Python $pyver at $python"

# --------------------------------------------------------------------------
# 2) Virtual environment.
# --------------------------------------------------------------------------
$venvDir = Join-Path $ProjectRoot ".venv"
$venvPy  = Join-Path $venvDir "Scripts\python.exe"
if (-not (Test-Path $venvPy)) {
    Info "Creating virtual environment in .venv ..."
    & $python -m venv $venvDir
    if (-not (Test-Path $venvPy)) { Die "venv creation failed." }
} else {
    Info ".venv already exists - reusing it."
}

# --------------------------------------------------------------------------
# 3) Pip dependencies + PyInstaller (pinned to match build.bat / CI).
# --------------------------------------------------------------------------
$PyInstallerPin = "pyinstaller==6.21.0"
Info "Upgrading pip ..."
& $venvPy -m pip install --upgrade pip
Info "Installing requirements.txt + $PyInstallerPin ..."
& $venvPy -m pip install -r (Join-Path $ProjectRoot "requirements.txt") $PyInstallerPin
if ($LASTEXITCODE -ne 0) { Die "pip install failed." }
Ok "Python dependencies installed."

# --------------------------------------------------------------------------
# 4) Stage a matched MSVC runtime for onnxruntime (see build.bat step 2c).
# --------------------------------------------------------------------------
$vcDir = Join-Path $ProjectRoot "_vcredist"
Info "Staging MSVC runtime DLLs into _vcredist ..."
if (Test-Path $vcDir) { Remove-Item -Recurse -Force $vcDir }
New-Item -ItemType Directory -Force $vcDir | Out-Null
$dlls = @("vcruntime140.dll","vcruntime140_1.dll","msvcp140.dll","concrt140.dll")
foreach ($d in $dlls) {
    $src = Join-Path $env:SystemRoot "System32\$d"
    if (Test-Path $src) {
        Copy-Item $src $vcDir -Force
        $fv = (Get-Item (Join-Path $vcDir $d)).VersionInfo.FileVersion
        Info "  $d  ($fv)"
    } else {
        Warn "  $d not found in System32 - install the latest 'Microsoft Visual C++ 2015-2022 Redistributable (x64)' and re-run."
    }
}
Ok "MSVC runtime staged."

# --------------------------------------------------------------------------
# 5) (optional) Pre-download the ~670 MB speech model into the shared cache.
# --------------------------------------------------------------------------
if ($PreloadModel) {
    $modelBase = Join-Path $env:ProgramData "ParakeetDictate\models"
    $hfHome    = Join-Path $modelBase "huggingface"
    Info "Pre-downloading speech model into $modelBase (this is the ~670 MB one-time download) ..."
    New-Item -ItemType Directory -Force $hfHome | Out-Null
    $env:HF_HOME = $hfHome
    & $venvPy -c "import onnx_asr; onnx_asr.load_model('nemo-parakeet-tdt-0.6b-v3', quantization='int8', providers=['CPUExecutionProvider']); print('model cached OK')"
    if ($LASTEXITCODE -ne 0) { Warn "Model preload failed; the exe will download it on first run instead." }
    else { Ok "Speech model cached at $modelBase" }
}

# --------------------------------------------------------------------------
Write-Host ""
Ok "Build environment ready."
Write-Host "[bootstrap] Next step:  build.bat   ->   dist\ParakeetDictate.exe" -ForegroundColor Green
if (-not $PreloadModel) {
    Write-Host "[bootstrap] (Tip: re-run with -PreloadModel to also cache the model for offline first-run.)" -ForegroundColor DarkGray
}
