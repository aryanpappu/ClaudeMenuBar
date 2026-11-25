#!/usr/bin/env python3
"""Runs protocol/vectors.json against a claude-notify binary.

usage: python3 protocol/run_vectors.py <path-to-claude-notify>
Exit code 0 when every case passes. Works on macOS, Linux and Windows.
"""
import json, os, subprocess, sys, tempfile, time

def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    helper = sys.argv[1]
    here = os.path.dirname(os.path.abspath(__file__))
    cases = json.load(open(os.path.join(here, "vectors.json"), encoding="utf-8"))
    failures = 0
    for case in cases:
        with tempfile.TemporaryDirectory() as tmp:
            d = os.path.join(tmp, "sessions")
            os.makedirs(d)
            path = os.path.join(d, "s1.json")
            if "existing" in case:
                with open(path, "w", encoding="utf-8") as f:
                    json.dump(case["existing"], f)
            if "stdin_raw" in case:
                data = case["stdin_raw"]
            else:
                payload = dict(case["stdin"])
                if payload.get("cwd") == "LONG1100":
                    payload["cwd"] = "/" + "a" * 1100
                data = json.dumps(payload)
            env = dict(os.environ, CLAUDE_MENUBAR_DIR=d)
            before = int(time.time() * 1000)
            p = subprocess.run([helper] + case["args"], input=data.encode(), env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
            after = int(time.time() * 1000)
            problems = []
            if p.returncode != 0:
                problems.append(f"exit code {p.returncode}")
            if p.stdout:
                problems.append(f"printed to stdout: {p.stdout[:80]!r}")
            leftovers = [n for n in os.listdir(d) if n != "s1.json"]
            if leftovers:
                problems.append(f"left files behind: {leftovers}")
            exp = case["expect"]
            exists = os.path.exists(path)
            if exp == "none":
                if exists and "existing" not in case:
                    problems.append("wrote a file but should have done nothing")
            elif exp == "deleted":
                if exists:
                    problems.append("file was not deleted")
            else:
                if not exists:
                    problems.append("no file written")
                else:
                    got = json.load(open(path, encoding="utf-8"))
                    if got.get("v") != 1:
                        problems.append(f"v = {got.get('v')}")
                    if got.get("session_id") != "s1":
                        problems.append(f"session_id = {got.get('session_id')}")
                    for k, v in exp.items():
                        if got.get(k) != v:
                            problems.append(f"{k}: expected {v!r}, got {got.get(k)!r}")
                    if "ts" not in exp and not (before - 5000 <= got.get("ts", 0) <= after + 1000):
                        problems.append(f"ts {got.get('ts')} not current")
            status = "ok  " if not problems else "FAIL"
            print(f"{status} {case['name']}" + ("" if not problems else ": " + "; ".join(problems)))
            failures += bool(problems)
    print(f"{len(cases) - failures}/{len(cases)} passed")
    sys.exit(1 if failures else 0)

if __name__ == "__main__":
    main()
