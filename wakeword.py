"""
Wake-word trigger for Parakeet Dictate, using openWakeWord (local, CPU, ONNX).

An always-on keyword spotter runs on the mic. When the wake phrase is heard the
engine calls on_wake() (the app starts capturing your speech); a small Silero VAD
then watches for the end of the utterance and calls on_end() so the app stops,
transcribes, and returns to listening for the wake word.

Everything is local and offline after the one-time model download. This is a
prototype: it's opt-in (a trigger source in the Input tab) and off by default.
The keyword spotter is cheap, so the heavy Parakeet model only runs once you've
actually spoken after the wake word.
"""

import queue
import threading

import numpy as np

SAMPLE_RATE = 16000
OWW_FRAME = 1280      # openWakeWord expects 80 ms @ 16 kHz int16 chunks
VAD_FRAME = 512       # Silero v5 frame size

# Friendly label -> pretrained openWakeWord model name.
PRESET_PHRASES = {
    "Hey Jarvis": "hey_jarvis",
    "Alexa": "alexa",
    "Hey Mycroft": "hey_mycroft",
    "Hey Rhasspy": "hey_rhasspy",
}


def available():
    """True if openWakeWord is importable (the optional dependency is present)."""
    try:
        import openwakeword  # noqa: F401
        return True
    except Exception:
        return False


class WakeWordEngine:
    """Runs its own thread. Feed it float32 16 kHz audio via feed(); it calls
    on_wake()/on_end() as the wake phrase and end-of-utterance are detected."""

    def __init__(self, on_wake, on_end, *, model="hey_jarvis", threshold=0.5,
                 end_silence_ms=1500, refractory_ms=1200, log=print):
        self.on_wake = on_wake
        self.on_end = on_end
        self.model_name = model or "hey_jarvis"
        self.threshold = float(threshold)
        self.end_silence = int(SAMPLE_RATE * end_silence_ms / 1000)
        self.refractory = int(SAMPLE_RATE * refractory_ms / 1000)
        self._log = log

        self._q = queue.Queue()
        self._stop = threading.Event()
        self._ready = threading.Event()
        self._thread = None

        self._buf = np.zeros(0, dtype=np.float32)
        self._state = "idle"          # idle -> active -> cooldown -> idle
        self._silence = 0
        self._spoke = False
        self._cooldown = 0

        self._oww = None
        self._key = self.model_name
        self._vad = None

    # -- public API --------------------------------------------------------
    def start(self):
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        self._q.put(None)

    def feed(self, frame_float32):
        """Called from the audio callback; keep it featherweight."""
        if self._stop.is_set():
            return
        self._q.put(np.asarray(frame_float32, dtype=np.float32).reshape(-1))

    def is_ready(self):
        return self._ready.is_set()

    # -- lifecycle ---------------------------------------------------------
    def _load(self):
        import openwakeword
        from openwakeword.model import Model
        try:
            openwakeword.utils.download_models([self.model_name])  # no-op if cached
        except Exception:
            pass
        self._oww = Model(wakeword_models=[self.model_name],
                          inference_framework="onnx")
        keys = list(self._oww.models.keys())
        self._key = self.model_name if self.model_name in keys else (keys[0] if keys else self.model_name)
        import vad
        self._vad = vad.SileroVAD()
        self._ready.set()
        self._log(f"wake: ready (phrase='{self.model_name}', threshold={self.threshold})")

    def _run(self):
        try:
            self._load()
        except Exception as e:
            self._log(f"wake: load failed: {e}")
            return
        while not self._stop.is_set():
            item = self._q.get()
            if item is None:
                break
            self._buf = np.concatenate([self._buf, item]) if self._buf.size else item
            self._drain()
        self._log("wake: stopped")

    # -- processing --------------------------------------------------------
    def _drain(self):
        while True:
            if self._state == "active":
                if self._buf.size < VAD_FRAME:
                    return
                frame = self._buf[:VAD_FRAME]
                self._buf = self._buf[VAD_FRAME:]
                self._on_active(frame)
            else:                      # idle or cooldown
                if self._buf.size < OWW_FRAME:
                    return
                chunk = self._buf[:OWW_FRAME]
                self._buf = self._buf[OWW_FRAME:]
                self._on_idle(chunk)

    def _on_idle(self, chunk_float):
        if self._state == "cooldown":
            self._cooldown -= len(chunk_float)
            if self._cooldown <= 0:
                self._state = "idle"
            return
        pcm = np.clip(chunk_float * 32767.0, -32768, 32767).astype(np.int16)
        try:
            preds = self._oww.predict(pcm)
        except Exception:
            return
        if float(preds.get(self._key, 0.0)) >= self.threshold:
            self._log(f"wake: detected '{self.model_name}'")
            self._enter_active()

    def _enter_active(self):
        self._state = "active"
        self._silence = 0
        self._spoke = False
        try:
            self._vad.reset()
        except Exception:
            pass
        try:
            self.on_wake()
        except Exception as e:
            self._log(f"wake: on_wake error: {e}")

    def _on_active(self, frame):
        try:
            p = self._vad.prob(frame)
        except Exception:
            p = 0.0
        if p >= 0.5:
            self._spoke = True
            self._silence = 0
        else:
            self._silence += VAD_FRAME
        # End once the user has actually spoken and then paused long enough.
        if self._spoke and self._silence >= self.end_silence:
            self._enter_cooldown()

    def _enter_cooldown(self):
        self._state = "cooldown"
        self._cooldown = self.refractory
        try:
            self._oww.reset()      # forget the just-ended speech so it can't re-fire
        except Exception:
            pass
        try:
            self.on_end()
        except Exception as e:
            self._log(f"wake: on_end error: {e}")
