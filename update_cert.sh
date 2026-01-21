#!/bin/bash
set -euo pipefail

DRY_RUN="${DRY_RUN:-true}"
readonly DRY_RUN

LOGFILE="${LOGFILE:-/var/log/update_cert.log}"
readonly LOGFILE

DOMAIN="${DOMAIN:-example.com}"
readonly DOMAIN

REMOTE_USER="${REMOTE_USER:-example_user}"
readonly REMOTE_USER

REMOTE_HOST="${REMOTE_HOST:-terra.example.com}"
readonly REMOTE_HOST

CERT_DESC="${CERT_DESC:-Letsencrypt}"
readonly CERT_DESC

LOCAL_BASE_DIR="${LOCAL_BASE_DIR:-/volume1/scriptuse/cert_update/$CERT_DESC}"
readonly LOCAL_BASE_DIR

ARCHIVE_BASE_DIR="${ARCHIVE_BASE_DIR:-/usr/syno/etc/certificate/_archive}"
readonly ARCHIVE_BASE_DIR

ARCHIVE_ID="$(< "${ARCHIVE_BASE_DIR}/DEFAULT")"
readonly ARCHIVE_ID

ARCHIVE_DIR="${ARCHIVE_DIR:-${ARCHIVE_BASE_DIR}/${ARCHIVE_ID}}"
readonly ARCHIVE_DIR

ARCHIVE_INFO_PATH="${ARCHIVE_INFO_PATH:-${ARCHIVE_BASE_DIR}/INFO}"
readonly ARCHIVE_INFO_PATH

ARCHIVE_INFO_JSON="$(< "$ARCHIVE_INFO_PATH")"
readonly ARCHIVE_INFO_JSON

SUBS_DIR_SYS="${SUBS_DIR_SYS:-/usr/syno/etc/certificate}"
readonly SUBS_DIR_SYS

SUBS_DIR_PKG="${SUBS_DIR_PKG:-/usr/local/etc/certificate}"
readonly SUBS_DIR_PKG

CERT_FILE_NAME_SRC="${CERT_FILE_NAME_SRC:-cert.cer}"
readonly CERT_FILE_NAME_SRC

CHAIN_FILE_NAME_SRC="${CHAIN_FILE_NAME_SRC:-chain.cer}"
readonly CHAIN_FILE_NAME_SRC

FULLCHAIN_FILE_NAME_SRC="${FULLCHAIN_FILE_NAME_SRC:-fullchain.cer}"
readonly FULLCHAIN_FILE_NAME_SRC

KEY_FILE_NAME_SRC="${KEY_FILE_NAME_SRC:-privkey.key}"
readonly KEY_FILE_NAME_SRC

CERT_FILE_NAME_TGT="${CERT_FILE_NAME_TGT:-cert.pem}"
readonly CERT_FILE_NAME_TGT

CHAIN_FILE_NAME_TGT="${CHAIN_FILE_NAME_TGT:-chain.pem}"
readonly CHAIN_FILE_NAME_TGT

FULLCHAIN_FILE_NAME_TGT="${FULLCHAIN_FILE_NAME_TGT:-fullchain.pem}"
readonly FULLCHAIN_FILE_NAME_TGT

KEY_FILE_NAME_TGT="${KEY_FILE_NAME_TGT:-privkey.pem}"
readonly KEY_FILE_NAME_TGT

SHORTCHAIN_FILE_NAME_TGT="${SHORTCHAIN_FILE_NAME_TGT:-short-chain.pem}"
readonly SHORTCHAIN_FILE_NAME_TGT

ROOT_CERT_FILE_NAME_TGT="${ROOT_CERT_FILE_NAME_TGT:-root.pem}"
readonly ROOT_CERT_FILE_NAME_TGT


mapfile -t SUBSCRIBERS_SYS < <(
  jq -r --arg CERT_DESC "$CERT_DESC" '
    .[] | select(.desc == $CERT_DESC)
    | .services[] | select(.isPkg == false)
    | .subscriber
  ' <<< "$ARCHIVE_INFO_JSON" | uniq
)

mapfile -t SUBSCRIBERS_PKG < <(
  jq -r --arg CERT_DESC "$CERT_DESC" '
    .[] | select(.desc == $CERT_DESC)
    | .services[] | select(.isPkg == true)
    | .subscriber
  ' <<< "$ARCHIVE_INFO_JSON" | uniq
)

readonly SUBSCRIBERS_SYS
readonly SUBSCRIBERS_PKG

date_str() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  echo "[$(date_str)] $*" >> "$LOGFILE"
}

log_error() {
  local entry
  entry="[$(date_str)] ERROR: $*"
  echo "$entry" >> "$LOGFILE"
  echo "$entry" >&2
}

run() {
  local silent=false
  # check for quiet flag
  if [ "${1:-}" = "--quiet" ] || [ "${1:-}" = "-q" ]; then
    silent=true
    shift
  fi

  # optional command echo
  if [ "$silent" = false ]; then
    echo "==> Command: $*"
  fi

  # dry-run logic
  if [ "${DRY_RUN:-false}" = "true" ]; then
    if [ "$silent" = false ]; then
      echo "--> [DRY-RUN] Command not executed."
    fi
    return 0
  fi

  # execute
  if ! "$@" 2>&1; then
    local status=$?
    log_error "Error ($status) on: $*"
    return $status
  fi

  if [ "$silent" = false ]; then
    echo "--> Success: $*"
  fi
  return 0
}

copy_file() {
  if [ "$#" -lt 2 ]; then
    log_error "copy_file(): not enough arguments."
    return 1
  fi
  local src="$1" tgt="$2"
  if [ "${DRY_RUN:-false}" = "true" ]; then
    echo "[DRY-RUN] Would copy: '$src' → '$tgt'"
    return 0
  fi
  run cp "$src" "$tgt"
}

copy_cert_files() {
  if [ "$#" -lt 2 ]; then
    log_error "copy_cert_files(): not enough arguments."
    return 1
  fi
  local SRC="$1" TGT="$2" is_archive="false"
  [ "$#" -eq 3 ] && [ "$3" == "true" ] && is_archive="true"

  if [ "$is_archive" = "false" ]; then
    copy_file "$SRC/$CERT_FILE_NAME_TGT"     "$TGT/$CERT_FILE_NAME_TGT"
    copy_file "$SRC/$CHAIN_FILE_NAME_TGT"    "$TGT/$CHAIN_FILE_NAME_TGT"
    copy_file "$SRC/$FULLCHAIN_FILE_NAME_TGT" "$TGT/$FULLCHAIN_FILE_NAME_TGT"
    copy_file "$SRC/$KEY_FILE_NAME_TGT"      "$TGT/$KEY_FILE_NAME_TGT"
  else
    copy_file "$SRC/$CERT_FILE_NAME_SRC"     "$TGT/$CERT_FILE_NAME_TGT"
    copy_file "$SRC/$CHAIN_FILE_NAME_SRC"    "$TGT/$CHAIN_FILE_NAME_TGT"
    copy_file "$SRC/$FULLCHAIN_FILE_NAME_SRC" "$TGT/$FULLCHAIN_FILE_NAME_TGT"
    local key_src="$SRC/$KEY_FILE_NAME_SRC" key_tgt="$TGT/$KEY_FILE_NAME_TGT" tmp="/tmp/$KEY_FILE_NAME_TGT"
    first_line=$(head -n1 "$key_src")
    if [ "$first_line" = "-----BEGIN PRIVATE KEY-----" ]; then
      copy_file "$key_src" "$key_tgt"
    else
      if ! run openssl pkcs8 -topk8 -nocrypt -in "$key_src" -out "$tmp"; then
        log_error "copy_cert_files(): OpenSSL failed to convert private key."
        return 1
      fi
      copy_file "$tmp" "$key_tgt"
      run rm "$tmp"
    fi
  fi

  run chown root:root "$TGT"/*.pem
  run chmod 600 "$TGT"/*.pem
}

update_cert_location() {
  if [ "$#" -lt 1 ]; then
    log_error "update_cert_location(): not enough arguments."
    return 1
  fi
  local type="$1"
  local dir subs services

  if [ "$type" = system ]; then
    dir="$SUBS_DIR_SYS"; subs=("${SUBSCRIBERS_SYS[@]}")
  else
    dir="$SUBS_DIR_PKG"; subs=("${SUBSCRIBERS_PKG[@]}")
  fi

  for subscriber in "${subs[@]}"; do
    mapfile -t services < <(
      jq -r --arg D "$CERT_DESC" --arg S "$subscriber" '
        .[] | select(.desc == $D)
        | .services[] | select((.isPkg == ('"$([ "$type" = pkg ] && echo true || echo false)"')) and .subscriber == $S)
        | .service
      ' <<< "$ARCHIVE_INFO_JSON"
    )
    for svc in "${services[@]}"; do
      copy_cert_files "$ARCHIVE_DIR" "$dir/$subscriber/$svc" "$([ "$type" = pkg ] && echo true)"
      copy_file      "$ARCHIVE_DIR/$CHAIN_FILE_NAME_TGT" "$dir/$subscriber/$svc/$SHORTCHAIN_FILE_NAME_TGT"
      copy_root_cert_from_trust "$ARCHIVE_DIR/$CHAIN_FILE_NAME_TGT" "$dir/$subscriber/$svc/$ROOT_CERT_FILE_NAME_TGT"
    done
  done
}

copy_root_cert_from_trust() {
  local chain="$1" target="$2" trust="/etc/ssl/certs"
  if [ ! -f "$chain" ]; then
    log_error "copy_root_cert_from_trust(): chain.pem not found: $chain"
    return 1
  fi
  if [ -z "$target" ]; then
    log_error "copy_root_cert_from_trust(): no target path specified."
    return 1
  fi

  # Extract the last certificate from the chain file
  local last
  last=$(
    awk '
      /-----BEGIN CERTIFICATE-----/ { in_cert=1; cert = $0 ORS; next }
      in_cert { cert = cert $0 ORS }
      /-----END CERTIFICATE-----/ {
        if (in_cert) {
          last_cert = cert $0 ORS
          in_cert = 0
        }
      }
      END { printf "%s", last_cert }
    ' "$chain"
  )
  if [ -z "$last" ]; then
    log_error "copy_root_cert_from_trust(): no certificate extracted."
    return 2
  fi

  # Determine the subject of the last certificate
  local subj
  subj=$(printf "%s" "$last" | openssl x509 -noout -subject 2>/dev/null | sed 's/^subject= //')
  [ -z "$subj" ] && { log_error "copy_root_cert_from_trust(): failed to retrieve certificate subject."; return 3; }

  # Search for matching root certificate in the trust store
  for c in "$trust"/*.pem "$trust"/*.0; do
    [ -f "$c" ] || continue
    if openssl x509 -noout -subject -in "$c" 2>/dev/null | sed 's/^subject= //' | grep -Fxq "$subj"; then
      copy_file "$c" "$target"
      return 0
    fi
  done

  log_error "copy_root_cert_from_trust(): no matching root certificate found."
  return 4
}

restart_services() {
  log "Restarting services..."
  run /usr/syno/bin/synow3tool --gen-all
  run /usr/syno/bin/synow3tool --nginx=reload
  run /usr/syno/bin/synow3tool --restart-dsm-service
  if netstat -tuln | grep -q ":21 "; then
    run /usr/syno/bin/synosystemctl restart ftpd
  fi
  log "Services successfully restarted."
}

# ===== Main flow =====

log "Changes detected – updating certificate archive for $CERT_DESC"
copy_cert_files "$LOCAL_BASE_DIR" "$ARCHIVE_DIR" true
log "Certificate archive successfully updated."
update_cert_location packages
update_cert_location system
log "All certificates for $CERT_DESC have been successfully updated."
restart_services
