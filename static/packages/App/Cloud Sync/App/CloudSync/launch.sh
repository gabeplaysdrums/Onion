#!/bin/sh
echo $0 $*

CONFIG_FILE=/mnt/SDCARD/rclone.conf
LOG_FILE=/mnt/SDCARD/rclone.log
ERROR_FLAG=/tmp/cloud_sync_error

NAME_FILE=/mnt/SDCARD/name.txt
NAME=unnamed
if [ -f "$NAME_FILE" ]; then
    NAME=$(cat "$NAME_FILE")
fi

echo NAME: $NAME

cd $(dirname "$0")

# Quick time sync fix
ntpd -N -p 162.159.200.1
hwclock -w
sleep 1

# rclone

exit_on_error() {
    local MESSAGE=$1
    LD_PRELOAD=/mnt/SDCARD/miyoo/lib/libpadsp.so /mnt/SDCARD/.tmp_update/bin/infoPanel -t "Error" -m "$MESSAGE" --auto &
    touch $ERROR_FLAG
    sleep 5
    exit 0
}

sync_dirs() {
    local TITLE="Syncing $NAME device"
    local WHAT=$1
    local MESSAGE="Syncing $WHAT with the cloud"
    local LOCAL_DIR=$2
    local CLOUD_DIR=$3
    echo "Title: $TITLE"
    echo "Message: $MESSAGE"
    echo "Local dir: $LOCAL_DIR"
    echo "Cloud dir: $CLOUD_DIR"

    LD_PRELOAD=/mnt/SDCARD/miyoo/lib/libpadsp.so /mnt/SDCARD/.tmp_update/bin/infoPanel -t "$TITLE" -m "$MESSAGE" --auto &

    rm $ERROR_FLAG >/dev/null 2>&1
    ./rclone copy -P -L --no-check-certificate --config=$CONFIG_FILE $LOCAL_DIR $CLOUD_DIR >$LOG_FILE 2>&1 || exit_on_error "Upload failed while syncing $WHAT"
    ./rclone copy -P -L --no-check-certificate --config=$CONFIG_FILE $CLOUD_DIR $LOCAL_DIR >$LOG_FILE 2>&1 || exit_on_error "Download failed while syncing $WHAT"
}

sync_dirs "saves" "/mnt/SDCARD/Saves/CurrentProfile/saves/" "cloud:Onion/$NAME/saves/"
sync_dirs "states" "/mnt/SDCARD/Saves/CurrentProfile/states/" "cloud:Onion/$NAME/states/"
sync_dirs "rom screens" "/mnt/SDCARD/Saves/CurrentProfile/romScreens/" "cloud:Onion/$NAME/romScreens/"
#sync_dirs "ROMs" "/mnt/SDCARD/Roms/" "cloud:Onion/Roms/"