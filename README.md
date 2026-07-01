# Pico-FI Quicksort Example

This repository provides a minimal, reproducible Raspberry Pi Pico benchmark example using **OpenOCD** and **GDB**.

The example loads `quicksort.elf` onto an RP2040-based board, runs the benchmark, and verifies the result by reading two symbols directly from SRAM:

```c
volatile uint32_t benchmark_done;
volatile uint32_t benchmark_result;
```

When the benchmark finishes, it sets:

```c
benchmark_done = 1;
```

and stores the computed checksum in:

```c
benchmark_result;
```

This allows the benchmark result to be checked through GDB without relying on serial output.

---

## What This Example Demonstrates

The script `run_quicksort.sh` automatically:

1. Connects to the Pico through OpenOCD.
2. Resets and halts the target.
3. Loads `quicksort.elf`.
4. Runs the Quicksort benchmark.
5. Waits for `benchmark_done` to become `1`.
6. Reads `benchmark_result` from memory.
7. Compares the observed checksum against the expected checksum.
8. Prints `PASS`, `FAIL`, `TIMEOUT`, or `ERROR`.

This is the first step toward a debugger-based fault injection workflow where benchmark state can be observed directly from memory.

---

## Hardware Requirements

You will need:

* Raspberry Pi Pico or another RP2040-based board
* Raspberry Pi Debug Probe or another CMSIS-DAP compatible debug probe
* USB connection to the host computer
* Linux or WSL Ubuntu environment

This example was tested using a Raspberry Pi Pico, Raspberry Pi Debug Probe, and WSL Ubuntu.

---

## Software Requirements

The following tools are required:

```bash
openocd
gdb-multiarch
arm-none-eabi-nm
timeout
```

You can check your installed versions with:

```bash
openocd --version
gdb-multiarch --version
arm-none-eabi-nm --version
timeout --version
```

Tested setup:

```text
GDB: gdb-multiarch 9.2
Target: Raspberry Pi Pico / RP2040
Debug interface: CMSIS-DAP
```

Other versions may work, but researchers reproducing this example should record their tool versions.

---

## Repository Files

The important files are:

```text
README.md
run_quicksort.sh
quicksort.elf
```

`run_quicksort.sh` runs and verifies the benchmark.

`quicksort.elf` is the compiled Quicksort program loaded onto the Pico.

---

## Running the Example

This example uses two terminals.

### Terminal 1: Start OpenOCD

Connect the Pico and debug probe, then run:

```bash
sudo openocd -f interface/cmsis-dap.cfg -f target/rp2040.cfg
```

Leave this terminal open.

OpenOCD should start a GDB server at:

```text
127.0.0.1:3333
```

### Terminal 2: Run the Benchmark

From the repository directory:

```bash
chmod +x run_quicksort.sh
./run_quicksort.sh
```

---

## Expected Output

A successful run should include:

```text
PICO_DONE=1
PICO_CHECKSUM=2825881671

[PASS] Quicksort completed and produced the correct checksum.
```

The expected checksum for the current `quicksort.elf` is:

```text
2825881671
```

A passing result means:

```text
benchmark_done   == 1
benchmark_result == 2825881671
```

---

## Result Classification

The script classifies each run as follows:

| Result    | Meaning                                                             |
| --------- | ------------------------------------------------------------------- |
| `PASS`    | The benchmark finished and the checksum matched.                    |
| `FAIL`    | The benchmark finished, but the checksum did not match.             |
| `TIMEOUT` | GDB did not observe `benchmark_done = 1` before the timeout.        |
| `ERROR`   | OpenOCD, GDB, ELF loading, symbol lookup, or memory reading failed. |

This memory-based verification method is useful because it checks the benchmark result directly from Pico memory instead of parsing serial output.

---

## Manual GDB Run

The benchmark can also be run manually.

Start OpenOCD in one terminal:

```bash
sudo openocd -f interface/cmsis-dap.cfg -f target/rp2040.cfg
```

Then start GDB in another terminal:

```bash
gdb-multiarch quicksort.elf
```

Inside GDB:

```gdb
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
```

A correct run should show:

```text
benchmark_done = 1
benchmark_result = 2825881671
```

If GDB cannot resolve the symbols, find their addresses with:

```bash
arm-none-eabi-nm -n quicksort.elf | grep benchmark
```

Example:

```text
200005ec B benchmark_done
200005f0 B benchmark_result
```

Then read the values directly in GDB:

```gdb
p *(unsigned int *)0x200005ec
p *(unsigned int *)0x200005f0
```

---

## Troubleshooting

### OpenOCD is not running

Start OpenOCD in a separate terminal:

```bash
sudo openocd -f interface/cmsis-dap.cfg -f target/rp2040.cfg
```

Then rerun:

```bash
./run_quicksort.sh
```

### GDB times out

Check that:

* The Pico is connected.
* The debug probe is connected.
* OpenOCD is still running.
* `quicksort.elf` is present.
* The benchmark includes `benchmark_done` and `benchmark_result`.

### Checksum mismatch

A checksum mismatch means the program finished, but the result was not the expected value.

This may happen if:

* `quicksort.elf` changed.
* The expected checksum needs to be updated.
* The benchmark output is incorrect.

### GDB detach issue

Some older versions of `gdb-multiarch`, including GDB 9.2, may crash when detaching from the RP2040 target.

To avoid this, the script does not explicitly call `detach` or `quit`.

---

## Current Status

The current Quicksort example has been tested successfully.

```text
Expected checksum: 2825881671
Observed checksum: 2825881671
Result: PASS
```

This confirms that the benchmark can be loaded, executed, and verified through GDB using memory-based checking.
