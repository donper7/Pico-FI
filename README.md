## Pico-FI Quicksort Examples

This repository contains reproducible Raspberry Pi Pico examples using OpenOCD and `gdb-multiarch`.

The current examples focus on a Quicksort benchmark running on the Raspberry Pi Pico. The first script runs and verifies the benchmark. The second script profiles the benchmark and reports useful program/hardware information that can later be used to design a targeted fault-injection strategy.

## Repository Contents

Pico-FI/
  ├── README.md
  ├── quicksort.elf
  ├── run_quicksort.sh
  ├── run_quicksort_profile.sh
  ├── .gitignore


```bash
├── Pico-FI
│   ├── README.md
│   │    
│   ├── quicksort.elf
│   ├── run_quicksort.sh
│   ├── run_quicksort_profile.sh
│   │  
│   └── .gitignore
```


## Hardware Requirements

* Raspberry Pi Pico or another RP2040-based board
* Raspberry Pi Pico Debug Probe or another CMSIS-DAP compatible debug probe
* USB connection from host computer to debug probe
* USB connection from host computer to Raspberry Pi Pico
* SWD connection between Raspberry Pi Pico and debug probe
* Linux or WSL Ubuntu environment

This project was tested using a Raspberry Pi Pico, Raspberry Pi Debug Probe, and WSL Ubuntu.

## Software Dependencies

The following tools are required:

* openocd
* gdb-multiarch
* arm-none-eabi-nm
* timeout

Check that they are available:


* openocd --version
* gdb-multiarch --version
* arm-none-eabi-nm --version
* timeout --version

This project uses `gdb-multiarch` for debugging the RP2040 target.

`arm-none-eabi-nm` is used only as an ELF symbol-inspection tool. It is used to read symbol addresses and sizes from `quicksort.elf`.

## Starting OpenOCD

Both examples assume that OpenOCD is already running in a separate terminal.

In Terminal 1, run:


sudo openocd -f interface/cmsis-dap.cfg -f target/rp2040.cfg


Leave this terminal open.

OpenOCD provides the GDB server at:


127.0.0.1:3333


Then run the scripts from a second terminal.

## Example 1: Run and Verify Quicksort

The first example loads and runs `quicksort.elf` on the Raspberry Pi Pico, then verifies the output using memory-based checking.

Run:


./run_quicksort.sh


The benchmark exposes two symbols in SRAM:


volatile uint32_t benchmark_done;
volatile uint32_t benchmark_result;


When the benchmark finishes, it sets:


benchmark_done = 1;


and stores the checksum in:


benchmark_result


The script waits for `benchmark_done`, reads `benchmark_result`, and compares the observed checksum against the expected checksum.

Expected successful output:


PICO_DONE=1
PICO_CHECKSUM=2825881671

----------------------------------------
Quicksort verification
----------------------------------------

benchmark_done:    1
Expected checksum: 2825881671
Observed checksum: 2825881671
[PASS] Quicksort completed and produced the correct checksum.

The expected checksum for the current `quicksort.elf` is:

2825881671

## Example 2: Profile Quicksort Program State

The second example does not inject faults. Instead, it gathers program information that can later be used to build a targeted fault-injection strategy.

Run:

./run_quicksort_profile.sh

This script reports:

* static SRAM symbols from the ELF
* addresses of `benchmark_done` and `benchmark_result`
* the address and size of the quicksort array
* the final sorted array
* PC and MSP values at selected benchmark functions
* the observed runtime stack window
* generated files containing possible future fault-injection target regions

This is useful because it helps identify SRAM regions that are actually used by the program instead of injecting randomly across the full RP2040 SRAM range.

## Profiling Output

A successful profiling run should include output similar to:


----------------------------------------
Static SRAM Symbols from ELF
----------------------------------------

START        END          SIZE       TYPE   SYMBOL
0x20000388  0x200003ab   36         D      data
0x200005ec  0x200005ef   4          B      benchmark_done
0x200005f0  0x200005f3   4          B      benchmark_result

The `TYPE` column comes from `arm-none-eabi-nm`. It describes how the symbol is classified in the ELF file.

Common symbol types include:

D    global initialized data
d    local initialized data
B    global uninitialized data / BSS
b    local uninitialized data / BSS
W    weak symbol
V    weak object symbol


For example:

0x20000388 0x200003ab 36 D data

means that the global symbol `data` lives in SRAM, starts at `0x20000388`, ends at `0x200003ab`, and occupies 36 bytes.

Since the quicksort array contains 9 integers and each integer is 4 bytes:

9 * 4 = 36 bytes

this corresponds to the array used by the benchmark.

## Final Array Output

The profiling script also prints the actual sorted array:


PICO_ARRAY=1 3 4 5 7 8 9 10 12


This allows the user to directly see the sorted quicksort result instead of only viewing a checksum.

The checksum is still retained for automatic verification.

## Function Entry Profile

The script profiles selected functions such as:

swap_int
partition
quickSort
print_array

Example output:

PROFILE_HIT=swap_int PC=0x10000332 MSP=0x20041f90 STACK_TOP=0x20042000
PROFILE_HIT=partition PC=0x10000360 MSP=0x20041fa8 STACK_TOP=0x20042000
PROFILE_HIT=quickSort PC=0x100003d8 MSP=0x20041fd0 STACK_TOP=0x20042000
PROFILE_HIT=print_array PC=0x1000041e MSP=0x20041fd8 STACK_TOP=0x20042000

This tells us where the program counter and stack pointer are when each function is reached.

This information is useful for future fault injection because it helps identify critical code locations and the active stack region during benchmark execution.

## Observed Runtime SRAM Information

The script estimates the active stack window from the lowest observed MSP value.

Example:

Lowest observed MSP:     0x20041f90
Stack top estimate:      0x20042000
Observed stack window:   0x20041f90 - 0x20041fff
Observed stack bytes:    112

This gives a runtime SRAM region that can be targeted later for stack-based fault injection.

## Generated Files

The profiling script generates the following files:

gdb_quicksort_profile.log
sram_symbols_quicksort.txt
target_regions_quicksort.csv

These files are generated output and are ignored by Git by default.

The most important generated file is:

target_regions_quicksort.csv

It contains target regions that can later be used by a fault-injection script.

Example:

region_type,name,start,end,size_bytes
static_symbol,data,0x20000388,0x200003ab,36
static_symbol,benchmark_done,0x200005ec,0x200005ef,4
static_symbol,benchmark_result,0x200005f0,0x200005f3,4
observed_stack,active_stack_window,0x20041f90,0x20041fff,112

A future fault-injection strategy can randomly select memory locations from this file instead of injecting across the entire SRAM region.

## Why This Profiling Example Matters

The RP2040 has a full SRAM region, but not all SRAM locations are equally meaningful for a specific benchmark.

Broad full-SRAM injection can model random soft errors, but targeted injection into actually used regions can help answer more focused research questions:

Which SRAM regions affect the benchmark output?
Which function entry points are most vulnerable?
Do faults in the benchmark array cause silent data corruption?
Do faults in the stack affect control flow or computation?
How do targeted faults compare to full-SRAM random faults?

This profiling script prepares the information needed to answer those questions later.

## Running the Scripts

From Terminal 1:

sudo openocd -f interface/cmsis-dap.cfg -f target/rp2040.cfg

From Terminal 2:

./run_quicksort.sh

or:

./run_quicksort_profile.sh

## Troubleshooting

### OpenOCD is not running

If a script reports that OpenOCD is not running, start OpenOCD in a separate terminal:

sudo openocd -f interface/cmsis-dap.cfg -f target/rp2040.cfg

Then rerun the script.

### Script is not executable

Run:

chmod +x run_quicksort.sh
chmod +x run_quicksort_profile.sh

### Array symbol is not found

By default, the profiling script looks for an array symbol named:

data

If your array has a different name, run the script with:

ARRAY_SYMBOL=my_array ./run_quicksort_profile.sh

### Function name mismatch

The script profiles functions such as `swap_int`, `partition`, `quickSort`, and `print_array`.

If your function names differ, override the function list:

PROFILE_FUNCTIONS="swap_int partition quickSort print_array" ./run_quicksort_profile.sh
