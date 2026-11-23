#!/usr/bin/env bash
# Shared helpers for the Omakvm clipboard relay. Sourced, never executed.
#
# The relay keeps no clipboard of its own. Each machine keeps its ordinary
# Wayland clipboard; a copy made on one is pushed to the peers, which place it
# on theirs with wl-copy. Omarchy's clipboard history then records it like any
# other copy.

OMAKVM_CLIP_PORT="${OMAKVM_CLIP_PORT:-4244}"
OMAKVM_CLIP_MAX_BYTES="${OMAKVM_CLIP_MAX_BYTES:-33554432}" # 32 MiB

OMAKVM_CONFIG_DIR="${OMAKVM_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/omakvm}"
OMAKVM_RUNTIME_DIR="${OMAKVM_RUNTIME_DIR:-${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is not set}/omakvm}"

# One peer per line: "<ipv4-address> [name]". Lines starting with # are ignored.
PEERS_FILE="$OMAKVM_CONFIG_DIR/peers"

# Checksum of the content both sides are known to hold. It is what stops a
# received clip from being sent straight back, and a repeated copy from being
# sent twice.
SYNCED_FILE="$OMAKVM_RUNTIME_DIR/clip-synced"

# Present while syncing is paused. Lives in the runtime directory on purpose:
# a pause does not outlive the session.
PAUSE_FILE="$OMAKVM_RUNTIME_DIR/clip-paused"

# Last transfer, for the bar widget: "<epoch> <in|out> <mime> <bytes> <peer>".
LAST_FILE="$OMAKVM_RUNTIME_DIR/clip-last"

MIME_TEXT='text/plain;charset=utf-8'
MIME_PNG='image/png'

# Where this machine keeps the screen edge its peer sits on, for the peer to
# ask: a machine configured second takes the opposite edge without being told.
POSITION_FILE="$OMAKVM_CONFIG_DIR/position"

# lan-mouse does the keyboard and mouse sharing. Its certificate is this
# machine's identity for pairing; its config lists who may send input here.
LAN_MOUSE_PORT=4242
LAN_MOUSE_DIR="${OMAKVM_LAN_MOUSE_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/lan-mouse}"
LAN_MOUSE_CONFIG="$LAN_MOUSE_DIR/config.toml"
LAN_MOUSE_CERT="$LAN_MOUSE_DIR/lan-mouse.pem"

log() {
  printf '%s\n' "$*" >&2
}

# The runtime directory holds clipboard payloads in transit, so it must be
# ours and private.
ensure_runtime_dir() {
  mkdir -p -m 700 -- "$OMAKVM_RUNTIME_DIR" 2>/dev/null || return 1
  [[ -d $OMAKVM_RUNTIME_DIR && -O $OMAKVM_RUNTIME_DIR ]]
}

valid_ipv4() {
  [[ ${1:-} =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local octet
  for octet in "${BASH_REMATCH[@]:1:4}"; do
    ((10#$octet <= 255)) || return 1
  done
}

# Tailscale hands out addresses from 100.64.0.0/10. The relay does not encrypt
# on its own, so a peer has to be one of them.
tailscale_ipv4() {
  valid_ipv4 "${1:-}" || return 1
  local first second
  IFS=. read -r first second _ <<<"$1"
  ((10#$first == 100 && 10#$second >= 64 && 10#$second <= 127))
}

valid_position() {
  [[ ${1:-} == left || ${1:-} == right || ${1:-} == top || ${1:-} == bottom ]]
}

opposite_position() {
  case "${1:-}" in
  left) printf right ;;
  right) printf left ;;
  top) printf bottom ;;
  bottom) printf top ;;
  *) return 1 ;;
  esac
}

# The form lan-mouse prints and stores: 32 lowercase hex pairs.
valid_fingerprint() {
  [[ ${1:-} =~ ^([0-9a-f]{2}:){31}[0-9a-f]{2}$ ]]
}

valid_peer_name() {
  [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]]
}

# SHA-256 of the certificate, which is how lan-mouse derives the fingerprint
# it shows and checks.
own_fingerprint() {
  local fingerprint
  [[ -r $LAN_MOUSE_CERT ]] || return 1
  fingerprint=$(openssl x509 -in "$LAN_MOUSE_CERT" -noout -fingerprint -sha256 2>/dev/null) || return 1
  fingerprint="${fingerprint##*=}"
  fingerprint="${fingerprint,,}"
  valid_fingerprint "$fingerprint" || return 1
  printf '%s' "$fingerprint"
}

stored_position() {
  local position=
  [[ -r $POSITION_FILE ]] && read -r position <"$POSITION_FILE"
  valid_position "$position" || return 1
  printf '%s' "$position"
}

# "<address> <name>" of the first configured peer.
first_peer() {
  [[ -r $PEERS_FILE ]] || return 1
  local address name
  while read -r address name _ || [[ -n $address ]]; do
    [[ -z $address || $address == \#* ]] && continue
    valid_ipv4 "$address" || continue
    valid_peer_name "$name" || name=peer
    printf '%s %s\n' "$address" "$name"
    return 0
  done <"$PEERS_FILE"
  return 1
}

peer_addresses() {
  [[ -r $PEERS_FILE ]] || return 0
  local address _
  while read -r address _ || [[ -n $address ]]; do
    [[ -z $address || $address == \#* ]] && continue
    valid_ipv4 "$address" && printf '%s\n' "$address"
  done <"$PEERS_FILE"
}

peer_allowed() {
  local candidate="${1:-}" address
  [[ -n $candidate ]] || return 1
  while read -r address; do
    [[ $address == "$candidate" ]] && return 0
  done < <(peer_addresses)
  return 1
}

sha256_file() {
  local sum _
  read -r sum _ < <(sha256sum -- "$1") || return 1
  printf '%s' "$sum"
}

synced_sha() {
  local sum=
  [[ -r $SYNCED_FILE ]] && read -r sum <"$SYNCED_FILE"
  printf '%s' "$sum"
}

# Written through a temporary file so a reader never sees half a checksum.
write_state() {
  local file="$1" value="$2" tmp
  tmp=$(mktemp -- "$file.XXXXXX") || return 1
  printf '%s\n' "$value" >"$tmp" && mv -f -- "$tmp" "$file" || {
    rm -f -- "$tmp"
    return 1
  }
}

mark_synced() {
  write_state "$SYNCED_FILE" "$1"
}

record_transfer() {
  write_state "$LAST_FILE" "$(date +%s) $1 $2 $3 $4"
}

# Anything that came off the network is clipped and stripped of control
# characters before it reaches a log line.
printable() {
  local value="${1:0:80}"
  printf '%s' "${value//[^[:print:]]/?}"
}
