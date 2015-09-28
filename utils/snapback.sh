#!/bin/bash

help()
{
    cat <<EOF
Simple script to create regular snapshot-based backups for Citrix Xenserver
Cocchi Lorenzo <lorenzo.cocchi@softecspa.it>
Original idea from:
    Mark Round, scripts@markround.com
    http://www.markround.com/snapback

Version 1.4:

Usage:

[root@xen ~]# xe vm-list name-label=vm_name params=uuid --minimal
95b7ae99-e66b-aac4-8851-a0ceaaef4292

[root@xen ~]# xe vm-param-set
    uuid=95b7ae99-e66b-aac4-8851-a0ceaaef4292
    other-config:XenCenter.CustomFields.backup_schedule="daily,weekly,monthly"

[root@xen ~]# xe vm-param-set
    uuid=95b7ae99-e66b-aac4-8851-a0ceaaef4292
    other-config:XenCenter.CustomFields.backup_retain="daily=2,weekly=1,monthly=1"

# default value=3
[root@xen ~]# xe vm-param-set
    uuid=95b7ae99-e66b-aac4-8851-a0ceaaef4292
    other-config:XenCenter.CustomFields.backup_retain_xva="2"

# optional, true, false or empty
[root@xen ~]# xe vm-param-set
    uuid=95b7ae99-e66b-aac4-8851-a0ceaaef4292
    other-config:XenCenter.CustomFields.backup_quiesce="true"

[root@xen ~]# echo "mounted" > /var/run/sr-mount/SR-UUID/.snapback

# dry-run mode
[root@xen ~]# ./snapback.sh -f ./snapback.conf -d

[root@xen ~]# ./snapback.sh -f ./snapback.conf
EOF
}

while getopts :f:dh OPT; do
    case ${OPT} in
        d)
            DRYRUN="true"
            ;;
        f)
            CONF="${OPTARG}"
            ;;

        h)
            help
            exit 0
            ;;
        \?)
            "ERROR: invalid option: -${OPTARG}"
            exit 1
            ;;
        :)
            echo "ERROR: option -$OPTARG requires an argument..."
            exit 1
            ;;
     esac
done

shift $((OPTIND -1))

[ -z "$CONF" ] && { help; exit 1; }
. "$CONF" 2>/dev/null || { echo "ERROR: $CONF: No such file"; exit 1; }

log()
{
    logger -p daemon.debug -s -t $(date "+%F %T") ${SELF}[$$]: -- "$@"
}

backup_schedule()
{
    local SCHEDULE=$1

    if [[ "$SCHEDULE" =~ 'monthly' ]] && [[ $(date '+%d') =~ ^01$ ]]; then
        echo "monthly"
        exit
    fi

    if [[ "$SCHEDULE" =~ 'daily' ]] && [[ $(date '+%w') =~ ^[1-6]$ ]]; then
        echo "daily"
        exit
    fi

    if [[ "$SCHEDULE" =~ 'weekly' ]] && [[ $(date '+%w') =~ ^0$ ]]; then
        echo "weekly"
        exit
    fi
}

retain_number()
{
    local RETAIN=$1
    local SCHEDULE=$2

    if [[ $RETAIN =~ ${SCHEDULE}=([0-9]{1,}) ]]; then
        echo ${BASH_REMATCH[1]}
    fi
}

# Quick hack to grab the required paramater from the output of the xe command
xe_param()
{
    local PARAM=$1

    while read DATA; do
        LINE=$(echo $DATA | egrep "$PARAM")
        if [ $? -eq 0 ]; then
            echo "$LINE" | awk 'BEGIN{ FS=": " } { print $2 }'
        fi
    done
}

# Deletes a snapshot's VDIs before uninstalling it. This is needed as
# snapshot-uninstall seems to sometimes leave "stray" VDIs in SRs
delete_snapshot()
{
    local SNAPSHOT_UUID=$1

    for VDI_UUID in $(xe vbd-list vm-uuid=$SNAPSHOT_UUID empty=false | \
        xe_param "vdi-uuid")
    do
        log "deleting snapshot VDI: $VDI_UUID"
        xe vdi-destroy uuid=$VDI_UUID
    done

    # Now we can remove the snapshot itself
    log "removing snapshot with UUID: $SNAPSHOT_UUID"
    xe snapshot-uninstall uuid=$SNAPSHOT_UUID force=true
}

# See above - templates also seem to leave stray VDIs around...
delete_template()
{
    local TEMPLATE_UUID=$1

    for VDI_UUID in $(xe vbd-list vm-uuid=$TEMPLATE_UUID empty=false | \
        xe_param "vdi-uuid")
    do
        log "deleting template VDI: $VDI_UUID"
        xe vdi-destroy uuid=$VDI_UUID
    done

    # Now we can remove the template itself
    log "removing template with UUID: $TEMPLATE_UUID"
    xe template-uninstall template-uuid=$TEMPLATE_UUID force=true
}

slack_msg()
{
    local MSG=$1

    curl -s -X POST -d \
        "payload={
            \"channel\": \"$SLACK_CHANNEL\",
            \"username\": \"$SLACK_USERNAME\",
            \"text\": \"$SELF: $MSG\"
        }" \
        $SLACK_URL -o /dev/null
}

check_sr_mount()
{
    local SR=$1
    local FILE=${2}
    local STR=${3:-'mounted'}

    if [ -z "$FILE" ]; then
        FILE=.${SELF/.sh/}
    fi

    SR_MOUNT=$(mount | grep $SR | awk '{print $3 }')

    if [ -z "$SR_MOUNT" ]; then
        return 1
    fi

    if grep -q $STR ${SR_MOUNT}/${FILE} 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

LOCKFILE=/tmp/snapback.lock

if [ -f $LOCKFILE ]; then
    log "failed: lockfile $LOCKFILE exists, exiting!"
    slack_msg "failed: lockfile $LOCKFILE exists, exiting!"
    exit 1
fi

if ! check_sr_mount $TMPL_SR; then
    log "failed: SR: $TMPL_SR not mounted"
    slack_msg "failed: SR: $TMPL_SR not mounted"
    exit 1
fi

if ! check_sr_mount $XVA_SR; then
    log "failed: SR: $XVA_SR not mounted"
    slack_msg "failed: SR: $XVA_SR not mounted"
    exit 1
fi


touch $LOCKFILE

# Date format must be %Y%m%d so we can sort them
BACKUP_DATE=$(date +"%Y%m%d")

log "XenServer backup started (pid $$)"

# Get all running VMs
# todo: Need to check this works across a pool
RUNNING_VMS=$(xe vm-list power-state=running is-control-domain=false | \
    xe_param uuid)

for VM in $RUNNING_VMS; do
    VM_NAME="$(xe vm-list uuid=$VM | xe_param name-label)"

    log "$VM_NAME: backup started"
    log "$VM_NAME: retrieving backup paramaters"

    SCHEDULE=$(xe vm-param-get uuid=$VM param-name=other-config \
        param-key=XenCenter.CustomFields.backup_schedule 2>/dev/null)

    RETAIN=$(xe vm-param-get uuid=$VM param-name=other-config \
        param-key=XenCenter.CustomFields.backup_retain 2>/dev/null)

    RETAIN_XVA=$(xe vm-param-get uuid=$VM param-name=other-config \
        param-key=XenCenter.CustomFields.backup_retain_xva 2>/dev/null)

    # Not using this yet, as there are some bugs to be worked out...
    QUIESCE=$(xe vm-param-get uuid=$VM param-name=other-config \
        param-key=XenCenter.CustomFields.backup_quiesce 2>/dev/null)

    if [[ "$SCHEDULE" == "" || "$RETAIN" == "" ]]; then
        log "$VM_NAME: no schedule or retention set, skip"
        continue
    fi

    [ "$RETAIN_XVA" == "" ] && RETAIN_XVA=0

    BACKUP_SCHEDULE=$(backup_schedule $SCHEDULE)

    if [ -z "$BACKUP_SCHEDULE" ]; then
        log "$VM_NAME: no schedule set, skip"
        continue
    fi

    RETAIN_NUMBER=$(retain_number $RETAIN $BACKUP_SCHEDULE)

    if [ -z "$RETAIN_NUMBER" ]; then
        log "$VM_NAME: no retain set, skip"
        continue
    fi

    BACKUP_SUFFIX="backup-${BACKUP_SCHEDULE}"

    log "$VM_NAME: backup_schedule: $BACKUP_SCHEDULE ($SCHEDULE)"
    log "$VM_NAME: backup_retention: $RETAIN_NUMBER previous snap ($RETAIN)"
    log "$VM_NAME: backup_retention_xva: $RETAIN_XVA"
    log "$VM_NAME: backup_quiesce: $QUIESCE"

    if [ "x$DRYRUN" == "xtrue" ]; then
        log "$VM_NAME: dry-run mode, continue without backup"
        continue
    fi

    log "$VM_NAME: checking snapshots"

    VM_SNAPSHOT_CHECK=$(xe snapshot-list \
        name-label=$VM_NAME-$SNAPSHOT_SUFFIX | xe_param uuid)

    if [ "$VM_SNAPSHOT_CHECK" != "" ]; then
        for SNAPSHOT in $VM_SNAPSHOT_CHECK; do
            log "$VM_NAME: found old snapshot $SNAPSHOT, deleting..."
            delete_snapshot $SNAPSHOT
        done
    fi

    log "$VM_NAME: creating snapshot backup"

    # Select appropriate snapshot command
    # See above - not using this yet, as have to work around failures
    if [ "$QUIESCE" == "true" ]; then
       log "$VM_NAME: using VSS plugin"
       SNAPSHOT_CMD="vm-snapshot-with-quiesce"
    else
       log "$VM_NAME: not using VSS plugin, disks will not be quiesced"
       SNAPSHOT_CMD="vm-snapshot"
    fi

    SNAPSHOT_UUID=$(xe $SNAPSHOT_CMD vm="$VM_NAME" \
        new-name-label="$VM_NAME-$SNAPSHOT_SUFFIX")

    SNAPSHOT_UUID_RET=$?

    if [ $SNAPSHOT_UUID_RET -ne 0 ]; then
        log "$VM_NAME: failed created snapshot"
        slack_msg "$VM_NAME: failed: created snapshot"
        continue
    fi

    log "created snapshot with UUID: $SNAPSHOT_UUID"
    log "copying snapshot with UUID: $SNAPSHOT_UUID to SR: $TMPL_SR"
    # Check there isn't a stale template with TEMP_SUFFIX name hanging
    # around from a failed job
    TEMPLATE_TEMP="$(xe template-list name-label="$VM_NAME-$TEMP_SUFFIX" | \
        xe_param uuid)"

    if [ "$TEMPLATE_TEMP" != "" ]; then
        for TEMPLATE in $TEMPLATE_TEMP; do
            log "$VM_NAME: found stale temporary template, removing $TEMPLATE"
            delete_template $TEMPLATE
        done
    fi

    TEMPLATE_UUID=$(xe snapshot-copy uuid=$SNAPSHOT_UUID sr-uuid=$TMPL_SR \
        new-name-description="Snapshot created on $(date)" \
        new-name-label="$VM_NAME-$TEMP_SUFFIX")

    TEMPLATE_UUID_RET=$?

    if [ $TEMPLATE_UUID_RET -ne 0 ]; then
        log "$VM_NAME: failed: copy snapshot $SNAPSHOT_UUID to SR $TMPL_SR"
        slack_msg \
            "failed: copy snapshot $SNAPSHOT_UUID to SR $TMPL_SR"

        log "$VM_NAME: removing temporary snapshot backup $SNAPSHOT_UUID"
        slack_msg \
            "removing temporary snapshot backup $SNAPSHOT_UUID"
        delete_snapshot $SNAPSHOT_UUID

        continue
    fi

    if [ "$RETAIN_XVA" -ne 0 ]; then
        unset BACKUP_DIR
        BACKUP_DIR=${XVA_SR}/${VM_NAME}

        if [ ! -d $BACKUP_DIR ]; then
            mkdir -p $BACKUP_DIR
            log "$VM_NAME: create $BACKUP_DIR"
        fi

        unset VM_FILENAME
        VM_FILENAME=${BACKUP_DIR}/${VM_NAME}-${BACKUP_DATE}.xva

        log "$VM_NAME: export to $VM_FILENAME"
        xe vm-export vm=$SNAPSHOT_UUID filename=$VM_FILENAME
        VM_EXPORT_RET=$?

        if [ $VM_EXPORT_RET -ne 0 ]; then
            log "$VM_NAME: failed export to $VM_FILENAME"
            slack_msg "failed: export $VM_NAME to $VM_FILENAME"
            continue
        fi

        log "$VM_NAME: checking for removing old XVA"

        # Remove old XVA
        OLD_XVA=$(ls -tr1 ${BACKUP_DIR} | head -n-${RETAIN_XVA})
        for XVA in ${OLD_XVA}; do
            log "$VM_NAME: delete old ${BACKUP_DIR}/${XVA}"
            rm -f "${BACKUP_DIR}/${XVA}"
        done

    else
        log "$VM_NAME: XVA no retain set, skip"
    fi

    log "$VM_NAME: removing temporary snapshot backup $SNAPSHOT_UUID"
    delete_snapshot $SNAPSHOT_UUID

    # List templates for all VMs, grep for $VM_NAME-$BACKUP_SUFFIX
    # Sort -n, head -n -$RETAIN
    # Loop through and remove each one

    log "$VM_NAME: checking for removing old backups"
    xe template-list | grep "$VM_NAME-$BACKUP_SUFFIX" | \
        xe_param name-label | sort -n | head -n-$RETAIN_NUMBER > $TEMP

    while read OLD_TEMPLATE
    do
        OLD_TEMPLATE_UUID=$(xe template-list name-label="$OLD_TEMPLATE" | \
            xe_param uuid)
        log "$VM_NAME: removing $OLD_TEMPLATE with UUID $OLD_TEMPLATE_UUID"
        delete_template $OLD_TEMPLATE_UUID
    done < $TEMP

    # Also check there is no template with the current timestamp.
    # Otherwise, you would not be able to backup more than once a day if
    # you needed...
    TODAYS_TEMPLATE="$(xe template-list \
        name-label="$VM_NAME-$BACKUP_SUFFIX-$BACKUP_DATE" | xe_param uuid)"
    if [ "$TODAYS_TEMPLATE" != "" ]; then
        log "$VM_NAME: found a template already for today, removing $TODAYS_TEMPLATE"
        delete_template $TODAYS_TEMPLATE
    fi

    log "$VM_NAME: renaming template"
    xe template-param-set name-label="$VM_NAME-$BACKUP_SUFFIX-$BACKUP_DATE" \
        uuid=$TEMPLATE_UUID

    log "$VM_NAME: backup successfully"
    log "sleeping for 30s"
    sleep 30
done

xe vdi-list sr-uuid=$TMPL_SR > /var/run/sr-mount/$TMPL_SR/mapping.txt
xe vbd-list > /var/run/sr-mount/$TMPL_SR/vbd-mapping.txt

log "XenServer backup finished"

[ -e $TEMP ] && rm $TEMP
rm $LOCKFILE
