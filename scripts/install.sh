#!/bin/sh
# ferri install script
#
#   curl -fsSL https://ferri.run/install.sh | sh
#
# Detects OS/arch, downloads the matching binary from GitHub Releases,
# verifies its sha256, and installs it to $HOME/.local/bin (or
# $FERRI_INSTALL_DIR if set).

set -eu

REPO="m1dnight/ferri"
INSTALL_DIR="${FERRI_INSTALL_DIR:-${HOME}/.local/bin}"

err() { echo "error: $*" >&2; exit 1; }
info() { echo "$*"; }

detect_target() {
    os=$(uname -s)
    arch=$(uname -m)

    case "$os" in
        Darwin) os_part="apple-darwin" ;;
        Linux)  os_part="unknown-linux-gnu" ;;
        *) err "unsupported OS: $os" ;;
    esac

    case "$arch" in
        x86_64|amd64)   arch_part="x86_64" ;;
        arm64|aarch64)  arch_part="aarch64" ;;
        *) err "unsupported arch: $arch" ;;
    esac

    echo "${arch_part}-${os_part}"
}

latest_tag() {
    # Resolves the /releases/latest redirect and pulls the tag off the end.
    curl -fsSLI -o /dev/null -w '%{url_effective}' \
        "https://github.com/${REPO}/releases/latest" \
        | sed 's|.*/||'
}

verify_sha() {
    sha_file=$1
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 -c "$sha_file" >/dev/null
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum -c "$sha_file" >/dev/null
    else
        info "warning: no shasum/sha256sum available, skipping checksum"
        return 0
    fi
}

main() {
    target=$(detect_target)
    tag=$(latest_tag)
    [ -n "$tag" ] || err "could not determine latest version"

    name="ferri-${tag}-${target}"
    archive_url="https://github.com/${REPO}/releases/download/${tag}/${name}.tar.gz"
    sha_url="${archive_url}.sha256"

    info "==> Installing ferri ${tag} for ${target}"

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT INT TERM

    info "    fetching ${archive_url}"
    curl -fsSL "$archive_url" -o "${tmp}/${name}.tar.gz"
    curl -fsSL "$sha_url"     -o "${tmp}/${name}.tar.gz.sha256"

    info "    verifying checksum"
    ( cd "$tmp" && verify_sha "${name}.tar.gz.sha256" )

    info "    extracting"
    tar -xzf "${tmp}/${name}.tar.gz" -C "$tmp"

    info "    installing to ${INSTALL_DIR}/ferri"
    mkdir -p "$INSTALL_DIR"
    install -m 0755 "${tmp}/ferri" "${INSTALL_DIR}/ferri"

    info ""
    info "Installed ferri ${tag} -> ${INSTALL_DIR}/ferri"

    case ":${PATH}:" in
        *":${INSTALL_DIR}:"*) ;;
        *)
            info ""
            info "Note: ${INSTALL_DIR} is not in your PATH."
            info "Add this to your shell config (~/.bashrc, ~/.zshrc):"
            info ""
            info "  export PATH=\"${INSTALL_DIR}:\$PATH\""
            ;;
    esac
}

main "$@"
