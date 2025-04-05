#!/usr/bin/env bash
# set -e
# xcodebuild build -scheme  FSKitExp -configuration Debug -destination 'platform=macOS,arch=arm64' -allowProvisioningUpdates -derivedDataPath .dist
# ./.dist/Build/Products/Debug/FSKitExp.app/Contents/MacOS/FSKitExp &

# sleep 5

# kill -9 $!

umount /tmp/TestVol || true
# -v verbose
# -F - force fskit
# 
# mount -F -t MyFS -o -m=/Users/vadymh/Library/Containers/app.badim.FSKitExpExtension/Data/deptree.json  /dev/disk5 /tmp/TestVol
mount -F -t MyFS -o -m=/Users/vadymh/work/responsive-editor-packages/.yarn/fuse-state.json  /dev/disk5 /tmp/TestVol
biggest_pid=$(pgrep FSKitExpExtension | sort -n | tail -1 | tr -d ' ')
echo "FSKIT PID: $biggest_pid"
echo $biggest_pid | pbcopy
