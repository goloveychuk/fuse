#!/usr/bin/env bash
# set -e
# xcodebuild build -scheme  FSKitExp -configuration Debug -destination 'platform=macOS,arch=arm64' -allowProvisioningUpdates -derivedDataPath .dist
# ./.dist/Build/Products/Debug/FSKitExp.app/Contents/MacOS/FSKitExp &

# sleep 5

# kill -9 $!

umount -f /tmp/asd|| true
# -v verbose
# -F - force fskit
# 
mount -F -t MyFS -o -m=/Users/vadymh/github/fskit/FSKitSample/example/.yarn/fuse-state.json,-u=/Users/vadymh/github/fskit/FSKitSample/upper /dev/disk4 /tmp/asd
# mount -F -t MyFS -o -m=./build.sh,-d=./  /dev/disk5 ./test2
biggest_pid=$(pgrep FSKitExpExtension | sort -n | tail -1 | tr -d ' ')
echo "FSKIT PID: $biggest_pid"
echo $biggest_pid | pbcopy
