#!/bin/sh
# Installs rex-extensions: the collection where Rex looks for it, each
# extension under its own name, every helper on PATH, and one line that loads
# the collection into init.lua.
#
# Asks nothing, and safe to run again after a `git pull`. Every change it makes
# to init.lua is undone if `rex config check` rejects the result.
#
#   ./install.sh                              # every extension
#   ./install.sh appearance rex-ladybird      # only these
#   ./install.sh --remove tui-launcher         # unlink it again
#   PREFIX=/usr/local ./install.sh            # somewhere else on PATH
#   REX_CONFIG=/path/to/init.lua ./install.sh # another account's config file
#
# The one load line stays valid through installs and removals, because it loads
# whatever is linked. Removal only touches symlinks this checkout's installer
# could have made: a directory, or a link that points somewhere else, is
# somebody's work and is refused.
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd -P)
config_file="${REX_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/rex/init.lua}"
config_dir=$(dirname -- "$config_file")
bindir="${PREFIX:-$HOME/.local}/bin"
extdir="$here/extensions"
line='require("rex-extensions").setup{}'
legacy_line='require("rex-ladybird").setup{}'

fail() {
    echo "rex-extensions: $*" >&2
    exit 1
}

every_extension() {
    for path in "$extdir"/*/; do
        [ -d "$path" ] && basename -- "$path"
    done
}

require_python() {
    command -v python3 >/dev/null 2>&1 ||
        fail "the extension '$1' ships a python helper and python3 is not on PATH"
}

# 1. What has to be there already. Rex is not optional: without it these are
#    modules nothing loads. A missing browser build is only a warning, because
#    a pane opened before the build exists says so itself.
command -v rex >/dev/null 2>&1 ||
    fail "the rex command is not on PATH. See https://www.superlogical.com/rex/docs/installation"
[ -f "$here/init.lua" ] && [ -d "$extdir" ] || fail "$here does not look like a rex-extensions checkout"

remove=0
case "${1:-}" in
    --remove|-r)
        remove=1
        shift
        [ "$#" -gt 0 ] || fail "which extension? usage: ./install.sh --remove NAME [NAME...]"
        ;;
esac

if [ "$#" -eq 0 ]; then
    # The output is one name per line and the split is the point.
    # shellcheck disable=SC2046
    set -- $(every_extension)
    [ "$#" -gt 0 ] || fail "$extdir has no extensions in it"
fi

selected=""
for name in "$@"; do
    [ -d "$extdir/$name" ] || fail "no extension called '$name' (this checkout has: $(every_extension | tr '\n' ' '))"
    selected="$selected $name"
done

# Removing does not need Rex on PATH: nothing is loaded and no config changes.
if [ "$remove" = 1 ]; then
    removed=""
    for name in "$@"; do
        case "$name" in
            */*|"") fail "not an extension name: $name" ;;
        esac
        link="$config_dir/$name"
        if [ -L "$link" ]; then
            target=$(readlink -- "$link")
            case "$target" in
                "$extdir/$name"|"$extdir/$name"/*)
                    rm -- "$link"
                    echo "removed $link"
                    ;;
                *)
                    fail "$link points at $target, not at this checkout's $name. Leaving it alone"
                    ;;
            esac
        elif [ -e "$link" ]; then
            fail "$link is not a symlink, so this installer did not make it. Move it aside yourself"
        else
            echo "$link is not linked"
        fi
        for helper in "$bindir"/*; do
            [ -L "$helper" ] || continue
            case "$(readlink -- "$helper")" in
                "$extdir/$name/bin/"*)
                    rm -- "$helper"
                    echo "removed $helper"
                    ;;
            esac
        done
        removed="$removed $name"
    done
    if command -v rex >/dev/null 2>&1; then
        rex config reload >/dev/null 2>&1 ||
            echo "warning: rex config reload failed; run it by hand once Rex is running" >&2
    fi
    echo "done. removed:$removed"
    echo "$config_file is unchanged: the load line loads whatever is linked."
    exit 0
fi

# 2. The collection, and the extension each name resolves to. Every link is a
#    symlink so that `git pull` is the update, and none is forced over a
#    directory: that one may be somebody's work.
mkdir -p -- "$config_dir"
link_module() {
    target=$1
    name=$2
    if [ -L "$config_dir/$name" ]; then
        rm -- "$config_dir/$name"
    elif [ -e "$config_dir/$name" ]; then
        fail "$config_dir/$name exists and is not a symlink. Move it aside, then run this again"
    fi
    ln -s -- "$target" "$config_dir/$name"
    echo "linked $config_dir/$name -> $target"
}

link_module "$here" "rex-extensions"
for name in $selected; do
    [ -f "$extdir/$name/init.lua" ] || continue
    link_module "$extdir/$name" "$name"
done

# 3. The helpers. Each extension may ship bin/, and a name that two extensions
#    both used would be a collision worth hearing about rather than losing.
mkdir -p -- "$bindir"
linked=""
for name in $selected; do
    [ -d "$extdir/$name/bin" ] || continue
    for helper in "$extdir/$name/bin"/*; do
        [ -f "$helper" ] || continue
        base=$(basename -- "$helper")
        case " $linked " in
            *" $base "*) fail "two extensions both ship a helper called $base" ;;
        esac
        linked="$linked $base"
        if head -n 1 "$helper" | grep -q python; then require_python "$name"; fi
        ln -sf -- "$helper" "$bindir/$base"
        echo "linked $bindir/$base"
    done
done

if [ -d "$extdir/rex-ladybird" ] && [ -z "${LADYBIRD_BINARY:-}" ] && ! command -v ladybird >/dev/null 2>&1; then
    echo "rex-extensions: no ladybird on PATH and LADYBIRD_BINARY is unset. A pane needs a" >&2
    echo "                source build with terminal mode; set LADYBIRD_BINARY to its path." >&2
fi

# 4. Loading it. One line loads whatever is linked, so installing another
#    extension later does not touch the file again. A line written by the
#    single-extension installer is replaced, not left beside it: two setup calls
#    would register every action twice.
if grep -qF -- "$line" "$config_file" 2>/dev/null; then
    echo "$config_file already loads the collection"
else
    backup="$config_file.before-rex-extensions"
    if [ -f "$config_file" ]; then
        cp -- "$config_file" "$backup"
    fi
    if grep -qF -- "$legacy_line" "$config_file" 2>/dev/null; then
        # awk rather than sed: the line is the whole match, and the file has to
        # come back byte for byte if Rex rejects the result.
        awk -v old="$legacy_line" -v new="$line" \
            '$0 == old { print new; next } { print }' "$config_file" >"$config_file.tmp"
        mv -- "$config_file.tmp" "$config_file"
        replaced=1
    else
        printf '\n%s\n' "$line" >>"$config_file"
        replaced=0
    fi
    if rex config check "$config_file" >/dev/null 2>&1; then
        if [ "$replaced" = 1 ]; then
            echo "replaced the single-extension load line in $config_file"
        else
            echo "added $line to $config_file"
        fi
    else
        if [ -f "$backup" ]; then
            cp -- "$backup" "$config_file"
        else
            rm -f -- "$config_file"
        fi
        fail "$config_file is unchanged: rex config check rejected it with the collection loaded. Run: rex config check"
    fi
fi

# 5. Tell the running server, if there is one. Not an error when there is not:
#    the next start reads the file anyway.
rex config reload >/dev/null 2>&1 || echo "warning: rex config reload failed; run it by hand once Rex is running" >&2

case ":$PATH:" in
    *":$bindir:"*) ;;
    *) echo "Add $bindir to your PATH, for example: echo 'export PATH=\"$bindir:\$PATH\"' >> ~/.zshrc" ;;
esac
echo "done. installed:$selected"
