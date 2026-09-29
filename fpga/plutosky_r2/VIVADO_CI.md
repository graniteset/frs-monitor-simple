# Manual full-route Vivado CI

`.github/workflows/vivado-frs-route.yml` is an opt-in, manual-only workflow for
the licensed, on-demand `vivado` runner. It never loads an FPGA, accesses the
SD card, reboots the board, or runs on `push`/`pull_request`. It builds both
`FRS_TEST_MODE=0` (live RX) and `FRS_TEST_MODE=1` (synthetic IQ), sequentially.
Both profiles must pass routed setup and hold slack, zero total violations,
complete timing constraints, and the DRC critical-severity gate for the job to
pass. The `.bit` files, reports, logs, and SHA-256 checksums are retained as a
30-day Actions artifact. A failed route is still uploaded for diagnosis.

## Runner-provisioned inputs

The workflow deliberately does not download vendor sources or trust paths from
the repository checkout. It takes a disposable probe project directory, the
already-extracted CLG400 legacy source tree, and the generated ADI IP catalog
from the runner environment. The disposable directory must contain exactly
one `frs_clg400_probe.xpr`. Its XPR records old vendor-origin `ImportPath`
metadata under `../vendor/MyCore_7010_V3/...`, but the real build inputs are
self-contained copies under `$PSRCDIR`; preflight verifies those copied files
are present and byte-equivalent to the pinned CLG400 legacy archive wherever
the 2026.1-upgraded block design is not expected to be byte-identical. It
validates the design part and `ADC_INIT_DELAY=23` in both the block design and
AD9361 XCI, checks the required RX-to-DMA IP instances, and checks that every
referenced XCI exists. The newer `work/vendor/PlutoSky-R2` tree is CLG484 and
is deliberately not used for these imports. The ADI catalog must include
`axi_ad9361`, `axi_dmac`, `util_axis_fifo`, `util_cdc`, `util_rfifo`, and
`util_wfifo`.

Export these variables in the shell that starts the interactive runner:

| Variable | Required value |
| --- | --- |
| `FRS_VENDOR_STAGE_ROOT` | Absolute path to the disposable project directory containing exactly one `frs_clg400_probe.xpr` |
| `FRS_VENDOR_STAGE_SHA256` | SHA-256 of that project directory, computed by `ci/prepare_vivado_route_inputs.py`'s tree-digest algorithm |
| `FRS_VENDOR_LEGACY_ROOT` | Absolute path to the extracted CLG400 archive tree containing `library/` and `projects/` (typically its `pl_unpacked/` directory) |
| `FRS_ADI_IP_REPO` | Absolute path to the staged/generated ADI IP catalog, outside the checkout |
| `FRS_ADI_IP_REPO_SHA256` | SHA-256 of the complete ADI IP catalog tree |

The prep step copies the disposable project and catalog into the ephemeral
checkout. It accepts an unresolved old `ImportPath` only when that XPR entry's
`$PSRCDIR` copy exists and matches the pinned source from the CLG400 legacy
archive. It rejects wrong hashes, symlinks, unexpected/missing XPRs, missing
local source copies, a mismatched set of imports, absent required IP
definitions, missing BD/XCI products, a wrong part, or any AD9361 initial
delay other than 23. It does not modify the runner's source trees. Do not
compute or update the expected project/catalog hashes automatically at
workflow runtime; they pin the exact inputs reviewed for the build.

To compute tree hashes locally after provisioning the inputs:

```sh
python3 - <<'PY'
from pathlib import Path
from ci.prepare_vivado_route_inputs import tree_digest
print("vendor:", tree_digest(Path("/path/to/vendor-stage").resolve()))
print("ADI IP:", tree_digest(Path("/path/to/adi-ip-repo").resolve()))
PY
```

For example, after replacing the placeholder paths and digest strings with the
validated values, export them in that shell before `./run.sh`. The paths below
are examples only; do not paste them literally:

```sh
export FRS_VENDOR_STAGE_ROOT=/validated/complete/frs-vendor-stage
export FRS_VENDOR_STAGE_SHA256=replace-with-validated-vendor-tree-sha256
export FRS_VENDOR_LEGACY_ROOT=/validated/extracted-clg400-legacy-tree
export FRS_ADI_IP_REPO=/validated/adi-ip-catalog
export FRS_ADI_IP_REPO_SHA256=replace-with-validated-adi-tree-sha256
./run.sh
```

These are runner-process environment variables, not repository secrets. Protect
the `vivado-ooc` environment with required reviewers and branch restrictions;
the manually launched runner inherits these values.

## Running safely

Use **Actions → Vivado FRS routed builds → Run workflow** and select only a
reviewed branch permitted by the protected `vivado-ooc` environment. Type the
full selected commit SHA into `confirm_sha`; the workflow verifies it equals
the dispatch event SHA and checks out exactly that SHA with persisted Git
credentials disabled. Required environment approval happens before the job
starts. Then start the runner interactively on the licensed desktop and stop
it with Ctrl-C after the workflow finishes. Do not allow public fork or
pull-request code onto this self-hosted runner.

The workflow's timing parser requires nonnegative routed WNS and WHS, zero TNS
and THS / failing endpoints, zero unconstrained or partially constrained
timing checks, and no Critical Warning or Error rows in the DRC summary. A
candidate with incomplete provisional board I/O timing is expected to fail
closed; changing that gate requires reviewed timing evidence, not relaxing the
parser. This workflow provides build evidence only. Passing timing is not
permission to load the image; board programming remains a separate reviewed
manual action.
