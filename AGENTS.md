# Repository Agent Instructions

## Optimization documentation is part of the implementation

`OPTIMIZATION.md` is a required design and performance reference for this
repository. It must be read and taken into account before making changes to
the M68030 frontend, DSP56001 program, rasterizer, packet format, Ordering
Table, framebuffer/Z-buffer path, host-port protocol, SSI, Falcon crossbar,
DMA routing, memory layout, or timing instrumentation.

Whenever a code change affects any of those areas:

1. Read the relevant sections of `OPTIMIZATION.md` before editing.
2. Preserve the documented architecture and stated constraints unless the
   change intentionally revises them.
3. Update `OPTIMIZATION.md` in the same change when behavior, interfaces,
   memory usage, performance data, optimization priorities, or design
   assumptions change.
4. Clearly distinguish measured results from estimates or theoretical limits.
5. Record new protocol fields, register usage, buffer ownership, ordering
   requirements, and validation results when applicable.

Changes must not leave `OPTIMIZATION.md` describing an obsolete pipeline,
stale DSP/CPU responsibility split, incorrect memory budget, or outdated
performance numbers.

## Performance claims

When changing performance-sensitive code, rerun the relevant build or test
where practical and update the documented baseline only with reproducible
measurements. Hatari/emulator timings and physical Falcon030 timings must be
identified separately.

If a fine-grained profiler is not available, document internal percentages as
an estimate or cost model rather than presenting them as measured values.

## Scope

These instructions apply to the entire repository. More specific
`AGENTS.md` files in subdirectories, if added later, may provide additional
rules for their respective directories but must not weaken the requirement to
keep `OPTIMIZATION.md` current.

