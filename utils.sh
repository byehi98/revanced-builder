#!/usr/bin/env bash

MODULE_TEMPLATE_DIR="module"
CWD=$(pwd)
TEMP_DIR="temp"
BIN_DIR="bin"
BUILD_DIR="build"
DL_SRCS=("direct" "archive" "apkmirror" "uptodown" "apkpure" "apkcombo" "apkeep" "gplaydl")

if [ "${GITHUB_TOKEN-}" ]; then GH_HEADER="Authorization: token ${GITHUB_TOKEN}"; else GH_HEADER=; fi
if [ "${GL_TOKEN-}" ]; then GL_HEADER="PRIVATE-TOKEN: ${GL_TOKEN}"; else GL_HEADER=; fi
NEXT_VER_CODE=${NEXT_VER_CODE:-$(date +'%Y%m%d')}
OS=$(uname -o)

toml_prep() {
	if [ ! -f "$1" ]; then return 1; fi
	if [ "${1##*.}" == toml ]; then
		__TOML__=$($TOML --output json --file "$1" .)
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
		t=$(toml_get_table "$table_name")
		enabled=$(toml_get "$t" enabled) || enabled=true
		if [ "$enabled" = "false" ]; then continue; fi
		PATCHES_SRC=$(toml_get "$t" patches-sources) || PATCHES_SRC=$(toml_get "$t" patches-source) || PATCHES_SRC=$DEF_PATCHES_SRC
		PATCHES_VER=$(toml_get "$t" patches-version) || PATCHES_VER=$DEF_PATCHES_VER
		if [[ -v sources["$PATCHES_SRC/$PATCHES_VER"] ]]; then
			if [ "${sources["$PATCHES_SRC/$PATCHES_VER"]}" = 1 ]; then upped+=("$table_name"); fi
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

_req() {
	local ip="$1" op="$2"
	shift 2
	if [ -z "$ip" ]; then
		epr "Error: empty URL passed to _req"
		return 1
	fi
	local dlp="$op"
	if [ "$op" != - ]; then
		if [ -z "$op" ]; then
			epr "Error: empty output path passed to _req"
			return 1
		fi
		if [ -f "$op" ]; then return; fi
		dlp="$(dirname "$op")/tmp.$(basename "$op")"
		if [ -f "$dlp" ]; then
			while [ -f "$dlp" ]; do sleep 1; done
			return
		fi
	fi
	if ! curl -L -c "$TEMP_DIR/cookie.txt" -b "$TEMP_DIR/cookie.txt" --connect-timeout 10 --retry 3 --fail -s -S "$@" "$ip" -o "$dlp"; then
		epr "Request failed: $ip"
		return 1
	fi
	if [ "$dlp" != - ]; then
		mv -f "$dlp" "$op"
	fi
}
_cf_get() {
	local url=$1
	local attempt
	local max_retries=3
	
	export CF_COOKIES=""
	export CF_UA=""
	
	if [ "${GITHUB_ACTIONS:-false}" = "true" ]; then
		# Try trawl on 8191
		for attempt in $(seq 1 $max_retries); do
			local response status html
			response=$(curl -s -X POST "http://localhost:8191/scrape" \
				-H 'Content-Type: application/json' \
				-d "{\"url\":\"$url\",\"maxTimeout\":60000,\"skipHttp\":true}") || true
			status=$(echo "$response" | jq -r '.statusCode // empty')
			if [[ "$status" == "200" ]]; then
				html=$(echo "$response" | jq -r '.html // empty')
				if [[ -n "$html" && "$html" != *"Attention Required!"* && "$html" != *"Just a moment..."* && "$html" != *"Please Wait... | Cloudflare"* && "$html" != *"Verify you are human"* ]]; then
					CF_COOKIES=$(echo "$response" | jq -r '[.cookies[] | .name + "=" + .value] | join("; ")')
					CF_UA=$(echo "$response" | jq -r '.userAgent // empty')
					export CF_COOKIES CF_UA
					echo "$html"
					return 0
				fi
			fi
			sleep 5
		done
		
		# Try cloudflarebypassforscraping on 8000
		for attempt in $(seq 1 $max_retries); do
			local response_file headers_file http_code
			response_file=$(mktemp)
			headers_file=$(mktemp)
			http_code=$(curl -s -o "$response_file" -w '%{http_code}' \
			    -D "$headers_file" \
				-G --data-urlencode "url=$url"\
				--max-time 30 \
				"http://localhost:8000/html") || true
			if [[ "$http_code" == "200" ]]; then
				local html
				html=$(cat "$response_file")
				if [[ -n "$html" ]]; then
					CF_COOKIES=$(grep -i '^x-cf-bypasser-cookies:' "$headers_file" 2>/dev/null | cut -d':' -f2- | xargs)
					CF_UA=$(grep -i '^x-cf-bypasser-user-agent:' "$headers_file" 2>/dev/null | cut -d':' -f2- | xargs)
					export CF_COOKIES CF_UA
					echo "$html"
					rm -f "$response_file" "$headers_file"
					return 0
				fi
			fi
			rm -f "$response_file" "$headers_file"
			sleep 5
		done
	fi

	# fallback
	req "$url" -
}

req() {
  if [ -n "${CF_COOKIES:-}" ] && [ -n "${CF_UA:-}" ]; then
    _req "$1" "$2" -H "User-Agent: $CF_UA" -H "Cookie: $CF_COOKIES"
  elif [ -n "${CF_COOKIES:-}" ]; then
    _req "$1" "$2" -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:108.0) Gecko/20100101 Firefox/108.0" -H "Cookie: $CF_COOKIES"
  elif [ -n "${CF_UA:-}" ]; then
    _req "$1" "$2" -H "User-Agent: $CF_UA"
  else
    _req "$1" "$2" -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:108.0) Gecko/20100101 Firefox/108.0"
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
	local list_patches=$1 pkg_name=$2 inc_sel=$3 _exc_sel=$4 _exclusive=$5 # TODO: resolve using all of these
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
		vers=$(awk '{$1=$1}1' <<<"$vers")
		if [ "$vers" ]; then
			get_highest_ver <<<"$vers"
			return
		fi
	fi
	op=$(patches_list_versions "$cli_jar" "$patches_jar" "$pkg_name") || return 1
	op=$(sed -n '/Most common compatible versions:/,$p' <<<"$op" | sed '1d' | awk '{$1=$1}1')
	if [ "$op" = "Any" ] || [ -z "$op" ]; then return 0; fi
	pcount=$(head -1 <<<"$op") pcount=${pcount#*(} pcount=${pcount% *}
	if [ -z "$pcount" ]; then
		epr "No patches found for '$pkg_name' in patches '$patches_jar'"
		return 1
	fi
	grep -F "($pcount patch" <<<"$op" | sed 's/ (.* patch.*//' | get_highest_ver || return 1
}

patches_list_versions() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 op cmd
	local cmd_base="java -jar '$cli_jar' list-versions"

	# TODO: remove this later
	local cli_name
	cli_name=$(basename "$cli_jar")
	if [ "${cli_name::8}" = revanced ]; then cmd_base+=" -b"; fi

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

	epr "Could not list versions $cli_jar: '$op'"
	return 1
}
patches_list() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 op
	if ! op=$(java -jar "$cli_jar" list-patches -p "$patches_jar" --filter-package-name "$pkg_name" --versions --packages -b 2>&1); then
		if ! op=$(java -jar "$cli_jar" list-patches --patches "$patches_jar" -f "$pkg_name" --with-versions --with-packages 2>&1); then
			epr "Could not get patches list $cli_jar: '$op'"
			return 1
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
	local release_path
	release_path=$(grep -m1 -o "href=\"/apk/[^\"]*-${version//./-}[a-zA-Z0-9-]*release/\"" <<<"$__APKMIRROR_RESP__")
	if [ -n "$release_path" ]; then
		release_path=${release_path#href=\"}
		release_path=${release_path%\"}
		url="https://www.apkmirror.com${release_path}"
	else
		apkmname=$($HTMLQ "h1.marginZero" --text <<<"$__APKMIRROR_RESP__")
		apkmname="${apkmname,,}"
		apkmname="${apkmname// /-}"
		apkmname="${apkmname//./-}"
		apkmname="${apkmname//[^a-z0-9-]/}"
		apkmname=$(echo "$apkmname" | tr -s '-')
		url="${url}/${apkmname}-${version//./-}-release/"
	fi
	resp=$(_cf_get "$url") || return 1
	node=$($HTMLQ "div.table-row.headerFont:nth-last-child(1)" -r "span:nth-child(n+3)" <<<"$resp")
	if [ "$node" ]; then
		for type in APK BUNDLE; do
			if dlurl=$(apkmirror_search "$resp" "$dpi" "$arch" "$type"); then
				if [ "$type" = "BUNDLE" ]; then
					is_bundle=true
				else is_bundle=false; fi
				break 2
			fi
		done
		if [ -z "$dlurl" ]; then return 1; fi
		resp=$(_cf_get "$dlurl")
	fi
	url=$(echo "$resp" | $HTMLQ --base https://www.apkmirror.com --attribute href "a.btn") || return 1
	url=$(_cf_get "$url" | $HTMLQ --base https://www.apkmirror.com --attribute href "span > a[rel = nofollow]") || return 1

	if [ "$is_bundle" = true ]; then
		req "$url" "${output}.apkm" || return 1
		merge_splits "${output}.apkm" "${output}"
	else
		req "$url" "${output}" || return 1
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
	__APKMIRROR_RESP__=$(_cf_get "${url}") || return 1
	__APKMIRROR_CAT__="${url##*/}"
}

# -------------------- uptodown --------------------
get_uptodown_resp() {
	__UPTODOWN_RESP__=$(_cf_get "${1}/versions") || return 1
	__UPTODOWN_RESP_PKG__=$(_cf_get "${1}/download") || return 1
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
	local versionURL=""
	local is_bundle=false
	local UA="User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
	for i in {1..20}; do
		resp=$(_cf_get "${uptodown_dlurl}/apps/${data_code}/versions/${i}")
		if ! op=$(jq -e -r ".data | map(select(.version == \"${version}\")) | .[0]" <<<"$resp"); then
			continue
		fi
		if [ "$(jq -e -r ".kindFile" <<<"$op")" = "xapk" ]; then is_bundle=true; fi
		if versionURL=$(jq -e -r '.versionURL' <<<"$op"); then break; else return 1; fi
	done
	if [ -z "$versionURL" ]; then return 1; fi
	versionURL=$(jq -e -r '.url + "/" + .extraURL + "/" + (.versionID | tostring)' <<<"$versionURL")
	resp=$(_cf_get "$versionURL") || return 1

	local data_version files node_arch="" data_file_id node_class
	data_version=$($HTMLQ '.button.variants' --attribute data-version <<<"$resp") || return 1
	if [ "$data_version" ]; then
		files=$(_cf_get "${uptodown_dlurl%/*}/app/${data_code}/version/${data_version}/files" | jq -e -r .content) || return 1
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
			resp=$(_cf_get "${uptodown_dlurl}/download/${data_file_id}-x")
			break
		done
		if [ $n -eq 12 ]; then return 1; fi
	fi
	local data_url
	data_url=$($HTMLQ "#detail-download-button" --attribute data-url <<<"$resp") || return 1
	if [ $is_bundle = true ]; then
		req "https://dw.uptodown.com/dwn/${data_url}" "$output.apkm" || return 1
		merge_splits "${output}.apkm" "${output}"
	else
		req "https://dw.uptodown.com/dwn/${data_url}" "$output"
	fi
}
get_uptodown_pkg_name() { $HTMLQ --text "tr.full:nth-child(1) > td:nth-child(3)" <<<"$__UPTODOWN_RESP_PKG__"; }

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
	local tr_dl_url="https://translate.google.com/website?sl=auto&tl=en&hl=en&client=webapp&u=https://apkcombo.com${dl_page_path}"
	dl_page_resp=$(_req "$tr_dl_url" - -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)") || return 1
	
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
	
	_req "$dl_url" "$output" -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
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
dl_apkpure() {
	local url=$1 version=$2 output=$3 arch=$4 _dpi=$5
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
	local pkg=$1 version=${2// /-} output=$3 arch=$4 _dpi=$5
	local email="${APK_KEEP_EMAIL:-}"
	local token="${APK_KEEP_TOKEN:-}"

	if [ -f "$output" ]; then return 0; fi
	local lock_file="${output}.lock"
	if [ -f "$lock_file" ]; then
		while [ -f "$lock_file" ]; do sleep 1; done
		if [ -f "$output" ]; then return 0; fi
	fi
	touch "$lock_file"

	if ! command -v apkeep >/dev/null 2>&1; then
		epr "apkeep is not installed or not in PATH. Are you in the nix shell?"
		rm -f "$lock_file"
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
	if [ -z "$email" ] || [ -z "$token" ]; then
		wpr "Note: building without credentials"
		if ! "$apkeep_bin" -a "${pkg}${target_ver}" "$out_dir"; then
			epr "apkeep failed to download $pkg"
			rm -rf "$out_dir" "$lock_file"
			return 1
		fi
	else
		if ! "$apkeep_bin" -a "${pkg}${target_ver}" -d google-play -e "$email" -t "$token" -o split_apk=true "$out_dir"; then
			epr "apkeep failed to download $pkg"
			rm -rf "$out_dir" "$lock_file"
			return 1
		fi
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
			rm -rf "$out_dir" "$lock_file"
			return 1
		fi
		merge_splits "${output}.apkm" "${output}"
		rm -f "${output}.apkm"
	else
		epr "Could not find downloaded files in $out_dir"
		rm -rf "$out_dir" "$lock_file"
		return 1
	fi
	rm -rf "$out_dir" "$lock_file"
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
	local list_patches
	list_patches=$(patches_list "$cli_jar" "$patches_jar" "$pkg_name") || return 1
	local get_latest_ver=false
	if [ "$version_mode" = auto ]; then
		if ! version=$(get_patch_last_supported_ver "$list_patches" "$pkg_name" \
			"${args[included_patches]}" "${args[excluded_patches]}" "${args[exclusive_patches]}"); then
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
		if [ "$version_mode" = beta ]; then __AAV__="true"; else __AAV__="false"; fi
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
	if [ ! -f "$stock_apk" ]; then
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
	log "${table}: ${version}"

	local microg_patch
	microg_patch=$(grep "^Name: " <<<"$list_patches" | grep -i "gmscore\|microg" || :) microg_patch=${microg_patch#*: }
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
		if [ -n "$microg_patch" ]; then
			if [ "$build_mode" = apk ]; then
				patcher_args+=("-e \"${microg_patch}\"")
			elif [ "$build_mode" = module ]; then
				patcher_args+=("-d \"${microg_patch}\"")
			fi
		fi

		local stock_apk_to_patch="${patched_apk}.stripped.apk"
		cp -f "$stock_apk" "$stock_apk_to_patch"

		pr "Applying Disable Play Store Updates patch..."
		if [ ! -f "$TEMP_DIR/apkeditor.jar" ]; then
			gh_dl "$TEMP_DIR/apkeditor.jar" "https://github.com/REAndroid/APKEditor/releases/download/V1.4.7/APKEditor-1.4.7.jar" >/dev/null || :
		fi
		local manifest_tmp="${stock_apk_to_patch}-manifest-tmp"
		local apk_decoded="${manifest_tmp}-decoded"
		cp "$stock_apk_to_patch" "$manifest_tmp"
		zip -q -d "$manifest_tmp" "res/*" "assets/*" "META-INF/*" "classes*.dex" "lib/*" "resources.arsc" 2>/dev/null || :
		if java -jar "$TEMP_DIR/apkeditor.jar" d -i "$manifest_tmp" -o "$apk_decoded" -f -t xml >/dev/null 2>&1; then
			if [ -f "$apk_decoded/AndroidManifest.xml" ]; then
				sed -i -E 's/android:versionCode="[0-9]+"/android:versionCode="2147483647"/g' "$apk_decoded/AndroidManifest.xml"
				if java -jar "$TEMP_DIR/apkeditor.jar" b -i "$apk_decoded" -o "${manifest_tmp}-new.apk" -f >/dev/null 2>&1; then
					local extracted_manifest="${manifest_tmp}-extracted"
					unzip -q "${manifest_tmp}-new.apk" AndroidManifest.xml -d "$extracted_manifest" 2>/dev/null || :
					if [ -f "$extracted_manifest/AndroidManifest.xml" ]; then
						(cd "$extracted_manifest" && zip -q "${CWD}/${stock_apk_to_patch}" AndroidManifest.xml) >/dev/null 2>&1 || :
					fi
					rm -rf "$extracted_manifest"
				fi
			fi
		fi
		rm -rf "$apk_decoded" "${manifest_tmp}" "${manifest_tmp}-new.apk"
		if [ "$build_mode" = module ]; then
			zip -d "$stock_apk_to_patch" "lib/*" >/dev/null 2>&1 || :
		else
			if [ "$arch" = "arm64-v8a" ]; then
				zip -d "$stock_apk_to_patch" "lib/armeabi-v7a/*" "lib/x86_64/*" "lib/x86/*" >/dev/null 2>&1 || :
			elif [ "$arch" = "arm-v7a" ]; then
				zip -d "$stock_apk_to_patch" "lib/arm64-v8a/*" "lib/x86_64/*" "lib/x86/*" >/dev/null 2>&1 || :
			elif [ "$arch" = "x86" ]; then
				zip -d "$stock_apk_to_patch" "lib/arm64-v8a/*" "lib/x86_64/*" "lib/armeabi-v7a/*" >/dev/null 2>&1 || :
			elif [ "$arch" = "x86_64" ]; then
				zip -d "$stock_apk_to_patch" "lib/arm64-v8a/*" "lib/armeabi-v7a/*" "lib/x86/*" >/dev/null 2>&1 || :
			else
				zip -d "$stock_apk_to_patch" "lib/x86_64/*" "lib/x86/*" >/dev/null 2>&1 || :
			fi
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
	fi

	return $ret
}
