#!/usr/bin/env bash
# Read-only USB SSH inventory of the booted PlutoSky/Z7020 board.
set -euo pipefail

board_ip=192.168.2.1
usb_interface=enp0s20f0u5
key_file=${SDR_CI_SSH_KEY:-$HOME/.ssh/frs_sdr_ci}
known_hosts_file=${SDR_CI_KNOWN_HOSTS:-$HOME/.ssh/frs_sdr_known_hosts}
out_dir=${1:-work/sdr-hil-inventory}
mkdir -p "$out_dir"

if [[ ! -r "$key_file" || ! -r "$known_hosts_file" ]]; then
  echo "CI SSH key or pinned known_hosts file is missing: $key_file / $known_hosts_file" >&2
  exit 1
fi

route=$(ip -4 route get "$board_ip")
printf '%s\n' "$route" | tee "$out_dir/route.txt"
if [[ ! $route =~ (^|[[:space:]])dev[[:space:]]$usb_interface($|[[:space:]]) ]]; then
  echo "Board route does not use the expected USB interface $usb_interface" >&2
  exit 1
fi

timeout 35s ssh -T -F /dev/null \
  -i "$key_file" \
  -o IdentitiesOnly=yes \
  -o BatchMode=yes \
  -o PreferredAuthentications=publickey \
  -o PasswordAuthentication=no \
  -o KbdInteractiveAuthentication=no \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$known_hosts_file" \
  -o ConnectTimeout=5 \
  -o ServerAliveInterval=5 \
  -o ServerAliveCountMax=2 \
  "root@$board_ip" sh -s <<'REMOTE' 2>&1 | tee "$out_dir/inventory.txt"
set -eu

model=$(tr -d '\000' </proc/device-tree/model)
printf 'model=%s\n' "$model"
if [ "$model" != 'Analog Devices PlutoSDR Rev.C (Z7020/AD9363)' ]; then
  echo 'Unexpected board model' >&2
  exit 1
fi

printf 'uname=%s\n' "$(uname -a)"
found_phy=0
device_count=0
for device in /sys/bus/iio/devices/iio:device*; do
  [ -r "$device/name" ] || continue
  name=$(cat "$device/name")
  printf 'iio_device=%s name=%s\n' "${device##*/}" "$name"
  device_count=$((device_count + 1))
  case "$name" in
    ad9361-phy|ad9363-phy) found_phy=1 ;;
  esac
  for attr in in_voltage_sampling_frequency in_voltage0_sampling_frequency \
    in_voltage_rf_bandwidth in_voltage0_rf_bandwidth; do
    if [ -r "$device/$attr" ]; then
      printf 'iio_attr=%s/%s value=%s\n' "${device##*/}" "$attr" "$(cat "$device/$attr")"
    fi
  done
done

printf 'iio_device_count=%s\n' "$device_count"
[ "$device_count" -gt 0 ] || { echo 'No IIO devices found' >&2; exit 1; }
[ "$found_phy" -eq 1 ] || { echo 'AD936x PHY not found in IIO inventory' >&2; exit 1; }
printf 'inventory_status=pass\n'
REMOTE

sha256sum "$out_dir/route.txt" "$out_dir/inventory.txt" > "$out_dir/SHA256SUMS"

# Exercise the board's existing AD936x-to-DMA receive path with a small,
# bounded capture. This reads RX samples only; it does not enable TX or alter
# radio configuration. Two signed 16-bit channels produce four bytes per
# complex sample, so 4096 samples must yield 16384 bytes.
if ! command -v iio_readdev >/dev/null 2>&1; then
  echo 'iio_readdev is required for the bounded AD9363 intake check' >&2
  exit 1
fi
capture_file=$(mktemp "${RUNNER_TEMP:-/tmp}/frs-ad9363-rx.XXXXXX")
trap 'rm -f "$capture_file"' EXIT
timeout 20s iio_readdev \
  -u "ip:$board_ip" -b 16 -s 4096 cf-ad9361-lpc voltage0 voltage1 \
  > "$capture_file"
capture_bytes=$(wc -c < "$capture_file")
if [[ $capture_bytes -ne 16384 ]]; then
  echo "AD9363 RX capture size mismatch: got $capture_bytes bytes; expected 16384" >&2
  exit 1
fi
nonzero_bytes=$(od -An -tu1 -v "$capture_file" | awk '{for (i=1; i<=NF; i++) if ($i != 0) n++} END {print n+0}')
if [[ $nonzero_bytes -eq 0 ]]; then
  echo 'AD9363 RX capture contains only zero bytes' >&2
  exit 1
fi
capture_sha256=$(sha256sum "$capture_file" | awk '{print $1}')
printf 'ad9363_capture_samples=4096\nad9363_capture_bytes=%s\nad9363_capture_nonzero_bytes=%s\nad9363_capture_sha256=%s\n' \
  "$capture_bytes" "$nonzero_bytes" "$capture_sha256" \
  | tee "$out_dir/capture.txt"
sha256sum "$out_dir/capture.txt" >> "$out_dir/SHA256SUMS"
