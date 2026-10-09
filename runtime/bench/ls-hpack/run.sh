#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
source_dir="$repo_root/runtime/deps/ls-hpack"
work_dir="${TMPDIR:-/tmp}/collo-ls-hpack-bench"
patch_dir="$repo_root/runtime/patches/ls-hpack"

if [[ ! -f "$source_dir/lshpack.c" ]]; then
    echo "missing ls-hpack source: $source_dir/lshpack.c" >&2
    exit 1
fi

if [[ -z "${CC:-}" ]]; then
    if command -v clang >/dev/null 2>&1; then
        CC=clang
    else
        CC=cc
    fi
fi

rm -rf "$work_dir"
mkdir -p "$work_dir"
cp -R "$source_dir" "$work_dir/original_copy"
cp -R "$source_dir" "$work_dir/patched_copy"

perl -pi -e 's/\r$//' \
    "$work_dir/patched_copy/CMakeLists.txt" \
    "$work_dir/patched_copy/lshpack.h" \
    "$work_dir/patched_copy/lshpack.c" \
    "$work_dir/patched_copy/bin/CMakeLists.txt" \
    "$work_dir/patched_copy/bin/encode-qif.c" \
    "$work_dir/patched_copy/test/test_hpack.c"
patch_files=("$patch_dir"/*.patch)
if [[ ! -f "${patch_files[0]}" ]]; then
    echo "missing ls-hpack patch series in $patch_dir" >&2
    exit 1
fi
for patch_file in "${patch_files[@]}"; do
    patch --no-backup-if-mismatch -l -d "$work_dir/patched_copy" \
        -p1 -i "$patch_file" >/dev/null
done

build_variant() {
    local variant="$1"
    local variant_dir="$work_dir/${variant}_copy"
    "$CC" \
        -O3 \
        -DNDEBUG \
        -std=c99 \
        -DLS_HPACK_USE_LARGE_TABLES=1 \
        -DLSHPACK_DEC_HTTP1X_OUTPUT=0 \
        -DLSHPACK_DEC_CALC_HASH=0 \
        '-DXXH_HEADER_NAME="xxhash.h"' \
        -I"$variant_dir" \
        -I"$variant_dir/deps/xxhash" \
        "$script_dir/bench.c" \
        "$variant_dir/lshpack.c" \
        "$variant_dir/deps/xxhash/xxhash.c" \
        -o "$variant_dir/bench"
    "$CC" \
        -O3 \
        -DNDEBUG \
        -std=c99 \
        -DLS_HPACK_USE_LARGE_TABLES=1 \
        -DLSHPACK_DEC_HTTP1X_OUTPUT=0 \
        -DLSHPACK_DEC_CALC_HASH=0 \
        '-DXXH_HEADER_NAME="xxhash.h"' \
        -I"$variant_dir" \
        -I"$variant_dir/deps/xxhash" \
        "$variant_dir/bin/encode-qif.c" \
        "$variant_dir/lshpack.c" \
        "$variant_dir/deps/xxhash/xxhash.c" \
        -o "$variant_dir/encode-qif"
}

build_variant original
build_variant patched

qif_file="$work_dir/sample.qif"
cat >"$qif_file" <<'QIF'
:method	GET
:scheme	https
:authority	demo.example.test
:path	/alpha
accept-encoding	gzip, deflate
content-type	text/plain
authorization	Bearer abc
set-cookie	sid=abc; HttpOnly

:method	POST
:scheme	https
:authority	demo.example.test
:path	/upload
content-length	128
content-type	application/json
cookie	a=1; b=2
cache-control	no-store

:method	GET
:scheme	https
:authority	demo.example.test
:path	/repeat
authorization	Bearer abc
set-cookie	sid=abc; HttpOnly
cookie	a=1; b=2
x-custom-repeat	value

QIF

qif_headers_per_iter="$(awk -F'\t' 'NF >= 2 { count++ } END { print count }' "$qif_file")"

encode_qif_to_file() {
    local variant="$1"
    local policy="$2"
    local iters="$3"
    local output="$4"
    local variant_dir="$work_dir/${variant}_copy"
    if [[ "$variant" == "patched" && "$policy" != "default" ]]; then
        "$variant_dir/encode-qif" -i "$qif_file" -n "$iters" -s "$policy" >"$output"
    else
        "$variant_dir/encode-qif" -i "$qif_file" -n "$iters" >"$output"
    fi
}

validate_encode_qif_policies() {
    local none_out="$work_dir/policy-none.hpack"
    local auth_out="$work_dir/policy-auth.hpack"
    local default_out="$work_dir/policy-default.hpack"
    local auth_set_cookie_out="$work_dir/policy-auth-and-set-cookie.hpack"
    local alias_out="$work_dir/policy-set-cookie.hpack"
    local cookies_out="$work_dir/policy-cookies.hpack"
    encode_qif_to_file patched none 4 "$none_out"
    encode_qif_to_file patched auth 4 "$auth_out"
    encode_qif_to_file patched default 4 "$default_out"
    encode_qif_to_file patched auth-and-set-cookie 4 "$auth_set_cookie_out"
    encode_qif_to_file patched set-cookie 4 "$alias_out"
    encode_qif_to_file patched cookies 4 "$cookies_out"
    cmp -s "$default_out" "$none_out" || {
        echo "encode-qif default policy differs from none" >&2
        exit 8
    }
    cmp -s "$auth_set_cookie_out" "$alias_out" || {
        echo "encode-qif set-cookie alias differs from auth-and-set-cookie policy" >&2
        exit 8
    }
    local none_size auth_size default_size auth_set_cookie_size cookies_size
    none_size="$(wc -c <"$none_out")"
    auth_size="$(wc -c <"$auth_out")"
    default_size="$(wc -c <"$default_out")"
    auth_set_cookie_size="$(wc -c <"$auth_set_cookie_out")"
    cookies_size="$(wc -c <"$cookies_out")"
    if ! (( default_size == none_size && none_size < auth_size && auth_size < auth_set_cookie_size && auth_set_cookie_size < cookies_size )); then
        echo "unexpected encode-qif policy sizes default=$default_size none=$none_size auth=$auth_size auth-and-set-cookie=$auth_set_cookie_size cookies=$cookies_size" >&2
        exit 9
    fi
    echo "encode_qif_policy_check default_bytes=$default_size none_bytes=$none_size auth_bytes=$auth_size auth_and_set_cookie_bytes=$auth_set_cookie_size cookies_bytes=$cookies_size"
}

run_encode_qif() {
    local variant="$1"
    local policy="$2"
    local qif_iters="${LS_PACK_QIF_ITERS:-100000}"
    local variant_dir="$work_dir/${variant}_copy"
    local start_ns end_ns elapsed_ns
    start_ns="$(date +%s%N)"
    if [[ "$variant" == "patched" && "$policy" != "default" ]]; then
        "$variant_dir/encode-qif" -K -i "$qif_file" -n "$qif_iters" -s "$policy" >/dev/null
    else
        "$variant_dir/encode-qif" -K -i "$qif_file" -n "$qif_iters" >/dev/null
    fi
    end_ns="$(date +%s%N)"
    elapsed_ns=$((end_ns - start_ns))
    awk -v variant="$variant" -v policy="$policy" -v iters="$qif_iters" -v ns="$elapsed_ns" -v per_iter="$qif_headers_per_iter" \
        'BEGIN {
            headers = iters * per_iter;
            printf("variant=%s case=encode_qif policy=%s iterations=%s headers=%d ns_total=%d ns_per_header=%.2f\n",
                variant, policy, iters, headers, ns, ns / headers);
        }'
}

echo "work_dir=$work_dir"
echo "compiler=$CC"
echo "flags=-O3 -DNDEBUG -std=c99 -DLS_HPACK_USE_LARGE_TABLES=1 -DLSHPACK_DEC_HTTP1X_OUTPUT=0 -DLSHPACK_DEC_CALC_HASH=0"
"$work_dir/original_copy/bench" original
"$work_dir/patched_copy/bench" patched
validate_encode_qif_policies
run_encode_qif original default
run_encode_qif patched default
run_encode_qif patched none
run_encode_qif patched auth-and-set-cookie
run_encode_qif patched cookies
