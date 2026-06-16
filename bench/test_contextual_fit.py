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

def test_label_from_clip_id():
    assert cf.label_for("c07-snyk-jon") == "term"
    assert cf.label_for("o06-snyk-sync-jon") == "common"
    assert cf.label_for("s13-numba-jon") == "stress"

def test_auc_high_perfect_separation():
    # higher score for positives => AUC 1.0
    assert cf.auc_high([0.8, 0.9], [0.1, 0.2]) == 1.0
    assert cf.auc_high([0.1], [0.9]) == 0.0

def test_keyword_overlap_discriminates():
    blurb = cf.sanitize_blurb("developer security vulnerability scanner")
    term_ctx = "run the security scan and audit dependencies before merge"
    common_ctx = "keep the two folders in order overnight"
    assert cf.keyword_overlap(term_ctx, blurb) > cf.keyword_overlap(common_ctx, blurb)

def test_keyword_overlap_zero_when_disjoint():
    assert cf.keyword_overlap("totally unrelated chatter", "in-memory key-value data store") == 0.0

if __name__ == "__main__":
    n = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn(); n += 1; print(f"ok  {name}")
    print(f"\n{n} passed")
