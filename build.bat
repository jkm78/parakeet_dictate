@echo off
REM ==========================================================================
REM  Build ParakeetDictate.exe  (run this ON the Windows 13400T box)
REM  Produces a single-file exe in .\dist\ParakeetDictate.exe
REM ==========================================================================

REM 0) Close any running instance first. A running ParakeetDictate.exe locks
REM    dist\ParakeetDictate.exe, and then PyInstaller can't overwrite it
REM    ("Access is denied" at the EXE step). Harmless if none is running.
taskkill /F /IM ParakeetDictate.exe >nul 2>&1

REM 1) Virtual env. Only create it if missing: re-running "python -m venv" over
REM    an existing venv tries to overwrite python.exe and fails on a network
REM    share / when the venv is in use. (Tip: build on a LOCAL disk, not a
REM    mapped/network drive like T:\, to avoid file-lock and venv copy errors.)
if not exist .venv\Scripts\python.exe python -m venv .venv
call .venv\Scripts\activate.bat

REM 1b) Clean stale build output so old artifacts never mix in
if exist build rmdir /s /q build
if exist dist rmdir /s /q dist
if exist ParakeetDictate.spec del /q ParakeetDictate.spec
if exist dist\ParakeetDictate.exe goto :locked

REM 2) Dependencies + PyInstaller.
REM    PyInstaller is PINNED so this local build and the GitHub CI build use the
REM    exact same bootloader. An unpinned install can grab a newer bootloader
REM    whose byte signature Windows Defender flags as a packer; pinning keeps
REM    both builds identical and reproducible. If Defender ever flags a build,
REM    change this one version in build.bat AND .github/workflows/build-windows.yml.
python -m pip install --upgrade pip
python -m pip install -r requirements.txt pyinstaller==6.21.0
REM Wake-word trigger dependency (openWakeWord). Bundled into the exe below.
python -m pip install -r requirements-wake.txt

REM 2a2) Pre-download openWakeWord's models into the package so PyInstaller can
REM      bundle them (the exe then runs the wake word fully offline). ~18 MB.
python -c "import openwakeword; openwakeword.utils.download_models()"

REM 2b) Sanity-check the pure-Python formatting/postprocess/VAD logic
python test_formatting.py || goto :eof
python test_vad.py || goto :eof

REM 2c) Bundle a CONSISTENT MSVC runtime (vcruntime140/vcruntime140_1/msvcp140).
REM    onnxruntime.dll links MSVCP140.dll + VCRUNTIME140.dll. PyInstaller auto-
REM    bundles Python's vcruntime140.dll (often older) but NOT msvcp140.dll, so
REM    at runtime msvcp140.dll loads from System32 (newer) against the older
REM    bundled vcruntime -> "DLL initialization routine failed" when onnxruntime
REM    imports. Shipping all three from System32 as one matched set fixes it.
if exist _vcredist rmdir /s /q _vcredist
mkdir _vcredist
copy /y "%SystemRoot%\System32\vcruntime140.dll"   _vcredist\ >nul
copy /y "%SystemRoot%\System32\vcruntime140_1.dll" _vcredist\ >nul
copy /y "%SystemRoot%\System32\msvcp140.dll"        _vcredist\ >nul
copy /y "%SystemRoot%\System32\concrt140.dll"       _vcredist\ >nul

REM 3) Build. --collect-all pulls onnxruntime's native DLLs and onnx-asr's
REM    bundled preprocessor/decoder assets, which PyInstaller misses otherwise.
REM    --hidden-import vad ensures the lazily-imported VAD module is bundled.
REM    --add-binary overrides PyInstaller's older vcruntime with the matched set.
pyinstaller --onefile --windowed --name ParakeetDictate ^
  --icon parakeet.ico ^
  --version-file version.txt ^
  --collect-all onnxruntime ^
  --collect-all pywinusb ^
  --collect-all onnx_asr ^
  --collect-all openwakeword ^
  --collect-submodules sounddevice ^
  --hidden-import vad ^
  --hidden-import wakeword ^
  --runtime-hook pyi_rth_oww_stubs.py ^
  --exclude-module scipy ^
  --exclude-module sklearn ^
  --exclude-module tflite_runtime ^
  --exclude-module speexdsp_ns ^
  --exclude-module matplotlib ^
  --exclude-module torch ^
  --exclude-module pandas ^
  --add-binary "_vcredist\vcruntime140.dll;." ^
  --add-binary "_vcredist\vcruntime140_1.dll;." ^
  --add-binary "_vcredist\msvcp140.dll;." ^
  --add-binary "_vcredist\concrt140.dll;." ^
  parakeet_dictate.py

echo.
echo ============================================================
echo  Done. Your exe is at:  dist\ParakeetDictate.exe
echo  First launch downloads the model (~640 MB) once, then it
echo  runs fully offline.
echo ============================================================
pause
goto :eof

:locked
echo.
echo [!] Could not delete dist\ParakeetDictate.exe - it is locked.
echo     Close the running app in Task Manager, then re-run build.bat.
echo     A virus scanner or network share can also hold it; a local disk helps.
pause
goto :eof
