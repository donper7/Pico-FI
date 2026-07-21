#!/usr/bin/env bash

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Profile-guided SRAM fault injection for quicksort.elf on Raspberry Pi Pico
#
# Usage:
#   ./run_profile_quicksort_fi.sh
#   ./run_profile_quicksort_fi.sh data-array
#   ./run_profile_quicksort_fi.sh active-stack
#   ./run_profile_quicksort_fi.sh static-sram-regions
#   ./run_profile_quicksort_fi.sh full-sram
#
# With no target-region argument, the script randomly chooses data-array or
# active-stack. The selected byte address is recorded before the write as the
# original_address. GDB then reports the address actually written as the
# fault_address. These addresses should match.
#
# OpenOCD must already be running in another terminal:
#
#   sudo openocd -f interface/cmsis-dap.cfg -f target/rp2040.cfg
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELF_FILE="${ELF_FILE:-${SCRIPT_DIR}/quicksort.elf}"
EXPECTED_CHECKSUM="${EXPECTED_CHECKSUM:-2825881671}"

OPENOCD_HOST="${OPENOCD_HOST:-127.0.0.1}"
OPENOCD_PORT="${OPENOCD_PORT:-3333}"
GDB_TIMEOUT="${GDB_TIMEOUT:-30}"

GDB_LOG="${GDB_LOG:-${SCRIPT_DIR}/gdb_profile_quicksort_fi.log}"
CSV_LOG="${CSV_LOG:-${SCRIPT_DIR}/profile_quicksort_fi_results.csv}"
GDB_COMMAND_FILE=""

# RP2040 main SRAM is 264 KiB: [0x20000000, 0x20042000).
SRAM_START_HEX="${SRAM_START_HEX:-0x20000000}"
SRAM_END_HEX="${SRAM_END_HEX:-0x20042000}"
STACK_TOP_HEX="${STACK_TOP_HEX:-0x20042000}"

ARRAY_SYMBOL="${ARRAY_SYMBOL:-data}"
ARRAY_LEN="${ARRAY_LEN:-}"

# Application-owned static SRAM allowlist. Separate names with spaces or commas.
# Add future application symbols here or through the environment, for example:
#   STATIC_SRAM_SYMBOLS="data application_state work_buffer" \
#       ./run_profile_quicksort_fi.sh static-sram-regions
STATIC_SRAM_SYMBOLS_RAW="${STATIC_SRAM_SYMBOLS:-data}"

# Extra symbols to exclude from full-sram mode. benchmark_done and
# benchmark_result are always protected because Pico-FI uses them to classify
# the run. Separate additional names with spaces or commas.
PROTECTED_SYMBOLS_RAW="${PROTECTED_SYMBOLS:-}"
FULL_SRAM_MAX_SELECTION_ATTEMPTS="${FULL_SRAM_MAX_SELECTION_ATTEMPTS:-10000}"

# Candidate function symbols used only to trigger the injection time.
if [[ -n "${PROFILE_FUNCTIONS:-}" ]]; then
    read -r -a CANDIDATE_FUNCTIONS <<< "${PROFILE_FUNCTIONS//,/ }"
else
    CANDIDATE_FUNCTIONS=(swap_int partition quickSort print_array)
fi

# Backward-compatible environment variable. A positional argument takes
# precedence over FI_MEM_SCOPE.
REQUESTED_SCOPE_RAW="${1:-${FI_MEM_SCOPE:-random-default}}"

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

print_usage()
{
    cat <<'USAGE_EOF'
Usage:
  ./run_profile_quicksort_fi.sh [target-region]

Target regions:
  random-default       Randomly choose data-array or active-stack (default)
  data-array           Inject into the quicksort data[] array
  active-stack         Inject into the live stack window at the breakpoint
  static-sram-regions  Inject into an allowlisted application SRAM symbol
  full-sram            Inject across RP2040 main SRAM, excluding protected data

Accepted legacy aliases:
  profile_guided, profile-guided, data_array, current_stack

Examples:
  ./run_profile_quicksort_fi.sh
  ./run_profile_quicksort_fi.sh data-array
  ./run_profile_quicksort_fi.sh active-stack
  STATIC_SRAM_SYMBOLS="data" ./run_profile_quicksort_fi.sh static-sram-regions
  ./run_profile_quicksort_fi.sh full-sram
USAGE_EOF
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

rand_u32()
{
    od -An -N4 -tu4 /dev/urandom | tr -d ' '
}

rand_range()
{
    local max="$1"
    local value

    if (( max <= 0 )); then
        fail "rand_range called with invalid max=${max}"
    fi

    value="$(rand_u32)"
    printf '%u\n' "$(( value % max ))"
}

format_hex32()
{
    printf '0x%08x\n' "$1"
}

normalize_scope()
{
    local scope="${1,,}"

    case "${scope}" in
        ""|random|random-default|random_default|profile-guided|profile_guided)
            printf 'random-default\n'
            ;;
        data-array|data_array|array)
            printf 'data-array\n'
            ;;
        active-stack|active_stack|current-stack|current_stack|stack)
            printf 'active-stack\n'
            ;;
        static-sram-regions|static_sram_regions|static-sram|static_sram)
            printf 'static-sram-regions\n'
            ;;
        full-sram|full_sram)
            printf 'full-sram\n'
            ;;
        -h|--help|help)
            printf 'help\n'
            ;;
        *)
            return 1
            ;;
    esac
}

find_symbol_address()
{
    local symbol_name="$1"
    local symbol_address

    symbol_address="$(
        arm-none-eabi-nm -S -n "${ELF_FILE}" |
        awk -v symbol="${symbol_name}" '$4 == symbol { print $1; exit }'
    )"

    [[ -n "${symbol_address}" ]] || return 1
    printf '0x%s\n' "${symbol_address}"
}

find_symbol_size_hex()
{
    local symbol_name="$1"
    local symbol_size

    symbol_size="$(
        arm-none-eabi-nm -S -n "${ELF_FILE}" |
        awk -v symbol="${symbol_name}" '$4 == symbol { print $2; exit }'
    )"

    [[ -n "${symbol_size}" ]] || return 1
    printf '%s\n' "${symbol_size}"
}

find_symbol_type()
{
    local symbol_name="$1"
    local symbol_type

    symbol_type="$(
        arm-none-eabi-nm -S -n "${ELF_FILE}" |
        awk -v symbol="${symbol_name}" '$4 == symbol { print $3; exit }'
    )"

    [[ -n "${symbol_type}" ]] || return 1
    printf '%s\n' "${symbol_type}"
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

csv_escape()
{
    local value="${1:-}"

    value="${value//$'\n'/ }"
    value="${value//$'\r'/ }"
    value="${value//\"/\"\"}"
    printf '"%s"' "${value}"
}

hex_values_match()
{
    local first="$1"
    local second="$2"

    [[ "${first}" =~ ^0[xX][0-9a-fA-F]+$ ]] || return 1
    [[ "${second}" =~ ^0[xX][0-9a-fA-F]+$ ]] || return 1
    (( first == second ))
}

choose_selected_scope()
{
    case "${REQUESTED_SCOPE}" in
        random-default)
            if (( $(rand_range 2) == 0 )); then
                printf 'data-array\n'
            else
                printf 'active-stack\n'
            fi
            ;;
        data-array|active-stack|static-sram-regions|full-sram)
            printf '%s\n' "${REQUESTED_SCOPE}"
            ;;
        *)
            fail "Internal error: unsupported normalized scope '${REQUESTED_SCOPE}'."
            ;;
    esac
}

# Globals populated by build_protected_ranges().
declare -a PROTECTED_RANGE_NAMES=()
declare -a PROTECTED_RANGE_STARTS=()
declare -a PROTECTED_RANGE_ENDS=()

build_protected_ranges()
{
    local combined="benchmark_done benchmark_result ${PROTECTED_SYMBOLS_RAW//,/ }"
    local -a symbols=()
    local symbol address size_hex size_dec start_dec end_dec

    read -r -a symbols <<< "${combined}"

    for symbol in "${symbols[@]}"; do
        [[ -n "${symbol}" ]] || continue

        address="$(find_symbol_address "${symbol}" 2>/dev/null || true)"
        size_hex="$(find_symbol_size_hex "${symbol}" 2>/dev/null || true)"

        if [[ -z "${address}" ]]; then
            warn "Protected symbol not found and will be skipped: ${symbol}"
            continue
        fi

        if [[ -n "${size_hex}" ]]; then
            size_dec="$((16#${size_hex}))"
        else
            size_dec=4
        fi

        (( size_dec > 0 )) || size_dec=1
        start_dec="$((address))"
        end_dec="$((start_dec + size_dec - 1))"

        PROTECTED_RANGE_NAMES+=("${symbol}")
        PROTECTED_RANGE_STARTS+=("${start_dec}")
        PROTECTED_RANGE_ENDS+=("${end_dec}")
    done
}

address_is_protected()
{
    local address_dec="$1"
    local i

    for ((i = 0; i < ${#PROTECTED_RANGE_STARTS[@]}; i++)); do
        if (( address_dec >= PROTECTED_RANGE_STARTS[i] &&
              address_dec <= PROTECTED_RANGE_ENDS[i] )); then
            return 0
        fi
    done

    return 1
}

prepare_data_array_target()
{
    FI_OFFSET="$(rand_range "${ARRAY_SIZE_BYTES}")"
    FI_SELECTED_ADDRESS_DEC="$((ARRAY_START_DEC + FI_OFFSET))"
    FI_SELECTED_ADDRESS_HEX="$(format_hex32 "${FI_SELECTED_ADDRESS_DEC}")"
    FI_REGION_NAME="${ARRAY_SYMBOL}"
    FI_REGION_START="${ARRAY_ADDRESS}"
    FI_REGION_END="${ARRAY_END_HEX}"
    FI_REGION_SIZE="${ARRAY_SIZE_BYTES}"
}

prepare_static_sram_target()
{
    local raw_symbols="${STATIC_SRAM_SYMBOLS_RAW//,/ }"
    local -a symbols=()
    local -a names=()
    local -a starts=()
    local -a sizes=()
    local symbol address size_hex size_dec start_dec end_dec type
    local total_bytes=0
    local selected_linear_offset remaining i

    read -r -a symbols <<< "${raw_symbols}"

    for symbol in "${symbols[@]}"; do
        [[ -n "${symbol}" ]] || continue

        address="$(find_symbol_address "${symbol}" 2>/dev/null || true)"
        size_hex="$(find_symbol_size_hex "${symbol}" 2>/dev/null || true)"
        type="$(find_symbol_type "${symbol}" 2>/dev/null || true)"

        if [[ -z "${address}" || -z "${size_hex}" ]]; then
            warn "Static SRAM symbol not found or has no size; skipping: ${symbol}"
            continue
        fi

        case "${type}" in
            B|b|D|d|S|s|G|g|C|c|V|v)
                ;;
            *)
                warn "Symbol is not a recognized static-data type; skipping ${symbol} (type ${type:-unknown})."
                continue
                ;;
        esac

        size_dec="$((16#${size_hex}))"
        start_dec="$((address))"
        end_dec="$((start_dec + size_dec - 1))"

        if (( size_dec <= 0 )); then
            warn "Static SRAM symbol has zero size; skipping: ${symbol}"
            continue
        fi

        if (( start_dec < SRAM_START_DEC || end_dec >= SRAM_END_DEC )); then
            warn "Static symbol is outside configured SRAM; skipping: ${symbol}"
            continue
        fi

        names+=("${symbol}")
        starts+=("${start_dec}")
        sizes+=("${size_dec}")
        total_bytes="$((total_bytes + size_dec))"
    done

    (( total_bytes > 0 )) ||
        fail "No valid symbols remain for static-sram-regions. Set STATIC_SRAM_SYMBOLS to application-owned SRAM symbols."

    # Select uniformly across all eligible bytes, not uniformly across symbols.
    selected_linear_offset="$(rand_range "${total_bytes}")"
    remaining="${selected_linear_offset}"

    for ((i = 0; i < ${#names[@]}; i++)); do
        if (( remaining < sizes[i] )); then
            FI_OFFSET="${remaining}"
            FI_SELECTED_ADDRESS_DEC="$((starts[i] + remaining))"
            FI_SELECTED_ADDRESS_HEX="$(format_hex32 "${FI_SELECTED_ADDRESS_DEC}")"
            FI_REGION_NAME="${names[i]}"
            FI_REGION_START="$(format_hex32 "${starts[i]}")"
            FI_REGION_END="$(format_hex32 "$((starts[i] + sizes[i] - 1))")"
            FI_REGION_SIZE="${sizes[i]}"
            return 0
        fi

        remaining="$((remaining - sizes[i]))"
    done

    fail "Internal error while selecting a static SRAM target."
}

prepare_full_sram_target()
{
    local sram_size="$((SRAM_END_DEC - SRAM_START_DEC))"
    local attempt random_offset candidate

    (( sram_size > 0 )) || fail "Configured SRAM range is empty or invalid."

    for ((attempt = 1; attempt <= FULL_SRAM_MAX_SELECTION_ATTEMPTS; attempt++)); do
        random_offset="$(rand_range "${sram_size}")"
        candidate="$((SRAM_START_DEC + random_offset))"

        if ! address_is_protected "${candidate}"; then
            FI_OFFSET="${random_offset}"
            FI_SELECTED_ADDRESS_DEC="${candidate}"
            FI_SELECTED_ADDRESS_HEX="$(format_hex32 "${candidate}")"
            FI_REGION_NAME="rp2040_main_sram"
            FI_REGION_START="${SRAM_START_HEX}"
            FI_REGION_END="$(format_hex32 "$((SRAM_END_DEC - 1))")"
            FI_REGION_SIZE="${sram_size}"
            return 0
        fi
    done

    fail "Could not choose an unprotected full-SRAM address after ${FULL_SRAM_MAX_SELECTION_ATTEMPTS} attempts."
}

CSV_HEADER="trial_id,timestamp,elf,requested_scope,selected_scope,breakpoint,pc,msp,region_name,region_start,region_end,region_size_bytes,region_offset,original_address,fault_address,bit_flipped,address_match,original_byte,faulted_byte,verified_byte,write_verified,benchmark_done,expected_checksum,observed_checksum,final_array,outcome,gdb_exit_status"

ensure_csv_schema()
{
    local existing_header backup_suffix backup_path

    if [[ -s "${CSV_LOG}" ]]; then
        existing_header="$(head -n 1 "${CSV_LOG}")"

        if [[ "${existing_header}" != "${CSV_HEADER}" ]]; then
            backup_suffix="$(date +%Y%m%d_%H%M%S)"
            backup_path="${CSV_LOG}.old_schema_${backup_suffix}.bak"
            mv "${CSV_LOG}" "${backup_path}"
            warn "Existing CSV used a different schema and was moved to: ${backup_path}"
        fi
    fi

    if [[ ! -s "${CSV_LOG}" ]]; then
        printf '%s\n' "${CSV_HEADER}" > "${CSV_LOG}"
    fi
}

append_csv_row()
{
    local outcome="$1"

    ensure_csv_schema

    {
        csv_escape "${TRIAL_ID}"; printf ','
        csv_escape "${TIMESTAMP}"; printf ','
        csv_escape "$(basename "${ELF_FILE}")"; printf ','
        csv_escape "${REQUESTED_SCOPE}"; printf ','
        csv_escape "${SELECTED_MEM_SCOPE}"; printf ','
        csv_escape "${SELECTED_FUNCTION:-N/A}"; printf ','
        csv_escape "${PROFILE_PC:-N/A}"; printf ','
        csv_escape "${PROFILE_MSP:-N/A}"; printf ','
        csv_escape "${FI_REGION_OBSERVED:-N/A}"; printf ','
        csv_escape "${FI_REGION_START_OBSERVED:-N/A}"; printf ','
        csv_escape "${FI_REGION_END_OBSERVED:-N/A}"; printf ','
        csv_escape "${FI_REGION_SIZE_OBSERVED:-N/A}"; printf ','
        csv_escape "${FI_OFFSET_OBSERVED:-N/A}"; printf ','
        csv_escape "${FI_ORIGINAL_ADDRESS_OBSERVED:-N/A}"; printf ','
        csv_escape "${FI_FAULT_ADDRESS_OBSERVED:-N/A}"; printf ','
        csv_escape "${FI_BIT:-N/A}"; printf ','
        csv_escape "${FI_ADDRESS_MATCH:-N/A}"; printf ','
        csv_escape "${FI_OLD_VALUE:-N/A}"; printf ','
        csv_escape "${FI_NEW_VALUE:-N/A}"; printf ','
        csv_escape "${FI_VERIFIED_VALUE:-N/A}"; printf ','
        csv_escape "${FI_WRITE_VERIFIED:-N/A}"; printf ','
        csv_escape "${OBSERVED_DONE:-N/A}"; printf ','
        csv_escape "${EXPECTED_CHECKSUM:-N/A}"; printf ','
        csv_escape "${OBSERVED_CHECKSUM:-N/A}"; printf ','
        csv_escape "${FINAL_ARRAY:-N/A}"; printf ','
        csv_escape "${outcome}"; printf ','
        csv_escape "${GDB_EXIT_STATUS:-N/A}"
        printf '\n'
    } >> "${CSV_LOG}"
}

# ---------------------------------------------------------------------------
# Argument validation and cleanup registration
# ---------------------------------------------------------------------------

if (( $# > 1 )); then
    print_usage >&2
    fail "Expected at most one target-region argument."
fi

REQUESTED_SCOPE="$(normalize_scope "${REQUESTED_SCOPE_RAW}" || true)"

if [[ -z "${REQUESTED_SCOPE}" ]]; then
    print_usage >&2
    fail "Unknown target region: ${REQUESTED_SCOPE_RAW}"
fi

if [[ "${REQUESTED_SCOPE}" == "help" ]]; then
    print_usage
    exit 0
fi

trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Trial metadata and dependency checks
# ---------------------------------------------------------------------------

TIMESTAMP="$(date -Iseconds)"
TRIAL_ID="$(date +%Y%m%d_%H%M%S)_$((RANDOM % 100000))"

info "Checking dependencies..."
command_exists gdb-multiarch || fail "gdb-multiarch was not found in PATH."
command_exists arm-none-eabi-nm || fail "arm-none-eabi-nm was not found in PATH."
command_exists timeout || fail "timeout was not found in PATH."
command_exists od || fail "od was not found in PATH."
[[ -f "${ELF_FILE}" ]] || fail "ELF file not found: ${ELF_FILE}"

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
# Resolve benchmark and SRAM symbols
# ---------------------------------------------------------------------------

info "Finding benchmark symbols..."

DONE_ADDRESS="$(find_symbol_address benchmark_done)" ||
    fail "Could not find symbol: benchmark_done"
RESULT_ADDRESS="$(find_symbol_address benchmark_result)" ||
    fail "Could not find symbol: benchmark_result"

ARRAY_ADDRESS="$(find_symbol_address "${ARRAY_SYMBOL}")" ||
    fail "Could not find array symbol: ${ARRAY_SYMBOL}"
ARRAY_SIZE_HEX="$(find_symbol_size_hex "${ARRAY_SYMBOL}")" ||
    fail "Could not determine size for array symbol: ${ARRAY_SYMBOL}"
ARRAY_TYPE="$(find_symbol_type "${ARRAY_SYMBOL}" || true)"

ARRAY_SIZE_BYTES="$((16#${ARRAY_SIZE_HEX}))"
(( ARRAY_SIZE_BYTES > 0 )) || fail "Array symbol ${ARRAY_SYMBOL} has zero size."

if [[ -z "${ARRAY_LEN}" ]]; then
    ARRAY_LEN="$((ARRAY_SIZE_BYTES / 4))"
fi

ARRAY_START_DEC="$((ARRAY_ADDRESS))"
ARRAY_END_DEC="$((ARRAY_START_DEC + ARRAY_SIZE_BYTES - 1))"
ARRAY_END_HEX="$(format_hex32 "${ARRAY_END_DEC}")"

SRAM_START_DEC="$((SRAM_START_HEX))"
SRAM_END_DEC="$((SRAM_END_HEX))"
STACK_TOP_DEC="$((STACK_TOP_HEX))"

(( SRAM_START_DEC < SRAM_END_DEC )) || fail "Invalid SRAM range."
(( ARRAY_START_DEC >= SRAM_START_DEC && ARRAY_END_DEC < SRAM_END_DEC )) ||
    fail "Array symbol ${ARRAY_SYMBOL} is outside the configured SRAM range."
(( STACK_TOP_DEC > SRAM_START_DEC && STACK_TOP_DEC <= SRAM_END_DEC )) ||
    fail "STACK_TOP_HEX is outside the configured SRAM range."

info "benchmark_done address:   ${DONE_ADDRESS}"
info "benchmark_result address: ${RESULT_ADDRESS}"
info "Expected checksum:        ${EXPECTED_CHECKSUM}"
info "Array symbol:             ${ARRAY_SYMBOL}"
info "Array address:            ${ARRAY_ADDRESS}"
info "Array end:                ${ARRAY_END_HEX}"
info "Array size bytes:         ${ARRAY_SIZE_BYTES}"
info "Array length:             ${ARRAY_LEN}"
info "Array symbol type:        ${ARRAY_TYPE:-unknown}"

# ---------------------------------------------------------------------------
# Choose a valid breakpoint trigger function
# ---------------------------------------------------------------------------

VALID_FUNCTIONS=()

for func in "${CANDIDATE_FUNCTIONS[@]}"; do
    if function_symbol_exists "${func}"; then
        VALID_FUNCTIONS+=("${func}")
    else
        warn "Skipping candidate because it is not a function symbol: ${func}"
    fi
done

(( ${#VALID_FUNCTIONS[@]} > 0 )) ||
    fail "No valid function symbols found for breakpoint selection."

SELECTED_FUNCTION="${VALID_FUNCTIONS[$(rand_range "${#VALID_FUNCTIONS[@]}")]}"
SELECTED_MEM_SCOPE="$(choose_selected_scope)"

# Random bit within the selected byte.
FI_BIT="$(rand_range 8)"
FI_MASK_DEC="$((1 << FI_BIT))"
FI_MASK_HEX="0x$(printf '%02x' "${FI_MASK_DEC}")"

# Build exclusions now so full-sram mode cannot target benchmark observation
# variables. This list is also printed for transparency.
build_protected_ranges

# Fixed-address modes choose their target in the shell. active-stack chooses its
# byte only after GDB reads the live MSP at the trigger breakpoint.
case "${SELECTED_MEM_SCOPE}" in
    data-array)
        prepare_data_array_target
        ;;
    active-stack)
        FI_STACK_RANDOM_RAW="$(rand_range 4294967295)"
        FI_SELECTED_ADDRESS_HEX="computed_at_runtime"
        FI_REGION_NAME="active_stack_window"
        FI_REGION_START="computed_from_msp"
        FI_REGION_END="$(format_hex32 "$((STACK_TOP_DEC - 1))")"
        FI_REGION_SIZE="computed_at_runtime"
        FI_OFFSET="computed_at_runtime"
        ;;
    static-sram-regions)
        prepare_static_sram_target
        ;;
    full-sram)
        prepare_full_sram_target
        ;;
esac

printf '\n'
printf '%s\n' '----------------------------------------'
printf '%s\n' 'Profile-Guided SRAM FI Setup'
printf '%s\n' '----------------------------------------'
printf 'Trial ID:             %s\n' "${TRIAL_ID}"
printf 'CSV log:              %s\n' "${CSV_LOG}"
printf 'ELF file:             %s\n' "${ELF_FILE}"
printf 'Breakpoint trigger:   %s\n' "${SELECTED_FUNCTION}"
printf 'Requested scope:      %s\n' "${REQUESTED_SCOPE}"
printf 'Selected scope:       %s\n' "${SELECTED_MEM_SCOPE}"
printf 'Target region:        %s\n' "${FI_REGION_NAME}"
printf 'Region start:         %s\n' "${FI_REGION_START}"
printf 'Region end:           %s\n' "${FI_REGION_END}"
printf 'Region size bytes:    %s\n' "${FI_REGION_SIZE}"
printf 'Selected address:     %s\n' "${FI_SELECTED_ADDRESS_HEX}"
printf 'Bit selected:         %s\n' "${FI_BIT}"
printf 'Bit mask:             %s\n' "${FI_MASK_HEX}"
printf '%s\n' '----------------------------------------'

# ---------------------------------------------------------------------------
# Prepare GDB command file
# ---------------------------------------------------------------------------

: > "${GDB_LOG}"
GDB_COMMAND_FILE="$(mktemp)"

cat > "${GDB_COMMAND_FILE}" <<GDB_EOF
set pagination off
set confirm off
set verbose off
set breakpoint pending off

target extended-remote ${OPENOCD_HOST}:${OPENOCD_PORT}

monitor reset halt
load
monitor reset halt

set \$done_addr = ${DONE_ADDRESS}
set \$result_addr = ${RESULT_ADDRESS}
set \$sram_start = ${SRAM_START_HEX}
set \$sram_end = ${SRAM_END_HEX}
set \$stack_top = ${STACK_TOP_HEX}

set *(unsigned int *)\$done_addr = 0

printf "PROFILE_SELECTED_BREAKPOINT=${SELECTED_FUNCTION}\\n"
printf "PROFILE_REQUESTED_SCOPE=${REQUESTED_SCOPE}\\n"
printf "PROFILE_SELECTED_SCOPE=${SELECTED_MEM_SCOPE}\\n"

tbreak ${SELECTED_FUNCTION}
continue

set \$current_pc = (unsigned int)\$pc
set \$current_msp = (unsigned int)\$msp
set \$stack_top_u = (unsigned int)\$stack_top
set \$stack_end_u = (unsigned int)(\$stack_top_u - 1)
set \$stack_window_size = (unsigned int)(\$stack_top_u - \$current_msp)

printf "PROFILE_HIT_BREAKPOINT=${SELECTED_FUNCTION}\\n"
printf "PROFILE_PC=0x%x\\n", \$current_pc
printf "PROFILE_MSP=0x%x\\n", \$current_msp
printf "PROFILE_STACK_TOP=0x%x\\n", \$stack_top_u
printf "PROFILE_CURRENT_STACK_START=0x%x\\n", \$current_msp
printf "PROFILE_CURRENT_STACK_END=0x%x\\n", \$stack_end_u
printf "PROFILE_CURRENT_STACK_SIZE=%u\\n", \$stack_window_size
GDB_EOF

if [[ "${SELECTED_MEM_SCOPE}" == "active-stack" ]]; then
    cat >> "${GDB_COMMAND_FILE}" <<GDB_EOF

if \$current_msp < \$sram_start
    printf "FI_STATUS=NOT_INJECTED\\n"
    printf "FI_REASON=msp_below_sram\\n"
else
    if \$current_msp >= \$stack_top_u
        printf "FI_STATUS=NOT_INJECTED\\n"
        printf "FI_REASON=invalid_stack_window\\n"
    else
        set \$fault_offset = (unsigned int)(${FI_STACK_RANDOM_RAW} % \$stack_window_size)
        set \$original_addr = (unsigned int)(\$current_msp + \$fault_offset)

        printf "FI_STATUS=INJECTED\\n"
        printf "FI_REGION=active_stack_window\\n"
        printf "FI_REGION_START=0x%x\\n", \$current_msp
        printf "FI_REGION_END=0x%x\\n", \$stack_end_u
        printf "FI_REGION_SIZE=%u\\n", \$stack_window_size
        printf "FI_OFFSET=%u\\n", \$fault_offset
        printf "FI_ORIGINAL_ADDRESS=0x%x\\n", \$original_addr
        printf "FI_BIT=${FI_BIT}\\n"
        printf "FI_MASK=${FI_MASK_HEX}\\n"

        set \$old_fault_value = (unsigned int)*(unsigned char *)\$original_addr
        set \$new_fault_value = (unsigned int)((\$old_fault_value ^ ${FI_MASK_DEC}) & 0xff)
        set *(unsigned char *)\$original_addr = (unsigned char)\$new_fault_value
        set \$fault_addr = \$original_addr
        set \$verified_fault_value = (unsigned int)*(unsigned char *)\$fault_addr

        printf "FI_FAULT_ADDRESS=0x%x\\n", \$fault_addr
        printf "FI_OLD_VALUE=0x%02x\\n", \$old_fault_value
        printf "FI_NEW_VALUE=0x%02x\\n", \$new_fault_value
        printf "FI_VERIFIED_VALUE=0x%02x\\n", \$verified_fault_value

        if \$verified_fault_value == \$new_fault_value
            printf "FI_WRITE_VERIFIED=YES\\n"
        else
            printf "FI_WRITE_VERIFIED=NO\\n"
        end
    end
end
GDB_EOF
else
    cat >> "${GDB_COMMAND_FILE}" <<GDB_EOF

set \$original_addr = ${FI_SELECTED_ADDRESS_HEX}

printf "FI_STATUS=INJECTED\\n"
printf "FI_REGION=${FI_REGION_NAME}\\n"
printf "FI_REGION_START=${FI_REGION_START}\\n"
printf "FI_REGION_END=${FI_REGION_END}\\n"
printf "FI_REGION_SIZE=${FI_REGION_SIZE}\\n"
printf "FI_OFFSET=${FI_OFFSET}\\n"
printf "FI_ORIGINAL_ADDRESS=0x%x\\n", \$original_addr
printf "FI_BIT=${FI_BIT}\\n"
printf "FI_MASK=${FI_MASK_HEX}\\n"

set \$old_fault_value = (unsigned int)*(unsigned char *)\$original_addr
set \$new_fault_value = (unsigned int)((\$old_fault_value ^ ${FI_MASK_DEC}) & 0xff)
set *(unsigned char *)\$original_addr = (unsigned char)\$new_fault_value
set \$fault_addr = \$original_addr
set \$verified_fault_value = (unsigned int)*(unsigned char *)\$fault_addr

printf "FI_FAULT_ADDRESS=0x%x\\n", \$fault_addr
printf "FI_OLD_VALUE=0x%02x\\n", \$old_fault_value
printf "FI_NEW_VALUE=0x%02x\\n", \$new_fault_value
printf "FI_VERIFIED_VALUE=0x%02x\\n", \$verified_fault_value

if \$verified_fault_value == \$new_fault_value
    printf "FI_WRITE_VERIFIED=YES\\n"
else
    printf "FI_WRITE_VERIFIED=NO\\n"
end
GDB_EOF
fi

cat >> "${GDB_COMMAND_FILE}" <<GDB_EOF

watch *(unsigned int *)\$done_addr
continue

set \$observed_done = *(unsigned int *)\$done_addr
set \$observed_result = *(unsigned int *)\$result_addr

printf "PICO_DONE=%u\\n", \$observed_done
printf "PICO_CHECKSUM=%u\\n", \$observed_result

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
printf "\\n"

monitor halt
GDB_EOF

# ---------------------------------------------------------------------------
# Run GDB. Keep verbose debugger traffic in GDB_LOG; the terminal receives only
# the concise setup/result summaries unless GDB itself fails.
# ---------------------------------------------------------------------------

info "Loading quicksort.elf, profiling runtime state, and injecting one SRAM fault..."

set +e
timeout "${GDB_TIMEOUT}" \
    gdb-multiarch \
    --batch \
    --quiet \
    -x "${GDB_COMMAND_FILE}" \
    "${ELF_FILE}" \
    >"${GDB_LOG}" 2>&1
GDB_EXIT_STATUS=$?
set -e

if (( GDB_EXIT_STATUS != 0 && GDB_EXIT_STATUS != 124 )); then
    warn "GDB exited with status ${GDB_EXIT_STATUS}. Last log lines:"
    tail -n 15 "${GDB_LOG}" >&2 || true
fi

# ---------------------------------------------------------------------------
# Extract result values
# ---------------------------------------------------------------------------

PROFILE_PC="$(extract_last_value PROFILE_PC "${GDB_LOG}")"
PROFILE_MSP="$(extract_last_value PROFILE_MSP "${GDB_LOG}")"
PROFILE_STACK_START="$(extract_last_value PROFILE_CURRENT_STACK_START "${GDB_LOG}")"
PROFILE_STACK_END="$(extract_last_value PROFILE_CURRENT_STACK_END "${GDB_LOG}")"
PROFILE_STACK_SIZE="$(extract_last_value PROFILE_CURRENT_STACK_SIZE "${GDB_LOG}")"

FI_STATUS_OBSERVED="$(extract_last_value FI_STATUS "${GDB_LOG}")"
FI_REASON_OBSERVED="$(extract_last_value FI_REASON "${GDB_LOG}")"
FI_REGION_OBSERVED="$(extract_last_value FI_REGION "${GDB_LOG}")"
FI_REGION_START_OBSERVED="$(extract_last_value FI_REGION_START "${GDB_LOG}")"
FI_REGION_END_OBSERVED="$(extract_last_value FI_REGION_END "${GDB_LOG}")"
FI_REGION_SIZE_OBSERVED="$(extract_last_value FI_REGION_SIZE "${GDB_LOG}")"
FI_OFFSET_OBSERVED="$(extract_last_value FI_OFFSET "${GDB_LOG}")"
FI_ORIGINAL_ADDRESS_OBSERVED="$(extract_last_value FI_ORIGINAL_ADDRESS "${GDB_LOG}")"
FI_FAULT_ADDRESS_OBSERVED="$(extract_last_value FI_FAULT_ADDRESS "${GDB_LOG}")"
FI_OLD_VALUE="$(extract_last_value FI_OLD_VALUE "${GDB_LOG}")"
FI_NEW_VALUE="$(extract_last_value FI_NEW_VALUE "${GDB_LOG}")"
FI_VERIFIED_VALUE="$(extract_last_value FI_VERIFIED_VALUE "${GDB_LOG}")"
FI_WRITE_VERIFIED="$(extract_last_value FI_WRITE_VERIFIED "${GDB_LOG}")"

OBSERVED_DONE="$(extract_last_value PICO_DONE "${GDB_LOG}")"
OBSERVED_CHECKSUM="$(extract_last_value PICO_CHECKSUM "${GDB_LOG}")"

PICO_ARRAY_LINE="$(grep '^PICO_ARRAY=' "${GDB_LOG}" | tail -n 1 || true)"
FINAL_ARRAY="${PICO_ARRAY_LINE#PICO_ARRAY=}"

if [[ "${FINAL_ARRAY}" == "${PICO_ARRAY_LINE}" ]]; then
    FINAL_ARRAY=""
fi

if [[ -n "${FI_ORIGINAL_ADDRESS_OBSERVED}" && -n "${FI_FAULT_ADDRESS_OBSERVED}" ]]; then
    if hex_values_match "${FI_ORIGINAL_ADDRESS_OBSERVED}" "${FI_FAULT_ADDRESS_OBSERVED}"; then
        FI_ADDRESS_MATCH="YES"
    else
        FI_ADDRESS_MATCH="NO"
    fi
else
    FI_ADDRESS_MATCH="N/A"
fi

# ---------------------------------------------------------------------------
# Classify result
# ---------------------------------------------------------------------------

OUTCOME="UNKNOWN"

if [[ "${GDB_EXIT_STATUS}" -eq 124 ]]; then
    OUTCOME="DUE_TIMEOUT_OR_HANG"
elif [[ "${GDB_EXIT_STATUS}" -ne 0 && -z "${OBSERVED_DONE}" && -z "${OBSERVED_CHECKSUM}" ]]; then
    OUTCOME="DUE_CRASH_OR_GDB_ERROR"
elif [[ "${FI_STATUS_OBSERVED:-}" != "INJECTED" ]]; then
    OUTCOME="NOT_INJECTED"
elif [[ "${FI_WRITE_VERIFIED:-}" != "YES" ]]; then
    OUTCOME="INJECTION_WRITE_FAILED"
elif [[ "${FI_ADDRESS_MATCH}" != "YES" ]]; then
    OUTCOME="INJECTION_ADDRESS_MISMATCH"
elif [[ "${OBSERVED_DONE:-}" != "1" ]]; then
    OUTCOME="DUE_INCOMPLETE"
elif [[ "${OBSERVED_CHECKSUM:-}" == "${EXPECTED_CHECKSUM}" ]]; then
    OUTCOME="MASKED"
else
    OUTCOME="SDC"
fi

# ---------------------------------------------------------------------------
# Append one clean CSV row
# ---------------------------------------------------------------------------

append_csv_row "${OUTCOME}"

# ---------------------------------------------------------------------------
# Human-readable terminal summary
# ---------------------------------------------------------------------------

printf '\n'
printf '%s\n' '----------------------------------------'
printf '%s\n' 'Profile-Guided Quicksort SRAM FI Result'
printf '%s\n' '----------------------------------------'
printf 'Trial ID:             %s\n' "${TRIAL_ID}"
printf 'Requested scope:      %s\n' "${REQUESTED_SCOPE}"
printf 'Selected scope:       %s\n' "${SELECTED_MEM_SCOPE}"
printf 'Breakpoint trigger:   %s\n' "${SELECTED_FUNCTION}"
printf 'PC at injection:      %s\n' "${PROFILE_PC:-N/A}"
printf 'MSP at injection:     %s\n' "${PROFILE_MSP:-N/A}"
printf 'Stack window:         %s - %s (%s bytes)\n' \
    "${PROFILE_STACK_START:-N/A}" \
    "${PROFILE_STACK_END:-N/A}" \
    "${PROFILE_STACK_SIZE:-N/A}"
printf '\n'
printf 'Fault status:         %s\n' "${FI_STATUS_OBSERVED:-UNKNOWN}"
if [[ -n "${FI_REASON_OBSERVED}" ]]; then
    printf 'Fault reason:         %s\n' "${FI_REASON_OBSERVED}"
fi
printf 'Fault region:         %s\n' "${FI_REGION_OBSERVED:-N/A}"
printf 'Region bounds:        %s - %s (%s bytes)\n' \
    "${FI_REGION_START_OBSERVED:-N/A}" \
    "${FI_REGION_END_OBSERVED:-N/A}" \
    "${FI_REGION_SIZE_OBSERVED:-N/A}"
printf 'Region offset:        %s\n' "${FI_OFFSET_OBSERVED:-N/A}"
printf 'Original address:     %s\n' "${FI_ORIGINAL_ADDRESS_OBSERVED:-N/A}"
printf 'Fault address:        %s\n' "${FI_FAULT_ADDRESS_OBSERVED:-N/A}"
printf 'Address match:        %s\n' "${FI_ADDRESS_MATCH}"
printf 'Bit flipped:          %s\n' "${FI_BIT}"
printf 'Original byte:        %s\n' "${FI_OLD_VALUE:-N/A}"
printf 'Faulted byte:         %s\n' "${FI_NEW_VALUE:-N/A}"
printf 'Verified byte:        %s\n' "${FI_VERIFIED_VALUE:-N/A}"
printf 'Write verified:       %s\n' "${FI_WRITE_VERIFIED:-N/A}"
printf '\n'
printf 'benchmark_done:       %s\n' "${OBSERVED_DONE:-N/A}"
printf 'Expected checksum:    %s\n' "${EXPECTED_CHECKSUM}"
printf 'Observed checksum:    %s\n' "${OBSERVED_CHECKSUM:-N/A}"

if [[ -n "${PICO_ARRAY_LINE}" ]]; then
    printf '%s\n' "${PICO_ARRAY_LINE}"
else
    printf '%s\n' 'PICO_ARRAY=N/A'
fi

printf 'Outcome:              %s\n' "${OUTCOME}"
printf 'CSV row appended to:  %s\n' "${CSV_LOG}"
printf 'GDB details log:      %s\n' "${GDB_LOG}"
printf 'GDB exit status:      %s\n' "${GDB_EXIT_STATUS}"
printf '%s\n' '----------------------------------------'

case "${OUTCOME}" in
    MASKED)
        printf '%s\n' '[PASS] Fault was injected, but the final checksum still matched.'
        ;;
    SDC)
        printf '%s\n' '[PASS] Fault was injected and changed the final checksum.'
        ;;
    DUE_TIMEOUT_OR_HANG)
        printf '%s\n' '[INFO] The target did not reach benchmark_done before the timeout.'
        ;;
    DUE_CRASH_OR_GDB_ERROR)
        printf '%s\n' '[INFO] GDB did not capture a complete benchmark result.'
        ;;
    DUE_INCOMPLETE)
        printf '%s\n' '[INFO] The benchmark did not report completion.'
        ;;
    NOT_INJECTED)
        printf '%s\n' '[INFO] No fault was injected.'
        ;;
    INJECTION_WRITE_FAILED)
        printf '%s\n' '[INFO] GDB wrote the target byte, but read-back verification failed.'
        ;;
    INJECTION_ADDRESS_MISMATCH)
        printf '%s\n' '[INFO] The selected address and GDB-reported fault address did not match.'
        ;;
    *)
        printf '%s\n' '[INFO] Outcome is unknown.'
        ;;
esac

exit 0

