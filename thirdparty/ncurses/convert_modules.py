# Given the ncurses source directory as its only argument, this script
# extracts buildable files from ncurses "modules" and prints some
# lines for the BUILD.ncurses file.

import os
import sys

def convert_modules(base_dir):
    mod_file = os.path.join(srcdir, base_dir, "modules")
    for l in open(mod_file):
        l = l.strip()
        if not l or l.startswith("#"):
            continue
        if l.startswith("@"):
            component = l.split()[-1]
            continue
        if component.startswith("port_"):
            continue
        parts = l.split()
        f = parts[0]
        if f == "link_test":
            continue
        d = parts[2].strip("()$")
        if d == "." or d == "srcdir":
            d = ""
        elif d == "wide":
            d = "widechar"
        elif d == "serial":
            d = "tty"
        print "    '%s.c'," % (os.path.join(base_dir, d, f),)

srcdir = sys.argv[1]
print "NCURSES_SRCS = ["
convert_modules("ncurses")
print "]"
print
print "PANEL_SRCS = ["
convert_modules("panel")
print "]"
