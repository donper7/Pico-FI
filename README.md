# Pico-FI Quicksort Example

This repository contains a reproducible Raspberry Pi Pico benchmark example using OpenOCD and GDB. The example loads and runs `quicksort.elf` on the Raspberry Pi Pico, then verifies that the program produced the correct result by reading a checksum directly from memory.

The goal of this example is to allow another researcher to clone the repository, connect a Pico through a debug probe, run one script, and verify that the benchmark works correctly.

## Overview

The current example uses a Quicksort benchmark compiled into:

quicksort.elf

The benchmark exposes two symbols in memory:

volatile uint32_t benchmark_done;
volatile uint32_t benchmark_result;

When the benchmark finishes running, it stores a checksum in `benchmark_result` and sets:

benchmark_done = 1;

The script `run_quicksort.sh` uses GDB to:

1. Connect to the Pico through OpenOCD.
2. Reset and halt the target.
3. Load `quicksort.elf`.
4. Run the benchmark.
5. Stop when `benchmark_done` changes.
6. Read the checksum from `benchmark_result`.
7. Compare the observed checksum against the expected checksum.
8. Print `PASS` or `FAIL`.

This avoids parsing serial output and makes the result easy to verify through memory.

## Hardware Requirements

The example requires:

* Raspberry Pi Pico or another RP2040-based board
* Raspberry Pi Debug Probe or another CMSIS-DAP compatible debug probe
* USB connection from the host computer to the debug probe
* Linux or WSL Ubuntu environment

This project was tested using a Raspberry Pi Pico, Raspberry Pi Debug Probe, and WSL Ubuntu.

## Software Dependencies

The following tools must be installed:

openocd
gdb-multiarch
arm-none-eabi-nm
timeout

You can check that the tools are available with:

openocd --version
gdb-multiarch --version
arm-none-eabi-nm --version
timeout --version

The tested environment used:

GDB: gdb-multiarch 9.2
Target: Raspberry Pi Pico / RP2040
Debug interface: CMSIS-DAP

Your exact versions may differ. If reproducing this work, record your versions using the commands above.

## Files Needed for the Example

The main files for this example are:

README.md
run_quicksort.sh
quicksort.elf

`run_quicksort.sh` is the script that runs the benchmark and verifies the checksum.

`quicksort.elf` is the compiled benchmark program that is loaded onto the Pico.

## How to Run the Example

This example uses two terminals.

### Terminal 1: Start OpenOCD

First, connect the Raspberry Pi Pico and debug probe to your computer.

Then start OpenOCD:

sudo openocd -f interface/cmsis-dap.cfg -f target/rp2040.cfg

Leave this terminal open. OpenOCD should remain running while the benchmark script executes.

OpenOCD provides the GDB server at:

127.0.0.1:3333

### Terminal 2: Run the Quicksort Benchmark

In a second terminal, go to the repository folder:

cd ~/Donovan/pico/Pico-FI

Make sure the script is executable:

chmod +x run_quicksort.sh

Run the example:

./run_quicksort.sh

## Expected Output

A successful run should look similar to this:

[INFO] Checking dependencies...
[INFO] Checking for OpenOCD on 127.0.0.1:3333...
[INFO] OpenOCD connection detected.
[INFO] Finding benchmark symbols...
[INFO] benchmark_done address:   0x200005ec
[INFO] benchmark_result address: 0x200005f0
[INFO] Expected checksum:        2825881671
[INFO] Loading and running quicksort.elf...
PICO_DONE=1
PICO_CHECKSUM=2825881671

----------------------------------------
Quicksort verification
----------------------------------------
benchmark_done:    1
Expected checksum: 2825881671
Observed checksum: 2825881671
----------------------------------------
[PASS] Quicksort completed and produced the correct checksum.

The most important lines are:

PICO_DONE=1
PICO_CHECKSUM=2825881671
[PASS] Quicksort completed and produced the correct checksum.

These lines confirm that the benchmark finished and produced the expected checksum.

## Verification Method

The expected checksum for the current `quicksort.elf` is:

2825881671

The script classifies the result as follows:

PASS:
    benchmark_done == 1
    benchmark_result == expected checksum

FAIL:
    benchmark_done == 1
    benchmark_result != expected checksum

TIMEOUT:
    GDB does not observe benchmark_done before the timeout

ERROR:
    OpenOCD, GDB, ELF loading, symbol lookup, or memory reading fails

This memory-based verification method is more reliable than parsing serial output because GDB reads the benchmark result directly from the Pico memory.

## Running Interactively with GDB

The example can also be run manually.

First, start OpenOCD in one terminal:

sudo openocd -f interface/cmsis-dap.cfg -f target/rp2040.cfg

Then open GDB in another terminal:

gdb-multiarch quicksort.elf

Inside GDB, run:

target remote localhost:3333
monitor reset halt
load
monitor reset halt

set $done_addr = &benchmark_done
set $result_addr = &benchmark_result

set *(unsigned int *)$done_addr = 0

watch *(unsigned int *)$done_addr
continue

p *(unsigned int *)$done_addr
p *(unsigned int *)$result_addr

A correct run should show that `benchmark_done` is `1` and that `benchmark_result` matches the expected checksum:

benchmark_done = 1
benchmark_result = 2825881671

If GDB cannot determine the symbol types, use `arm-none-eabi-nm` to find the addresses manually:

arm-none-eabi-nm -n quicksort.elf | grep benchmark

Example output:

200005ec B benchmark_done
200005f0 B benchmark_result

Then read the values directly in GDB:

p *(unsigned int *)0x200005ec
p *(unsigned int *)0x200005f0

## Troubleshooting

### OpenOCD is not running

If the script prints:

[FAIL] OpenOCD is not running.

start OpenOCD in another terminal:

sudo openocd -f interface/cmsis-dap.cfg -f target/rp2040.cfg

Then run the script again:

./run_quicksort.sh

### GDB times out

If GDB times out, the benchmark may not have reached `benchmark_done = 1`. Check that:

* The Pico is connected.
* The debug probe is connected.
* OpenOCD is still running.
* The correct `quicksort.elf` file is present.
* The benchmark contains the `benchmark_done` and `benchmark_result` symbols.

### Checksum mismatch

If the checksum does not match, then the benchmark executed but produced an unexpected result. This may indicate that the ELF file changed, the expected checksum needs to be updated, or the benchmark output is incorrect.

### GDB detach issue

Some older versions of `gdb-multiarch`, including GDB 9.2, may crash when detaching from the RP2040 target. The script avoids explicitly calling `detach` or `quit` to prevent this issue.

## Current Status

The current quicksort example has been tested successfully. The observed checksum matches the expected checksum:

Expected checksum: 2825881671
Observed checksum: 2825881671

This confirms that the benchmark can be loaded, run, and verified through GDB using memory-based checking.


