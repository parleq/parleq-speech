#!/usr/bin/env python3
"""Plain-assert unit tests for analyze_contextual_fit pure functions.
Run: bench/.venv/bin/python bench/test_contextual_fit.py  (exits non-zero on failure)"""
import importlib.util, os
spec = importlib.util.spec_from_file_location("cf", os.path.join(os.path.dirname(__file__), "analyze_contextual_fit.py"))
cf = importlib.util.module_from_spec(spec); spec.loader.exec_module(cf)

def test_sanitize_strips_confusion_note():
    # the leak that would otherwise match negative clips: "work tree"/"word tree"
    out = cf.sanitize_blurb('A git worktree, used a lot by me and often confused with "word tree" or "work tree"')
    assert "work tree" not in out.lower() and "word tree" not in out.lower(), out
    assert "git worktree" in out.lower(), out

def test_sanitize_strips_self_reference():
    out = cf.sanitize_blurb("The primary R package repository. Used a LOT in my conversations")
    assert "conversations" not in out.lower(), out
    assert "package repository" in out.lower(), out

def test_sanitize_passes_clean_blurb():
    out = cf.sanitize_blurb("in-memory key-value data store")
    assert out == "in-memory key-value data store", out

if __name__ == "__main__":
    n = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn(); n += 1; print(f"ok  {name}")
    print(f"\n{n} passed")
