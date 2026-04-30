# FT601 RX Command Simulation

This simulation verifies the host-to-FPGA path:

- `ft601_fifo_if.v` drains FT601-style synchronous FIFO data using `RXF_N`, `OE_N`, and `RD_N`.
- `cmd_dispatcher.v` consumes `rx_data/rx_valid/rx_ready` and decodes command frames.
- A local `ila_ft601` stub is included in the testbench so the debug IP is not required for behavioral simulation.

Run from the Vivado 2024.2 command prompt at the project root:

```bat
vivado -mode batch -source TDC_PC_Ver2.0.srcs/sources_1/sim/run_ft601_cmd_dispatcher_sim.tcl
```

Expected result:

- The log prints `TEST PASSED: FT601 RX words advanced correctly and commands decoded`.
- The temporary simulation project is created under `TDC_PC_Ver2.0.srcs/sources_1/sim/xsim_ft601_cmd_dispatcher`.

The test covers:

- A single AD5686 command with unique payload words.
- Back-to-back commands while `cmd_dispatcher` temporarily deasserts `rx_ready`.
- A downstream-ready stall where FT601 input keeps draining into the local RX FIFO, then resumes decoding without repeating the same word.
