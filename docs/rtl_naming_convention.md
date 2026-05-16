# CHI RTL Naming Convention

This project uses Verilog-2001 RTL and keeps naming explicit so flattened
channel wiring remains reviewable.

- Module names use `chi_<block>_<role>`.
- Clock and reset are `clk` and active-low `rstn`.
- Registered state ends in `_q`; next-state or combinational helpers avoid
  `_q`.
- Valid/ready handshakes use `<name>_valid`, `<name>_ready`, and pulse-style
  accepts use `<name>_fire`.
- Flattened channel payloads end in `_flit`; vectors carrying several flits
  use `_flat`.
- Global node IDs are named `<type>_NODE_ID` at the instance boundary.
- Simulation-only checks are wrapped in `synthesis translate_off/on`.
- Vendor-specific physical hooks use neutral insertion-point names such as
  `*_cg_en`, `*_bist_*`, or `*_init_*`.
