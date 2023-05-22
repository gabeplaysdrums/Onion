#!/bin/sh

log() {
    if [ "$ENABLE_LOG" = "1" ]; then
        echo "$*"
    fi
}

log Finding ROMs for saves in profile

PROFILE=
ROMS=

show_usage_and_exit() {
    echo "usage: $(basename $0) -p profile_directory -r roms_directory"
    exit 1
}

while getopts 'p:r:' opt; do
    case "$opt" in
        p)
            PROFILE="${OPTARG%/}"
            ;;
        r)
            ROMS="${OPTARG%/}"
            ;;
        ?)
            show_usage_and_exit
            ;;
    esac
done
shift "$(($OPTIND -1))"

if [ -z "$PROFILE" ] || [ -z "$ROMS" ]; then
    show_usage_and_exit
fi

log "PROFILE: $PROFILE"
log "ROMS: $ROMS"

TEMP_DIR=/tmp/find-roms
rm -Rf $TEMP_DIR >/dev/null 2>&1

process_files() {
    local dir="$1"
    local match="$2"
    find "$dir" -type f -name "$match" -print0 |
        while IFS= read -r -d '' line; do
            system=$(basename "$(dirname "$line")")
            save_file=$(basename "$line")

            case $save_file in 
                *.db)
                    continue;;
                *.png)
                    continue;;
                *.state.auto)
                    rom_prefix="${save_file%.*}"
                    rom_prefix="${rom_prefix%.*}"
                    ;;
                ?)
                    rom_prefix="${save_file%.*}"
                    ;;
            esac

            mkdir -p "$TEMP_DIR/$system"
            touch "$TEMP_DIR/$system/$rom_prefix"
        done
}

process_category() {
    local match=$2
    find "$PROFILE/$1" -maxdepth 1 -mindepth 1 -type d -print0 |
    while IFS= read -r -d '' line; do
        process_files "$line" "$match"
    done
}

process_category "saves" "*.*"
process_category "states" "*.state*"

find_matching_roms() {
    local system="$1"
    local rom_prefix="$2"
    find "$ROMS" -type f -name "${rom_prefix}.*" -print0 |
        while IFS= read -r -d '' line; do
            log $line
            rom_subpath=${line#*$ROMS/}

            case "$rom_subpath" in
                #ignore files in hidden directories
                */.*)
                    continue;;
            esac

            echo $rom_subpath
        done
}

log "Searching for ROMs ..."
if [ -d "$TEMP_DIR" ]; then
    find "$TEMP_DIR" -type f -print0 |
        while IFS= read -r -d '' line; do
            system=$(basename "$(dirname "$line")")
            rom_prefix=$(basename "$line")
            log "  system: $system"
            log "  rom_prefix: $rom_prefix"
            find_matching_roms "$system" "$rom_prefix"
        done
fi