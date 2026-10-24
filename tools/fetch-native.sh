#!/bin/sh
# Fetch Nachtul's per-platform native libraries (libgstaudio, libTagUtils)
# into third_party/native/<platform>/ — same shape as NielloUI's
# fetch-native.sh.
#
# STUB: there is no Nachtul native release yet. Until one exists, build
# gstaudio and TagUtils from their repos and drop the artifacts into
# third_party/native/<platform>/ by hand (linux-x64 is populated that
# way in the working tree; the binaries are gitignored).
#
# When releases exist this script will download
#   nachtul-native-<platform>.zip
# from this repo's GitHub Releases and unpack it into place.
set -eu
echo "fetch-native: no native release published yet — see README.md" >&2
exit 1
