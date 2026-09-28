#!/usr/bin/env bash
# Stock-APK cache helpers, used around actions/cache in the workflows.
#
#   apk_cache.sh manifest   write temp/cache_manifest.txt (path + size per file)
#   apk_cache.sh prune      tiered age retention, then an oldest-first sweep to
#                           get the cache back under the size watermark
#
# ONLY stock APKs/bundles (and apkeditor.jar) are cached. Patch and CLI jars
# are deliberately excluded: get_prebuilts() resolves `patches-version = "latest"`
# from whatever jar already sits in temp/, so a warm jar cache would pin the
# build to the patches that were current when the cache was written.
#
# Tunables: APK_CACHE_MAX_MB (default 8192), APK_CACHE_TIERS (default "30 14 7 3").

set -euo pipefail

TEMP_DIR="${1:-temp}"
MODE="${2:-manifest}"
WATERMARK_KB=$((${APK_CACHE_MAX_MB:-8192} * 1024))
read -r -a TIERS_DAYS <<<"${APK_CACHE_TIERS:-30 14 7 3}"

cache_files() {
	find "$TEMP_DIR" -maxdepth 1 -type f \( -name '*.apk' -o -name '*.apkm' \) -print 2>/dev/null || :
	if [ -f "$TEMP_DIR/apkeditor.jar" ]; then
		printf '%s\n' "$TEMP_DIR/apkeditor.jar"
	fi
}

total_kb() {
	local total=0 size f
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		size=$(stat -c %s "$f" 2>/dev/null) || continue
		total=$((total + size))
	done < <(cache_files)
	printf '%s\n' "$((total / 1024))"
}

cmd_manifest() {
	local out="$TEMP_DIR/cache_manifest.txt" f size n
	mkdir -p "$TEMP_DIR"
	: >"$out"
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		size=$(stat -c %s "$f" 2>/dev/null) || continue
		printf '%s %s\n' "$f" "$size" >>"$out"
	done < <(cache_files)
	sort -o "$out" "$out"
	n=$(wc -l <"$out")
	if [ "$n" -eq 0 ]; then
		# nothing cached: drop the manifest so the workflow's
		# hashFiles guard skips the (no-op) save step entirely
		rm -f "$out"
		echo "cache manifest: empty, nothing to save"
		return 0
	fi
	echo "cache manifest: $n files, $(total_kb)K"
}

delete_older_than() {
	find "$TEMP_DIR" -maxdepth 1 -type f \( -name '*.apk' -o -name '*.apkm' \) -mtime "+$1" -delete 2>/dev/null || :
	if [ -f "$TEMP_DIR/apkeditor.jar" ]; then
		find "$TEMP_DIR/apkeditor.jar" -maxdepth 0 -mtime "+$1" -delete 2>/dev/null || :
	fi
	return 0
}

delete_oldest_until() {
	local limit_kb=$1 total oldest
	total=$(total_kb)
	while [ "$total" -gt "$limit_kb" ]; do
		oldest=$(find "$TEMP_DIR" -maxdepth 1 -type f \( -name '*.apk' -o -name '*.apkm' \) \
			-printf '%T@ %p\n' 2>/dev/null | sort -n | head -n 1 | sed 's/^[0-9.]* //')
		if [ -z "$oldest" ]; then break; fi
		rm -f "$oldest" || break # unreadable file: stop rather than loop forever
		total=$(total_kb)
	done
}

cmd_prune() {
	local total tier
	total=$(total_kb)
	if [ "$total" -le "$WATERMARK_KB" ]; then
		echo "cache is ${total}K (<= ${WATERMARK_KB}K), nothing to prune"
		return 0
	fi
	echo "cache is ${total}K, pruning to <= ${WATERMARK_KB}K"
	for tier in "${TIERS_DAYS[@]}"; do
		delete_older_than "$tier"
		total=$(total_kb)
		echo "  after dropping files older than ${tier}d: ${total}K"
		if [ "$total" -le "$WATERMARK_KB" ]; then return 0; fi
	done
	delete_oldest_until "$WATERMARK_KB"
	echo "  after oldest-first sweep: $(total_kb)K"
}

case "$MODE" in
manifest) cmd_manifest ;;
prune) cmd_prune ;;
*)
	echo "usage: $0 [temp-dir] {manifest|prune}" >&2
	exit 2
	;;
esac
