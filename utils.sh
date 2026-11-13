#!/usr/bin/env bash

MODULE_TEMPLATE_DIR="module"
CWD=$(pwd)
TEMP_DIR="temp"
BIN_DIR="bin"
BUILD_DIR="build"
DL_SRCS=("morphe" "aptoide" "apkeep" "apkcombo" "apkmirror" "apkpure" "archive" "direct" "gplaydl" "uptodown")
# Set per build in build_rv(): patches that check the developer certificate
# (GmsCore/MicroG support) need the untouched stock signature, so a split bundle
# must not be merged and re-signed. merge_splits() reads this flag.
REQUIRE_STOCK_SIGNATURE=false

if [ "${GITHUB_TOKEN-}" ]; then GH_HEADER="Authorization: token ${GITHUB_TOKEN}"; else GH_HEADER=; fi
if [ "${GL_TOKEN-}" ]; then GL_HEADER="PRIVATE-TOKEN: ${GL_TOKEN}"; else GL_HEADER=; fi
NEXT_VER_CODE=${NEXT_VER_CODE:-$(date +'%Y%m%d')}
OS=$(uname -o)

toml_read_json() { $TOML --output json --file "$1" . 2>/dev/null; }

# Print the extra config files that a TOML config file pulls in, one per line:
#   `app-configs = "dir"`  -> every *.toml in dir, sorted by name
#   `imports = ["f.toml"]` -> those files, in the listed order
# Paths are relative to the directory of the file that names them.
toml_extra_files() {
	local src=$1 json=$2
	local dir
	dir=$(dirname "$src")

	local dir_arg
	dir_arg=$(jq -r 'if (."app-configs" | type) == "string" then ."app-configs" else empty end' <<<"$json") || :

	if [ -n "$dir_arg" ]; then
		local d="$dir/$dir_arg"
		if [ ! -d "$d" ]; then epr "app-configs: '$dir_arg' is not a directory"; return 1; fi
		local had_nullglob=0
		shopt -q nullglob || had_nullglob=1
		shopt -s nullglob
		local files=("$d"/*.toml)
		((had_nullglob)) || shopt -u nullglob
		((${#files[@]})) || wpr "app-configs: no *.toml found in '$dir_arg'"
		printf '%s\n' "${files[@]}"
	fi

	local imports
	imports=$(jq -r 'if (.imports | type) == "array" then .imports[]
		elif (.imports | type) == "string" then .imports
		else empty end' <<<"$json") || :
	if [ -n "$imports" ]; then
		local f
		while IFS= read -r f; do
			[ -n "$f" ] && printf '%s\n' "$dir/$f"
		done <<<"$imports"
	fi
}

# Merge a config's whole include tree into $1 (a JSON object string).
# `imports`/`app-configs` are consumed and never reach the merged output.
# A duplicate app table name is an error, so an app cannot silently shadow another.
#
# $1 merged json so far   $2 file whose includes are being expanded
# $3 files already merged (cycle guard)
toml_merge() {
	local json=$1 src=$2 seen=${3:-" $2 "} f own

	# includes are resolved from this file's own json only, never from the
	# merged result, otherwise a root `app-configs` would be re-applied to
	# every file below it
	own=$(toml_read_json "$src") || own=$json

	# command substitution, not process substitution: a process substitution
	# would swallow the non-zero status of toml_extra_files
	local list
	list=$(toml_extra_files "$src" "$own") || return 1

	while IFS= read -r f; do
		[ -n "$f" ] || continue
		case "$seen" in *" $f "*) continue ;; esac
		seen+="$f "
		[ -f "$f" ] || { epr "import: '$f' does not exist"; return 1; }

		local sub
		sub=$(toml_read_json "$f") || { epr "could not parse '$f'"; return 1; }
		[ -n "$sub" ] || { epr "'$f' produced no output"; return 1; }

		local dup
		dup=$(jq -r --argjson sub "$sub" '
			def tables: [ to_entries[] | select(.value | type == "object") | .key ];
			($sub | tables) as $new | (tables) as $old
			| [ $new[] | select(. as $k | $old | index($k)) ] | join(" ")' <<<"$json") || :
		if [ -n "$dup" ]; then epr "duplicate app table(s) in '$f': $dup"; return 1; fi

		json=$(jq -c --argjson sub "$sub" '. * ($sub | del(."app-configs", .imports))' <<<"$json") || return 1
		json=$(toml_merge "$json" "$f" "$seen") || return 1
	done <<<"$list"
	printf '%s' "$json"
}

toml_prep() {
	if [ ! -f "$1" ]; then return 1; fi
	if [ "${1##*.}" == toml ]; then
		local json
		json=$(toml_read_json "$1") || { epr "could not parse '$1'"; return 1; }
		json=$(toml_merge "$json" "$1" " $1 ") || return 1
		# the include directives themselves are not part of the result, so a
		# merged config looks exactly like a single-file one
		__TOML__=$(jq -c 'del(."app-configs", .imports)' <<<"$json") || return 1
	elif [ "${1##*.}" == json ]; then
		__TOML__=$(cat "$1")
	else abort "config extension not supported"; fi
}
toml_get_table_names() { jq -r -e 'to_entries[] | select(.value | type == "object") | .key' <<<"$__TOML__"; }
toml_get_table_main() { jq -r -e 'to_entries | map(select(.value | type != "object")) | from_entries' <<<"$__TOML__"; }
toml_get_table() { jq -r -e ".\"${1}\"" <<<"$__TOML__"; }
toml_get() {
	local op quote_placeholder=$'\001'
	op=$(jq -r ".\"${2}\" | values" <<<"$1")
	if [ "$op" ]; then
		op="${op#"${op%%[![:space:]]*}"}"
		op="${op%"${op##*[![:space:]]}"}"
		op=${op//\\\'/$quote_placeholder}
		op=${op//"''"/$quote_placeholder}
		op=${op//"'"/'"'}
		op=${op//$quote_placeholder/$'\''}
		echo "$op"
	else return 1; fi
}

pr() { echo -e "\033[0;32m[+] ${1}\033[0m"; }
epr() {
	echo >&2 -e "\033[0;31m[-] ${1}\033[0m"
	if [ "${GITHUB_REPOSITORY-}" ]; then echo >&2 -e "::error::utils.sh [-] ${1}\n"; fi
}
wpr() {
	echo >&2 -e "\033[0;33m[!] ${1}\033[0m"
	if [ "${GITHUB_REPOSITORY-}" ]; then echo >&2 -e "::warning::utils.sh [!] ${1}\n"; fi
}
abort() {
	epr "ABORT: ${1-}"
	rm -rf ./${TEMP_DIR}/*tmp.* ./${TEMP_DIR}/*/*tmp.* ./${TEMP_DIR}/*-temporary-files ./*-temporary-files
	trap - SIGTERM SIGINT EXIT
	kill -- -$$ 2>/dev/null
	exit 1
}
java() { env -i PATH="$PATH" HOME="$HOME" java --enable-native-access=ALL-UNNAMED "$@"; }

get_prebuilts() {
	local cli_src=$1 cli_ver=$2 patches_src=$3 patches_ver=$4
	local patches_src_name=${patches_src#GitLab:}
	pr "Getting prebuilts ($patches_src_name)" >&2
	local cl_dir=${patches_src_name%/*}
	cl_dir=${TEMP_DIR}/${cl_dir,,}-rv
	[ -d "$cl_dir" ] || mkdir "$cl_dir"

	for src_ver in "$cli_src CLI $cli_ver cli" "$patches_src Patches $patches_ver patches"; do
		set -- $src_ver
		local src=$1 tag=$2 ver=${3-} fprefix=$4

		if [ "$tag" = "CLI" ]; then
			local grab_cl=false
		elif [ "$tag" = "Patches" ]; then
			local grab_cl=true
		else abort unreachable; fi

		local dir=${src%/*}
		dir=${TEMP_DIR}/${dir,,}-rv
		[ -d "$dir" ] || mkdir "$dir"

		local rv_rel name_ver
		if [[ $src == GitLab:* ]]; then
			local gl_src=${src#GitLab:}
			local gl_src_enc=${gl_src//\//%2F}
			rv_rel="https://gitlab.com/api/v4/projects/${gl_src_enc}/releases"
		else
			rv_rel="https://api.github.com/repos/${src}/releases"
		fi

		if [ "$ver" = "dev" ]; then
			local resp
			if [[ $src == GitLab:* ]]; then
				resp=$(gl_req "$rv_rel" -) || return 1
			else
				resp=$(gh_req "$rv_rel" -) || return 1
			fi
			ver=$(jq -e -r '.[] | .tag_name' <<<"$resp" | get_highest_ver) || return 1
		fi

		if [ "$ver" = "latest" ]; then
			if [[ $src != GitLab:* ]]; then rv_rel+="/latest"; fi
			name_ver="*"
		else
			if [[ $src == GitLab:* ]]; then
				rv_rel+="/${ver}"
			else
				rv_rel+="/tags/${ver}"
			fi
			name_ver="$ver"
		fi

		local url file tag_name matches
		file=$(find "$dir" -name "*${fprefix}-${name_ver#v}.*" -type f 2>/dev/null)
		if [ "$ver" = "latest" ]; then
			file=$(grep -v '/[^/]*dev[^/]*$' <<<"$file" | head -1)
		else
			file=$(grep "/[^/]*${ver#v}[^/]*\$" <<<"$file" | head -1)
		fi
		if [ -z "$file" ]; then
			local resp asset name
			if [[ $src == GitLab:* ]]; then
				if [ "$ver" = "latest" ]; then
					resp=$(gl_req "$rv_rel" - | jq -e '.[0]') || return 1
				else
					resp=$(gl_req "$rv_rel" -) || return 1
				fi
				tag_name=$(jq -r '.tag_name' <<<"$resp") || return 1
				matches=$(jq -e '.assets.links | map(select(.name | (endswith("asc") or endswith("json")) | not))' <<<"$resp") || return 1
			else
				resp=$(gh_req "$rv_rel" -) || return 1
				tag_name=$(jq -r '.tag_name' <<<"$resp") || return 1
				matches=$(jq -e '.assets | map(select(.name | (endswith("asc") or endswith("json")) | not))' <<<"$resp") || return 1
			fi
			if [ "$(jq 'length' <<<"$matches")" -gt 1 ]; then
				local matches_new
				matches_new=$(jq -e -r 'map(select(.name | contains("-dev") | not))' <<<"$matches")
				if [ "$(jq 'length' <<<"$matches_new")" -eq 1 ]; then
					matches=$matches_new
				fi
			fi
			if [ "$(jq 'length' <<<"$matches")" -eq 0 ]; then
				epr "No asset was found"
				return 1
			elif [ "$(jq 'length' <<<"$matches")" -ne 1 ]; then
				wpr "More than 1 asset was found for this release. Falling back to the first one found..."
			fi
			asset=$(jq -r ".[0]" <<<"$matches")
			url=$(jq -r .url <<<"$asset")
			name=$(jq -r .name <<<"$asset")
			file="${dir}/${name}"
			if [[ $src == GitLab:* ]]; then
				gl_dl "$file" "$url" >&2 || return 1
			else
				gh_dl "$file" "$url" >&2 || return 1
			fi
			echo "$tag: $(cut -d/ -f1 <<<"${src#GitLab:}")/${name}  " >>"${cl_dir}/changelog.md"
		else
			grab_cl=false
			name=$(basename "$file")
			tag_name=$(cut -d'-' -f3- <<<"$name")
			tag_name=v${tag_name%.*}
		fi

		if [ "$tag" = "Patches" ]; then
			if [ "$grab_cl" = true ]; then
				if [[ $src == GitLab:* ]]; then
					echo -e "[Changelog](https://gitlab.com/${src#GitLab:}/-/releases/${tag_name})\n" >>"${cl_dir}/changelog.md"
				else
					echo -e "[Changelog](https://github.com/${src}/releases/tag/${tag_name})\n" >>"${cl_dir}/changelog.md"
				fi
			fi
			if [ "$REMOVE_RV_INTEGRATIONS_CHECKS" = true ]; then
				local extensions_ext
				extensions_ext=$(unzip -l "${file}" "extensions/shared.*" | grep -o "shared\..*") extensions_ext="${extensions_ext#*.}"
				if ! (
					mkdir -p "${file}-zip" || return 1
					unzip -qo "${file}" -d "${file}-zip" || return 1
					java -cp "${BIN_DIR}/paccer.jar:${BIN_DIR}/dexlib2.jar" com.jhc.Main "${file}-zip/extensions/shared.${extensions_ext}" "${file}-zip/extensions/shared-patched.${extensions_ext}" || return 1
					mv -f "${file}-zip/extensions/shared-patched.${extensions_ext}" "${file}-zip/extensions/shared.${extensions_ext}" || return 1
					rm "${file}" || return 1
					cd "${file}-zip" || abort
					zip -0rq "${CWD}/${file}" . || return 1
				) >&2; then
					echo >&2 "Patching revanced-integrations failed"
				fi
				rm -r "${file}-zip" || :
			fi
		fi
		echo -n "$file "
	done
	echo
}

set_prebuilts() {
	APKSIGNER="${BIN_DIR}/apksigner.jar"
	local arch
	arch=$(uname -m)
	if [ "$arch" = aarch64 ]; then arch=arm64; elif [ "${arch:0:5}" = "armv7" ]; then arch=arm; fi
	HTMLQ="${BIN_DIR}/htmlq/htmlq-${arch}"
	AAPT2="${BIN_DIR}/aapt2/aapt2-${arch}"
	TOML="${BIN_DIR}/toml/tq-${arch}"
}

config_update() {
	if [ ! -f build.md ]; then abort "build.md not available"; fi
	declare -A sources
	: >"$TEMP_DIR"/skipped
	local upped=()
	local prcfg=false
	for table_name in $(toml_get_table_names); do
		if [ -z "$table_name" ]; then continue; fi
		# `--app` narrows config_update to the selected app(s), like the build
		# loop in build.sh; it also wins over `enabled = false`
		if [ -n "${ONLY_APP-}" ] && ! grep -qxF -- "$table_name" <<<"$ONLY_APP"; then continue; fi
		t=$(toml_get_table "$table_name")
		enabled=$(toml_get "$t" enabled) || enabled=true
		if [ "$enabled" = "false" ] && [ -z "${ONLY_APP-}" ]; then
			grep -m1 "^${table_name}:" build.md >>"$TEMP_DIR"/skipped 2>/dev/null || true
			continue
		fi
		PATCHES_SRC=$(toml_get "$t" patches-sources) || PATCHES_SRC=$(toml_get "$t" patches-source) || PATCHES_SRC=$DEF_PATCHES_SRC
		PATCHES_VER=$(toml_get "$t" patches-version) || PATCHES_VER=$DEF_PATCHES_VER
		if [[ -v sources["$PATCHES_SRC/$PATCHES_VER"] ]]; then
			if [ "${sources["$PATCHES_SRC/$PATCHES_VER"]}" = 1 ]; then
				upped+=("$table_name")
				prcfg=true
			else
				if ! grep -q "^${table_name}:" build.md || { [ -f README.md ] && grep -q " ❌ | \`${table_name}\`" README.md; }; then
					upped+=("$table_name")
					prcfg=true
				else
					grep -m1 "^${table_name}:" build.md >>"$TEMP_DIR"/skipped 2>/dev/null || true
				fi
			fi
		else
			sources["$PATCHES_SRC/$PATCHES_VER"]=0
			local rv_rel
			if [[ $PATCHES_SRC == GitLab:* ]]; then
				local gl_src=${PATCHES_SRC#GitLab:}
				local gl_src_enc=${gl_src//\//%2F}
				rv_rel="https://gitlab.com/api/v4/projects/${gl_src_enc}/releases"
			else
				rv_rel="https://api.github.com/repos/${PATCHES_SRC}/releases"
			fi

			if [ "$PATCHES_VER" = "dev" ]; then
				if [[ $PATCHES_SRC == GitLab:* ]]; then
					last_patches=$(gl_req "$rv_rel" - | jq -e -r '.[0]') || continue
				else
					last_patches=$(gh_req "$rv_rel" - | jq -e -r '.[0]') || continue
				fi
			elif [ "$PATCHES_VER" = "latest" ]; then
				if [[ $PATCHES_SRC == GitLab:* ]]; then
					last_patches=$(gl_req "$rv_rel" - | jq -e '.[0]') || continue
				else
					last_patches=$(gh_req "$rv_rel/latest" -) || continue
				fi
			else
				if [[ $PATCHES_SRC == GitLab:* ]]; then
					last_patches=$(gl_req "${rv_rel}/${PATCHES_VER}" -) || continue
				else
					last_patches=$(gh_req "$rv_rel/tags/${PATCHES_VER}" -) || continue
				fi
			fi

			if [[ $PATCHES_SRC == GitLab:* ]]; then
				if ! last_patches=$(jq -e -r '.assets.links[] | select(.name | (endswith("asc") or endswith("json")) | not) | .name' <<<"$last_patches"); then
					abort "config_update error: '$last_patches'"
				fi
			else
				if ! last_patches=$(jq -e -r '.assets[] | select(.name | (endswith("asc") or endswith("json")) | not) | .name' <<<"$last_patches"); then
					abort "config_update error: '$last_patches'"
				fi
			fi

			if [ "$last_patches" ]; then
				local src_user
				if [[ $PATCHES_SRC == GitLab:* ]]; then
					src_user=$(cut -d/ -f1 <<<"${PATCHES_SRC#GitLab:}")
				else
					src_user=${PATCHES_SRC%%/*}
				fi
				if ! OP=$(grep "^Patches: ${src_user}/" build.md | grep -m1 "$last_patches"); then
					sources["$PATCHES_SRC/$PATCHES_VER"]=1
					prcfg=true
					upped+=("$table_name")
				else
					if ! grep -q "^${table_name}:" build.md || { [ -f README.md ] && grep -q " ❌ | \`${table_name}\`" README.md; }; then
						prcfg=true
						upped+=("$table_name")
					else
						grep -m1 "^${table_name}:" build.md >>"$TEMP_DIR"/skipped 2>/dev/null || true
					fi
					echo "$OP" >>"$TEMP_DIR"/skipped
				fi
			fi
		fi
	done
	if [ "$prcfg" = true ]; then
		local query=""
		for table in "${upped[@]}"; do
			if [ -n "$query" ]; then query+=" or "; fi
			query+=".key == \"$table\""
		done
		jq "to_entries | map(select(${query} or (.value | type != \"object\"))) | from_entries" <<<"$__TOML__"
	fi
}

# ------------------------- cross-job locking -------------------------------
# Parallel build jobs (and the `arch = both` fan-out) can race on the same
# stock APK / split bundle. flock replaces the old tmp-file and lock-file
# spin-waits, which hung forever if the process holding them died.
LOCK_DIR="$TEMP_DIR/locks"

_lock_key() {
	if command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$1" | sha256sum | cut -c1-40
	else
		printf '%s' "$1" | md5sum | cut -c1-40
	fi
}

# _with_lock <name> <cmd> [args...]
# Runs cmd while holding an exclusive lock keyed by <name>. Runs in a subshell,
# so only side effects (files) made by cmd are visible to the caller.
_with_lock() {
	local name="$1" st=0
	shift
	if ! mkdir -p "$LOCK_DIR" 2>/dev/null; then
		# cannot lock at all (unwritable temp) - run unlocked rather than
		# spin forever waiting for a dir we can never create
		"$@" || st=$?
		return "$st"
	fi
	if command -v flock >/dev/null 2>&1; then
		# `|| st=$?` keeps set -e from killing the caller when cmd fails
		(
			exec {_lock_fd}>"$LOCK_DIR/$name.lock" || exit 1
			flock -x "$_lock_fd" || exit 1
			"$@"
		) || st=$?
		return "$st"
	fi
	# Fallback for hosts without util-linux: mkdir lock with a stale-break.
	local dir="$LOCK_DIR/$name.d" waited=0
	while ! mkdir "$dir" 2>/dev/null; do
		sleep 1
		waited=$((waited + 1))
		if [ "$waited" -ge 1800 ]; then
			wpr "Breaking stale lock '$name'"
			rmdir "$dir" 2>/dev/null || :
			waited=0
		fi
	done
	"$@" || st=$?
	rmdir "$dir" 2>/dev/null || :
	return "$st"
}

_req() {
	local ip="$1" op="$2"
	shift 2
	if [ -z "$ip" ]; then
		epr "Error: empty URL passed to _req"
		return 1
	fi
	if [ "$op" = - ]; then
		if ! curl -L -c "$TEMP_DIR/cookie.txt" -b "$TEMP_DIR/cookie.txt" --connect-timeout 15 --retry 5 --retry-all-errors --retry-delay 5 --fail -s -S "$@" "$ip" -o -; then
			epr "Request failed: $ip"
			return 1
		fi
		return 0
	fi
	if [ -z "$op" ]; then
		epr "Error: empty output path passed to _req"
		return 1
	fi
	if [ -f "$op" ]; then return 0; fi
	_with_lock "dl.$(_lock_key "$op")" _req_locked "$ip" "$op" "$@"
}

# Downloads to $op while holding the lock for that path. Re-checks $op because
# another job may have finished the same download while we waited for the lock.
_req_locked() {
	local ip="$1" op="$2"
	shift 2
	if [ -f "$op" ]; then return 0; fi
	local dlp="$(dirname "$op")/tmp.$(basename "$op")"
	rm -f "$dlp"
	if ! curl -L -c "$TEMP_DIR/cookie.txt" -b "$TEMP_DIR/cookie.txt" --connect-timeout 15 --retry 5 --retry-all-errors --retry-delay 5 --fail -s -S "$@" "$ip" -o "$dlp"; then
		epr "Request failed: $ip"
		rm -f "$dlp"
		return 1
	fi
	mv -f "$dlp" "$op"
}
_cf_endpoint_up() {
	curl -s -o /dev/null --connect-timeout 3 --max-time 5 "$1" 2>/dev/null
}

_cf_wait_endpoint() {
	local url=$1 max=${2:-60} waited=0
	while ! _cf_endpoint_up "$url"; do
		sleep 2
		waited=$((waited + 2))
		if [ "$waited" -ge "$max" ]; then return 1; fi
	done
}

_cf_write_state() {
	# $1 solver_url $2 trawl_url $3 has_solver $4 has_trawl $5 may_spawn
	local state="$TEMP_DIR/cf_services.sh"
	{
		printf 'CF_SOLVER_URL=%q\n' "$1"
		printf 'CF_TRAWL_URL=%q\n' "$2"
		printf 'CF_HAS_SOLVER=%s\n' "$3"
		printf 'CF_HAS_TRAWL=%s\n' "$4"
		printf 'CF_MAY_SPAWN=%s\n' "$5"
	} >"$state.tmp"
	mv -f "$state.tmp" "$state"
}

_cf_spawn_trawl() {
	docker run -d --name redis_service -p 6379:6379 redis:alpine >/dev/null 2>&1 || :
	docker run -d --name trawl_service -p 8191:8191 -e REDIS_URL=redis://host.docker.internal:6379 --add-host=host.docker.internal:host-gateway --shm-size=1gb ghcr.io/germondai/trawl:latest >/dev/null 2>&1 || :
}

_cf_spawn_containers() {
	_cf_spawn_trawl
	docker run -d --name cloudflare_service -p 8000:8000 ghcr.io/sarperavci/cloudflarebypassforscraping:latest >/dev/null 2>&1 || :
}

_cf_resolve_services() {
	[ -f "$TEMP_DIR/cf_services.sh" ] && return 0
	local solver_from_service=false
	[ -n "${CF_SOLVER_URL:-}" ] && solver_from_service=true
	local solver_url="${CF_SOLVER_URL:-http://localhost:8000}"
	local trawl_url="${CF_TRAWL_URL:-http://localhost:8191}"
	local has_solver=false has_trawl=false may_spawn=false

	if [ "$solver_from_service" = true ]; then
		# Provisioned by the workflow's `services:` block: nothing to spawn.
		if _cf_wait_endpoint "$solver_url" 60; then has_solver=true; fi
		if [ -n "${CF_TRAWL_URL:-}" ]; then
			if _cf_wait_endpoint "$trawl_url" 30; then has_trawl=true; fi
		else
			may_spawn=true
		fi
	elif [ "${GITHUB_ACTIONS:-false}" = "true" ] && [ "${CF_SPAWN_CONTAINERS:-true}" = "true" ]; then
		wpr "Starting Cloudflare bypass containers on-demand..."
		_cf_spawn_containers
		if _cf_wait_endpoint "$solver_url" 90; then has_solver=true; fi
		if _cf_wait_endpoint "$trawl_url" 90; then has_trawl=true; fi
	fi
	_cf_write_state "$solver_url" "$trawl_url" "$has_solver" "$has_trawl" "$may_spawn"
}

# Resolve the bypass endpoints once per run (shared across parallel jobs via
# $TEMP_DIR/cf_services.sh). A workflow `services:` container (CF_SOLVER_URL)
# is preferred: it is already listening before the first step runs, so the
# image pulls and the on-demand `docker run` both disappear from the hot path.
_cf_ensure_services() {
	if [ -f "$TEMP_DIR/cf_services.sh" ]; then
		. "$TEMP_DIR/cf_services.sh"
		return 0
	fi
	_with_lock cf.services _cf_resolve_services || :
	if [ -f "$TEMP_DIR/cf_services.sh" ]; then
		. "$TEMP_DIR/cf_services.sh"
	fi
}

# Last resort when the service solver could not pass the challenge: start the
# full browser (trawl) ourselves. Only ever done once per run.
_cf_lazy_spawn_trawl() {
	[ -f "$TEMP_DIR/cf_services.sh" ] || return 0
	_with_lock cf.lazy _cf_lazy_spawn_trawl_locked || :
	if [ -f "$TEMP_DIR/cf_services.sh" ]; then
		. "$TEMP_DIR/cf_services.sh"
	fi
}

_cf_lazy_spawn_trawl_locked() {
	. "$TEMP_DIR/cf_services.sh"
	[ "${CF_HAS_TRAWL:-false}" = true ] && return 0
	wpr "Starting trawl bypass container on-demand..."
	_cf_spawn_trawl
	local has_trawl=false
	if _cf_wait_endpoint "${CF_TRAWL_URL:-http://localhost:8191}" 90; then has_trawl=true; fi
	_cf_write_state "${CF_SOLVER_URL:-http://localhost:8000}" "${CF_TRAWL_URL:-http://localhost:8191}" \
		"${CF_HAS_SOLVER:-false}" "$has_trawl" false
}

_cf_try_trawl() {
	local url=$1 attempt response status html
	for attempt in $(seq 1 3); do
		response=$(curl -s -X POST "${CF_TRAWL_URL:-http://localhost:8191}/scrape" \
			-H 'Content-Type: application/json' \
			-d "{\"url\":\"$url\",\"maxTimeout\":60000,\"skipHttp\":true}") || true
		status=$(jq -r '.statusCode // empty' <<<"$response" 2>/dev/null) || status=""
		if [[ "$status" == "200" ]]; then
			html=$(jq -r '.html // empty' <<<"$response" 2>/dev/null) || html=""
			if [[ -n "$html" && "$html" != *"Attention Required!"* && "$html" != *"Just a moment..."* && "$html" != *"Please Wait... | Cloudflare"* && "$html" != *"Verify you are human"* ]]; then
				CF_COOKIES=$(jq -r '[.cookies[] | .name + "=" + .value] | join("; ")' <<<"$response" 2>/dev/null) || CF_COOKIES=""
				CF_UA=$(jq -r '.userAgent // empty' <<<"$response" 2>/dev/null) || CF_UA=""
				export CF_COOKIES CF_UA
				printf 'export CF_COOKIES=%q; export CF_UA=%q\n' "$CF_COOKIES" "$CF_UA" >"$TEMP_DIR/cf_env.sh.tmp"
				mv -f "$TEMP_DIR/cf_env.sh.tmp" "$TEMP_DIR/cf_env.sh"
				printf '%s\n' "$html"
				return 0
			fi
		fi
		sleep 5
	done
	return 1
}

_cf_try_solver() {
	local url=$1 attempt response_file headers_file http_code html
	for attempt in $(seq 1 3); do
		response_file=$(mktemp)
		headers_file=$(mktemp)
		http_code=$(curl -s -o "$response_file" -w '%{http_code}' \
			-D "$headers_file" \
			-G --data-urlencode "url=$url" \
			--max-time 30 \
			"${CF_SOLVER_URL:-http://localhost:8000}/html") || true
		if [[ "$http_code" == "200" ]]; then
			html=$(cat "$response_file")
			if [[ -n "$html" ]]; then
				# strip the CR curl leaves at the end of every header line
				CF_COOKIES=$(grep -i '^x-cf-bypasser-cookies:' "$headers_file" 2>/dev/null | cut -d':' -f2- | tr -d '\r' | xargs) || CF_COOKIES=""
				CF_UA=$(grep -i '^x-cf-bypasser-user-agent:' "$headers_file" 2>/dev/null | cut -d':' -f2- | tr -d '\r' | xargs) || CF_UA=""
				export CF_COOKIES CF_UA
				printf 'export CF_COOKIES=%q; export CF_UA=%q\n' "$CF_COOKIES" "$CF_UA" >"$TEMP_DIR/cf_env.sh.tmp"
				mv -f "$TEMP_DIR/cf_env.sh.tmp" "$TEMP_DIR/cf_env.sh"
				printf '%s\n' "$html"
				rm -f "$response_file" "$headers_file"
				return 0
			fi
		fi
		rm -f "$response_file" "$headers_file"
		sleep 5
	done
	return 1
}

_cf_get() {
	local url=$1

	export CF_COOKIES=""
	export CF_UA=""

	if [ "${GITHUB_ACTIONS:-false}" = "true" ] || [ -n "${CF_SOLVER_URL:-}" ] || curl -s -m 1 "${CF_SOLVER_URL:-http://localhost:8000}/html" >/dev/null 2>&1; then
		_cf_ensure_services

		if [ "${CF_HAS_TRAWL:-false}" = true ]; then
			_cf_try_trawl "$url" && return 0
		fi
		if [ "${CF_HAS_SOLVER:-false}" = true ]; then
			_cf_try_solver "$url" && return 0
		fi
		if [ "${CF_MAY_SPAWN:-false}" = true ] && [ "${CF_SPAWN_CONTAINERS:-true}" = "true" ]; then
			_cf_lazy_spawn_trawl
			if [ "${CF_HAS_TRAWL:-false}" = true ]; then
				_cf_try_trawl "$url" && return 0
			fi
		fi
	fi

	# fallback
	req "$url" -
}

req() {
  local arg1="$1" arg2="$2"
  shift 2
  [ -f "$TEMP_DIR/cf_env.sh" ] && source "$TEMP_DIR/cf_env.sh"
  if [ -n "${CF_COOKIES:-}" ] && [ -n "${CF_UA:-}" ]; then
    _req "$arg1" "$arg2" "$@" -H "User-Agent: $CF_UA" -H "Cookie: $CF_COOKIES"
  elif [ -n "${CF_COOKIES:-}" ]; then
    _req "$arg1" "$arg2" "$@" -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:108.0) Gecko/20100101 Firefox/108.0" -H "Cookie: $CF_COOKIES"
  elif [ -n "${CF_UA:-}" ]; then
    _req "$arg1" "$arg2" "$@" -H "User-Agent: $CF_UA"
  else
    _req "$arg1" "$arg2" "$@" -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:108.0) Gecko/20100101 Firefox/108.0"
  fi
}
gh_req() {
	if [ "${GH_HEADER-}" ]; then
		_req "$1" "$2" -H "$GH_HEADER"
	else
		_req "$1" "$2"
	fi
}
gl_req() {
	if [ "${GL_HEADER-}" ]; then
		_req "$1" "$2" -H "$GL_HEADER"
	else
		_req "$1" "$2"
	fi
}
gh_dl() {
	if [ ! -f "$1" ]; then
		pr "Getting '$1' from '$2'"
		if [ "${GH_HEADER-}" ]; then
			_req "$2" "$1" -H "$GH_HEADER" -H "Accept: application/octet-stream"
		else
			_req "$2" "$1" -H "Accept: application/octet-stream"
		fi
	fi
}
gl_dl() {
	if [ ! -f "$1" ]; then
		pr "Getting '$1' from '$2'"
		if [ "${GL_HEADER-}" ]; then
			_req "$2" "$1" -H "$GL_HEADER"
		else
			_req "$2" "$1"
		fi
	fi
}

log() { echo -e "$1  " >>"build.md"; }

# `build.md` is the machine-readable run log: `config_update` parses the
# `App: version` and `Patches: owner/file` lines out of it on the next run, so
# it has to stay complete. It is far too long to use as a release body though
# (one line per app, plus a line per CLI), so this renders the short human
# version from it instead.
#
# $1 machine build log   $2 output file
# $3 built count         $4 unchanged count
release_notes_from_build_md() {
	local in=$1 out=$2 built=${3:-0} unchanged=${4:-0} patches
	patches=$(awk '
		function trim(s) { sub(/[[:space:]]+$/, "", s); return s }
		/^Patches: / {
			line = $0
			sub(/^Patches:[[:space:]]*/, "", line)
			line = trim(line)
			n = split(line, a, "/")
			ver = a[n]
			sub(/^patches-/, "", ver)
			sub(/\.(mpp|rvp)$/, "", ver)
			p = "`" a[n - 1] "` " ver
			next
		}
		/^\[Changelog\]/ {
			if (p != "" && !seen[p]++) print "- " p " · " trim($0)
			p = ""
			next
		}
	' "$in")
	{
		printf '**%s apps built**' "$built"
		if [ "$unchanged" -gt 0 ]; then printf ' · %s unchanged' "$unchanged"; fi
		printf '.\n\n'
		printf 'Install [Microg](https://github.com/ReVanced/GmsCore/releases) for non-root YouTube and YT Music APKs\n'
		printf 'Use [zygisk-detach](https://github.com/j-hc/zygisk-detach) to detach YouTube and YT Music modules from Play Store\n'
		if [ -n "$patches" ]; then printf '\n### Patches\n%s\n' "$patches"; fi
		printf '\n'
	} >"$out"
}
get_highest_ver() {
	local vers m
	vers=$(tee)
	m=$(head -1 <<<"$vers")
	if ! semver_validate "$m"; then echo "$m"; else sort -s -t- -k1,1Vr <<<"$vers" | head -1; fi
}
semver_validate() {
	local a="${1%-*}"
	local a="${a#v}"
	local ac="${a//[.0-9]/}"
	[ ${#ac} = 0 ]
}
get_patch_last_supported_ver() {
	local list_patches=$1 pkg_name=$2 inc_sel=$3 _exc_sel=$4 _exclusive=$5 is_exp=${6:-false} # TODO: resolve using all of these
	local op
	if [ "$inc_sel" ]; then
		if ! op=$(awk '{$1=$1}1' <<<"$list_patches"); then
			epr "list-patches: '$op'"
			return 1
		fi
		local ver vers="" NL=$'\n'
		while IFS= read -r line; do
			line="${line:1:${#line}-2}"
			ver=$(sed -n "/^Name: $line\$/,/^\$/p" <<<"$op" | sed -n "/^Compatible versions:\$/,/^\$/p" | tail -n +2)
			vers=${ver}${NL}
		done <<<"$(list_args "$inc_sel")"
		vers=$(awk '{$1=$1}1' <<<"$vers" | grep -E '^[0-9]' | awk '{print $1}')
		if [ "$vers" ]; then
			get_highest_ver <<<"$vers"
			return
		fi
	fi
	op=$(patches_list_versions "$cli_jar" "$patches_jar" "$pkg_name" "$is_exp") || return 1
	op=$(sed -n '/Most common compatible versions:/,$p' <<<"$op" | sed '1d' | awk '{$1=$1}1')
	if [ "$op" = "Any" ] || [ -z "$op" ]; then return 0; fi
	pcount=$(head -1 <<<"$op") pcount=${pcount#*(} pcount=${pcount% *}
	if [ -z "$pcount" ]; then
		epr "No patches found for '$pkg_name' in patches '$patches_jar'"
		return 1
	fi
	grep -F "($pcount patch" <<<"$op" | awk '{print $1}' | get_highest_ver || return 1
}

patches_list_versions() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 is_exp=${4:-false} op cmd
	local cmd_base="java -jar '$cli_jar' list-versions"
	local exp_flag=""
	if [ "$is_exp" = true ]; then exp_flag="-x"; fi

	# TODO: remove this later
	local cli_name
	cli_name=$(basename "$cli_jar")
	if [ "${cli_name::8}" = revanced ]; then cmd_base+=" -b"; fi

	cmd="${cmd_base} --patches='$patches_jar' -f '$pkg_name' $exp_flag"
	if op=$(eval "$cmd" 2>&1); then
		echo "$op"
		return
	fi

	cmd="${cmd_base} '$patches_jar' -f '$pkg_name' $exp_flag"
	if op=$(eval "$cmd" 2>&1); then
		echo "$op"
		return
	fi

	if [ "$is_exp" = true ]; then
		cmd="${cmd_base} --patches='$patches_jar' -f '$pkg_name'"
		if op=$(eval "$cmd" 2>&1); then
			echo "$op"
			return
		fi

		cmd="${cmd_base} '$patches_jar' -f '$pkg_name'"
		if op=$(eval "$cmd" 2>&1); then
			echo "$op"
			return
		fi
	fi

	epr "Could not list versions $cli_jar: '$op'"
	return 1
}
patches_list() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 is_exp=${4:-false} op
	local exp_flag=""
	if [ "$is_exp" = true ]; then exp_flag="-x"; fi
	if ! op=$(java -jar "$cli_jar" list-patches -p "$patches_jar" --filter-package-name "$pkg_name" --versions --packages -b $exp_flag 2>&1); then
		if ! op=$(java -jar "$cli_jar" list-patches --patches "$patches_jar" -f "$pkg_name" --with-versions --with-packages $exp_flag 2>&1); then
			if [ "$is_exp" = true ]; then
				if ! op=$(java -jar "$cli_jar" list-patches -p "$patches_jar" --filter-package-name "$pkg_name" --versions --packages -b 2>&1); then
					if ! op=$(java -jar "$cli_jar" list-patches --patches "$patches_jar" -f "$pkg_name" --with-versions --with-packages 2>&1); then
						epr "Could not get patches list $cli_jar: '$op'"
						return 1
					fi
				fi
			else
				epr "Could not get patches list $cli_jar: '$op'"
				return 1
			fi
		fi
	fi
	echo "$op"
}

isoneof() {
	local i=$1 v
	shift
	for v; do [ "$v" = "$i" ] && return 0; done
	return 1
}

merge_splits() {
	local bundle=$1 output=$2
	_with_lock "merge.$(_lock_key "$output")" _merge_splits_locked "$bundle" "$output"
}

# Extract the original, developer-signed base APK from a split bundle. Used when
# a patch validates the stock certificate: an APKEditor merge is re-signed with
# ks-p12.keystore, which invalidates that certificate (Morphe then aborts with
# "Patch a stock APK instead").
extract_base_apk() {
	local bundle=$1 output=$2 entry="" entries
	# Capture the listing once: `unzip -Z1 | grep -q` would make grep close the
	# pipe on the first match, and pipefail (set in build.sh) would then report
	# unzip's SIGPIPE as a failure.
	entries=$(unzip -Z1 "$bundle" 2>/dev/null) || entries=""
	if [ -z "$entries" ]; then
		epr "Could not read split bundle: $bundle"
		return 1
	fi

	# XAPK/APKM manifests name the base module explicitly.
	if grep -qx "manifest.json" <<<"$entries"; then
		entry=$(unzip -p "$bundle" manifest.json 2>/dev/null |
			jq -r '[(.split_apks // [])[] | select(.id == "base") | .file][0] // empty' 2>/dev/null) || entry=""
	fi

	# No usable manifest: the base is the largest module that is not a config split.
	if [ -z "$entry" ] || ! grep -qxF -- "$entry" <<<"$entries"; then
		entry=$(unzip -Z -l "$bundle" 2>/dev/null |
			awk '$1 ~ /^-/ && $NF ~ /\.apk$/ && $NF !~ /(^|\/)config\./ {print $4, $NF}' |
			sort -rn | sed -n '1p' | cut -d' ' -f2-) || entry=""
	fi
	if [ -z "$entry" ]; then
		epr "No base APK module in '$bundle'"
		return 1
	fi

	local tmp="${output}.base" inner
	rm -f "$tmp"
	if ! unzip -p "$bundle" "$entry" >"$tmp" 2>/dev/null; then
		epr "Could not extract '$entry' from '$bundle'"
		rm -f "$tmp" || :
		return 1
	fi
	inner=$(unzip -Z1 "$tmp" 2>/dev/null) || inner=""
	if ! grep -qx "AndroidManifest.xml" <<<"$inner"; then
		epr "Extracted '$entry' from '$bundle' is not an APK"
		rm -f "$tmp" || :
		return 1
	fi
	mv -f "$tmp" "$output"
}

_merge_splits_locked() {
	local bundle=$1 output=$2
	# another job may have merged it while we waited for the lock
	if [ -f "$output" ]; then return 0; fi
	if [ "$REQUIRE_STOCK_SIGNATURE" = true ]; then
		pr "Extracting signed base APK from split bundle"
		if ! extract_base_apk "$bundle" "$output"; then
			epr "Could not extract base APK from split bundle: $bundle"
			return 1
		fi
		return 0
	fi
	pr "Merging splits"
	gh_dl "$TEMP_DIR/apkeditor.jar" "https://github.com/REAndroid/APKEditor/releases/download/V1.4.7/APKEditor-1.4.7.jar" >/dev/null || return 1
	if ! OP=$(java -jar "$TEMP_DIR/apkeditor.jar" merge -i "$bundle" -o "${output}-unsigned" -clean-meta -f 2>&1); then
		epr "APKEditor error: $OP"
		return 1
	fi
	# sign the merged stock apk
	if ! OP=$(java -jar "$APKSIGNER" sign --ks ks-p12.keystore --ks-pass pass:123456789 --key-pass pass:123456789 --ks-key-alias jhc \
		--out "${output}" "${output}-unsigned"); then
		epr "apksigner error: $OP"
		return 1
	fi
	rm "${output}.idsig" "${output}-unsigned" 2>/dev/null || :
	return 0
}

# Content-based bundle detection. Some download sources hand us split-bundle bytes
# under a plain ".apk" filename — most notably APKPure's /b/APK/<pkg> endpoint, which
# keeps serving the XAPK payload when a release only publishes a split bundle (Dead
# Target 4.186.0 is one: /b/APK/ and /b/XAPK/ both redirect to the same 410 MB
# Dead+Target…APKPure.xapk, and ?arch= is ignored).
#
# A real APK always has a root AndroidManifest.xml. A bundle never does: it carries
# manifest.json and/or the inner *.apk modules instead. Checking the entry list (not
# the extension) is what makes this robust — .apk / .apkm / .xapk / .apks are all
# just ZIPs and the builder renames files around freely.
is_split_bundle() {
	local file=$1 entries
	[ -f "$file" ] || return 1
	entries=$(unzip -Z1 "$file" 2>/dev/null) || return 1
	if grep -qx "AndroidManifest.xml" <<<"$entries"; then
		return 1
	fi
	grep -qx "manifest.json" <<<"$entries" && return 0
	grep -qE "\.apk$" <<<"$entries" && return 0
	return 1
}

# Merge a disguised split bundle in place, so the rest of the pipeline (ApkPrep,
# morphe-cli) only ever sees a real APK. morphe-cli in particular cannot read bundle
# bytes: it looks for the root AndroidManifest.xml during ResourcePatchContext
# construction and dies with
#   NullPointerException: … AndroidManifestBlock.isExtractNativeLibs() because "manifest" is null
# before a single patch executes.
#
# merge_splits() refuses to run when its output already exists, so the bundle is moved
# aside first and restored if the merge fails.
normalize_stock_apk() {
	local apk=$1 bundle
	is_split_bundle "$apk" || return 0
	pr "Stock file is a split bundle, preparing a full APK"
	bundle="${apk}.bundle"
	rm -f "$bundle"
	if ! mv -f "$apk" "$bundle"; then
		epr "Could not move split bundle aside: $apk"
		return 1
	fi
	if ! merge_splits "$bundle" "$apk"; then
		epr "Could not merge split bundle: $bundle"
		mv -f "$bundle" "$apk" 2>/dev/null || :
		return 1
	fi
	rm -f "$bundle"
	return 0
}

# Space-separated list of ABIs that actually ship under lib/ in the APK.
apk_abis() {
	local file=$1
	unzip -Z1 "$file" 2>/dev/null | sed -n 's|^lib/\([^/]*\)/.*|\1|p' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# -------------------- apkmirror --------------------
apkmirror_search() {
	local resp="$1" dpi="$2" arch="$3" apk_bundle="$4"
	local dlurl="" node app_table emptyCheck

	local apparch=('universal' 'noarch' 'arm64-v8a + armeabi-v7a')
	if [ "$arch" != all ]; then
		apparch+=("$arch")
	else
		apparch+=("arm64-v8a" "armeabi-v7a")
	fi

	local appdpi=("nodpi" "anydpi")
	if [ "$dpi" ]; then
		appdpi+=($dpi)
	fi

	for ((n = 1; n < 40; n++)); do
		node=$($HTMLQ "div.table-row.headerFont:nth-last-child($n)" -r "span:nth-child(n+3)" <<<"$resp")
		if [ -z "$node" ]; then break; fi
		emptyCheck=$($HTMLQ -t -w "div.table-cell:nth-child(1) > a:nth-child(1)" <<<"$node" | xargs)
		if [ -z "$emptyCheck" ]; then break; fi
		app_table=$($HTMLQ --text --ignore-whitespace <<<"$node")
		if [ "$(sed -n 3p <<<"$app_table")" != "$apk_bundle" ]; then continue; fi
		dlurl=$($HTMLQ --base https://www.apkmirror.com --attribute href "div:nth-child(1) > a:nth-child(1)" <<<"$node")
		if isoneof "$(sed -n 6p <<<"$app_table")" "${appdpi[@]}" &&
			isoneof "$(sed -n 4p <<<"$app_table")" "${apparch[@]}"; then
			echo "$dlurl"
			return 0
		fi
	done
	if [ "$n" -eq 2 ] && [ "$dlurl" ]; then
		# only one apk exists, return it
		echo "$dlurl"
		return 0
	fi
	return 1
}
dl_apkmirror() {
	local url=$1 version=${2// /-} output=$3 arch=$4 dpi=$5 is_bundle=false

	if [ -f "${output}.apkm" ]; then
		merge_splits "${output}.apkm" "${output}"
		return 0
	fi

	if [ "$arch" = "arm-v7a" ]; then arch="armeabi-v7a"; fi
	local resp node app_table apkmname dlurl=""
	local clean_url="${url%/}"
	local cat="${__APKMIRROR_CAT__:-${clean_url##*/}}"
	local app_path="${clean_url#*apkmirror.com}"
	app_path="/${app_path#/}/"

	local release_path
	release_path=$(grep -E -o "href=\"${app_path}[^\"]*-${version//./-}[a-zA-Z0-9_-]*release/?\"" <<<"$__APKMIRROR_RESP__" | head -n 1 || true)
	if [ -z "$release_path" ]; then
		release_path=$(grep -E -o "href=\"/apk/[^\"]*-${version//./-}[a-zA-Z0-9_-]*release/?\"" <<<"$__APKMIRROR_RESP__" | head -n 1 || true)
	fi
	if [ -z "$release_path" ]; then
		local uploads_resp
		if uploads_resp=$(_cf_get "https://www.apkmirror.com/uploads/?appcategory=${cat}"); then
			release_path=$(grep -E -o "href=\"${app_path}[^\"]*-${version//./-}[a-zA-Z0-9_-]*release/?\"" <<<"$uploads_resp" | head -n 1 || true)
			if [ -z "$release_path" ]; then
				release_path=$(grep -E -o "href=\"/apk/[^\"]*-${version//./-}[a-zA-Z0-9_-]*release/?\"" <<<"$uploads_resp" | head -n 1 || true)
			fi
		fi
	fi
	if [ -z "$release_path" ]; then
		local search_resp
		if search_resp=$(_cf_get "https://www.apkmirror.com/?post_type=app_release&searchtype=apk&s=${cat}+${version}"); then
			release_path=$(grep -E -o "href=\"${app_path}[^\"]*-${version//./-}[a-zA-Z0-9_-]*release/?\"" <<<"$search_resp" | head -n 1 || true)
			if [ -z "$release_path" ]; then
				release_path=$(grep -E -o "href=\"/apk/[^\"]*-${version//./-}[a-zA-Z0-9_-]*release/?\"" <<<"$search_resp" | head -n 1 || true)
			fi
		fi
	fi
	if [ -n "$release_path" ]; then
		release_path=${release_path#href=\"}
		release_path=${release_path%\"}
		release_path="/${release_path#/}"
		release_path="${release_path%/}/"
		url="https://www.apkmirror.com${release_path}"
	else
		apkmname=$($HTMLQ "h1.marginZero" --text <<<"$__APKMIRROR_RESP__")
		apkmname="${apkmname,,}"
		apkmname="${apkmname// /-}"
		apkmname="${apkmname//./-}"
		apkmname="${apkmname//[^a-z0-9-]/}"
		apkmname=$(echo "$apkmname" | tr -s '-')
		url="${clean_url}/${apkmname}-${version//./-}-release/"
	fi
	resp=$(_cf_get "$url") || return 1
	node=$($HTMLQ "div.table-row.headerFont:nth-last-child(1)" -r "span:nth-child(n+3)" <<<"$resp")
	if [ "$node" ]; then
		for type in APK BUNDLE; do
			if dlurl=$(apkmirror_search "$resp" "$dpi" "$arch" "$type"); then
				if [ "$type" = "BUNDLE" ]; then
					is_bundle=true
				else is_bundle=false; fi
				break
			fi
		done
		if [ -z "$dlurl" ]; then return 1; fi
		resp=$(_cf_get "$dlurl")
	fi
	local referer_url
	referer_url=$(echo "$resp" | $HTMLQ --base https://www.apkmirror.com --attribute href "a.btn") || return 1
	url=$(_cf_get "$referer_url" | $HTMLQ --base https://www.apkmirror.com --attribute href "span > a[rel = nofollow]") || return 1

	local cookie_args=()
	[ -n "${CF_COOKIES:-}" ] && cookie_args=(--header "Cookie: $CF_COOKIES")
	local ua="${CF_UA:-Mozilla/5.0 (X11; Linux x86_64; rv:108.0) Gecko/20100101 Firefox/108.0}"

	if [ "$is_bundle" = true ]; then
		wget -nv -O "${output}.apkm" --header="User-Agent: $ua" --referer="$referer_url" "${cookie_args[@]}" --timeout=300 "$url" || return 1
		merge_splits "${output}.apkm" "${output}"
	else
		wget -nv -O "${output}" --header="User-Agent: $ua" --referer="$referer_url" "${cookie_args[@]}" --timeout=300 "$url" || return 1
	fi
}
get_apkmirror_vers() {
	local vers apkm_resp
	apkm_resp=$(_cf_get "https://www.apkmirror.com/uploads/?appcategory=${__APKMIRROR_CAT__}")
	vers=$(sed -n 's;.*Version:</span><span class="infoSlide-value">\(.*\) </span>.*;\1;p' <<<"$apkm_resp" | awk '{$1=$1}1')
	if [ "$__AAV__" = false ]; then
		local IFS=$'\n'
		vers=$(grep -iv "\(beta\|alpha\)" <<<"$vers")
		local v r_vers=()
		for v in $vers; do
			grep -iq "${v} \(beta\|alpha\)" <<<"$apkm_resp" || r_vers+=("$v")
		done
		echo "${r_vers[*]}"
	else
		echo "$vers"
	fi
}
get_apkmirror_pkg_name() { sed -n 's;.*id=\(.*\)" class="accent_color.*;\1;p' <<<"$__APKMIRROR_RESP__"; }
get_apkmirror_resp() {
	local url="${1%/}"
	__APKMIRROR_RESP__=$(_cf_get "${url}/") || return 1
	__APKMIRROR_CAT__="${url##*/}"
}

# -------------------- uptodown --------------------
_utd_eapi_secret='MDGMXUMdvHJBG/vjdFgmqX6LUdy7ecfwvYNd0gyfOCs='
_UTD_EAPI_TOKEN=""
_UTD_EAPI_TOKEN_AT=0

_utd_eapi_token() {
	local now hmac resp token
	now=$(date +%s)
	if [ -n "$_UTD_EAPI_TOKEN" ] && [ $((now - _UTD_EAPI_TOKEN_AT)) -lt 1500 ]; then
		echo "$_UTD_EAPI_TOKEN"
		return 0
	fi
	hmac=$(printf '%s' "$now" | openssl dgst -sha256 -hmac "$_utd_eapi_secret" -hex | awk '{print $2}')
	resp=$(_req "https://www.uptodown.app/eapi/auth/token" - \
		-X POST -H "Content-Type: application/x-www-form-urlencoded" \
		-H "Identificador: Uptodown_Android" -H "Identificador-Version: 736" \
		-H "User-Agent: Dalvik/2.1.0 (Linux; U; Android 14; SM-G955F Build/AP2A.240805.005)" \
		-d "hmac=${hmac}&unixtime=${now}") || return 1
	token=$(jq -er '.token' <<<"$resp") || return 1
	_UTD_EAPI_TOKEN="$token"
	_UTD_EAPI_TOKEN_AT="$now"
	echo "$token"
}

_utd_eapi_get() {
	local path=$1 token resp
	token=$(_utd_eapi_token) || return 1
	resp=$(_req "https://www.uptodown.app/eapi${path}" - \
		-H "Authorization: Bearer ${token}" \
		-H "Identificador: Uptodown_Android" -H "Identificador-Version: 736" \
		-H "User-Agent: Dalvik/2.1.0 (Linux; U; Android 14; SM-G955F Build/AP2A.240805.005)") || return 1
	echo "$resp"
}
_utd_eapi_dlurl() {
	local app_id=$1 file_id=$2
	_utd_eapi_get "/apps/${app_id}/file/${file_id}/downloadUrl?update=0" | jq -er '.data.downloadURL'
}
get_uptodown_resp() {
	if [ "${GITHUB_ACTIONS:-false}" = "true" ]; then
		sleep $((RANDOM % 15))
	fi
	__UPTODOWN_RESP__=$(_cf_get "${1}/versions") || {
		local UA="User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
		__UPTODOWN_RESP__=$(_req "${1}/versions" - -H "$UA") || return 1
	}
	local data_code
	data_code=$($HTMLQ "#detail-app-name" --attribute data-code <<<"$__UPTODOWN_RESP__") || data_code=""
	__UPTODOWN_RESP_PKG__=""
	if [ -n "$data_code" ]; then
		__UPTODOWN_RESP_PKG__=$(_utd_eapi_get "/v3/apps/${data_code}/device/0?countryIsoCode=US" | jq -er '.data.packagename' 2>/dev/null) || __UPTODOWN_RESP_PKG__=""
	fi
	if [ -z "$__UPTODOWN_RESP_PKG__" ]; then
		local UA="User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
		__UPTODOWN_RESP_PKG__=$(_req "${1}/download" - -H "$UA") || return 1
	fi
}
get_uptodown_vers() { $HTMLQ --text ".version" <<<"$__UPTODOWN_RESP__" | awk '{$1=$1}1' | grep -E '^[0-9]' || :; }
dl_uptodown() {
	local uptodown_dlurl=$1 version=$2 output=$3 arch=$4 _dpi=$5
	if [ "$arch" = "arm-v7a" ]; then arch="armeabi-v7a"; fi

	local apparch=('arm64-v8a, armeabi-v7a, x86_64' 'arm64-v8a, armeabi-v7a, x86, x86_64' 'arm64-v8a, armeabi-v7a')
	if [ "$arch" != all ]; then
		apparch+=("$arch")
	else
		apparch+=("arm64-v8a" "armeabi-v7a")
	fi

	local op resp data_code
	data_code=$($HTMLQ "#detail-app-name" --attribute data-code <<<"$__UPTODOWN_RESP__")
	local versionURL="" file_id=""
	local is_bundle=false
	for i in {1..20}; do
		sleep 1
		resp=$(req "${uptodown_dlurl}/apps/${data_code}/versions/${i}" -)
		if ! op=$(jq -e -r ".data | map(select(.version == \"${version}\")) | .[0]" <<<"$resp"); then
			continue
		fi
		if [ "$(jq -e -r ".kindFile" <<<"$op")" = "xapk" ]; then is_bundle=true; fi
		file_id=$(jq -er '.fileID' <<<"$op" 2>/dev/null)
		if versionURL=$(jq -e -r '.versionURL' <<<"$op"); then break; else return 1; fi
	done
	if [ -z "$versionURL" ]; then return 1; fi
	versionURL=$(jq -e -r '.url + "/" + .extraURL + "/" + (.versionID | tostring)' <<<"$versionURL")
	resp=$(req "$versionURL" -) || return 1

	local data_version files node_arch="" data_file_id node_class
	data_version=$($HTMLQ '.button.variants' --attribute data-version <<<"$resp") || return 1
	if [ "$data_version" ]; then
		files=$(req "${uptodown_dlurl%/*}/app/${data_code}/version/${data_version}/files" - | jq -e -r .content) || return 1
		for ((n = 1; n < 12; n += 1)); do
			node_class=$($HTMLQ -w -t ".content > :nth-child($n)" --attribute class <<<"$files") || return 1
			if [ "$node_class" != "variant" ]; then
				node_arch=$($HTMLQ -w -t ".content > :nth-child($n)" <<<"$files" | xargs) || return 1
				continue
			fi
			if [ -z "$node_arch" ]; then return 1; fi
			if ! isoneof "$node_arch" "${apparch[@]}"; then continue; fi

			file_type=$($HTMLQ -w -t ".content > :nth-child($n) > .v-file > span" <<<"$files") || return 1
			if [ "$file_type" = "xapk" ]; then is_bundle=true; else is_bundle=false; fi
			data_file_id=$($HTMLQ ".content > :nth-child($n) > .v-report" --attribute data-file-id <<<"$files") || return 1
			resp=$(req "${uptodown_dlurl}/download/${data_file_id}-x" -)
			break
		done
		if [ $n -eq 12 ]; then return 1; fi
	fi
	local data_url=""
	local eapi_fid="${data_file_id:-$file_id}"
	if [ -n "$eapi_fid" ]; then
		data_url=$(_utd_eapi_dlurl "$data_code" "$eapi_fid")
	fi
	if [ -z "$data_url" ]; then
		data_url=$($HTMLQ "#detail-download-button" --attribute data-url <<<"$resp") || data_url=""
	fi
	if [ -z "$data_url" ]; then return 1; fi
	case "$data_url" in
		http://*|https://*) dl_url="$data_url" ;;
		*) dl_url="https://dw.uptodown.com/dwn/${data_url}" ;;
	esac
	if [ $is_bundle = true ]; then
		req "$dl_url" "$output.apkm" || return 1
		merge_splits "${output}.apkm" "${output}"
	else
		req "$dl_url" "$output" || return 1
	fi
}
get_uptodown_pkg_name() {
	local pkg
	pkg=$(grep -oE '^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+$' <<<"$__UPTODOWN_RESP_PKG__") || pkg=""
	if [ -z "$pkg" ]; then
		pkg=$($HTMLQ --text "tr.full:nth-child(1) > td:nth-child(3)" <<<"$__UPTODOWN_RESP_PKG__")
	fi
	echo "$pkg"
}

# -------------------- apkcombo --------------------
get_apkcombo_resp() {
	local url="${1%/}"
	url="${url%/versions}"
	url="${url%/download}"
	url="${url%/}"
	__APKCOMBO_URL__="$url"
	local tr_url="https://translate.google.com/website?sl=auto&tl=en&hl=en&client=webapp&u=${__APKCOMBO_URL__}/versions/"
	__APKCOMBO_RESP__=$(_req "$tr_url" - -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)") || return 1
}

get_apkcombo_pkg_name() {
	local p="${__APKCOMBO_URL__%/}"
	echo "${p##*/}"
}

get_apkcombo_vers() {
	$HTMLQ "ul.list-versions li a .vername" --text <<<"$__APKCOMBO_RESP__" | awk '{print $NF}'
}

dl_apkcombo() {
	local url=$1 version=$2 output=$3 arch=$4 dpi=$5
	local dl_page_path=""
	dl_page_path=$($HTMLQ "ul.list-versions li a.ver-item" --attribute href <<<"$__APKCOMBO_RESP__" | grep -m1 "$version")
	dl_page_path=$(echo "$dl_page_path" | sed 's/[?&]_x_tr.*//g' | sed 's/https:\/\/apkcombo-com.translate.goog//g')
	
	if [ -z "$dl_page_path" ]; then
		epr "ERROR: version $version not found in apkcombo"
		return 1
	fi
	
	if [[ "$dl_page_path" != /* ]]; then
		dl_page_path="/${dl_page_path}"
	fi
	
	local dl_page_resp
	dl_page_resp=$(_cf_get "https://apkcombo.com${dl_page_path}") || return 1
	
	local dl_url=""
	dl_url=$($HTMLQ "a.variant" --attribute href <<<"$dl_page_resp" | grep -E "(r2|d)\?u=" | head -n 1)
	
	if [ -z "$dl_url" ]; then
		epr "ERROR: Could not find direct download link on apkcombo download page"
		return 1
	fi
	
	local direct_url=""
	direct_url=$(echo "$dl_url" | grep -oP '(?<=\?u=)[^&]+' | base64 -d 2>/dev/null)
	
	if [[ "$direct_url" == http* ]]; then
		dl_url="$direct_url"
	elif [[ "$dl_url" == /* ]]; then
		dl_url="https://apkcombo.com${dl_url}"
	else
		dl_url=$(echo "$dl_url" | sed 's/&_x_tr.*//g' | sed 's/apkcombo-com.translate.goog/apkcombo.com/g')
	fi

	if grep -qiE "/(XAPK|APKS)/|\.xapk|\.apks" <<<"$dl_url"; then
		_req "$dl_url" "${output}.apkm" -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)" || return 1
		merge_splits "${output}.apkm" "${output}"
	else
		_req "$dl_url" "$output" -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)" || return 1
	fi
}

# -------------------- apkpure --------------------
get_apkpure_resp() {
	local url="${1%/}"
	url="${url%/versions}"
	url="${url%/download}"
	url="${url%/}"
	__APKPURE_RESP__=$(req "${url}/versions" -) || return 1
	__APKPURE_URL__="$url"
}
get_apkpure_pkg_name() {
	local pkg
	pkg=$($HTMLQ "li.dt-version-item" --attribute data-dt-package-name <<<"$__APKPURE_RESP__" | head -n 1)
	if [ -n "$pkg" ]; then
		echo "$pkg"
	else
		echo "${__APKPURE_URL__##*/}"
	fi
}
get_apkpure_vers() {
	local vers
	vers=$($HTMLQ "li.dt-version-item" --attribute data-dt-version <<<"$__APKPURE_RESP__" | awk '{$1=$1}1')
	if [ "$__AAV__" = false ]; then
		echo "$vers" | grep -iv "\(beta\|alpha\)" || :
	else
		echo "$vers"
	fi
}
# Fast direct 1-hop signed download via d.apkpure.com CDN (from helper-for-morphe)
_dl_apkpure_direct() {
	local pkg=$1 version=${2// /-} output=$3
	local target_ver="${version:-latest}"
	if [ "$target_ver" = "auto" ]; then target_ver="latest"; fi

	# `version=latest` only works while a patch tracks APKPure's newest release.
	# For a pinned version, ask for the version code when the last version
	# component looks like one (e.g. 1.20.86.0.1002565 -> 1002565); APKPure
	# accepts that and still serves the original, signed single APK.
	local -a queries=("version=latest")
	local last_segment="${target_ver##*.}"
	if [[ "$last_segment" =~ ^[0-9]+$ ]]; then
		queries+=("versionCode=${last_segment}")
	fi

	for kind in "APK" "XAPK"; do
		for query in "${queries[@]}"; do
			local direct_url="https://d.apkpure.com/b/${kind}/${pkg}?${query}"
			local loc
			# Read only the first redirect. Following it lands on a CDN host that
			# varies by region (data.winudf.com, a signed object URL, ...), while
			# the first Location already points at the file.
			loc=$(curl -sI -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" --max-time 20 "$direct_url" | grep -i "^location:" | head -n 1 | awk '{print $2}' | tr -d '\r') || loc=""
			if [ -z "$loc" ] || [[ "$loc" != *"filename="* ]]; then
				continue
			fi

			local fname=""
			if [[ "$loc" =~ filename=([^&]+) ]]; then
				fname="${BASH_REMATCH[1]}"
			fi
			local ver_hyphen="${target_ver//./-}"
			local ver_underscore="${target_ver//./_}"
			if [ "$target_ver" != "latest" ] &&
				[[ "$fname" != *"$target_ver"* ]] &&
				[[ "$loc" != *"$target_ver"* ]] &&
				[[ "$loc" != *"$ver_hyphen"* ]] &&
				[[ "$loc" != *"$ver_underscore"* ]]; then
				continue
			fi

			pr "Found direct APKPure CDN download for '${pkg}' (${target_ver})"
			if [ "$kind" = "XAPK" ]; then
				_req "$loc" "${output}.apkm" || return 1
				merge_splits "${output}.apkm" "${output}"
			else
				_req "$loc" "${output}" || return 1
			fi
			return 0
		done
	done
	return 1
}

dl_apkpure() {
	local url=$1 version=$2 output=$3 arch=$4 _dpi=$5
	local clean_pkg="${url%/}"
	clean_pkg="${clean_pkg##*/}"

	if _dl_apkpure_direct "$clean_pkg" "$version" "$output"; then
		return 0
	fi

	url="${url%/}"
	url="${url%/versions}"
	url="${url%/download}"
	url="${url%/}"

	local is_bundle=false
	local version_node
	version_node=$($HTMLQ "li.dt-version-item[data-dt-version='${version}']" <<<"$__APKPURE_RESP__")
	if [ "$version_node" ]; then
		local file_type
		file_type=$($HTMLQ "span.apk-type-tag" --attribute data-tag <<<"$version_node")
		if [ "${file_type,,}" = "xapk" ]; then
			is_bundle=true
		fi
	fi

	local dl_page_resp
	dl_page_resp=$(req "${url}/download/${version}" -) || return 1

	local dl_url
	dl_url=$($HTMLQ "a#download_link" --attribute href <<<"$dl_page_resp" | head -n 1) || return 1
	if [ -z "$dl_url" ]; then
		dl_url=$($HTMLQ "a" --attribute href <<<"$dl_page_resp" | grep -m1 -E "d\.apkpure\.net/b/(APK|XAPK)/") || return 1
	fi

	if [ -z "$dl_url" ]; then
		epr "ERROR: Could not find direct download link on APKPure download page"
		return 1
	fi

	if [[ "$dl_url" == //* ]]; then
		dl_url="https:${dl_url}"
	fi

	if [ "$is_bundle" = true ]; then
		req "$dl_url" "${output}.apkm" || return 1
		merge_splits "${output}.apkm" "${output}"
	else
		req "$dl_url" "${output}" || return 1
	fi
}

# -------------------- archive --------------------
dl_archive() {
	local url=$1 version=$2 output=$3 arch=$4
	local path output_m version=${version// /}

	if [ -f "${output}.apkm" ]; then
		merge_splits "${output}.apkm" "$output"
		return 0
	fi

	path=$(grep -m1 "${version_f#v}-${arch// /}" <<<"$__ARCHIVE_RESP__") || return 1
	if [ "${path##*.}" = "apkm" ]; then
		output_m="${output}.apkm"
	else
		output_m=$output
	fi
	req "${url}/${path}" "$output_m" || return 1
	if [ "${path##*.}" = "apkm" ]; then
		merge_splits "$output_m" "$output"
	fi
}
get_archive_resp() {
	local r
	r=$(req "$1" -)
	if [ -z "$r" ]; then return 1; else __ARCHIVE_RESP__=$(sed -n 's;^<a href="\(.*\)"[^"]*;\1;p' <<<"$r"); fi
	__ARCHIVE_PKG_NAME__=$(awk -F/ '{print $NF}' <<<"$1")
}
get_archive_vers() { sed 's/^[^-]*-//;s/-\(all\|arm64-v8a\|arm-v7a\)\.apk//g' <<<"$__ARCHIVE_RESP__"; }
get_archive_pkg_name() { echo "$__ARCHIVE_PKG_NAME__"; }

# -------------------- direct --------------------
dl_direct() {
	local url=$1 version=${2// /-} output=$3 arch=$4 _dpi=$5
	req "$url" "${output}" || return 1
}
get_direct_vers() { cut -d- -f2 <<<"$__DIRECT_APKNAME__"; }
get_direct_pkg_name() { cut -d- -f1 <<<"$__DIRECT_APKNAME__"; }
get_direct_resp() { __DIRECT_APKNAME__=$(awk -F/ '{print $NF}' <<<"$1"); }

# -------------------- apkeep --------------------
dl_apkeep() {
	local pkg=$1 version=$2 output=$3 arch=$4 _dpi=$5
	if [ -f "$output" ]; then return 0; fi
	_with_lock "apkeep.$(_lock_key "$output")" _dl_apkeep_locked "$pkg" "$version" "$output" "$arch" "$_dpi"
}

_dl_apkeep_locked() {
	local pkg=$1 version=${2// /-} output=$3 arch=$4 _dpi=$5

	# another job may have downloaded it while we waited for the lock
	if [ -f "$output" ]; then return 0; fi

	# Fast 1-hop signed direct CDN download before running apkeep
	if _dl_apkpure_direct "$pkg" "$version" "$output"; then
		return 0
	fi
	pr "Direct APKPure APK unavailable for '$pkg' ($version); falling back to apkeep"

	if ! command -v apkeep >/dev/null 2>&1; then
		epr "apkeep is not installed or not in PATH. Are you in the nix shell?"
		return 1
	fi
	local apkeep_bin="apkeep"

	local target_ver=""
	if [ "$version" ] && [ "$version" != "latest" ]; then
		target_ver="@${version}"
	fi

	local out_dir="${TEMP_DIR}/${pkg}_apkeep_$$_${RANDOM}"
	rm -rf "$out_dir"
	mkdir -p "$out_dir"
	
	pr "Running apkeep for $pkg..."

	# APKPure only. Google Play is deliberately not used here: apkeep's
	# google-play source cannot be relied on for this builder. Anonymous
	# requests are rejected outright on apkeep >= 1.0.0, and authenticated
	# ones (APK_KEEP_EMAIL/APK_KEEP_TOKEN) exit 0 while silently downloading
	# nothing. Since every patch here is pinned to a specific version, a
	# source that quietly returns the wrong build is worse than no source.
	#
	# -o acknowledge_dangers=true is required by apkeep >= 1.1.0, which refuses
	# to use APKPure without an explicit acknowledgement. See
	# https://github.com/EFForg/apkeep/blob/master/USAGE-apkpure.md
	#
	# Note apkeep exits 0 even when the version is unavailable, so success is
	# judged by whether any file landed, not by the exit code.
	local -a src_args=(-d apk-pure -o acknowledge_dangers=true)

	local max_retries=3
	local retry_count=0
	local success=false
	while [ $retry_count -lt $max_retries ]; do
		if "$apkeep_bin" -a "${pkg}${target_ver}" "${src_args[@]}" "$out_dir" &&
			[ -n "$(ls -A "$out_dir" 2>/dev/null)" ]; then
			success=true
			break
		fi
		wpr "apkeep did not return $pkg${target_ver}, retrying in 20 seconds... ($((retry_count + 1))/$max_retries)"
		sleep 20
		retry_count=$((retry_count + 1))
	done
	if [ "$success" = false ]; then
		epr "apkeep failed to download $pkg after $max_retries attempts"
		rm -rf "$out_dir"
		return 1
	fi
	
	local apk_file xapk_file downloaded_dir
	apk_file=$(find "$out_dir" -maxdepth 1 -name "*.apk" | head -n 1)
	xapk_file=$(find "$out_dir" -maxdepth 1 -name "*.xapk" | head -n 1)
	downloaded_dir=$(find "$out_dir" -maxdepth 1 -mindepth 1 -type d | head -n 1)
	
	if [ -n "$apk_file" ]; then
		mv -f "$apk_file" "$output"
	elif [ -n "$xapk_file" ]; then
		mv -f "$xapk_file" "${output}.apkm"
		merge_splits "${output}.apkm" "${output}"
		rm -f "${output}.apkm"
	elif [ -n "$downloaded_dir" ]; then
		if ! (
			cd "$downloaded_dir" || exit 1
			zip -0rq "${CWD}/${output}.apkm" . || exit 1
		); then
			rm -rf "$out_dir"
			return 1
		fi
		merge_splits "${output}.apkm" "${output}"
		rm -f "${output}.apkm"
	else
		epr "Could not find downloaded files in $out_dir"
		rm -rf "$out_dir"
		return 1
	fi
	rm -rf "$out_dir"
}
get_apkeep_vers() { echo "latest"; }
get_apkeep_pkg_name() { echo "$__APKEEP_PKG_NAME__"; }
get_apkeep_resp() { __APKEEP_PKG_NAME__="$1"; }

# -------------------- gplaydl --------------------
dl_gplaydl() {
	local pkg=$1 version=${2// /-} output=$3 arch=$4 _dpi=$5
	
	if ! command -v gplaydl >/dev/null 2>&1; then
		if command -v pipx >/dev/null 2>&1; then
			pr "Installing gplaydl via pipx..."
			pipx install gplaydl || return 1
		elif command -v pip >/dev/null 2>&1; then
			pr "Installing gplaydl via pip..."
			pip install --break-system-packages gplaydl || pip install gplaydl || return 1
		else
			epr "gplaydl is not installed and pip/pipx is not available."
			return 1
		fi
	fi
	
	if [ -d "$HOME/.local/bin" ] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
		export PATH="$HOME/.local/bin:$PATH"
	fi
	
	local target_ver=""
	if [ -n "$version" ] && [ "$version" != "latest" ] && [ "$version" != "auto" ]; then
		if [[ "$version" =~ ^[0-9]+$ ]]; then
			target_ver="-v $version"
		else
			wpr "gplaydl requires an integer versionCode (e.g. '12345'), but got versionName '$version'. Downloading latest instead."
		fi
	fi
	
	local target_arch=""
	if [[ "$arch" == "armeabi-v7a" ]]; then
		target_arch="-a armv7"
	elif [[ "$arch" == "arm64-v8a" ]]; then
		target_arch="-a arm64"
	fi
	
	local out_dir="${TEMP_DIR}/${pkg}_gplaydl_$$_${RANDOM}"
	rm -rf "$out_dir"
	mkdir -p "$out_dir"
	
	pr "Running gplaydl for $pkg..."
	if ! gplaydl download "$pkg" $target_ver $target_arch --no-splits --no-extras -o "$out_dir"; then
		epr "gplaydl failed to download $pkg"
		rm -rf "$out_dir"
		return 1
	fi
	
	local apk_file
	apk_file=$(find "$out_dir" -maxdepth 1 -name "*.apk" | head -n 1)
	if [ -n "$apk_file" ]; then
		mv -f "$apk_file" "$output"
		rm -rf "$out_dir"
		return 0
	else
		epr "gplaydl did not output an APK for $pkg"
		rm -rf "$out_dir"
		return 1
	fi
}
get_gplaydl_vers() { echo "latest"; }
get_gplaydl_pkg_name() { echo "$__GPLAYDL_PKG_NAME__"; }
get_gplaydl_resp() { __GPLAYDL_PKG_NAME__="$1"; }
# -------------------- morphe --------------------
get_morphe_resp() {
	local val="${1%/}"
	val="${val##*/}"
	__MORPHE_PKG_NAME__="$val"
}

get_morphe_pkg_name() {
	echo "$__MORPHE_PKG_NAME__"
}

get_morphe_vers() {
	local loc raw_ver
	loc=$(curl -sIL -A "Morphe-Manager/1.0" --max-redirs 5 "https://api.morphe.software/v2/web-search/${__MORPHE_PKG_NAME__}~any~arm64-v8a" | grep -i "^location:" | tail -n 1 | awk '{print $2}' | tr -d '\r')
	if [[ "$loc" =~ /([^/]+)-([0-9]+-[0-9]+-[0-9]+[0-9a-zA-Z_-]*)-release/ ]]; then
		raw_ver="${BASH_REMATCH[2]}"
		echo "${raw_ver//-/.}"
	else
		echo "latest"
	fi
}

dl_morphe() {
	local pkg=$1 version=${2// /-} output=$3 arch=$4 dpi=$5 get_latest_ver=$6
	local clean_pkg="${pkg%/}"
	clean_pkg="${clean_pkg##*/}"

	local abi="arm64-v8a"
	if [ "$arch" = "arm-v7a" ] || [ "$arch" = "armeabi-v7a" ]; then
		abi="armeabi-v7a"
	elif [ "$arch" = "x86_64" ]; then
		abi="x86_64"
	elif [ "$arch" = "x86" ]; then
		abi="x86"
	elif [ "$arch" = "all" ] || [ "$arch" = "both" ]; then
		abi="arm64-v8a"
	fi

	local req_ver="${version:-any}"
	if [ "$get_latest_ver" = "true" ] || [ "$version" = "latest" ] || [ "$version" = "auto" ]; then
		req_ver="any"
	fi

	local query="${clean_pkg}~${req_ver}~${abi}"
	pr "Querying Morphe resolver for '${query}'"
	local resolved_url
	resolved_url=$(curl -sIL -A "Morphe-Manager/1.0" --max-redirs 5 "https://api.morphe.software/v2/web-search/${query}" | grep -i "^location:" | tail -n 1 | awk '{print $2}' | tr -d '\r')

	if [ -z "$resolved_url" ] || [[ "$resolved_url" == *google.com/search* ]] || [[ "$resolved_url" == *api.morphe.software* ]] || [[ "$resolved_url" == *fallback* ]]; then
		# If specific version failed, check if latest ("any") matches the requested version (e.g. 351.11 matching 351-11-stable)
		if [ "$req_ver" != "any" ]; then
			local query_any="${clean_pkg}~any~${abi}"
			local resolved_any
			resolved_any=$(curl -sIL -A "Morphe-Manager/1.0" --max-redirs 5 "https://api.morphe.software/v2/web-search/${query_any}" | grep -i "^location:" | tail -n 1 | awk '{print $2}' | tr -d '\r')
			if [ -n "$resolved_any" ] && [[ "$resolved_any" != *google.com/search* ]] && [[ "$resolved_any" != *api.morphe.software* ]] && [[ "$resolved_any" != *fallback* ]]; then
				local ver_hyphen="${req_ver//./-}"
				if [[ "$resolved_any" == *"$ver_hyphen"* ]] || [[ "$resolved_any" == *"$req_ver"* ]]; then
					resolved_url="$resolved_any"
				fi
			fi
		fi
	fi

	if [ -z "$resolved_url" ] || [[ "$resolved_url" == *google.com/search* ]] || [[ "$resolved_url" == *api.morphe.software* ]] || [[ "$resolved_url" == *fallback* ]]; then
		wpr "Morphe resolver did not find a direct download target for '${clean_pkg}' (${req_ver})"
		return 1
	fi

	pr "Morphe resolved '${clean_pkg}' to: ${resolved_url}"

	if [[ "$resolved_url" == *apkmirror.com* ]]; then
		if [[ "$resolved_url" == *"-android-apk-download"* ]]; then
			local resp referer_url final_url
			resp=$(_cf_get "$resolved_url") || return 1
			referer_url=$(echo "$resp" | $HTMLQ --base https://www.apkmirror.com --attribute href "a.btn") || return 1
			final_url=$(_cf_get "$referer_url" | $HTMLQ --base https://www.apkmirror.com --attribute href "span > a[rel = nofollow]") || return 1

			local is_bundle=false
			if grep -qi "bundle" <<<"$($HTMLQ 'a.btn' --text <<<"$resp")"; then
				is_bundle=true
			fi

			local cookie_args=()
			[ -n "${CF_COOKIES:-}" ] && cookie_args=(--header "Cookie: $CF_COOKIES")
			local ua="${CF_UA:-Mozilla/5.0 (X11; Linux x86_64; rv:108.0) Gecko/20100101 Firefox/108.0}"

			if [ "$is_bundle" = true ]; then
				wget -nv -O "${output}.apkm" --header="User-Agent: $ua" --referer="$referer_url" "${cookie_args[@]}" --timeout=300 "$final_url" || return 1
				merge_splits "${output}.apkm" "${output}"
			else
				wget -nv -O "${output}" --header="User-Agent: $ua" --referer="$referer_url" "${cookie_args[@]}" --timeout=300 "$final_url" || return 1
			fi
			return 0
		else
			dl_apkmirror "$resolved_url" "$version" "$output" "$arch" "$dpi" "$get_latest_ver"
			return $?
		fi
	elif [[ "$resolved_url" == *uptodown.com* ]]; then
		if [[ "$resolved_url" =~ /android/download/([0-9]+) ]]; then
			local file_id="${BASH_REMATCH[1]}"
			local app_host="${resolved_url#*://}"
			app_host="${app_host%%/*}"
			local data_code
			data_code=$(_req "https://${app_host}/android" - | $HTMLQ "#detail-app-name" --attribute data-code) || data_code=""
			if [ -n "$data_code" ]; then
				local utd_dl
				utd_dl=$(_utd_eapi_dlurl "$data_code" "$file_id") || utd_dl=""
				if [ -n "$utd_dl" ]; then
					if _req "$utd_dl" "$output"; then
						return 0
					fi
				fi
			fi
		fi
		local base_utd="${resolved_url%/download/*}"
		base_utd="${base_utd%/android/*}/android"
		dl_uptodown "$base_utd" "$version" "$output" "$arch" "$dpi"
		return $?
	else
		wpr "Unsupported destination host from Morphe: ${resolved_url}"
		return 1
	fi
}
# -------------------- aptoide --------------------
get_aptoide_resp() {
	local val="${1%/}"
	val="${val##*/}"
	__APTOIDE_PKG_NAME__="$val"
	__APTOIDE_RESP__=$(curl -s "https://ws75.aptoide.com/api/7/listAppVersions?package_name=${val}&limit=100") || return 1
	local status
	status=$(jq -r '.info.status // empty' <<<"$__APTOIDE_RESP__" 2>/dev/null)
	if [ "$status" != "OK" ]; then
		__APTOIDE_RESP__=$(curl -s -X POST "https://ws75.aptoide.com/api/7/listSearchApps" -H "Content-Type: application/json" -d "{\"query\":\"${val}\",\"limit\":20}") || return 1
		status=$(jq -r '.info.status // empty' <<<"$__APTOIDE_RESP__" 2>/dev/null)
		[ "$status" = "OK" ] || return 1
	fi
}

get_aptoide_pkg_name() {
	echo "$__APTOIDE_PKG_NAME__"
}

get_aptoide_vers() {
	local vers
	vers=$(jq -r '(.list[]?.file.vername // .datalist?.list[]?.file.vername // empty)' <<<"$__APTOIDE_RESP__" 2>/dev/null | awk '{$1=$1}1' | grep -v "^$" || :)
	if [ "$__AAV__" = false ]; then
		echo "$vers" | grep -iv "\(beta\|alpha\)" || :
	else
		echo "$vers"
	fi
}

dl_aptoide() {
	local pkg=$1 version=${2// /-} output=$3 arch=$4 dpi=$5 get_latest_ver=$6
	local clean_pkg="${pkg%/}"
	clean_pkg="${clean_pkg##*/}"

	local app_id="" dl_url=""
	if [ "$get_latest_ver" = "true" ] || [ "$version" = "latest" ] || [ "$version" = "auto" ]; then
		local latest_meta
		latest_meta=$(curl -s "https://ws75.aptoide.com/api/7/getApp?package_name=${clean_pkg}")
		dl_url=$(jq -r '.nodes.meta.data.file.path // .nodes.meta.data.file.path_alt // empty' <<<"$latest_meta" 2>/dev/null)
	else
		if [ -z "${__APTOIDE_RESP__:-}" ]; then
			__APTOIDE_RESP__=$(curl -s "https://ws75.aptoide.com/api/7/listAppVersions?package_name=${clean_pkg}&limit=100") || true
		fi

		local clean_ver="${version#v}"
		clean_ver="${clean_ver// /}"
		app_id=$(jq -r --arg ver "$clean_ver" '
			(.list[]?, .datalist?.list[]?) |
			select((.file.vername // "") == $ver or (.file.vername // "" | split(" ")[0]) == $ver or (.file.vername // "" | sub("^v";"")) == $ver) |
			.id
		' <<<"$__APTOIDE_RESP__" 2>/dev/null | head -n 1)

		if [ -z "$app_id" ]; then
			local search_resp
			search_resp=$(curl -s -X POST "https://ws75.aptoide.com/api/7/listSearchApps" -H "Content-Type: application/json" -d "{\"query\":\"${clean_pkg} ${clean_ver}\",\"limit\":15}")
			app_id=$(jq -r --arg pkg "$clean_pkg" --arg ver "$clean_ver" '
				.datalist.list[]? |
				select(.package == $pkg and ((.file.vername // "") == $ver or (.file.vername // "" | split(" ")[0]) == $ver or (.file.vername // "" | sub("^v";"")) == $ver)) |
				.id
			' <<<"$search_resp" 2>/dev/null | head -n 1)
		fi

		if [ -n "$app_id" ]; then
			local app_meta
			app_meta=$(curl -s "https://ws75.aptoide.com/api/7/getApp?app_id=${app_id}")
			dl_url=$(jq -r '.nodes.meta.data.file.path // .nodes.meta.data.file.path_alt // empty' <<<"$app_meta" 2>/dev/null)
		fi
	fi

	if [ -z "$dl_url" ]; then
		epr "Could not resolve Aptoide download URL for '${clean_pkg}' (${version})"
		return 1
	fi

	pr "Downloading '${clean_pkg}' (${version}) from Aptoide: ${dl_url}"
	if grep -qiE "\.(xapk|apkm)" <<<"$dl_url"; then
		_req "$dl_url" "${output}.apkm" || return 1
		merge_splits "${output}.apkm" "${output}"
	else
		_req "$dl_url" "$output" || return 1
	fi
}
# --------------------------------------------------

patch_apk() {
	local stock_input=$1 patched_apk=$2 patcher_args=$3 cli_jar=$4 patches_jar=$5
	local tmp_files
	tmp_files="$(pwd)/$(mktemp -d -p "$TEMP_DIR")"

	local cmd="java -jar '$cli_jar' patch '$stock_input' -o '$patched_apk' -p '$patches_jar' --keystore=ks.keystore \
--keystore-entry-password=123456789 --keystore-password=123456789 --signer=jhc --keystore-entry-alias=jhc -t '$tmp_files' $patcher_args"

	# TODO: remove this later
	local cli_name
	cli_name=$(basename "$cli_jar")
	if [ "${cli_name::8}" = revanced ]; then cmd+=" -b"; fi

	if [ "$OS" = Android ]; then cmd+=" --custom-aapt2-binary='${AAPT2}'"; fi
	pr "$cmd"
	if eval "$cmd"; then [ -f "$patched_apk" ]; else
		rm "$patched_apk" 2>/dev/null || :
		return 1
	fi
}

check_sig() {
	local file=$1 pkg_name=$2
	local sig
	if grep -q "$pkg_name" sig.txt; then
		sig=$(java -jar "$APKSIGNER" verify --print-certs "$file" | grep ^Signer | grep SHA-256 | tail -1 | awk '{print $NF}')
		echo "$pkg_name signature: ${sig}"
		grep -qFx "$sig $pkg_name" sig.txt
	fi
}

build_rv() {
	if [ "${GITHUB_ACTIONS:-false}" = "true" ]; then
		sleep $((RANDOM % 15))
	fi
	eval "declare -A args=${1#*=}"
	local version="" pkg_name=""
	local mode_arg=${args[build_mode]} version_mode=${args[version]}
	local app_name=${args[app_name]}
	local app_name_l=${app_name,,}
	app_name_l=${app_name_l// /-}
	local table=${args[table]}
	local dl_from=${args[dl_from]}
	local arch=${args[arch]}
	local arch_f="${arch// /}"

	local p_patcher_args=()
	if [ "${args[excluded_patches]}" ]; then p_patcher_args+=("$(join_args "${args[excluded_patches]}" -d)"); fi
	if [ "${args[included_patches]}" ]; then p_patcher_args+=("$(join_args "${args[included_patches]}" -e)"); fi
	[ "${args[exclusive_patches]}" = true ] && p_patcher_args+=("--exclusive")

	local tried_dl=()
	if [ "${args[pkg_name]}" ]; then
		pkg_name="${args[pkg_name]}"
	else
		for dl_p in "${DL_SRCS[@]}"; do
			if [ -z "${args[${dl_p}_dlurl]}" ]; then continue; fi
			if ! get_${dl_p}_resp "${args[${dl_p}_dlurl]}" || ! pkg_name=$(get_"${dl_p}"_pkg_name); then
				args[${dl_p}_dlurl]=""
				epr "ERROR: Could not find ${table} in ${dl_p}"
				continue
			fi
			tried_dl+=("$dl_p")
			dl_from=$dl_p
			break
		done
	fi

	if [ -z "$pkg_name" ]; then
		epr "empty pkg name, not building ${table}."
		return 1
	fi
	pr "Package name of '${table}' is '$pkg_name'"
	local is_exp=false
	if isoneof "$version_mode" experiment experimental; then is_exp=true; fi
	local list_patches
	list_patches=$(patches_list "$cli_jar" "$patches_jar" "$pkg_name" "$is_exp") || return 1
	# GmsCore/MicroG support depends on the stock signing certificate. Merge a
	# split bundle for such a build and the re-signing step invalidates that
	# certificate, so use the bundle's signed base APK instead (see merge_splits).
	local microg_patch
	microg_patch=$(grep "^Name: " <<<"$list_patches" | grep -i "gmscore\|microg" || :)
	microg_patch=${microg_patch#*: }
	REQUIRE_STOCK_SIGNATURE=false
	if [ -n "$microg_patch" ] && [ "$mode_arg" != module ]; then REQUIRE_STOCK_SIGNATURE=true; fi
	local get_latest_ver=false
	if isoneof "$version_mode" auto experiment experimental; then
		if ! version=$(get_patch_last_supported_ver "$list_patches" "$pkg_name" \
			"${args[included_patches]}" "${args[excluded_patches]}" "${args[exclusive_patches]}" "$is_exp"); then
			epr "get_patch_last_supported_ver failed '$list_patches'"
			return 1
		elif [ -z "$version" ]; then get_latest_ver=true; fi
	elif isoneof "$version_mode" latest beta; then
		get_latest_ver=true
		p_patcher_args+=("-f")
	else
		version=$version_mode
		p_patcher_args+=("-f")
	fi
	if [ $get_latest_ver = true ]; then
		if isoneof "$version_mode" beta experiment experimental; then __AAV__="true"; else __AAV__="false"; fi
		pkgvers=$(get_"${dl_from}"_vers)
		version=$(get_highest_ver <<<"$pkgvers") || version=$(head -1 <<<"$pkgvers")
	fi
	if [ -z "$version" ]; then
		epr "empty version, not building ${table}."
		return 1
	fi

	if [ "$mode_arg" = module ]; then
		build_mode_arr=(module)
	elif [ "$mode_arg" = apk ]; then
		build_mode_arr=(apk)
	elif [ "$mode_arg" = both ]; then
		build_mode_arr=(apk module)
	fi

	pr "Choosing version '${version}' for ${table}"
	local version_f=${version// /}
	version_f=${version_f#v}
	local stock_apk="${TEMP_DIR}/${pkg_name}-${version_f}-${arch_f}.apk"
	# tracked by run_build_rv_bg so a failed build does not leave (and cache) the
	# stock artifact it failed on
	BUILD_STOCK_APK="$stock_apk"
	if [ ! -f "$stock_apk" ]; then
		# Only use the Morphe resolver when the config explicitly has a
		# morphe-dlurl. It can return a different packaging/signature than the
		# app's stock APK, so it must not be an implicit default.
		if [ -z "${args[aptoide_dlurl]}" ] && [ -n "$pkg_name" ]; then
			args[aptoide_dlurl]="$pkg_name"
		fi
		for dl_p in "${DL_SRCS[@]}"; do
			if [ -z "${args[${dl_p}_dlurl]}" ]; then continue; fi
			pr "Downloading '${table}' from '${dl_p}'"
			if ! isoneof $dl_p "${tried_dl[@]}"; then
				if ! get_${dl_p}_resp "${args[${dl_p}_dlurl]}"; then
					epr "ERROR: Could not get '${table}' from '${dl_p}'"
					continue
				fi
			fi
			if ! dl_${dl_p} "${args[${dl_p}_dlurl]}" "$version" "$stock_apk" "$arch" "${args[dpi]}" "$get_latest_ver"; then
				epr "ERROR: Could not download '${table}' from '${dl_p}' with version '${version}', arch '${arch}', dpi '${args[dpi]}'"
				continue
			fi
			break
		done
		if [ ! -f "$stock_apk" ]; then
			epr "Stock apk not found ($stock_apk)"
			return 1
		fi
	fi

	# Downloaders cache the payload under "<pkg>-<ver>-<arch>.apk" and a few sources
	# return split-bundle bytes for that name (APKPure's /b/APK/ endpoint does this for
	# releases that only ship an XAPK). Merge such a bundle into a real APK before
	# ApkPrep / morphe-cli touch it, otherwise morphe-cli aborts during
	# ResourcePatchContext construction with a NullPointerException on a null
	# AndroidManifestBlock. Runs on every build, so already-cached broken files heal.
	if ! normalize_stock_apk "$stock_apk"; then
		epr "Could not normalize '$stock_apk' into a single APK"
		return 1
	fi

	# Warn when the source does not actually publish the requested architecture. APKPure
	# only ships armeabi-v7a for some releases (Dead Target 4.186.0), so the "arm64-v8a"
	# build silently ends up 32-bit; ApkPrep then keeps the shipped ABI instead of
	# stripping the only native library. Better to say so than to ship a surprise.
	if ! isoneof "$arch" all universal noarch ""; then
		local have_abis want_abi
		have_abis=$(apk_abis "$stock_apk")
		want_abi=$arch
		case "$want_abi" in
			arm-v7a|armv7|armv7a) want_abi=armeabi-v7a ;;
		esac
		if [ -n "$have_abis" ] && ! grep -qw "$want_abi" <<<"$have_abis"; then
			wpr "Requested arch '$arch' is not in the stock APK (has: ${have_abis}), so the build will contain the shipped ABI(s)"
		fi
	fi

	local sig_op
	if [ -f "${stock_apk}.apkm" ]; then
		rm -rf "${stock_apk}-zip" || :
		unzip -j "${stock_apk}.apkm" -d "${stock_apk}-zip" >/dev/null
		for a in "${stock_apk}"-zip/*.apk; do
			if ! sig_op=$(check_sig "$a" "$pkg_name" 2>&1); then
				epr "Not building $table, apk signature mismatch '$a': $sig_op"
				return 1
			fi
		done
		rm -rf "${stock_apk}-zip" || :
	else
		if ! sig_op=$(check_sig "$stock_apk" "$pkg_name" 2>&1); then
			epr "Not building $table, apk signature mismatch '$stock_apk': $sig_op"
			return 1
		fi
	fi

	if [ -n "$microg_patch" ] && [[ ${p_patcher_args[*]} =~ $microg_patch ]]; then
		wpr "You cant include/exclude microg patch as that's done by rvmm builder automatically."
		p_patcher_args=("${p_patcher_args[@]//-[ei] ${microg_patch}/}")
	fi

	local patcher_args patched_apk build_mode
	local rv_brand_f=${args[rv_brand],,}
	rv_brand_f=${rv_brand_f// /-}
	if [ "${args[patcher_args]}" ]; then p_patcher_args+=("${args[patcher_args]}"); fi
	for build_mode in "${build_mode_arr[@]}"; do
		patcher_args=("${p_patcher_args[@]}")
		pr "Building '${table}' in '$build_mode' mode"
		if [ -n "$microg_patch" ]; then
			patched_apk="${TEMP_DIR}/${app_name_l}-${rv_brand_f}-${version_f}-${arch_f}-${build_mode}.apk"
		else
			patched_apk="${TEMP_DIR}/${app_name_l}-${rv_brand_f}-${version_f}-${arch_f}.apk"
		fi
		# tracked by run_build_rv_bg so a failed build leaves nothing cacheable
		BUILD_PATCHED_APK="$patched_apk"
		if [ -n "$microg_patch" ]; then
			if [ "$build_mode" = apk ]; then
				patcher_args+=("-e \"${microg_patch}\"")
			elif [ "$build_mode" = module ]; then
				patcher_args+=("-d \"${microg_patch}\"")
			fi
		fi

		local stock_apk_to_patch="${patched_apk}.stripped.apk"

		pr "Applying Disable Play Store Updates patch..."
		if [ ! -f "$TEMP_DIR/apkeditor.jar" ]; then
			gh_dl "$TEMP_DIR/apkeditor.jar" "https://github.com/REAndroid/APKEditor/releases/download/V1.4.7/APKEditor-1.4.7.jar" >/dev/null || :
		fi
		local is_module=false
		[ "$build_mode" = module ] && is_module=true
		local prep_cp="${BIN_DIR}/apkprep.jar:${args[cli]}:${TEMP_DIR}/apkeditor.jar"
		if [ -f "${BIN_DIR}/apkprep.jar" ]; then
			if ! java -cp "$prep_cp" ApkPrep "$stock_apk" "$stock_apk_to_patch" "$arch" "$is_module" >/dev/null 2>&1; then
				wpr "ApkPrep failed, falling back to stock APK"
				cp -f "$stock_apk" "$stock_apk_to_patch"
			fi
		elif [ -f "${BIN_DIR}/ApkPrep.java" ]; then
			if ! java -cp "$prep_cp" "${BIN_DIR}/ApkPrep.java" "$stock_apk" "$stock_apk_to_patch" "$arch" "$is_module" >/dev/null 2>&1; then
				wpr "ApkPrep failed, falling back to stock APK"
				cp -f "$stock_apk" "$stock_apk_to_patch"
			fi
		else
			cp -f "$stock_apk" "$stock_apk_to_patch"
		fi

		local apk_output="${BUILD_DIR}/${app_name_l}-${rv_brand_f}-v${version_f}-${arch_f}.apk"
		if [ "${NORB:-}" != true ] || { [ ! -f "$patched_apk" ] && [ ! -f "$apk_output" ]; }; then
			if ! patch_apk "$stock_apk_to_patch" "$patched_apk" "${patcher_args[*]}" "${args[cli]}" "${args[ptjar]}"; then
				epr "Building '${table}' failed!"
				return 1
			fi
		fi
		rm "$stock_apk_to_patch"
		if [ "$build_mode" = apk ]; then
			if [ "${NORB:-}" != true ] || { [ ! -f "$patched_apk" ] && [ ! -f "$apk_output" ]; }; then
				mv -f "$patched_apk" "$apk_output"
			fi
			pr "Built ${table} (non-root): '${apk_output}'"
			continue
		fi
		local base_template
		base_template=$(mktemp -d -p "$TEMP_DIR")
		cp -a $MODULE_TEMPLATE_DIR/. "$base_template"
		local upj="${table,,}-update.json"

		module_config "$base_template" "$pkg_name" "$version" "$arch"

		local patches_ver="${patches_jar##*-}"
		module_prop \
			"${args[module_prop_name]}" \
			"${app_name} ${args[rv_brand]}" \
			"${version} (patches ${patches_ver})" \
			"${app_name} ${args[rv_brand]} module" \
			"https://raw.githubusercontent.com/${GITHUB_REPOSITORY-}/update/${upj}" \
			"$base_template"

		local module_output="${app_name_l}-${rv_brand_f}-module-v${version_f}-${arch_f}.zip"
		pr "Packing module ${table}"
		cp -f "$patched_apk" "${base_template}/base.apk"

		if [ "${args[include_stock]}" != "disable" ]; then
			mkdir -p "${base_template}/stock/"
			if [ "${args[include_stock]}" = "merged" ]; then
				cp -f "$stock_apk" "${base_template}/stock/base.apk"
			elif [ "${args[include_stock]}" = "split" ]; then
				if [ ! -f "${stock_apk}.apkm" ]; then
					epr "Cannot include as 'split' because stock apk of $table_name is not a bundle"
					return 1
				fi
				if [ "$arch" = "arm64-v8a" ]; then
					unzip -j "${stock_apk}.apkm" '*.apk' -x '*x86_64.apk' -x '*x86.apk' -x '*armeabi_v7a.apk' -d "${base_template}/stock/" >/dev/null 2>&1
				elif [ "$arch" = "arm-v7a" ]; then
					unzip -j "${stock_apk}.apkm" '*.apk' -x '*x86_64.apk' -x '*x86.apk' -x '*arm64_v8a.apk' -d "${base_template}/stock/" >/dev/null 2>&1
				elif [ "$arch" = "x86" ]; then
					unzip -j "${stock_apk}.apkm" '*.apk' -x '*x86_64.apk' -x '*arm64_v8a.apk' -x '*armeabi_v7a.apk' -d "${base_template}/stock/" >/dev/null 2>&1
				elif [ "$arch" = "x86_64" ]; then
					unzip -j "${stock_apk}.apkm" '*.apk' -x '*x86.apk' -x '*arm64_v8a.apk' -x '*armeabi_v7a.apk' -d "${base_template}/stock/" >/dev/null 2>&1
				else
					unzip -j "${stock_apk}.apkm" '*.apk' -x '*x86_64.apk' -x '*x86.apk' -d "${base_template}/stock/" >/dev/null 2>&1
				fi
			fi
		fi

		pushd >/dev/null "$base_template" || abort "Module template dir not found"
		zip -"$COMPRESSION_LEVEL" -FSqr "${CWD}/${BUILD_DIR}/${module_output}" .
		popd >/dev/null || :
		pr "Built ${table} (root): '${BUILD_DIR}/${module_output}'"
	done
	# kept out of build.md until the end of the run so the changelog stays at
	# the top. config_update still reads these back out of build.md.
	echo "${table}: ${version}" >>"${TEMP_DIR}/built_apps"
}

list_args() { tr -d '\t\r' <<<"$1" | tr -s ' ' | sed 's/" "/"\n"/g' | sed 's/\([^"]\)"\([^"]\)/\1'\''\2/g' | grep -v '^$' || :; }
join_args() { list_args "$1" | sed "s/^/${2} /" | paste -sd " " - || :; }

module_config() {
	local ma=""
	if [ "$4" = "arm64-v8a" ]; then
		ma="arm64"
	elif [ "$4" = "arm-v7a" ]; then
		ma="arm"
	fi
	echo "PKG_NAME=$2
PKG_VER=$3
MODULE_ARCH=$ma" >"$1/config"
}
module_prop() {
	echo "id=${1}
name=${2}
version=v${3}
versionCode=${NEXT_VER_CODE}
author=j-hc
description=${4}" >"${6}/module.prop"

	if [ "$ENABLE_MODULE_UPDATE" = true ]; then echo "updateJson=${5}" >>"${6}/module.prop"; fi
}

run_build_rv_bg() {
	local app_args_str=$1
	local table_name=$2
	local table_name_f=${table_name// /-}
	table_name_f=${table_name_f//\//-}
	local log_file="${TEMP_DIR}/build_${table_name_f}_$$.${RANDOM}.log"

	local ret=0
	# set by build_rv once it knows which stock file the build uses
	BUILD_STOCK_APK=""
	BUILD_PATCHED_APK=""
	build_rv "$app_args_str" > "$log_file" 2>&1 || ret=$?

	local lock_dir="${TEMP_DIR}/print_lock.dir"
	while ! mkdir "$lock_dir" 2>/dev/null; do
		sleep 0.2
	done

	echo -e "\n\033[0;34m=== Logs for ${table_name} ===\033[0m"
	cat "$log_file"
	
	rm -r "$lock_dir" 2>/dev/null || :
	rm "$log_file" 2>/dev/null || :

	if [ $ret -ne 0 ]; then
		touch "$TEMP_DIR/some_job_failed"
		# Never cache the stock artifact of a failed build: a bad download (for
		# example a re-signed split merge) would otherwise poison every later run
		# from the actions/cache restore. Intermediate patched APKs go too.
		if [ -n "${BUILD_STOCK_APK:-}" ]; then
			rm -f "$BUILD_STOCK_APK" "${BUILD_STOCK_APK}.apkm" "${BUILD_STOCK_APK}.bundle" 2>/dev/null || :
		fi
		if [ -n "${BUILD_PATCHED_APK:-}" ]; then
			rm -f "$BUILD_PATCHED_APK" "${BUILD_PATCHED_APK}.stripped.apk" 2>/dev/null || :
		fi
	fi

	return $ret
}
