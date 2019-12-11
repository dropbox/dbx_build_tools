Build tools for DRTE (versions >= 2)

What's in a version a DRTE version in controlled by a shell script
configuration file. See drtev2.cfg for an example.

The main entrypoints to actually do the build are build.sh and
drte-package.sh. build.sh runs a docker container to download all
relevant sources, compile them, and install them into a temporary
root. It takes a very long time (hours). drte-package.sh takes in the
temporary root and produces a runtime root debian package, an
associated debug package, and a tar file with the toolchain.

A complete build looks like:
$ cd build_tools/drte/tools
$ ./build.sh drtev2.cfg
$ ./drte-package.sh drtev2.cfg
