#!/bin/bash
set -e

function osd_volume_simple {
  # Find the devices used by ceph-disk
  DEVICES=$(ceph-volume inventory --format json | $PYTHON -c 'import sys, json; print(" ".join([d.get("path") for d in json.load(sys.stdin) if "Used by ceph-disk" in d.get("rejected_reasons")]))')

  # Scan devices with ceph data partition
  for device in ${DEVICES}; do
    if parted --script "${device}" print | grep -qE '^ 1.*ceph data'; then
      if [[ "${device}" =~ ^/dev/(cciss|nvme) ]]; then
        device+="p"
      fi
      ceph-volume simple scan ${device}1 --force || true
    fi
  done

  # Find the OSD json file associated to the ID
  OSD_JSON=$(grep -l "whoami\": ${OSD_ID}$" /etc/ceph/osd/*.json)
  if [ -z "${OSD_JSON}" ]; then
    log "OSD id ${OSD_ID} does not exist"
    exit 1
  fi

  # Activate the OSD
  # The command can fail so if it does, let's output the ceph-volume logs
  if ! ceph-volume simple activate --file ${OSD_JSON} --no-systemd; then
    cat /var/log/ceph
    exit 1
  fi
}

function osd_volume_lvm {
  # Find the OSD FSID from the OSD ID
  OSD_FSID="$(echo "$CEPH_VOLUME_LIST_JSON" | $PYTHON -c "import sys, json; print(json.load(sys.stdin)[\"$OSD_ID\"][0][\"tags\"][\"ceph.osd_fsid\"])")"

  # Find the OSD type
  OSD_TYPE="$(echo "$CEPH_VOLUME_LIST_JSON" | $PYTHON -c "import sys, json; print(json.load(sys.stdin)[\"$OSD_ID\"][0][\"type\"])")"

  # Discover the objectstore
  if [[ "data journal" =~ $OSD_TYPE ]]; then
    OSD_OBJECTSTORE=(--filestore)
  elif [[ "block wal db" =~ $OSD_TYPE ]]; then
    OSD_OBJECTSTORE=(--bluestore)
  else
    log "Unable to discover osd objectstore for OSD type: $OSD_TYPE"
    exit 1
  fi

  # Activate the OSD
  # The command can fail so if it does, let's output the ceph-volume logs
  if ! ceph-volume lvm activate --no-systemd "${OSD_OBJECTSTORE[@]}" "${OSD_ID}" "${OSD_FSID}"; then
    cat /var/log/ceph
    exit 1
  fi
}

function osd_volume_activate {
  : "${OSD_ID:?Give me an OSD ID to activate, eg: -e OSD_ID=0}"

  CEPH_VOLUME_LIST_JSON="$(ceph-volume lvm list --format json)"

  if echo "$CEPH_VOLUME_LIST_JSON" | $PYTHON -c "import sys, json; print(json.load(sys.stdin)[\"$OSD_ID\"])" &> /dev/null; then
    osd_volume_lvm
  else
    osd_volume_simple
  fi

  log "SUCCESS"
  # This ensures all resources have been unmounted after the OSD has exited
  # We define `sigterm_cleanup_post` here because:
  # - we want to 'protect' the following `exec` in particular.
  # - having the cleaning code just next to the concerned function in the same file is nice.
  function sigterm_cleanup_post {
    local ceph_mnt
    ceph_mnt=$(findmnt --nofsroot --noheadings --output SOURCE --submounts --target /var/lib/ceph/osd/ | grep '^/')
    for mnt in $ceph_mnt; do
      log "osd_volume_activate: Unmounting $mnt"
      umount "$mnt" || (log "osd_volume_activate: Failed to umount $mnt"; lsof "$mnt")
    done
  }
  exec /usr/bin/ceph-osd "${DAEMON_OPTS[@]}" -i "${OSD_ID}"
}
