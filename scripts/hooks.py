#!/usr/bin/env python3
"""Add or remove the Claude Menu Bar hooks in ~/.claude/settings.json.

usage: hooks.py install <path-to-claude-notify> [--dry-run]
       hooks.py uninstall [--dry-run]
       hooks.py check

Safe by design: keeps every other setting and hook, never adds a duplicate,
writes a timestamped backup first and replaces the file atomically.
"""
import json, os, re, shlex, shutil, sys, tempfile, time

# Resolve a symlinked settings.json so we update the real file, not the link.
SETTINGS = os.path.realpath(os.path.expanduser("~/.claude/settings.json"))
# Our hook commands look like:  <path>/claude-notify <state>   (path may be quoted)
OURS = re.compile(r"""^\s*(?:'[^']*/claude-notify'|"[^"]*/claude-notify"|\S*/claude-notify|claude-notify)\s+(running|waiting|done|idle|end)\s*$""")
EVENTS = [  # (hook event, state passed to claude-notify)
    ("UserPromptSubmit", "running"),
    ("PreToolUse", "running"),
    ("PermissionRequest", "waiting"),
    ("Notification", "waiting"),
    ("Stop", "done"),
    ("SessionEnd", "end"),
]


def load():
    if not os.path.exists(SETTINGS):
        return {}
    with open(SETTINGS, encoding="utf-8") as f:
        text = f.read().strip()
    return json.loads(text) if text else {}


def is_ours(hook):
    """Only exact helper commands count: a user's own script that merely
    mentions claude-notify is never touched."""
    return hook.get("type") == "command" and bool(OURS.match(str(hook.get("command", ""))))


def install(settings, notify):
    hooks = settings.setdefault("hooks", {})
    changes = []
    for event, state in EVENTS:
        groups = hooks.setdefault(event, [])
        if any(is_ours(h) for g in groups for h in g.get("hooks", [])):
            continue
        command = f"{shlex.quote(notify)} {state}"
        groups.append({"matcher": "", "hooks": [{"type": "command", "command": command}]})
        changes.append(f"+ {event}: claude-notify {state}")
    return changes


def uninstall(settings):
    hooks = settings.get("hooks", {})
    changes = []
    for event in list(hooks):
        kept_groups, touched = [], False
        for g in hooks[event]:
            before = g.get("hooks", [])
            after = [h for h in before if not is_ours(h)]
            if len(after) == len(before):
                kept_groups.append(g)          # untouched group: keep exactly as is
                continue
            touched = True
            changes.append(f"- {event}: claude-notify")
            if after:
                kept_groups.append({**g, "hooks": after})
        if not touched:
            continue
        if kept_groups:
            hooks[event] = kept_groups
        else:
            del hooks[event]
    if changes and "hooks" in settings and not settings["hooks"]:
        del settings["hooks"]
    return changes


def save(settings):
    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    if os.path.exists(SETTINGS):
        backup = f"{SETTINGS}.bak-claudemenubar-{time.strftime('%Y%m%d-%H%M%S')}"
        shutil.copy2(SETTINGS, backup)
        print(f"  backup: {backup}")
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(SETTINGS), prefix=".settings.", suffix=".json")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, SETTINGS)


def main():
    args = [a for a in sys.argv[1:] if a != "--dry-run"]
    dry = "--dry-run" in sys.argv
    if args == ["check"]:
        # Used by install.sh before it changes anything.
        try:
            s = load()
        except (OSError, json.JSONDecodeError) as e:
            sys.exit(f"  {SETTINGS} can't be read as JSON ({e}). Fix it first; nothing was changed.")
        if not isinstance(s, dict):
            sys.exit(f"  {SETTINGS} is not a JSON object. Fix it first; nothing was changed.")
        return
    if not args or args[0] not in ("install", "uninstall") or (args[0] == "install" and len(args) < 2):
        print(__doc__)
        sys.exit(2)
    try:
        settings = load()
    except json.JSONDecodeError as e:
        sys.exit(f"  {SETTINGS} is not valid JSON ({e}); fix it first. Nothing changed.")
    changes = install(settings, args[1]) if args[0] == "install" else uninstall(settings)
    if not changes:
        print("  hooks: already up to date")
        return
    for c in changes:
        print("  " + c)
    if dry:
        print("  (dry run: nothing written)")
    else:
        save(settings)


if __name__ == "__main__":
    main()
