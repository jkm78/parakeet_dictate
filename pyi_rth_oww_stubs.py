"""
PyInstaller runtime hook: stub scipy / scikit-learn for openWakeWord.

openWakeWord's __init__ imports openwakeword.custom_verifier_model, which imports
scipy and sklearn at module top. Those are used ONLY for training a custom
verifier (never at inference), so we exclude the real (large) packages from the
exe and register lightweight stand-ins here, before openWakeWord is imported, so
`import openwakeword` still succeeds.
"""

import sys
import types


def _module(name):
    m = sys.modules.get(name)
    if m is None:
        m = types.ModuleType(name)
        sys.modules[name] = m
    return m


# import scipy
_module("scipy")

# from sklearn.linear_model import LogisticRegression
# from sklearn.pipeline import make_pipeline
# from sklearn.preprocessing import FunctionTransformer, StandardScaler
sk = _module("sklearn")
lm = _module("sklearn.linear_model")
pl = _module("sklearn.pipeline")
pp = _module("sklearn.preprocessing")
lm.LogisticRegression = type("LogisticRegression", (), {})
pl.make_pipeline = lambda *a, **k: None
pp.FunctionTransformer = type("FunctionTransformer", (), {})
pp.StandardScaler = type("StandardScaler", (), {})
sk.linear_model = lm
sk.pipeline = pl
sk.preprocessing = pp
