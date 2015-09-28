#!/bin/bash

SELF=$(basename $0)
SNAPBACK_LOG="/var/log/snapback.log"
TMP_FILE="/tmp/${SELF/.sh/}.$$.tmp"

if [ ! -s "${SNAPBACK_LOG}" ]; then
   exit 1
fi

cat << EOF >> ${TMP_FILE}
To:notifiche@example.com
From:$HOSTNAME
Subject: [$HOSTNAME on ClusterCactus Snapback Log]

EOF

cat "${SNAPBACK_LOG}" >> "${TMP_FILE}"
ssmtp notifiche@example.com < "${TMP_FILE}"
rm -f "${TMP_FILE}"

# EOF
