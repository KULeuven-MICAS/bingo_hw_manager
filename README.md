# Bingo Hardware Task Manager

A hardware task scheduler for heterogeneous multi-core, multi-chiplet SoCs. It accepts a stream of task descriptors with encoded dependency information, resolves inter-task dependencies through a per-cluster dependency matrix, and dispatches ready tasks to execution cores. The dependency matrix is an **identity-aware tagged scoreboard** — a consumer waits for *its* producer rather than any signal from a producer core. See **Identity-Aware Dependencies**.

On top of that static core, the manager carries the DARTS extensions: a per-chiplet
**CERF** (Conditional Execution Register File) for runtime task skipping, a
per-(core, cluster) **load monitor**, and a **power manager** with an autonomous
DFS mode and a host-notifying DVFS mode.

**Authors:** Fanchen Kong, Xiaoling Yi, Yunhao Deng  
**Affiliation:** KU Leuven (MICAS)

## Architecture Overview

```
Host / Software Runtime
         |
         | Task descriptors (64-bit packed structs)
         v
  +--------------+       +---------------------------------------------------+
  | Task Queue   |       |  Per-Chiplet HW Manager (bingo_hw_manager_top)    |
  | (AXI-Lite    |------>|                                                   |
  |  slave or    |       |  stream_demux (by assigned_core_id)               |
  |  master)     |       |        |                |                         |
  +--------------+       |        v                v                         |
                         |  +-----------+    +-----------+                   |
                         |  | Waiting   |    | Waiting   |  ... one per core |
                         |  | Queue c0  |    | Queue c1  |  (depth 8)        |
                         |  +-----+-----+    +-----+-----+                   |
                         |        |                |                         |
                         |   dep_check_manager FSM (IDLE -> WAIT_DEP_CHECK   |
                         |        |            -> WAIT_QUEUES -> FINISH)     |
       CERF (32 groups) -+---> cond_exec_skip[core] (skip / propagate deps)  |
                         |        |                |                         |
                         |  +-----v----------------v-----------------+       |
                         |  | Tagged Dependency Matrix (per cluster) |       |
                         |  | cell = 2**DepTagWidth presence bits    |       |
                         |  |  set  : sb[row][col][tag] = 1 (always) |       |
                         |  |  check: bit[row][c][tag] for c in mask |       |
                         |  |  clear: drop that one bit on pass      |       |
                         |  +-----+----------------------------------+       |
                         |        |                                          |
                         |  +-----+---------------+                          |
                         |  v                     v                          |
                         | Ready Queue        Checkout Queue                 |
                         | [core][cluster]    [core][cluster]                |
                         |  -> Device Core     -> dep_set                    |
                         |        |                 |                        |
                         |   (execute)     +--------+--------+               |
                         |        |        |                 |               |
                         |        v    Local dep_set    Remote dep_set (H2H) |
                         |  Done Queue     |            Chiplet Dep Set      |
                         |  [core][cluster]|            (AXI-Lite master)    |
                         |  (per-pair FIFO)|                 |               |
                         |        |        |                 v               |
                         |        +--> dep_matrix_set arbiter        to remote|
                         |             (N_CORES*N_CLUSTERS + 1 inputs)       |
                         |               ^                                   |
                         |  Chiplet Done Queue (write_mailbox) <---- from    |
                         |                                        remote H2H |
                         |                                                   |
                         |  Load Monitor (pending per core/cluster)          |
                         |  Power Manager (DFS clock scaling | DVFS doorbell) |
                         +---------------------------------------------------+
```

## Task Descriptor Format

Each task is a 64-bit packed struct pushed into the task queue. Fields are listed
in packing order, most-significant first (`bingo_hw_manager_task_desc_full_t` in
[bingo_hw_manager_top.sv](src/bingo_hw_manager_top.sv)):

| Field | Width | Description |
|-------|-------|-------------|
| `reserved_bits` | `64 - TaskDescWidth` | Padding (4 bits at default parameters) |
| `dep_set_tag` | `DepTagWidth` | Per-edge identity tag this set carries |
| `dep_set_code` | N_CORES | Bitmask: which core rows to signal in dep matrix |
| `dep_set_cluster_id` | log2(clusters) | Target cluster for dep_set |
| `dep_set_chiplet_id` | `ChipIdWidth` | Target chiplet for dep_set |
| `dep_set_all_chiplet` | 1 | Broadcast dep_set to all chiplets |
| `dep_set_en` | 1 | Enable dependency signaling after completion |
| `dep_check_tag` | `DepTagWidth` | Per-edge identity tag this check expects |
| `dep_check_code` | N_CORES | Bitmask: which core columns to check in dep matrix |
| `dep_check_en` | 1 | Enable dependency checking before dispatch |
| `assigned_core_id` | log2(cores) | Target core within cluster |
| `assigned_cluster_id` | log2(clusters) | Target cluster within chiplet |
| `assigned_chiplet_id` | `ChipIdWidth` | Target chiplet |
| `task_id` | `TaskIdWidth` | Unique identifier (0-4095 by default) |
| `task_type` | 2 | `00` normal, `01` dummy (sync only), `10` gating, `11` reserved |
| `cond_exec_en` | 1 | Task is conditional — dispatch gated by the CERF |
| `cond_exec_group_id` | 5 | CERF group (0-31) this task is gated by |
| `cond_exec_invert` | 1 | Execute when the group is *inactive* instead |

The tag fields and the CERF fields are carved from the descriptor's reserved
bits, so the 64-bit layout is unchanged. The RTL flags a build-time `$error` if
`TaskDescWidth` ever exceeds `HostAxiLiteDataWidth`.

The `done_info` written back by a core is a 32-bit struct:
`{reserved, assigned_cluster_id, assigned_core_id, task_id}` — the core and
cluster fields are what route a completion to its per-(core, cluster) done queue.

## Task Lifecycle

```
1. PUSH      Host writes task descriptor to task queue (slave mailbox or
             manager-side master fetch from task_list_base_addr_i)
2. ROUTE     Demux routes task to assigned core's waiting queue
3. GATE      CERF check (cond_exec_en): if the task's group is inactive
             (or active with cond_exec_invert), cond_exec_skip fires — the
             task is dropped from the ready queue and rewritten as a dummy
             into the checkout queue, so its dep_set still propagates
4. CHECK     dep_check_manager reads dep_matrix:
             - dep_check_en=0: bypass (immediate pass)
             - dep_check_en=1: wait until the expected tag is present in
               every required column
5. CLEAR     On pass, clear the checked (column, tag) presence bits
6. DISPATCH  Task enters ready queue; core reads and executes
             (dummy tasks are filtered out — they never reach a core)
7. COMPLETE  Core writes done_info to per-(core,cluster) done queue
8. SIGNAL    Done queue + checkout queue match triggers dep_set:
             - Local: set the tag's presence bit in target cluster's dep matrix
             - Remote: AXI-Lite write to target chiplet's H2H mailbox
             Dummy checkout entries fire dep_set with no done-queue match;
             normal (00) and gating (10) entries require one
```

## Tagged Dependency Matrix

Each cluster has a dependency matrix with `N_CORES x N_CORES` cells, where each cell is a `2**DepTagWidth` **presence-bit scoreboard** over per-edge identity tags.

```
             Column (signal source core)
             core 0    core 1    core 2
Row 0 (co0)  [tags]    [tags]    [tags]   <- what core 0 waits for
Row 1 (co1)  [tags]    [tags]    [tags]   <- what core 1 waits for
Row 2 (co2)  [tags]    [tags]    [tags]   <- what core 2 waits for
```

**Operations** ([bingo_hw_manager_dep_matrix.sv](src/bingo_hw_manager_dep_matrix.sv), parameter `TagWidth`, driven from the top-level `DepTagWidth`):
- `set_column(col, mask, tag)`: For each row in mask, set the presence bit `[row][col][tag]`. **Always succeeds** (no overlap rejection, `dep_set_ready = '1`).
- `check_row(row, mask, tag)`: True if bit `[row][c][tag]` is set for every column `c` in the mask.
- `clear_row(row, mask, tag)`: Clear bit `[row][c][tag]` for each column `c` in the mask.

A set and a clear in the same cycle always target different tag slots (a clear
follows a check that read the registered set a cycle earlier), so they never
conflict. There is no overlap rejection or backpressure, so the deadlock of the
historical 1-bit overlap-detecting design (a second `set` to an already-set bit
was rejected, creating circular backpressure through the done queue) cannot
occur.

## Identity-Aware Dependencies (per-edge tags)

An identity-blind cell (one shared counter per `(consumer_core, producer_core)`
pair) knows the *number* of pending signals from a producer core, not *which*
producer raised them. Because one cell is shared by **every** producer→consumer
edge that maps to the same pair, a consumer could drain a stray signal meant for
a different consumer and dispatch **before its own input is ready** (the
counter-sharing hazard). That legacy counter matrix — and the even older
`serialize_shared_counter_consumers` software mitigation — have been **removed**;
per-edge identity tags are the design.

- **Hardware:** each cell is a `2**DepTagWidth` **presence-bit scoreboard**. A
  `set` writes the bit at its `dep_set_tag`; a `check` passes only on its own
  `dep_check_tag`; `clear` clears that one bit. A stray set carries a tag no
  consumer expects, so it can never satisfy an unrelated check. `DepTagWidth=4`
  (default) sizes the scoreboard to a layer's natural concurrency. The tag is
  keyed on the **bare producer core column**, so cross-cluster and cross-chiplet
  producers fold onto the same cell — the tag is exactly what keeps them apart.
- **Software (mini-compiler):** `bingo_transform_dfg_allocate_dep_tags(W)` assigns
  each edge a tag via an optimal **minimum chain-cover** of the happens-before
  partial order per cell (edges that can never be live at once share a tag). The
  order accounts for **same-core HOL** execution (each core dispatches its tasks in
  topological order), which collapses same-core/diagonal cells to a single chain →
  one tag. This reuse is what lets a tiny fixed `DepTagWidth` suffice with **no
  separate concurrency-bounding pass**: if a cell ever needs more than `2**W`
  simultaneously-live edges the allocator **raises** (a placement signal —
  co-locate/serialize those producers, or widen `DepTagWidth`), rather than
  silently aliasing. Multi-target set/check ops (true broadcast dep_set) are not
  yet tagged and raise `NotImplementedError` instead of guessing. The pass must
  run **last**, after the dummy-set/dummy-check transforms and dep-info
  assignment, when every set/check operation is final. `tag_width` passed here
  must match the RTL `DepTagWidth`.

The tags ride the existing datapath: they live inside `dep_check_info`/
`dep_set_info` in the descriptor, flow through the dep-matrix set arbiter/demux in
the `dep_matrix_set_meta` struct, and are checked by the per-core
`dep_check_manager`. End-to-end RTL tests: `test/tb_bingo_hw_manager_tagged.sv`
(single cluster) and `test/tb_bingo_hw_manager_tagged_mc.sv` (multi-cluster
cross-cluster aliasing).

## Per-(Core, Cluster) Done Queues

Each `(core, cluster)` pair has its own independent done queue FIFO:

```
Done Queues: [NUM_CORES][NUM_CLUSTERS] independent FIFOs

done_q[0][0]   done_q[0][1]     <- core 0, clusters 0..1
done_q[1][0]   done_q[1][1]     <- core 1, clusters 0..1
done_q[2][0]   done_q[2][1]     <- core 2, clusters 0..1
```

The pop condition for each FIFO depends ONLY on its own state:
```
done_q_pop[core][cluster] = !done_q_empty[core][cluster]
                          && checkout[core][cluster].task_type inside {NORMAL, GATING}
                          && arbiter_ready[core + cluster * N_CORES]
```

No cross-core or cross-cluster dependency in the pop logic. This eliminates head-of-line blocking where one core's completion stalls behind another core's entry in a shared FIFO.

In CSR mode the per-core writes are arbitrated once (`stream_arbiter`) and then
demuxed to the target FIFO by the `assigned_core_id` / `assigned_cluster_id`
carried in the done info; in AXI-Lite mode a single write mailbox feeds the same
demux.

## Module Hierarchy

```
bingo_hw_manager_top
 |
 +-- Task Queue (1x)
 |    +-- write_mailbox (TASK_QUEUE_TYPE=0, AXI-Lite slave) OR
 |    +-- task_queue_master (TASK_QUEUE_TYPE=1, AXI-Lite master)
 |
 +-- Per-Core Pipeline (NUM_CORES_PER_CLUSTER instances)
 |    +-- stream_demux (task queue -> core, by assigned_core_id)
 |    +-- fifo_v3 (waiting_dep_check_queue, depth=8, hardcoded)
 |    +-- dep_check_manager (4-state FSM)
 |    +-- stream_filter (dep_check_en bypass) + stream_demux (to cluster matrix)
 |    +-- stream_filter (dummy-check drop)   + stream_demux (ready+checkout path)
 |
 +-- Per-Cluster Dep Matrix (NUM_CLUSTERS_PER_CHIPLET instances)
 |    +-- dep_matrix (tagged presence-bit scoreboard, TagWidth=DepTagWidth)
 |
 +-- Per-(Core, Cluster) Queues (N_CORES x N_CLUSTERS instances each)
 |    +-- stream_filter (dummy-set + CERF-skip drop before ready queue)
 |    +-- Ready Queue: read_mailbox (AXI-Lite) or fifo_v3 (CSR)
 |    +-- Checkout Queue: fifo_v3 (depth=CheckoutQueueDepth)
 |    +-- Done Queue: fifo_v3 (depth=DoneQueueDepth)
 |    +-- stream_demux (local vs H2H dep_set routing)
 |    +-- stream_filter (dep_set_en filtering)
 |
 +-- Dep Matrix Set Arbiter (1x)
 |    +-- stream_arbiter (N_CORES*N_CLUSTERS + 1 inputs)
 |    +-- stream_demux (route to cluster dep matrix)
 |    +-- stream_demux (route to core column within cluster)
 |
 +-- Ready/Done CSR bridge (READY_AND_DONE_QUEUE_INTERFACE_TYPE=1)
 |    +-- csr_to_fifo (csr_to_fifo_read + csr_to_fifo_write)
 |    +-- stream_arbiter (done-queue writes) -> per-(core,cluster) demux
 |
 +-- H2H Communication
 |    +-- Chiplet Dep Set Master (AXI-Lite master, 1x)
 |    +-- stream_arbiter (chiplet dep set, from all checkout queues)
 |    +-- Chiplet Done Queue (write_mailbox, depth=ChipletDoneQueueDepth, 1x)
 |
 +-- Power Manager (1x)
 |    +-- bingo_hw_manager_pm (DFS clock gating/scaling or DVFS host doorbell)
 |
 +-- DARTS (1x each)
      +-- bingo_hw_manager_cond_exec_controller (CERF, NumGroups=32)
      +-- bingo_hw_manager_load_monitor (pending counters per core/cluster)
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `NUM_CORES_PER_CLUSTER` | 4 | Execution cores per cluster |
| `NUM_CLUSTERS_PER_CHIPLET` | 2 | Clusters per chiplet |
| `DepTagWidth` | 4 | Tag width (cell holds up to `2**DepTagWidth` concurrent edges) |
| `TaskIdWidth` | 12 | Task ID width (max 4096 tasks) |
| `ChipIdWidth` | 8 | Chiplet ID width (max 256 chiplets) |
| `HostAxiLiteAddrWidth` | 48 | Host-side AXI address width |
| `HostAxiLiteDataWidth` | 64 | Host-side AXI data width (task descriptor) |
| `DeviceAxiLiteAddrWidth` | 48 | Device-side AXI address width |
| `DeviceAxiLiteDataWidth` | 32 | Device-side AXI data width (done info) |
| `TaskQueueDepth` | 32 | Incoming task FIFO depth |
| `ChipletDoneQueueDepth` | 32 | H2H (from-remote) dep_set mailbox depth |
| `DoneQueueDepth` | 32 | Per-(core,cluster) done FIFO depth |
| `CheckoutQueueDepth` | 8 | Per-(core,cluster) checkout FIFO depth |
| `ReadyQueueDepth` | 8 | Per-(core,cluster) ready FIFO depth |
| `ReadyQueueAddrOffset` | 4096 | Address stride between per-(core,cluster) ready queues |
| `TASK_QUEUE_TYPE` | 1 | 0: AXI-Lite slave, 1: AXI-Lite master |
| `READY_AND_DONE_QUEUE_INTERFACE_TYPE` | 1 | 0: AXI-Lite, 1: CSR req/resp |
| `HOST_DVFS_MSIP_BIT` | 3 | Host DVFS doorbell bit inside the shared CLINT MSIP word |

The per-core waiting queue depth is currently hardcoded to 8 rather than
parameterized.

## Interface Modes

**Task Queue:**
- **Mode 0 (Slave):** Host pushes task descriptors via AXI-Lite writes to a mailbox
- **Mode 1 (Master):** HW manager fetches task descriptors from host memory at `task_list_base_addr_i` (`num_task_i` descriptors, kicked off by `bingo_hw_manager_start_i`, which the manager clears via `reset_start_o`)

**Ready/Done Queues:**
- **Mode 0 (AXI-Lite):** Cores read ready tasks and write completions via AXI-Lite. Each `(core, cluster)` ready queue sits at `ready_queue_base_addr_i + (core + cluster * N_CORES) * ReadyQueueAddrOffset`
- **Mode 1 (CSR):** Cores use lightweight CSR req/resp interface (lower latency)

Either way the manager derives a per-core "waiting for a task" status from the
stalled read (AR valid without R ready, or CSR read request not accepted) and
feeds it to the power manager.

## Cross-Chiplet Communication

When a task's `dep_set_chiplet_id != chip_id_i`, the dependency signal is routed to a remote chiplet via the H2H path:

1. Checkout queue entry routed to chiplet dep_set arbiter
2. `bingo_hw_manager_chiplet_dep_set` module sends AXI-Lite write to remote chiplet's mailbox
3. Remote chiplet receives via `from_remote_axi_lite_req_i` into its chiplet done queue
4. Remote chiplet processes the signal through its dep matrix set arbiter (input `N_CORES*N_CLUSTERS`, the extra port on the arbiter), using the *sending* task's `assigned_core_id` as the matrix column and its `dep_set_tag`

Broadcast mode (`dep_set_all_chiplet = 1`) sends the signal to all chiplets simultaneously. Note that broadcast sets are not yet covered by the per-edge tag allocator (see **Identity-Aware Dependencies**).

## Power Management

`bingo_hw_manager_pm` aggregates the per-core idle status into up to 32 power
domains (`core_power_domain_i` maps each `(core, cluster)` to a domain; a value
≥ 32 means "unmapped"). A domain is idle only when *all* of its cores are
waiting for a task. Two modes, selected by `pm_mode_i`:

- **DFS (`pm_mode_i = 0`):** the PM autonomously writes the on-chip clock/reset
  controller over its AXI-Lite master, switching each domain between
  `normal_power_level_i` and `idle_power_level_i`.
- **DVFS (`pm_mode_i = 1`):** the PM only monitors chip-wide idle/busy and
  notifies the host. It publishes `dvfs_request_o = {target_level[15:8],
  direction[1], pending[0]}` and rings a doorbell by read-modify-writing the
  host's dedicated CLINT MSIP bit (`HOST_DVFS_MSIP_BIT` at
  `dvfs_clint_msip_addr_i`), preserving other harts' pending bits. The host ISR
  drives the external PMIC (voltage) and the clock controller (frequency) in the
  safe V/F order — raise: V then F; lower: F then V — and closes the handshake
  through `dvfs_ack_i`.

Idle power management as a whole is gated by `bingo_hw_manager_enable_idle_pm_i`.

## Dependencies

- [AXI](https://github.com/pulp-platform/axi) v0.39.1 — AXI-Lite definitions, crossbar
- [common_cells](https://github.com/pulp-platform/common_cells) v1.37.0 — FIFO, stream arbiter/demux/filter, counters

## DARTS: Dynamic Adaptive Runtime Task Scheduling

DARTS extends the static scheduler with conditional execution support for data-dependent workloads (MoE routing, early exit, mixture-of-depths).

### Conditional Execution (CERF)

A **32-entry** Conditional Execution Register File (CERF) per chiplet enables
runtime task skipping. Tasks marked conditional (`cond_exec_en`) are executed or
skipped based on the CERF bit selected by their `cond_exec_group_id` (0-31,
inverted by `cond_exec_invert`). The CERF is a single 32-bit bitmask register:
software writes the whole state via `cerf_write_data_i` + `cerf_write_en_i` and
reads it back on `cerf_state_o` — in practice a **gating task** (`task_type=10`)
runs on a core and writes the CSR on completion. Because the CERF lives inside
`bingo_hw_manager_top`, group *N* on chiplet 0 and group *N* on chiplet 1 are
different physical registers.

The user expresses conditional execution through **conditional edges** in the DFG:

```python
# Router conditionally activates each expert (compiler handles the rest)
dfg.bingo_add_edge(router, expert_0, cond=True)
dfg.bingo_add_edge(router, expert_1, cond=True)
dfg.bingo_add_edge(expert_0, aggregator)          # unconditional

# Compile: auto-assigns CERF groups, promotes router to gating task
compile_dfg(dfg)

# Simulate: specify which nodes are active
run_sim(dfg, config, active_nodes={expert_0})
```

The compiler pass `bingo_compile_conditional_regions()`:
1. Validates that every node has a core assignment, then scans edges for `cond=True`
2. Auto-promotes source nodes to gating tasks (`task_type=2`)
3. Groups conditional targets by connected components over *unconditional* edges (unconditional edges between targets = shared CERF group)
4. Assigns CERF group IDs with **cross-region reuse**: two gating regions may share a group pool iff one provably happens before the other (every target of *a* has a DFG path to *b*'s gating node). By Dilworth's theorem the minimum number of pools equals the largest antichain of simultaneously-live regions, found by minimum chain cover via bipartite matching — the same construction as the dep-tag allocator. The pool counter is scoped **per chiplet** (one CERF per chiplet) and each independent chain is sized to its widest region; overflowing 32 groups raises rather than aliasing.
5. Records the actual vs. naive (no-reuse) group counts per chiplet for the compiler ablation, and snapshots each gating node's own conditional targets so later dummy-insertion rewiring can't confuse runtime activation resolution

Skipped tasks still propagate dependency signals — the checkout entry is rewritten as a dummy — preserving graph correctness.

### Load Monitor

`bingo_hw_manager_load_monitor` keeps a saturating pending-task counter per
`(core, cluster)`: incremented on ready-queue pop (dispatch), decremented on
done-queue push (completion), unchanged when both happen in the same cycle. The
chip-wide sum is exposed as `load_total_pending_o` for host-driven load
balancing; the per-core vector is left unconnected at the top level today.

### Evaluation Results

Evaluated via cycle-accurate Python simulator (`scripts/eval_darts.py`):

| Workload | Configuration | Speedup |
|----------|---------------|---------|
| MoE 8 experts, top-2 | 1 cluster, 3 cores | 2.29x |
| MoE 16 experts, top-1 | 1 cluster, 3 cores | 4.15x |
| MoE 8 experts, top-2 | 2 chiplets | 1.84-1.95x |
| Early exit (stage 0/4) | 1 cluster, 3 cores | 3.28x |

## Source Files

| Level | File | Description |
|-------|------|-------------|
| 0 | `bingo_hw_manager_mailbox_adapter.sv` | AXI-Lite to mailbox adapter |
| 0 | `bingo_hw_manager_read_mailbox.sv` | FIFO-to-AXI-Lite read bridge |
| 0 | `bingo_hw_manager_write_mailbox.sv` | AXI-Lite-to-FIFO write bridge |
| 0 | `bingo_hw_manager_task_queue_master.sv` | AXI-Lite master for task fetching |
| 0 | `bingo_hw_manager_csr_to_fifo{,_read,_write}.sv` | CSR interface adapters |
| 1 | `bingo_hw_manager_dep_matrix.sv` | Dependency matrix: identity-aware tagged presence-bit scoreboard |
| 1 | `bingo_hw_manager_chiplet_dep_set.sv` | H2H AXI-Lite master |
| 1 | `bingo_hw_manager_dep_check_manager.sv` | Dependency check FSM |
| 1 | `bingo_hw_manager_pm.sv` | Power manager (DFS / DVFS) |
| 1 | `bingo_hw_manager_cond_exec_controller.sv` | CERF (conditional execution) |
| 1 | `bingo_hw_manager_load_monitor.sv` | Load monitoring |
| 2 | `bingo_hw_manager_top.sv` | Top-level integration |
| — | `bingo_hw_manager_dep_check_sum.sv` | H2H fan-in barrier counter — standalone, **not yet instantiated** and not listed in `Bender.yml` |

## Testing

Two layers, both self-contained in this repo:

- **Cycle-accurate Python model** (`model/`) mirroring the RTL pipeline, with a
  pytest suite in `model/tests/`:
  - `test_dep_matrix.py` — the matrix primitive (tagged presence-bit scoreboard)
  - `test_single_chiplet.py`, `test_multi_chiplet.py` — pipeline / H2H integration
  - `test_cross_cluster_handoff_guard.py` — cross-cluster placement guard
  - `test_identity_stray_increment.py` — reproduces the counter-sharing hazard and shows the tag fix closes it
  - `test_dep_tag_allocator.py` — the tag allocator (min-chain-cover): edge pairing, tag reuse, distinct tags for concurrent edges, capacity backstop
  - `test_cerf_group_allocator.py` — the CERF group allocator: per-chiplet scoping, cross-region reuse, chain-pool sizing, 32-group overflow
  - `test_dep_sync.py` — multi-cluster dispatch-before-producer gate (must be clean under tags); also runnable as a CLI
- **RTL testbench harness** (`test/tb_bingo_hw_manager_harness.svh`) with deadlock
  detection, dep-matrix monitoring, and trace logging, driving the testbenches:
  `tb_bingo_hw_manager_top` (multi-chiplet), `tb_bingo_hw_manager_cerf_basic/skip`
  (CERF), `tb_bingo_hw_manager_dep_matrix` (matrix unit), and
  `tb_bingo_hw_manager_tagged`/`_tagged_mc` (identity-aware deps end-to-end).
  Per-test stimulus lives in the matching `tb_stimulus_*.svh`.
- **DFG compiler** (`sw/bingo_dfg.py`) with automatic dummy task insertion, the
  identity-aware per-edge tag allocator, and the CERF group allocator (both
  min-chain-cover). Model frontends for MoE / early-exit / speculative-decode
  workloads live in `sw/bingo_frontend.py`.

```bash
# RTL: compile + simulate one testbench (requires QuestaSim)
make compile.log
make sim-bingo_hw_manager_top.log           # or _tagged / _tagged_mc / _dep_matrix / _cerf_basic / _cerf_skip

# Python model + compiler tests (42 tests)
make test-model                             # python3 -m pytest model/tests/ -v

# Generated DFG-pattern tests and model-vs-RTL cross-validation
make test-all-patterns
make test-cross-validate

# Dependency-sync gate as a standalone report
python3 model/tests/test_dep_sync.py --seeds 20 --clusters 2
```

All Python model tests and all RTL testbenches pass; the per-edge identity tags
drive the dispatch-before-producer hazard to zero.
