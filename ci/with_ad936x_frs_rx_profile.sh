#!/usr/bin/env bash
# Temporarily configure AD936x RX for the FRS receive image, run a caller's
# capture/server command, then restore the original RX configuration.
# Does not touch TX attributes, device-tree/SD files, or FPGA configuration.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ci/with_ad936x_frs_rx_profile.sh --uri URI [--apply] -- COMMAND [ARG ...]

Without --apply, this performs read-only preflight and prints the proposed
profile. With --apply, it temporarily sets RX LO=465125000 Hz, sample rate
6400000 Hz, and RF bandwidth=5600000 Hz while COMMAND runs, then restores the
original values on normal exit, error, INT, or TERM. RX gain mode/gain are
recorded but never modified. COMMAND inherits FRS_IIO_URI.

Example (after an FRS-compatible image is already loaded):
  ci/with_ad936x_frs_rx_profile.sh --uri usb: --apply -- \
    ./web_go/frs-web-armv7 -listen 0.0.0.0:8765 -source frs-iio \
    -iio-uri usb: -iio-device cf-ad9361-lpc \
    -iio-elements voltage0,voltage1,voltage2,voltage3

No FPGA load, TX operation, or SD-card write is performed by this helper.
EOF
}

uri=
apply=0
while (($#)); do
  case "$1" in
    --uri)
      (($# >= 2)) || { usage >&2; exit 2; }
      uri=$2
      shift 2
      ;;
    --apply)
      apply=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n $uri ]] || { echo '--uri is required' >&2; usage >&2; exit 2; }
(( $# > 0 )) || { echo 'A command after -- is required' >&2; usage >&2; exit 2; }
command -v iio_attr >/dev/null || { echo 'iio_attr is required (libiio CLI)' >&2; exit 1; }

phy=${FRS_IIO_PHY:-ad9361-phy}
rx_channel=${FRS_IIO_RX_CHANNEL:-voltage0}
target_lo=465125000
target_rate=6400000
target_bw=5600000

# iio_attr v0.26 syntax: -c DEVICE CHANNEL ATTR [VALUE] for channel attrs;
# -d DEVICE ATTR [VALUE] for device attrs. Omitting VALUE reads; supplying it
# writes. AD936x RX bandwidth is exposed on the RX voltage channel as
# `rf_bandwidth`, not as a device attr named `in_voltage_rf_bandwidth`.
read_channel_attr() { iio_attr -u "$uri" -i -c "$phy" "$rx_channel" "$1"; }
read_device_attr() { iio_attr -u "$uri" -d "$phy" "$1"; }
write_channel_attr() { iio_attr -u "$uri" -i -q -c "$phy" "$rx_channel" "$1" "$2"; }
write_device_attr() { iio_attr -q -u "$uri" -d "$phy" "$1" "$2"; }
read_rx_lo() { iio_attr -u "$uri" -c "$phy" altvoltage0 frequency; }
write_rx_lo() { iio_attr -u "$uri" -q -c "$phy" altvoltage0 frequency "$1"; }

original_lo=$(read_rx_lo)
original_rate=$(read_channel_attr sampling_frequency)
original_bw=$(read_channel_attr rf_bandwidth)
original_gain_mode=$(read_channel_attr gain_control_mode)
original_gain=$(read_channel_attr hardwaregain)

for pair in "LO:$original_lo" "sample-rate:$original_rate" "RF-bandwidth:$original_bw"; do
  name=${pair%%:*}
  value=${pair#*:}
  [[ $value =~ ^[0-9]+$ ]] || { echo "Unexpected $name readback: $value" >&2; exit 1; }
done
[[ -n $original_gain_mode && -n $original_gain ]] || {
  echo 'Could not read RX gain mode and hardware gain; refusing to proceed' >&2
  exit 1
}

printf 'board_uri=%s\nphy=%s\nrx_channel=%s\n' "$uri" "$phy" "$rx_channel"
printf 'saved_rx_lo_hz=%s\nsaved_sample_rate_hz=%s\nsaved_rf_bandwidth_hz=%s\n' \
  "$original_lo" "$original_rate" "$original_bw"
printf 'saved_rx_gain_mode=%s\nsaved_rx_hardware_gain=%s\n' \
  "$original_gain_mode" "$original_gain"
printf 'requested_rx_lo_hz=%s\nrequested_sample_rate_hz=%s\nrequested_rf_bandwidth_hz=%s\n' \
  "$target_lo" "$target_rate" "$target_bw"

if (( ! apply )); then
  echo 'Read-only preflight complete. Re-run with --apply to temporarily apply the profile.'
  exit 0
fi

if ! command -v iio_readdev >/dev/null; then
  echo 'iio_readdev is required for the requested live capture/server command' >&2
  exit 1
fi

restore_needed=0
restore_profile() {
  local exit_status=$? restore_failed=0
  trap - EXIT INT TERM
  if (( restore_needed )); then
    echo 'Restoring original AD936x RX LO, sample rate, and RF bandwidth...' >&2
    # Restore the prior sample rate before a possibly wider original RF filter.
    write_channel_attr sampling_frequency "$original_rate" || restore_failed=1
    write_channel_attr rf_bandwidth "$original_bw" || restore_failed=1
    write_rx_lo "$original_lo" || restore_failed=1
    [[ $(read_channel_attr sampling_frequency 2>/dev/null || true) == "$original_rate" ]] || restore_failed=1
    [[ $(read_channel_attr rf_bandwidth 2>/dev/null || true) == "$original_bw" ]] || restore_failed=1
    [[ $(read_rx_lo 2>/dev/null || true) == "$original_lo" ]] || restore_failed=1
    if (( restore_failed )); then
      echo 'ERROR: one or more original RX settings could not be restored/verified.' >&2
      exit_status=1
    else
      echo 'Original RX settings restored and verified.' >&2
    fi
  fi
  exit "$exit_status"
}
trap restore_profile EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Mark restoration necessary before the first write, so even a partial failure
# restores all three captured values.
restore_needed=1
# Lower RF filter first, then select the RTL-compatible IQ rate, then LO.
write_channel_attr rf_bandwidth "$target_bw"
write_channel_attr sampling_frequency "$target_rate"
write_rx_lo "$target_lo"

[[ $(read_channel_attr rf_bandwidth) == "$target_bw" ]] || {
  echo 'RF bandwidth readback did not match requested value' >&2; exit 1;
}
[[ $(read_channel_attr sampling_frequency) == "$target_rate" ]] || {
  echo 'Sample-rate readback did not match requested value' >&2; exit 1;
}
[[ $(read_rx_lo) == "$target_lo" ]] || {
  echo 'RX LO readback did not match requested value' >&2; exit 1;
}
[[ $(read_channel_attr gain_control_mode) == "$original_gain_mode" ]] || {
  echo 'RX gain mode changed unexpectedly; refusing to start test' >&2; exit 1;
}
echo 'FRS RX profile active; gain settings unchanged. Running command; Ctrl-C restores the original profile.' >&2
FRS_IIO_URI=$uri "$@"
