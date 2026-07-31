# Parakeet Dictate v1.0.0

**Fully local, HIPAA-friendly voice-to-text for Windows — an open-source
alternative to Dragon.** Push a key (or your dictation mic's button), speak, and
the transcript appears at your cursor in any application. No cloud, no GPU, no
audio or text ever leaves the machine.

Runs NVIDIA's **Parakeet TDT 0.6B** speech model (INT8 ONNX) entirely on the CPU,
on-device. Built for medical private practices, but useful to anyone who wants
private, offline dictation.

---

## Downloads

| Package | Size | Best for |
|---|---|---|
| **ParakeetDictate-v1.0.0-win64.zip** | ~50 MB | Most users. Downloads the ~640 MB speech model from Hugging Face on first launch, then runs fully offline. |
| **ParakeetDictate-v1.0.0-win64-offline.zip** | ~964 MB | Locked-down / air-gapped clinical machines. Bundles both models + a launcher; needs **zero network**, ever. |

**SHA-256**
```
ParakeetDictate-v1.0.0-win64.zip
  9DE96C889C0EA12E9BEF7A89E92C9E33434F164F03D9F8693026AD54C2F18D48

ParakeetDictate-v1.0.0-win64-offline.zip
  22AA18B5B85637E8BD88610E0297330A40152025C2239B4AB101DA3A75EEF28F
```

> Builds are unsigned, so Windows SmartScreen may warn on first launch —
> **More info → Run anyway**.

---

## Getting started

1. Unzip anywhere.
2. **Lean package:** run `ParakeetDictate.exe` (first launch downloads the model
   once, then it's offline).
   **Offline package:** run `run-ParakeetDictate.bat` to start fully offline from
   the bundled models.
3. Put your cursor in any text field, **hold Right Ctrl**, speak, release — the
   transcript pastes at the cursor.
4. Open **Edit settings** to change the trigger, microphone, macros, and
   formatting.

See `docs/USER_GUIDE.md` for the full settings walkthrough and `docs/PRIVACY.md`
for the HIPAA / data-handling posture.

---

## Features

### Dictation
- **Local CPU speech recognition** — Parakeet TDT 0.6B (INT8 ONNX). No GPU, no
  network after setup. The recognizer punctuates and capitalizes on its own.
- **Push-to-talk hold** or **press-to-toggle**.
- **Trigger by keyboard hotkey** *or* a **mic / HID record button** (e.g. a
  Dragon-style dictation mic).
- **Pick which microphone** records.
- **Insert by clipboard paste** (fast) or **direct typing** (nothing ever touches
  the clipboard — the strongest PHI posture, and the default).
- **Continuous dictation** (General tab) — hold and talk with no length limit;
  sentences insert as you pause, via a small Silero VAD.

### Text shaping
- **Macros** — say a phrase, insert a whole paragraph/template.
- **Substitutions** — spoken abbreviation → written form, inline.
- **Medical formatting** — `one twenty over eighty` → `120/80`,
  `twenty five milligrams` → `25 mg`, and optional all-numbers-to-digits.
- **Filler-word cleanup** — strip fillers from the start, or drop them when
  they're the entire utterance.

### Interface
- **Compact status window** that shows a colored indicator light:
  🔵 **blue** = listening · 🟢 **green** = dictating · 🔴 **red** = off.
- **Always-on-top** so the status stays visible while you dictate into another
  app (toggle in the General tab).
- **Follows the Windows light/dark theme** — title bar and window contents adapt
  automatically, including the Settings window.
- **Standard Windows (Segoe UI) font sizing** throughout.

### Deployment
- **Single-file Windows `.exe`** — no installer, no Python required on the target.
- **Roaming settings** — stored in the user's Documents folder, so they follow
  the user across machines where Documents is redirected/roamed.
- **Shared model cache** — all users on a PC reuse one `%ProgramData%` download.
- **Reproducible builds** — `bootstrap.ps1` sets up the build environment,
  `build.bat` produces the exe, and `release.ps1` packages the release zips.
  Automated Windows CI build + release via GitHub Actions.

---

## System requirements

- **Windows 10 or 11 (64-bit).**
- **~640 MB disk** for the model (or ~700 MB inside the offline package).
- Any CPU — no GPU required. Runs comfortably on modern low-power desktops.

---

## Notes & known limitations

- **First run downloads ~640 MB** (the INT8 model) from Hugging Face to a shared
  `%ProgramData%\ParakeetDictate\models` cache. After that it is fully offline.
  The download is model weights — never patient data. (The offline package skips
  this entirely.)
- **Global hotkey:** normally works without elevation. If the key does nothing on
  a locked-down machine, try running as administrator — some Windows configs
  restrict the global keyboard hook.
- **Using a Dragon mic button?** Close Dragon first so the button's HID reports
  reach this app.
- **Utterance length:** by default each press is one clip (happiest under ~30 s).
  Turn on **Continuous dictation** for paragraph-length notes.
- **Window border (Windows 10):** the app themes the title bar and all contents
  to dark/light, but the OS-drawn ~1px outer resize border can't be recolored on
  Windows 10 (that DWM API is Windows 11-only). Windows 11 gets the fully themed
  border.
- **Unsigned builds:** SmartScreen may warn on first launch (*More info → Run
  anyway*).

---

## Privacy

No audio or text ever leaves the machine. Transcription runs entirely on-device;
the only network use is the one-time model download from Hugging Face (which the
offline package removes). See `docs/PRIVACY.md` for the full data-handling
posture. Licensed under the **GNU GPL v3**.
