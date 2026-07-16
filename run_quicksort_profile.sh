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
PROFILE_TIMEOUT="${PROFILE_TIMEOUT:-10}"

GDB_LOG="${SCRIPT_DIR}/gdb_quicksort_profile.log"
SRAM_MAP_FILE="${SCRIPT_DIR}/sram_symbols_quicksort.txt"
TARGET_REGIONS_FILE="${SCRIPT_DIR}/target_regions_quicksort.csv"

GDB_COMMAND_FILE=""

# RP2040 SRAM range: 264 KB
SRAM_START_HEX="${SRAM_START_HEX:-0x20000000}"
SRAM_END_HEX="${SRAM_END_HEX:-0x20042000}"
STACK_TOP_HEX="${STACK_TOP_HEX:-0x20042000}"

# Array symbol to display after the benchmark completes.
# Change this if your global quicksort array has a different name.
ARRAY_SYMBOL="${ARRAY_SYMBOL:-data}"

# If ARRAY_LEN is not provided, the script tries to infer it from symbol size.
ARRAY_LEN="${ARRAY_LEN:-}"

# Candidate functions to profile.
# "data" will be skipped automatically if it is not a function symbol.
if [[ -n "${PROFILE_FUNCTIONS:-}" ]]; then
    read -r -a CANDIDATE_FUNCTIONS <<< "${PROFILE_FUNCTIONS}"
else
    CANDIDATE_FUNCTIONS=(data swap_int partition quickSort print_array)
fi

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
        arm-none-eabi-nm -S -n "${ELF_FILE}" |
        awk -v symbol="${symbol_name}" \
            '$4 == symbol { print $1; exit }'
    )"

    if [[ -z "${symbol_address}" ]]; then
        return 1
    fi

    printf '0x%s\n' "${symbol_address}"
}

find_symbol_size_hex()
{
    local symbol_name="$1"
    local symbol_size

    symbol_size="$(
        arm-none-eabi-nm -S -n "${ELF_FILE}" |
        awk -v symbol="${symbol_name}" \
            '$4 == symbol { print $2; exit }'
    )"

    if [[ -z "${symbol_size}" ]]; then
        return 1
    fi

    printf '%s\n' "${symbol_size}"
}

function_symbol_exists()
{
    local function_name="$1"

    arm-none-eabi-nm -C "${ELF_FILE}" |
    awk -v target="${function_name}" '
        ($2 ~ /^[TtWw]$/) {
            name = $0
            sub(/^[0-9a-fA-F]+[[:space:]]+[A-Za-z][[:space:]]+/, "", name)

            if (name == target || name ~ "^" target "\\(") {
                found = 1
                exit
            }
        }

        END {
            exit !found
        }
    '
}

write_static_sram_map()
{
    : > "${SRAM_MAP_FILE}"

    printf "%-12s %-12s %-10s %-6s %s\n" \
        "START" "END" "SIZE" "TYPE" "SYMBOL" >> "${SRAM_MAP_FILE}"

    arm-none-eabi-nm -S -n "${ELF_FILE}" |
    while read -r addr size sym_type name rest; do
        [[ -n "${addr:-}" ]] || continue
        [[ -n "${size:-}" ]] || continue
        [[ -n "${sym_type:-}" ]] || continue
        [[ -n "${name:-}" ]] || continue

        [[ "${addr}" =~ ^[0-9a-fA-F]+$ ]] || continue
        [[ "${size}" =~ ^[0-9a-fA-F]+$ ]] || continue

        addr_dec=$((16#${addr}))
        size_dec=$((16#${size}))
        sram_start_dec=$((SRAM_START_HEX))
        sram_end_dec=$((SRAM_END_HEX))

        if (( addr_dec >= sram_start_dec && addr_dec < sram_end_dec && size_dec > 0 )); then
            end_dec=$((addr_dec + size_dec - 1))

            printf "0x%08x 0x%08x %-10d %-6s %s\n" \
                "${addr_dec}" "${end_dec}" "${size_dec}" "${sym_type}" "${name}" \
                >> "${SRAM_MAP_FILE}"
        fi
    done
}

extract_last_value()
{
    local key="$1"
    local file="$2"

    awk -F= -v key="${key}" '
        $1 == key {
            value = $2
        }
        END {
            print value
        }
    ' "${file}"
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
# Static SRAM map
# ---------------------------------------------------------------------------

info "Building static SRAM symbol map from quicksort.elf..."

write_static_sram_map

echo
echo "----------------------------------------"
echo "Static SRAM Symbols from ELF"
echo "----------------------------------------"
cat "${SRAM_MAP_FILE}"
echo "----------------------------------------"
echo

# ---------------------------------------------------------------------------
# Required benchmark symbols
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
# Optional array symbol
# ---------------------------------------------------------------------------

ARRAY_ADDRESS=""
ARRAY_SIZE_BYTES=""

if ARRAY_ADDRESS="$(find_symbol_address "${ARRAY_SYMBOL}" 2>/dev/null)"; then
    ARRAY_SIZE_HEX="$(find_symbol_size_hex "${ARRAY_SYMBOL}" 2>/dev/null || true)"

    if [[ -n "${ARRAY_SIZE_HEX}" ]]; then
        ARRAY_SIZE_BYTES="$((16#${ARRAY_SIZE_HEX}))"

        if [[ -z "${ARRAY_LEN}" ]]; then
            ARRAY_LEN="$((ARRAY_SIZE_BYTES / 4))"
        fi
    fi

    info "Array symbol:             ${ARRAY_SYMBOL}"
    info "Array address:            ${ARRAY_ADDRESS}"
    info "Array size bytes:         ${ARRAY_SIZE_BYTES:-unknown}"
    info "Array length:             ${ARRAY_LEN:-unknown}"
else
    warn "Could not find array symbol '${ARRAY_SYMBOL}'. Array display will be skipped."
fi

# ---------------------------------------------------------------------------
# Prepare log files
# ---------------------------------------------------------------------------

: > "${GDB_LOG}"

# ---------------------------------------------------------------------------
# Baseline run: load ELF, run to benchmark_done, read checksum and array
# ---------------------------------------------------------------------------

info "Running quicksort once to completion and collecting final program state..."

GDB_COMMAND_FILE="$(mktemp)"

cat > "${GDB_COMMAND_FILE}" <<EOF
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

printf "PROFILE_COMPLETION_PC=0x%x\n", \$pc
printf "PROFILE_COMPLETION_MSP=0x%x\n", \$msp
printf "PICO_DONE=%u\n", \$observed_done
printf "PICO_CHECKSUM=%u\n", \$observed_result
EOF

if [[ -n "${ARRAY_ADDRESS}" && -n "${ARRAY_LEN}" ]]; then
    cat >> "${GDB_COMMAND_FILE}" <<EOF

printf "PICO_ARRAY="
set \$i = 0
while \$i < ${ARRAY_LEN}
    set \$array_value = *(int *)(${ARRAY_ADDRESS} + (\$i * 4))

    if \$i == 0
        printf "%d", \$array_value
    else
        printf " %d", \$array_value
    end

    set \$i = \$i + 1
end
printf "\n"
EOF
fi

cat >> "${GDB_COMMAND_FILE}" <<EOF

monitor halt
EOF

BASELINE_OUTPUT="$(mktemp)"

set +e

timeout "${GDB_TIMEOUT}" \
    gdb-multiarch \
    --batch \
    --quiet \
    -x "${GDB_COMMAND_FILE}" \
    "${ELF_FILE}" \
    > "${BASELINE_OUTPUT}" 2>&1

BASELINE_STATUS=$?

set -e

cat "${BASELINE_OUTPUT}" >> "${GDB_LOG}"

if [[ "${BASELINE_STATUS}" -eq 124 ]]; then
    cat "${BASELINE_OUTPUT}"
    rm -f "${BASELINE_OUTPUT}"
    fail "Baseline GDB run timed out after ${GDB_TIMEOUT} seconds."
fi

if [[ "${BASELINE_STATUS}" -ne 0 ]]; then
    cat "${BASELINE_OUTPUT}"
    rm -f "${BASELINE_OUTPUT}"
    fail "Baseline GDB run failed with status ${BASELINE_STATUS}."
fi

echo
echo "----------------------------------------"
echo "Final Quicksort State"
echo "----------------------------------------"
grep -E 'PROFILE_COMPLETION_PC=|PROFILE_COMPLETION_MSP=|PICO_DONE=|PICO_CHECKSUM=|PICO_ARRAY=' "${BASELINE_OUTPUT}" || true
echo "----------------------------------------"

rm -f "${BASELINE_OUTPUT}"
rm -f "${GDB_COMMAND_FILE}"
GDB_COMMAND_FILE=""

# ---------------------------------------------------------------------------
# Profile candidate functions one at a time
# ---------------------------------------------------------------------------

echo
echo "----------------------------------------"
echo "Function Entry Profile"
echo "----------------------------------------"

VALID_FUNCTIONS=()

for func in "${CANDIDATE_FUNCTIONS[@]}"; do
    if function_symbol_exists "${func}"; then
        VALID_FUNCTIONS+=("${func}")
    else
        warn "Skipping candidate because it is not a function symbol: ${func}"
    fi
done

if (( ${#VALID_FUNCTIONS[@]} == 0 )); then
    warn "No valid function symbols found for profiling."
else
    for func in "${VALID_FUNCTIONS[@]}"; do
        PROFILE_CMD="$(mktemp)"
        PROFILE_OUT="$(mktemp)"

        cat > "${PROFILE_CMD}" <<EOF
set pagination off
set confirm off
set verbose off
set breakpoint pending off

target extended-remote ${OPENOCD_HOST}:${OPENOCD_PORT}

monitor reset halt

set \$done_addr = ${DONE_ADDRESS}
set *(unsigned int *)\$done_addr = 0

tbreak ${func}
continue

printf "PROFILE_HIT=${func} PC=0x%x MSP=0x%x STACK_TOP=${STACK_TOP_HEX}\n", \$pc, \$msp

monitor halt
EOF

        set +e

        timeout "${PROFILE_TIMEOUT}" \
            gdb-multiarch \
            --batch \
            --quiet \
            -x "${PROFILE_CMD}" \
            "${ELF_FILE}" \
            > "${PROFILE_OUT}" 2>&1

        PROFILE_STATUS=$?

        set -e

        cat "${PROFILE_OUT}" >> "${GDB_LOG}"

        HIT_LINE="$(grep 'PROFILE_HIT=' "${PROFILE_OUT}" | tail -n 1 || true)"

        if [[ -n "${HIT_LINE}" ]]; then
            echo "${HIT_LINE}"
        elif [[ "${PROFILE_STATUS}" -eq 124 ]]; then
            echo "PROFILE_MISS=${func} REASON=timeout_or_not_reached"
        else
            echo "PROFILE_ERROR=${func} STATUS=${PROFILE_STATUS}"
        fi

        rm -f "${PROFILE_CMD}" "${PROFILE_OUT}"
    done
fi

echo "----------------------------------------"

# ---------------------------------------------------------------------------
# Compute observed stack window
# ---------------------------------------------------------------------------

MIN_MSP_DEC=""

while read -r msp_token; do
    msp_hex="${msp_token#MSP=}"
    msp_dec=$((msp_hex))

    if [[ -z "${MIN_MSP_DEC}" || "${msp_dec}" -lt "${MIN_MSP_DEC}" ]]; then
        MIN_MSP_DEC="${msp_dec}"
    fi
done < <(grep -oE 'MSP=0x[0-9a-fA-F]+' "${GDB_LOG}" || true)

echo
echo "----------------------------------------"
echo "Observed Runtime SRAM Information"
echo "----------------------------------------"

if [[ -n "${MIN_MSP_DEC}" ]]; then
    STACK_TOP_DEC=$((STACK_TOP_HEX))
    STACK_USED_BYTES=$((STACK_TOP_DEC - MIN_MSP_DEC))

    printf "Lowest observed MSP:     0x%08x\n" "${MIN_MSP_DEC}"
    printf "Stack top estimate:      0x%08x\n" "${STACK_TOP_DEC}"
    printf "Observed stack window:   0x%08x - 0x%08x\n" \
        "${MIN_MSP_DEC}" "$((STACK_TOP_DEC - 1))"
    printf "Observed stack bytes:    %d\n" "${STACK_USED_BYTES}"
else
    echo "No MSP values were observed."
fi

echo "----------------------------------------"

# ---------------------------------------------------------------------------
# Write future target-region file
# ---------------------------------------------------------------------------

{
    echo "region_type,name,start,end,size_bytes"

    tail -n +2 "${SRAM_MAP_FILE}" |
    while read -r start end size sym_type name; do
        [[ -n "${start:-}" ]] || continue
        [[ -n "${end:-}" ]] || continue
        [[ -n "${size:-}" ]] || continue
        [[ -n "${name:-}" ]] || continue

        echo "static_symbol,${name},${start},${end},${size}"
    done

    if [[ -n "${MIN_MSP_DEC}" ]]; then
        STACK_TOP_DEC=$((STACK_TOP_HEX))
        STACK_USED_BYTES=$((STACK_TOP_DEC - MIN_MSP_DEC))

        printf "observed_stack,active_stack_window,0x%08x,0x%08x,%d\n" \
            "${MIN_MSP_DEC}" "$((STACK_TOP_DEC - 1))" "${STACK_USED_BYTES}"
    fi
} > "${TARGET_REGIONS_FILE}"

echo
echo "----------------------------------------"
echo "Generated Files"
echo "----------------------------------------"
echo "GDB log:              ${GDB_LOG}"
echo "Static SRAM map:      ${SRAM_MAP_FILE}"
echo "Target regions CSV:   ${TARGET_REGIONS_FILE}"
echo "----------------------------------------"

# ---------------------------------------------------------------------------
# Final classification
# ---------------------------------------------------------------------------

OBSERVED_DONE="$(extract_last_value PICO_DONE "${GDB_LOG}")"
OBSERVED_CHECKSUM="$(extract_last_value PICO_CHECKSUM "${GDB_LOG}")"
PICO_ARRAY_LINE="$(grep 'PICO_ARRAY=' "${GDB_LOG}" | tail -n 1 || true)"

echo
echo "----------------------------------------"
echo "Inspection Summary"
echo "----------------------------------------"
echo "benchmark_done:      ${OBSERVED_DONE:-N/A}"
echo "Expected checksum:   ${EXPECTED_CHECKSUM}"
echo "Observed checksum:   ${OBSERVED_CHECKSUM:-N/A}"

if [[ -n "${PICO_ARRAY_LINE}" ]]; then
    echo "${PICO_ARRAY_LINE}"
fi

if [[ "${OBSERVED_DONE:-}" == "1" && "${OBSERVED_CHECKSUM:-}" == "${EXPECTED_CHECKSUM}" ]]; then
    echo "Outcome:             PASS"
    echo "FI strategy:    target static symbols and observed stack window"
    exit 0
elif [[ "${OBSERVED_DONE:-}" == "1" ]]; then
    echo "Outcome:             CHECKSUM_MISMATCH"
    exit 1
else
    echo "Outcome:             INCOMPLETE"
    exit 1
fi
