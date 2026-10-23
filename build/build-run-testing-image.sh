#!/bin/bash
#
# Author: Tonghao Zhang <tonghao@bamaicloud.com>
#
# Copyright 2025, 2026 The HuaTuo Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

set -eu

WORKSPACE_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

# A target kernel tree is no longer needed with the bundled CO-RE headers.
if [ "${KERNEL_BUILD_DIR+x}" = x ]; then
	echo "KERNEL_BUILD_DIR is no longer used; unset it to build with bundled headers" >&2
	exit 1
fi

[ "${TARGETPLATFORM:-linux/arm64}" = linux/arm64 ] || {
	echo "Unsupported TARGETPLATFORM: $TARGETPLATFORM; this script exports linux/arm64 binary releases" >&2
	exit 1
}
[ "$(id -u)" -ne 0 ] || {
	echo "Run the package build as a regular user with Docker access; do not use sudo" >&2
	exit 1
}
RELEASE_VERSION=$(awk -F '"' '/^APP_VERSION[[:space:]]*=/ { print $2; exit }' "$WORKSPACE_DIR/Makefile")
case "$RELEASE_VERSION" in
'' | *[!a-zA-Z0-9._+-]*)
	echo "Cannot read APP_VERSION from $WORKSPACE_DIR/Makefile" >&2
	exit 1
	;;
esac
PACKAGE_NAME="huatuo-bamai-v$RELEASE_VERSION-static-linux-arm64"
PACKAGE_ARCHIVE="$WORKSPACE_DIR/$PACKAGE_NAME.tar.gz"
for file in "$WORKSPACE_DIR/$PACKAGE_NAME" "$PACKAGE_ARCHIVE"; do
	if [ -L "$file" ] || { [ -e "$file" ] && [ ! -w "$file" ]; }; then
		echo "Cannot replace release output: $file; remove the symlink or restore ownership" >&2
		exit 1
	fi
done
if [ -e "$PACKAGE_ARCHIVE" ] && [ ! -f "$PACKAGE_ARCHIVE" ]; then
	echo "Release archive path is not a regular file: $PACKAGE_ARCHIVE; remove the conflicting path" >&2
	exit 1
fi
APP_COMMIT=${APP_COMMIT:-$(git -c safe.directory="$WORKSPACE_DIR" -C "$WORKSPACE_DIR" describe --dirty --long --always 2> /dev/null || printf unknown)}
BUILD_IMAGE=$(sh "$WORKSPACE_DIR/build/prepare-build-image.sh")
umask 022
PACKAGE_WORK_DIR=$(mktemp -d "$WORKSPACE_DIR/.huatuo-release.XXXXXX")
PACKAGE_CONTAINER=''
cleanup_package() {
	if [ -n "$PACKAGE_CONTAINER" ]; then
		docker rm -f "$PACKAGE_CONTAINER" > /dev/null || :
	fi
	rm -rf -- "$PACKAGE_WORK_DIR"
}
trap cleanup_package EXIT
trap 'exit 1' HUP INT TERM

# Copy sources instead of mounting them writable: generators stay in the container.
tar --exclude-from="$WORKSPACE_DIR/.dockerignore" \
	-cf "$PACKAGE_WORK_DIR/source.tar" -C "$WORKSPACE_DIR" .
PACKAGE_CONTAINER=$(docker create --pull=never --network=none --workdir /workspace \
	--env "APP_COMMIT=$APP_COMMIT" --env "PACKAGE_NAME=$PACKAGE_NAME" \
	--env TARGETPLATFORM=linux/arm64 --env TARGETOS=linux --env TARGETARCH=arm64 \
	--env GOPROXY=off --env GOSUMDB=off --env GOTOOLCHAIN=local \
	--entrypoint sh "$BUILD_IMAGE" -ec '
	umask 022
	tar xf /tmp/huatuo-source.tar -C /workspace
	rm /tmp/huatuo-source.tar
	make all BUILD_MODE=static APP_COMMIT="$APP_COMMIT" GO_BUILD_COMMAND=xx-go \
		BPF_EXTRA_CFLAGS="-U__TARGET_ARCH_x86 -D__TARGET_ARCH_arm64"
	for binary in _output/bin/*; do
		xx-verify --static "$binary"
	done
	# Keep the upstream release layout and archive name; package inside Docker.
	mkdir -p "/tmp/release/$PACKAGE_NAME"
	cp -a _output/bin _output/bpf _output/conf LICENSE "/tmp/release/$PACKAGE_NAME/"
	printf "\n    KubeletReadOnlyPort=0\n    KubeletAuthorizedPort=0\n" \
		>> "/tmp/release/$PACKAGE_NAME/conf/huatuo-bamai.conf"
	cd /tmp/release
	tar zcf "$PACKAGE_NAME.tar.gz" "$PACKAGE_NAME"
')
docker cp "$PACKAGE_WORK_DIR/source.tar" "$PACKAGE_CONTAINER:/tmp/huatuo-source.tar"
rm "$PACKAGE_WORK_DIR/source.tar"
docker start --attach "$PACKAGE_CONTAINER"
# Without -a, docker cp gives the exported files to the invoking host user.
docker cp "$PACKAGE_CONTAINER:/tmp/release/$PACKAGE_NAME" "$PACKAGE_WORK_DIR/"
docker cp "$PACKAGE_CONTAINER:/tmp/release/$PACKAGE_NAME.tar.gz" "$PACKAGE_WORK_DIR/"
docker rm "$PACKAGE_CONTAINER" > /dev/null
PACKAGE_CONTAINER=''
# Replace previous outputs only after the new archive is complete.
rm -rf -- "$WORKSPACE_DIR/$PACKAGE_NAME"
mv "$PACKAGE_WORK_DIR/$PACKAGE_NAME" "$WORKSPACE_DIR/"
mv "$PACKAGE_WORK_DIR/$PACKAGE_NAME.tar.gz" "$PACKAGE_ARCHIVE"
echo "Binary release package: $PACKAGE_ARCHIVE"
