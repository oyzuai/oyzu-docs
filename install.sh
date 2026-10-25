#!/bin/sh
# Installs the oyzu CLI from a GitHub release on macOS and Linux.
# Reference: https://docs.oyzu.ai/docs/reference/install-script
#   curl -fsSL https://docs.oyzu.ai/install.sh | sh
#   curl -fsSL https://docs.oyzu.ai/install.sh | sh -s -- --version v0.0.3
# It downloads the release executable for this platform (and its oyzu-shim
# companion, and on macOS and Windows the Linux oyzu that isolated builds run),
# refuses it unless its SHA-256 digest matches the digest GitHub reports,
# installs it into ~/.oyzu/bin and runs `oyzu --version` (and `oyzu engine
# install --linux`). It then runs `oyzu shell install`, which activates oyzu in
# your shells and keeps oyzu and its shims on PATH; --no-modify-path skips that.
# It never uses sudo. Everything runs from main, called on the last line, so a
# partly downloaded script does nothing.
set -eu

usage() {
  cat <<'EOF'
Install the oyzu CLI from a GitHub release.

Usage: install.sh [--version TAG] [--dir DIR] [--no-modify-path] [--help]

  --version TAG   install this release tag instead of the newest release
                  (previews included) that has an executable for this platform
  --dir DIR       install into DIR (default: ~/.oyzu/bin)
  --no-modify-path  do not set up your shells and PATH (by default the installer
                  runs `oyzu shell install`: shell activation, oyzu and the
                  shims on PATH)
  --help          show this help

Environment:
  OYZU_VERSION, OYZU_INSTALL_DIR, OYZU_NO_MODIFY_PATH=1   same as the options
  GH_TOKEN or GITHUB_TOKEN   GitHub token, for a private OYZU_RELEASE_REPO or the rate limit (needs curl)
  OYZU_RELEASE_REPO          release repository (default: oyzuai/oyzu-releases)
  OYZU_API_BASE              GitHub API (default: https://api.github.com)
  OYZU_DOWNLOAD_BASE         release downloads (default: https://github.com)

Exit status: 0 installed, 1 failed, 2 usage error, 3 digest refused.
EOF
}

say() { printf '%s\n' "$*"; }
die() { code_=$1; shift; printf 'oyzu install: %s\n' "$*" >&2; exit "$code_"; }

# The release asset names for this host, as tooling/bootstrap-oyzu.sh maps them:
# oyzu-<os>-<arch>[-musl][.exe] and oyzu-shim-<os>-<arch>[-musl][.exe].
detect_platform() {
  machine=$(uname -m)
  case $(uname -s) in
    Linux) os=linux ;;
    Darwin)
      os=darwin
      # A shell under Rosetta reports x86_64 on Apple silicon; prefer the native build.
      if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then machine=arm64; fi ;;
    MINGW*|MSYS*|CYGWIN*)
      os=windows
      # uname -m reports x86_64 under emulation; the native architecture is in these.
      machine=${PROCESSOR_ARCHITEW6432:-${PROCESSOR_ARCHITECTURE:-$machine}} ;;
    *) die 1 "oyzu releases have no executable for $(uname -s). Build it from source instead: https://docs.oyzu.ai/docs/get-started/install" ;;
  esac
  case $machine in
    x86_64|amd64|AMD64) arch=x86_64 ;;
    aarch64|arm64|ARM64) arch=arm64 ;;
    *) die 1 "oyzu releases have no executable for the $machine architecture. Build it from source instead: https://docs.oyzu.ai/docs/get-started/install" ;;
  esac
  abi=; ext=
  [ "$os" != windows ] || ext=.exe
  if [ "$os" = linux ] && { ldd --version 2>&1 | grep -qi musl || ls /lib/ld-musl-* >/dev/null 2>&1; }; then abi=-musl; fi
  asset="oyzu-$os-$arch$abi$ext"
  shim="oyzu-shim-$os-$arch$abi$ext"
}

# fetch URL FILE ACCEPT: download URL into FILE and set $code to the final HTTP
# status (000 when the server could not be reached). A token is passed to curl
# on standard input, never on the command line, and curl drops it when GitHub
# redirects the download to another host.
fetch() {
  if [ -n "$curl" ] && [ -n "$token" ]; then
    code=$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
      curl -sSL --proto "$proto" --proto-redir "$proto" -K - -H "Accept: $3" \
        -H 'X-GitHub-Api-Version: 2022-11-28' -o "$2" -w '%{http_code}' "$1") || code=000
  elif [ -n "$curl" ]; then
    code=$(curl -sSL --proto "$proto" --proto-redir "$proto" -H "Accept: $3" \
      -H 'X-GitHub-Api-Version: 2022-11-28' -o "$2" -w '%{http_code}' "$1" </dev/null) || code=000
  else
    code=$(wget -q -S -O "$2" --header "Accept: $3" "$1" 2>&1 </dev/null |
      sed -n 's/.*HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p' | tail -n 1) || true
    [ -n "$code" ] || code=000
  fi
}

# http_fail WHAT: explain a failed request in plain words and stop.
http_fail() {
  case $code in
    000) die 1 "could not connect to download $1. Check the network connection or proxy (HTTPS_PROXY), then run again." ;;
    401) die 1 "GitHub rejected the token in GH_TOKEN or GITHUB_TOKEN (HTTP 401) for $1. Check that it is valid and not expired." ;;
    403|429) die 1 "GitHub refused $1 (HTTP $code). Anonymous requests are limited to 60 an hour: set GH_TOKEN to a GitHub token, or try again later." ;;
    404)
      [ -n "$token" ] || die 1 "GitHub answered 404 Not Found for $1. Either it does not exist, or $repo is private; if OYZU_RELEASE_REPO names a private repository you can read, run again with a token: curl -fsSL https://docs.oyzu.ai/install.sh | GH_TOKEN=\$(gh auth token) sh"
      die 1 "GitHub answered 404 Not Found for $1 with your token: it does not exist, or the token cannot read $repo." ;;
    *) die 1 "GitHub answered HTTP $code for $1." ;;
  esac
}

# Reads a GitHub releases response (a list, or one release) on standard input and
# prints one line per asset: tag, draft, asset name, asset id and digest,
# separated by tabs. A small JSON scanner, so neither jq nor python is needed.
scan_releases() {
  awk '{ s = s $0 "\n" }
  END {
    n = length(s); d = 0; rd = 0
    for (i = 1; i <= n; i++) {
      c = substr(s, i, 1)
      if (c == "{" || c == "[") {
        if (d == 0) rd = (c == "[") ? 2 : 1
        p = (d > 0 && t[d] == "{") ? k[d] : ""
        d++; t[d] = c; k[d] = ""; pk[d] = p
        if (d == rd && c == "{") { tag = ""; draft = ""; na = 0 }
        if (d == rd + 2 && c == "{") { an = ""; ai = ""; ag = "" }
        continue
      }
      if (c == "}" || c == "]") {
        if (d == rd + 2 && c == "}" && pk[d - 1] == "assets") A[++na] = an "\t" ai "\t" ag
        if (d == rd && c == "}") for (j = 1; j <= na; j++) print tag "\t" draft "\t" A[j]
        d--; continue
      }
      if (c == "\"") {
        j = i + 1
        while (j <= n) { ch = substr(s, j, 1); if (ch == "\\") j += 2; else if (ch == "\"") break; else j++ }
        v = substr(s, i + 1, j - i - 1); i = j
        m = i + 1; while (m <= n && substr(s, m, 1) ~ /[ \t\r\n]/) m++
        if (substr(s, m, 1) == ":") { k[d] = v; i = m; continue }
      } else if (c ~ /[-0-9a-z]/) {
        j = i; while (j < n && substr(s, j + 1, 1) ~ /[-+.0-9a-zA-Z]/) j++
        v = substr(s, i, j - i + 1); i = j
      } else continue
      if (d == rd && t[d] == "{") { if (k[d] == "tag_name") tag = v; else if (k[d] == "draft") draft = v }
      else if (d == rd + 2 && t[d] == "{" && pk[d - 1] == "assets") {
        if (k[d] == "name") an = v; else if (k[d] == "id") ai = v; else if (k[d] == "digest") ag = v
      }
    }
  }'
}

# pick ASSET [TAG]: "tag id digest" of the newest published release (of TAG) with ASSET.
pick() {
  awk -F '\t' -v a="$1" -v t="${2:-}" '$2 == "false" && $3 == a && (t == "" || $1 == t) { print $1, $4, $5; exit }' "$tmp/assets.tsv"
}

# download NAME ID DIGEST [DIR]: fetch one asset into $tmp/DIR/NAME (DIR: bin) and verify its digest.
download() {
  case $3 in sha256:*) ;; *) die 3 "release $tag reports no SHA-256 digest for $1, so the download cannot be verified; nothing was installed." ;; esac
  url=$dl/$repo/releases/download/$tag/$1
  [ -z "$token" ] || url=$api/repos/$repo/releases/assets/$2
  fetch "$url" "$tmp/${4:-bin}/$1" application/octet-stream
  [ "$code" = 200 ] || http_fail "$1 from release $tag"
  actual="sha256:$($sha "$tmp/${4:-bin}/$1" | cut -d' ' -f1)"
  [ "$actual" = "$3" ] || die 3 "$1 from release $tag has digest $actual, but the release reports $3. The download was refused; nothing was installed."
}

# Runs `oyzu shell install`: activation in each shell found, plus oyzu and the
# shims folder on PATH. A failure does not undo the install; it says what to run.
setup_shell() {
  say ""
  if "$dir/oyzu$ext" shell install </dev/null; then
    case ${SHELL-} in
      */fish|fish) say "fish: oyzu does not set up fish yet; run: fish_add_path \"$dir\"" ;;
    esac
  else
    say "oyzu install: oyzu is installed, but setting up your shells and PATH failed. Run it again later: $dir/oyzu$ext shell install" >&2
  fi
}

main() {
  version=${OYZU_VERSION:-}; dir=${OYZU_INSTALL_DIR:-}; skip_setup=${OYZU_NO_MODIFY_PATH:-}
  while [ $# -gt 0 ]; do
    case $1 in
      --version) [ $# -ge 2 ] || die 2 "--version needs a release tag, for example --version v0.0.3"; version=$2; shift ;;
      --version=*) version=${1#*=} ;;
      --dir) [ $# -ge 2 ] || die 2 "--dir needs a directory"; dir=$2; shift ;;
      --dir=*) dir=${1#*=} ;;
      --no-modify-path) skip_setup=1 ;;
      --modify-path) ;; # the old opt-in; setup is now the default
      -h|--help) usage; exit 0 ;;
      *) die 2 "unknown option $1 (see --help)" ;;
    esac
    shift
  done
  [ -n "$dir" ] || dir=${HOME:?HOME is not set; pass --dir}/.oyzu/bin
  repo=${OYZU_RELEASE_REPO:-oyzuai/oyzu-releases}
  api=${OYZU_API_BASE:-https://api.github.com}; api=${api%/}
  dl=${OYZU_DOWNLOAD_BASE:-https://github.com}; dl=${dl%/}
  token=${GH_TOKEN:-${GITHUB_TOKEN:-}}
  proto='=https'
  case "$api $dl" in *http:*) proto='=http,https' ;; esac
  detect_platform
  curl=; command -v curl >/dev/null 2>&1 && curl=curl
  if [ -z "$curl" ]; then
    command -v wget >/dev/null 2>&1 || die 1 "neither curl nor wget is installed; install one of them and run again."
    [ -z "$token" ] || die 1 "GH_TOKEN or GITHUB_TOKEN is set, but curl is not installed. The installer passes tokens only to curl; install curl and run again."
  fi
  for sha in sha256sum 'shasum -a 256' 'openssl dgst -sha256 -r' ''; do command -v "${sha%% *}" >/dev/null 2>&1 && break; done
  [ -n "$sha" ] || die 3 "no sha256sum, shasum or openssl was found to verify the download; install one of them and run again."
  tmp=$(mktemp -d 2>/dev/null || mktemp -d -t oyzu-install)
  trap 'rm -rf "$tmp"' EXIT
  trap 'exit 130' INT TERM
  mkdir "$tmp/bin"
  if [ -n "$version" ]; then path=releases/tags/$version; what="release $version of $repo"
  else path='releases?per_page=30'; what="the release list of $repo"; fi
  fetch "$api/repos/$repo/$path" "$tmp/releases.json" application/vnd.github+json
  [ "$code" = 200 ] || http_fail "$what"
  scan_releases <"$tmp/releases.json" >"$tmp/assets.tsv"
  found=$(pick "$asset")
  if [ -z "$found" ]; then
    [ -z "$version" ] || die 1 "release $version of $repo has no $asset, the executable for this platform. Choose another release, or build from source: https://docs.oyzu.ai/docs/get-started/install"
    die 1 "no published release of $repo has $asset, the executable for this platform. Build from source instead: https://docs.oyzu.ai/docs/get-started/install"
  fi
  set -- $found; tag=$1; digest=$3
  say "Installing oyzu $tag for $os/$arch$abi from $repo"
  download "$asset" "$2" "$digest"
  mv "$tmp/bin/$asset" "$tmp/bin/oyzu$ext"
  shim_found=$(pick "$shim" "$tag")
  if [ -n "$shim_found" ]; then set -- $shim_found; download "$shim" "$2" "$3"; mv "$tmp/bin/$shim" "$tmp/bin/oyzu-shim$ext"; fi
  linux=oyzu-linux-$arch; engine=; [ "$os" = linux ] || engine=$(pick "$linux" "$tag")
  if [ -n "$engine" ]; then mkdir "$tmp/engine"; set -- $engine; download "$linux" "$2" "$3" engine; fi
  # Run the new executable under its installed name before replacing anything,
  # so a build that cannot run here (a glibc build on musl) leaves the old one.
  chmod 755 "$tmp/bin/"*
  ver=$("$tmp/bin/oyzu$ext" --version </dev/null 2>&1) || die 1 "the downloaded $asset does not run on this host: $ver"
  mkdir -p "$dir" || die 1 "cannot create $dir"
  [ ! -e "$dir/oyzu$ext" ] || say "Replacing $dir/oyzu$ext"
  for src in "$tmp/bin/"*; do
    name=${src##*/}
    { cp "$src" "$dir/.$name.new" && mv -f "$dir/.$name.new" "$dir/$name"; } || die 1 "cannot write $dir/$name"
  done
  say "Installed oyzu $tag ($asset, $digest) to $dir/oyzu$ext"
  say "$ver"
  if [ -z "$engine" ]; then [ "$os" = linux ] || say "Release $tag has no $linux, so isolated builds need one: see oyzu engine install --help"
  elif (cd "$tmp" && "$dir/oyzu$ext" engine install --linux "$tmp/engine/$linux" </dev/null >/dev/null); then say "Installed the Linux engine for isolated builds ($linux)"
  else say "oyzu install: setting up the Linux engine for isolated builds failed; run again later: $dir/oyzu$ext engine install --linux <$linux of $tag>" >&2; fi
  if [ "$skip_setup" != 1 ]; then setup_shell; return; fi
  case ":$PATH:" in *":$dir:"*) return ;; esac
  say ""
  say "$dir is not on PATH, and you asked the installer not to change your shell or PATH. To set them up:"
  say "  $dir/oyzu$ext shell install"
}

main "$@"
