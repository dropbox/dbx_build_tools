# mypy: allow-untyped-defs, allow-untyped-globals

import re
import time


default_excludes = []
regex_excludes = []
for x in default_excludes:
    regex_excludes.append(re.compile(x, re.IGNORECASE))

blacklist = set()


def _matches_excludes(line):
    if line in blacklist:
        return True
    for pattern in regex_excludes:
        if pattern.match(line):
            return True
    return False


# Merge a list of bash lines into a single list of lines.
def _merge_history_lines(lines):
    line_map = {}  # type: ignore[var-annotated]
    i = 0
    has_timestamps = False
    for line in lines:
        line = line.strip()
        if not line:
            continue
        # check and see if there are embedded time codes
        if line[0] == "#":
            if line[1:].isdigit():
                i = int(line[1:])
                has_timestamps = True
            continue
        elif not has_timestamps:
            i += 1
        if _matches_excludes(line):
            continue
        # make sure the line map has the latest timestamp for a given command.
        if line_map.get(line, 0) <= i:
            line_map[line] = i
    items = list(line_map.items())
    items.sort(key=lambda x: x[-1])

    lines = []
    for line, timestamp in items:
        if has_timestamps:
            lines.append("#%s" % timestamp)
        lines.append(line)
    return lines


# Merge history files and commands into a new history file.
def merge_history(filenames, history_cmds, history_file):
    now = int(time.time())
    lines_list = []
    for filename in filenames:
        try:
            lines_list.extend(open(filename).readlines())
        except IOError:
            pass
    timed_history_cmds = []
    for i, cmd in enumerate(history_cmds):
        timed_history_cmds.append("#%d" % (now + i))
        timed_history_cmds.append(cmd)

    output_lines = _merge_history_lines(lines_list + timed_history_cmds)
    with open(history_file, "w") as f:
        f.write("\n".join(output_lines) + "\n")
