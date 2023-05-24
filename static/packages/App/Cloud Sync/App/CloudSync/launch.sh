#!/bin/sh

start=$(date +%s)

CONFIG_FILE=/mnt/SDCARD/rclone.conf
LOG_FILE_PREFIX=/mnt/SDCARD/cloud_sync
LOG_FILE_SUFFIX=.log
ERROR_FLAG=/tmp/cloud_sync_error
PROFILE=/mnt/SDCARD/Saves/CurrentProfile
SYNC_ROMS_CONFIG_FLAG=/mnt/SDCARD/.tmp_update/config/.cloudSyncRoms
ROMS=/mnt/SDCARD/Roms
RCLONE_REMOTE=cloud
CLOUD_DIR=$RCLONE_REMOTE:Onion
RCLONE_OPTIONS="--no-check-certificate --config=$CONFIG_FILE"

LOG_FILE=

# keep up to 10 log files
for i in "" ".1" ".2" ".3" ".4" ".5" ".6" ".7" ".8" ".9"; do
    file="${LOG_FILE_PREFIX}$i${LOG_FILE_SUFFIX}"
    if [ -f "$file" ]; then
        continue
    fi
    LOG_FILE="$file"
    break
done

if [ -z "$LOG_FILE" ]; then
    echo "Replacing oldest log file"
    LOG_FILE=$(
        ls -tr ${LOG_FILE_PREFIX}*${LOG_FILE_SUFFIX} | tr '\n' '\n' |
        while IFS= read -r file; do
            echo $file
            break
        done
    )
fi

echo "LOG_FILE: $LOG_FILE"

echo $0 $* >$LOG_FILE

log() {
    echo $* >>$LOG_FILE
    echo $*
}

NAME_FILE=/mnt/SDCARD/name.txt
NAME=unnamed
if [ -f "$NAME_FILE" ]; then
    NAME=$(cat "$NAME_FILE")
fi

echo NAME: $NAME

cd $(dirname "$0")

TITLE="Syncing $NAME device"

log $TITLE

preload_info_panel() {
    local MESSAGE=$1
    local PANEL_TITLE=$2

    if [ -z "$PANEL_TITLE" ]; then
        PANEL_TITLE=$TITLE
    fi

    log $MESSAGE
    LD_PRELOAD=/mnt/SDCARD/miyoo/lib/libpadsp.so /mnt/SDCARD/.tmp_update/bin/infoPanel -t "$PANEL_TITLE" -m "$MESSAGE" --auto &
}

rm $ERROR_FLAG >/dev/null 2>&1

exit_on_error() {
    local MESSAGE=$1
    preload_info_panel "$MESSAGE" "Error"
    touch $ERROR_FLAG
    sleep 5
    exit 0
}

now=$(date +%s)
elapsed_offset=$(expr $now - $start)

# Quick time sync fix
preload_info_panel "Syncing clock to network time"
export TZ=UTC-0
ntpd -n -q -N -p time.nist.gov >>$LOG_FILE 2>&1 || exit_on_error "NTPD failed"
hwclock -w >>$LOG_FILE 2>&1 || exit_on_error "hwclock failed"
start=$(date +%s)

TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
log "Current time is $TIMESTAMP"

# rclone
preload_info_panel "Checking cloud connection"
./rclone $RCLONE_OPTIONS -vv lsd ${RCLONE_REMOTE}: >>$LOG_FILE 2>&1 || exit_on_error "Could not verify cloud connection"

sync_dirs() {
    local WHAT=$1
    local LOCAL_DIR=$2
    local CLOUD_DIR=$3
    local OP=$4

    if [ -z "$OP" ]; then
        OP="sync"
    fi

    log "LOCAL_DIR: $LOCAL_DIR"
    log "CLOUD_DIR: $CLOUD_DIR"
    log "OP: $OP"


    if [ "$OP" = "sync" || "$OP" = "upload" ]; then
        preload_info_panel "Uploading $WHAT to the cloud"
        ./rclone copy --update -P -L $RCLONE_OPTIONS $LOCAL_DIR $CLOUD_DIR >>$LOG_FILE 2>&1 || exit_on_error "Upload failed while syncing $WHAT"
    fi

    if [ "$OP" = "sync" || "$OP" = "download" ]; then
        preload_info_panel "Downloading $WHAT from the cloud"
        ./rclone copy --update -P -L $RCLONE_OPTIONS $CLOUD_DIR $LOCAL_DIR >>$LOG_FILE 2>&1 || exit_on_error "Download failed while syncing $WHAT"
    fi
}

sync_dirs "saves" "$PROFILE/saves/" "$CLOUD_DIR/$NAME/saves/"
sync_dirs "states" "$PROFILE/states/" "$CLOUD_DIR/$NAME/states/"
sync_dirs "rom screens" "$PROFILE/romScreens/" "$CLOUD_DIR/$NAME/romScreens/"

#sync_dirs "ROMs" "$ROMS/" "$CLOUD_DIR/Roms/" "upload"

# Smart sync of matching ROMs
if [ -f "$SYNC_ROMS_CONFIG_FLAG" ]; then
    preload_info_panel "Searching for matching ROMs"
    ./find-roms.sh -p "$PROFILE" -r "$ROMS" |
        while IFS= read -r rom_subpath; do
            preload_info_panel "Copying ROMs to the cloud\n$rom_subpath"
            ./rclone copyto --update -P -L $RCLONE_OPTIONS "$ROMS/$rom_subpath" "$CLOUD_DIR/Roms/$rom_subpath" >>$LOG_FILE 2>&1 || exit_on_error "Failed to upload $rom_subpath"
        done
fi

now=$(date +%s)
elapsed=$(expr $elapsed_offset + $now - $start)
preload_info_panel "Success!\nSync took $elapsed seconds"