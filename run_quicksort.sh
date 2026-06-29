#!/usr/bin/env bash

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELF_FILE="${ELF_FILE:-${SCRIPT_DIR}/quicksort.elf}"

EXPECTED_CHECKSUM="${EXPECTED_CHECKSUM:-2825881671}"

OPENOCD_HOST="${OPENOCD_HOST:-127.0.0.1}"
OPENOCD_PORT="${OPENOCD_PORT:-3333}"

GDB_TIMEOUT="${GDB_TIMEOUT:-30}"

GDB_LOG="${SCRIPT_DIR}/gdb_quicksort.log"
GDB_COMMAND_FILE=""

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

info()
{
    printf '[INFO] %s\n' "$1"
}

warn()
{
    printf '[WARN] %s\n' "$1" >&2
}

pass()
{
    printf '[PASS] %s\n' "$1"
}

fail()
{
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

cleanup()
{
    if [[ -n "${GDB_COMMAND_FILE}" && -f "${GDB_COMMAND_FILE}" ]]; then
        rm -f "${GDB_COMMAND_FILE}"
    fi
}

command_exists()
{
    command -v "$1" >/dev/null 2>&1
}

openocd_is_running()
{
    (
        echo >"/dev/tcp/${OPENOCD_HOST}/${OPENOCD_PORT}"
    ) >/dev/null 2>&1
}

find_symbol_address()
{
    local symbol_name="$1"
    local symbol_address

    symbol_address="$(
        arm-none-eabi-nm -n "${ELF_FILE}" |
        awk -v symbol="${symbol_name}" \
            '$3 == symbol { print $1; exit }'
    )"

    if [[ -z "${symbol_address}" ]]; then
        return 1
    fi

    printf '0x%s\n' "${symbol_address}"
}

# ---------------------------------------------------------------------------
# Cleanup registration
# ---------------------------------------------------------------------------

trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------

info "Checking dependencies..."

command_exists gdb-multiarch ||
    fail "gdb-multiarch was not found in PATH."

command_exists arm-none-eabi-nm ||
    fail "arm-none-eabi-nm was not found in PATH."

command_exists timeout ||
    fail "timeout was not found in PATH."

[[ -f "${ELF_FILE}" ]] ||
    fail "ELF file not found: ${ELF_FILE}"

# ---------------------------------------------------------------------------
# OpenOCD connection check
# ---------------------------------------------------------------------------

info "Checking for OpenOCD on ${OPENOCD_HOST}:${OPENOCD_PORT}..."

if ! openocd_is_running; then
    fail "OpenOCD is not running.

Start OpenOCD in another terminal with:

  sudo openocd -f interface/cmsis-dap.cfg -f target/rp2040.cfg

Then run this script again."
fi

info "OpenOCD connection detected."

# ---------------------------------------------------------------------------
# Find benchmark symbols
# ---------------------------------------------------------------------------

info "Finding benchmark symbols..."

DONE_ADDRESS="$(find_symbol_address benchmark_done)" ||
    fail "Could not find symbol: benchmark_done"

RESULT_ADDRESS="$(find_symbol_address benchmark_result)" ||
    fail "Could not find symbol: benchmark_result"

info "benchmark_done address:   ${DONE_ADDRESS}"
info "benchmark_result address: ${RESULT_ADDRESS}"
info "Expected checksum:        ${EXPECTED_CHECKSUM}"

# ---------------------------------------------------------------------------
# Prepare GDB log and command file
# ---------------------------------------------------------------------------

: >"${GDB_LOG}"

GDB_COMMAND_FILE="$(mktemp)"

cat >"${GDB_COMMAND_FILE}" <<EOF
set pagination off
set confirm off
set verbose off

target extended-remote ${OPENOCD_HOST}:${OPENOCD_PORT}

monitor reset halt
load
monitor reset halt

set \$done_addr = ${DONE_ADDRESS}
set \$result_addr = ${RESULT_ADDRESS}

set *(unsigned int *)\$done_addr = 0

watch *(unsigned int *)\$done_addr
continue

set \$observed_done = *(unsigned int *)\$done_addr
set \$observed_result = *(unsigned int *)\$result_addr

printf "PICO_DONE=%u\n", \$observed_done
printf "PICO_CHECKSUM=%u\n", \$observed_result

delete 1
monitor halt
EOF

# ---------------------------------------------------------------------------
# Run GDB
# ---------------------------------------------------------------------------

info "Loading and running quicksort.elf..."

set +e

timeout "${GDB_TIMEOUT}" \
    gdb-multiarch \
    --batch \
    --quiet \
    -x "${GDB_COMMAND_FILE}" \
    "${ELF_FILE}" \
    2>&1 | tee "${GDB_LOG}"

GDB_EXIT_STATUS=${PIPESTATUS[0]}

set -e

# ---------------------------------------------------------------------------
# Extract benchmark result
# ---------------------------------------------------------------------------

OBSERVED_DONE="$(
    awk -F= '
        /PICO_DONE=[0-9]+/ {
            value=$2
        }
        END {
            print value
        }
    ' "${GDB_LOG}"
)"

OBSERVED_CHECKSUM="$(
    awk -F= '
        /PICO_CHECKSUM=[0-9]+/ {
            value=$2
        }
        END {
            print value
        }
    ' "${GDB_LOG}"
)"

# ---------------------------------------------------------------------------
# Handle GDB failures
# ---------------------------------------------------------------------------

if [[ "${GDB_EXIT_STATUS}" -eq 124 ]]; then
    fail "GDB timed out after ${GDB_TIMEOUT} seconds. The benchmark may have hung."
fi

if [[ "${GDB_EXIT_STATUS}" -ne 0 ]]; then
    if [[ -n "${OBSERVED_DONE}" && -n "${OBSERVED_CHECKSUM}" ]]; then
        warn "GDB exited with status ${GDB_EXIT_STATUS} after producing a complete benchmark result."
    else
        fail "GDB failed with exit status ${GDB_EXIT_STATUS}. See ${GDB_LOG}."
    fi
fi

[[ -n "${OBSERVED_DONE}" ]] ||
    fail "GDB did not report benchmark_done."

[[ -n "${OBSERVED_CHECKSUM}" ]] ||
    fail "GDB did not report benchmark_result."

# ---------------------------------------------------------------------------
# Verify benchmark output
# ---------------------------------------------------------------------------

echo
echo "----------------------------------------"
echo "Quicksort verification"
echo "----------------------------------------"
echo "benchmark_done:    ${OBSERVED_DONE}"
echo "Expected checksum: ${EXPECTED_CHECKSUM}"
echo "Observed checksum: ${OBSERVED_CHECKSUM}"
echo "----------------------------------------"

if [[ "${OBSERVED_DONE}" != "1" ]]; then
    fail "The benchmark did not report successful completion."
fi

if [[ "${OBSERVED_CHECKSUM}" != "${EXPECTED_CHECKSUM}" ]]; then
    fail "Quicksort checksum does not match the expected value."
fi

pass "Quicksort completed and produced the correct checksum."
