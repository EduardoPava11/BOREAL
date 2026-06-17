#!/bin/bash
#
# build-zig.sh — Compile zig/borealkernel for the current Xcode target.
#
# Invoked as a "Run Script" pre-build phase by the BOREAL Xcode target. Reads
# Xcode's PLATFORM_NAME and ARCHS env vars to pick the right Zig target triple,
# then `zig build`s the static library and leaves it at:
#
#   ${SRCROOT}/zig/borealkernel/zig-out/<triple>/lib/libborealkernel.a
#
# Per-target subdirectories so device + simulator builds don't clobber each
# other's .a (Xcode invokes this script per-platform; we keep the artifacts
# isolated so a `xcodebuild -destination` switch picks up the right one
# without a re-build).
#
# Xcode's PATH does NOT include /opt/homebrew/bin, so we use the absolute
# path to zig.

set -euo pipefail

# Auto-detect zig in PATH; honor explicit override via ZIG_PATH.
# Xcode's PATH does NOT include /opt/homebrew/bin, so we explicitly
# prepend the canonical Homebrew bin to PATH for `command -v` to
# find a brew-installed zig. Users on a non-Homebrew install can
# set ZIG_PATH (in the .xcconfig, env, or shell) to override.
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin}"
ZIG="${ZIG_PATH:-$(command -v zig || true)}"
if [ -z "$ZIG" ] || [ ! -x "$ZIG" ]; then
    echo "ERROR: zig not found." >&2
    echo "  Install:  brew install zig" >&2
    echo "  Or set:   ZIG_PATH=/path/to/zig" >&2
    exit 1
fi
KERNEL_DIR="${SRCROOT}/zig/borealkernel"

# ----------------------------------------------------------------------------
# Map Xcode PLATFORM_NAME + ARCHS → Zig target triple.
# ----------------------------------------------------------------------------

case "${PLATFORM_NAME:-}" in
    iphoneos)
        ZIG_TARGET="aarch64-ios"
        ;;
    iphonesimulator)
        if [[ "${ARCHS:-}" == *"arm64"* ]]; then
            ZIG_TARGET="aarch64-ios-simulator"
        else
            ZIG_TARGET="x86_64-ios-simulator"
        fi
        ;;
    macosx)
        # Used by the BOREALTests target (Mac host). Use Zig's native target.
        ZIG_TARGET="native"
        ;;
    *)
        echo "build-zig.sh: ERROR unsupported PLATFORM_NAME='${PLATFORM_NAME:-<unset>}'" >&2
        exit 1
        ;;
esac

# ----------------------------------------------------------------------------
# Map Xcode CONFIGURATION → Zig optimize mode.
#
# IMPORTANT: For iOS targets we ALWAYS use ReleaseFast, regardless of
# Xcode's Debug/Release setting. Reason: Zig's Debug mode pulls in stack-
# trace + panic-handling machinery that references `_dyld_get_image_header_
# containing_address` (via `_debug.SelfInfo.MachO.findModule`), which is
# unresolved at iOS link time without linking libdyld explicitly. ReleaseFast
# strips that machinery; the resulting .a links cleanly. We don't lose much
# debugging value for the kernel itself — its tests run via `zig build test`
# on the host, which still uses Debug mode.
# ----------------------------------------------------------------------------

case "${PLATFORM_NAME:-}" in
    iphoneos|iphonesimulator)
        ZIG_OPT="ReleaseFast"
        ;;
    *)
        case "${CONFIGURATION:-Debug}" in
            Release) ZIG_OPT="ReleaseFast" ;;
            *)       ZIG_OPT="Debug" ;;
        esac
        ;;
esac

OUT_DIR="${KERNEL_DIR}/zig-out/${ZIG_TARGET}"

echo "build-zig.sh: target=${ZIG_TARGET} opt=${ZIG_OPT} out=${OUT_DIR}"

# ----------------------------------------------------------------------------
# Build.
# ----------------------------------------------------------------------------

cd "${KERNEL_DIR}"

if [[ "${ZIG_TARGET}" == "native" ]]; then
    "${ZIG}" build \
        -Doptimize="${ZIG_OPT}" \
        --prefix "${OUT_DIR}"
else
    "${ZIG}" build \
        -Dtarget="${ZIG_TARGET}" \
        -Doptimize="${ZIG_OPT}" \
        --prefix "${OUT_DIR}"
fi

ARTIFACT="${OUT_DIR}/lib/libborealkernel.a"
if [[ ! -f "${ARTIFACT}" ]]; then
    echo "build-zig.sh: ERROR expected artifact missing at ${ARTIFACT}" >&2
    exit 1
fi

# Re-archive with Apple's libtool to produce 8-byte-aligned Mach-O members.
# Zig 0.16's default ar output doesn't satisfy Apple ld's strict alignment
# requirement, which manifests as:
#   ld: 64-bit mach-o member 'libborealkernel_zcu.o' not 8-byte aligned in
#       'libborealkernel.a'
# Workaround: extract the .o files, re-archive via xcrun libtool -static.
if [[ "${PLATFORM_NAME:-}" == "iphoneos" || "${PLATFORM_NAME:-}" == "iphonesimulator" ]]; then
    TMP_AR_DIR=$(mktemp -d -t borealkernel-realign)
    trap "rm -rf '${TMP_AR_DIR}'" EXIT
    (cd "${TMP_AR_DIR}" && ar x "${ARTIFACT}")
    # Zig's archive format doesn't preserve POSIX file modes; ar x extracts
    # the .o files with mode 000 ("----------"). libtool then can't read them
    # (errno=13 EACCES, surfacing as a misleading "cannot open()" warning
    # plus a 96-byte empty output archive). Fix: chmod the extracted files
    # to be readable before re-archiving.
    chmod -R u+r "${TMP_AR_DIR}"
    O_FILES=("${TMP_AR_DIR}"/*.o)
    if [[ ${#O_FILES[@]} -eq 0 ]]; then
        echo "build-zig.sh: ERROR no .o files extracted from ${ARTIFACT}" >&2
        exit 1
    fi
    xcrun libtool -static -no_warning_for_no_symbols \
        -o "${ARTIFACT}.aligned" "${O_FILES[@]}"
    mv "${ARTIFACT}.aligned" "${ARTIFACT}"
fi

SIZE=$(stat -f%z "${ARTIFACT}" 2>/dev/null || stat -c%s "${ARTIFACT}" 2>/dev/null || echo "?")
echo "build-zig.sh: ✓ produced ${ARTIFACT} (${SIZE} bytes)"
