#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)

for example in "$repo_dir"/env/*.env.example; do
    target=${example%.example}
    if [ ! -e "$target" ]; then
        cp "$example" "$target"
        printf 'Created %s\n' "${target#"$repo_dir"/}"
    fi
done

printf '%s\n' 'Replace every CHANGE_ME value (generate secrets with: openssl rand -hex 32) before starting Atlas.'

