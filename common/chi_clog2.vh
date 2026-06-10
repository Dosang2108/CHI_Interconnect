`ifndef CHI_CLOG2_VH
`define CHI_CLOG2_VH

// Macro-only clog2 helper. This file is intentionally safe if Vivado adds it
// as a standalone Verilog source in 95/2K mode.
`define CHI_CLOG2(VALUE) \
    (((VALUE) <= 1)          ? 0  : \
     ((VALUE) <= 2)          ? 1  : \
     ((VALUE) <= 4)          ? 2  : \
     ((VALUE) <= 8)          ? 3  : \
     ((VALUE) <= 16)         ? 4  : \
     ((VALUE) <= 32)         ? 5  : \
     ((VALUE) <= 64)         ? 6  : \
     ((VALUE) <= 128)        ? 7  : \
     ((VALUE) <= 256)        ? 8  : \
     ((VALUE) <= 512)        ? 9  : \
     ((VALUE) <= 1024)       ? 10 : \
     ((VALUE) <= 2048)       ? 11 : \
     ((VALUE) <= 4096)       ? 12 : \
     ((VALUE) <= 8192)       ? 13 : \
     ((VALUE) <= 16384)      ? 14 : \
     ((VALUE) <= 32768)      ? 15 : \
     ((VALUE) <= 65536)      ? 16 : \
     ((VALUE) <= 131072)     ? 17 : \
     ((VALUE) <= 262144)     ? 18 : \
     ((VALUE) <= 524288)     ? 19 : \
     ((VALUE) <= 1048576)    ? 20 : \
     ((VALUE) <= 2097152)    ? 21 : \
     ((VALUE) <= 4194304)    ? 22 : \
     ((VALUE) <= 8388608)    ? 23 : \
     ((VALUE) <= 16777216)   ? 24 : \
     ((VALUE) <= 33554432)   ? 25 : \
     ((VALUE) <= 67108864)   ? 26 : \
     ((VALUE) <= 134217728)  ? 27 : \
     ((VALUE) <= 268435456)  ? 28 : \
     ((VALUE) <= 536870912)  ? 29 : \
     ((VALUE) <= 1073741824) ? 30 : 31)

`endif
