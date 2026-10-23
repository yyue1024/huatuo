#!/bin/sh
# Copyright 2026 The HuaTuo Authors
# SPDX-License-Identifier: Apache-2.0

set -eu
repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
default_image=huatuo/huatuo-toolchain:latest
default_archive="$repo_dir/build/toolchain/huatuo-toolchain.tar"
fail() {
	echo "build image: $*" >&2
	exit 1
}

# Check daemon access first so a permission error cannot mean a missing image.
platform=$(docker info --format '{{.OSType}}/{{.Architecture}}') || fail "cannot access Docker; configure Docker access for the current user before building"
case "$platform" in
linux/amd64 | linux/x86_64) build_arch=amd64 ;;
linux/arm64 | linux/aarch64) build_arch=arm64 ;;
*) fail "unsupported Docker daemon platform: $platform; use Linux AMD64 or ARM64" ;;
esac
format='{{.Id}}|{{.Os}}/{{.Architecture}}|{{index .Config.Labels "tech.huatuo.toolchain.target"}}'
load_archive() {
	[ -n "$1" ] && [ -r "$1" ] && [ -f "$1" ] || fail "toolchain archive must name a readable docker image save tar: $1"
	echo "Loading toolchain archive: $1" >&2
	load_output=$(docker image load --input "$1") || fail "cannot load $1; provide a valid docker image save archive"
	printf '%s\n' "$load_output" >&2
	build_image=$(printf '%s\n' "$load_output" | sed -n -e 's/^Loaded image: //p' -e 's/^Loaded image ID: //p' | sort -u)
	[ -n "$build_image" ] && [ "$(printf '%s\n' "$build_image" | wc -l)" -eq 1 ] || fail "archive must contain one image reference; export it with docker image save -o FILE IMAGE"
	if [ "${HUATUO_BUILD_IMAGE+x}" = x ]; then
		[ "$build_image" = "$HUATUO_BUILD_IMAGE" ] || fail "archive contains $build_image, not HUATUO_BUILD_IMAGE=$HUATUO_BUILD_IMAGE; use the name saved in the archive"
	fi
}

if [ "${HUATUO_BUILD_IMAGE+x}" = x ]; then
	[ -n "$HUATUO_BUILD_IMAGE" ] || fail "HUATUO_BUILD_IMAGE is empty; specify a local image or unset it"
fi
use_default=false
# Explicit inputs must never silently fall back to a different environment.
if [ "${HUATUO_BUILD_IMAGE_TAR+x}" = x ]; then
	load_archive "$HUATUO_BUILD_IMAGE_TAR"
elif [ "${HUATUO_BUILD_IMAGE+x}" = x ]; then
	build_image=$HUATUO_BUILD_IMAGE
	docker image inspect "$build_image" > /dev/null 2>&1 || fail "local image not found: $build_image; load it first or provide HUATUO_BUILD_IMAGE_TAR"
else
	use_default=true
	build_image=$default_image
	if docker image inspect "$build_image" > /dev/null 2>&1; then
		echo "Reusing local build image: $build_image" >&2
	elif [ -e "$default_archive" ] || [ -L "$default_archive" ]; then
		load_archive "$default_archive"
	else
		echo "Building missing toolchain image: $build_image" >&2
		# The Docker driver shares the image store used by inspect, save, and load.
		docker buildx build --builder default --platform "linux/$build_arch" \
			--network host --progress=plain --target arm64-toolchain --load --provenance=false \
			-t "$build_image" -f "$repo_dir/Dockerfile.devel" "$repo_dir" >&2
	fi
fi
metadata=$(docker image inspect --format "$format" "$build_image") || fail "cannot inspect $build_image; check Docker daemon access and image availability"
IFS='|' read -r image_id image_platform image_target << EOF
$metadata
EOF
[ "$image_platform" = "linux/$build_arch" ] || fail "$build_image runs on $image_platform; select a linux/$build_arch toolchain image"
[ "$image_target" = linux/arm64 ] || fail "$build_image is not a Huatuo ARM64 toolchain; select the toolchain image instead of the runtime image"
if [ "$use_default" = true ] && [ "$build_image" != "$default_image" ]; then
	docker image tag "$image_id" "$default_image"
	build_image=$default_image
fi
echo "Build image: $build_image ($image_id)" >&2
# Resolve the tag once so a concurrent retag cannot change this build's image.
printf '%s\n' "$image_id"
