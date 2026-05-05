# Bingo Hardware Task Manager

A hardware task scheduler for heterogeneous multi-core, multi-chiplet SoCs. It accepts a stream of task descriptors with encoded dependency information, resolves inter-task dependencies through a counter-based dependency matrix, and dispatches ready tasks to execution cores.

**Authors:** Fanchen Kong, Xiaoling Yi, Yunhao Deng  
**Affiliation:** KU Leuven (MICAS)

## Architecture Overview

```
Host / Software Runtime
         |
         | Task descriptors (64-bit packed structs)
         v
  +--------------+       +------------------------------------------+
  | Task Queue   |       |  Per-Chiplet HW Manager                  |
  | (AXI-Lite or |------>|                                          |
  |  Master)     |       |  +-- stream_demux (by core_id) ------+  |
  +--------------+       |  |                                    |  |
                         |  v                                    |  |
                +--------+----------+   +--------+----------+   |  |
                | Waiting Queue     |   | Waiting Queue     |...|  |
                | Core 0 (depth 8)  |   | Core 1 (depth 8)  |   |  |
                +--------+----------+   +--------+----------+   |  |
                         |                       |               |  |
                    dep_check_manager FSM    dep_check_manager   |  |
                    (IDLE->CHECK->QUEUE->FINISH)                 |  |
                         |                       |               |  |
                +--------v-----------+-----------v---------+     |  |
                |  Counter-Based Dependency Matrix         |     |  |
                |  (per cluster, 8-bit saturating counters)|     |  |
                |  set: counter++ (always accepts)         |     |  |
                |  check: all required counters >= 1       |     |  |
                |  clear: counter-- (on successful check)  |     |  |
                +--------+-----------+---------------------+     |  |
                         |                                       |  |
          +--------------+--------------+                        |  |
          v                             v                        |  |
  +-------+--------+   +-------+--------+                       |  |
  | Ready Queue    |   | Checkout Queue |                       |  |
  | [core][cluster]|   | [core][cluster]|                       |  |
  | -> Device Core |   | -> dep_set     |                       |  |
  +----------------+   +-------+--------+                       |  |
          |                     |                                |  |
     (execute)        +---------+----------+                     |  |
          |           |                    |                     |  |
          v      Local dep_set      Remote dep_set (H2H)        |  |
  +-------+--------+  |           +-------------------+         |  |
  | Done Queue     |  |           | Chiplet Dep Set   |         |  |
  | [core][cluster]|  |           | AXI-Lite Master   |------+  |  |
  | (per-pair FIFO)|  |           | -> remote chiplet |      |  |  |
  +-------+--------+  |           +-------------------+      |  |  |
          |            |                                      |  |  |
          +----> Arbiter -> dep_matrix.set_column()           |  |  |
                                                              |  |  |
  +-----------------------------------------------------------+  |  |
  | From Remote Chiplets (H2H)                                   |  |
  |   -> Chiplet Done Queue -> Arbiter -> dep_matrix.set_column()|  |
  +--------------------------------------------------------------+  |
  +------------------------------------------------------------------+
```

## Task Descriptor Format

Each task is a 64-bit packed struct pushed into the task queue:

| Field | Width | Description |
|-------|-------|-------------|
| `task_type` | 2 | `00`=normal, `01`=dummy (sync only), `10`=gating (writes CERF), `11`=JIT-DFG (reserve / bind) |
| `is_bind` | 1 | When `task_type=2'b11`: `0`=RESERVE, `1`=BIND. Ignored otherwise |
| `task_id` | 12 | Unique identifier (0–4095) |
| `assigned_chiplet_id` | 8 | Target chiplet |
| `assigned_cluster_id` | log2(clusters) | Target cluster within chiplet |
| `assigned_core_id` | log2(cores) | Target core within cluster |
| `dep_check_en` | 1 | Enable dependency checking before dispatch |
| `dep_check_code` | N_CORES + 1 | Bitmask: which columns to check in dep matrix. The extra column is `WAIT_FOR_BIND_COL` (JIT-DFG) |
| `dep_set_en` | 1 | Enable dependency signaling after completion. **Repurposed as `rvdb_chain_en` on a JIT RESERVE.** |
| `dep_set_all_chiplet` | 1 | Broadcast dep_set to all chiplets |
| `dep_set_chiplet_id` | 8 | Target chiplet for dep_set. **Low 6 bits repurposed as `rvdb_table_base` on an RVDB-armed RESERVE.** |
| `dep_set_cluster_id` | log2(clusters) | Target cluster for dep_set |
| `dep_set_code` | N_CORES | Bitmask: which rows to signal in dep matrix. **Low log2(N_CORES) bits repurposed as `rvdb_source_slot` on an RVDB-armed RESERVE.** |
| `cond_exec_en` / `cond_exec_group_id` / `cond_exec_invert` | 1 / 5 / 1 | CERF gating |

## Task Lifecycle

```
1. PUSH      Host writes task descriptor to task queue
2. ROUTE     Demux routes task to assigned core's waiting queue
3. CHECK     dep_check_manager reads dep_matrix:
             - dep_check_en=0: bypass (immediate pass)
             - dep_check_en=1: wait until all required counters >= 1
4. CLEAR     On pass, decrement checked counters by 1
5. DISPATCH  Task enters ready queue; core reads and executes
6. COMPLETE  Core writes done_info to per-(core,cluster) done queue
7. SIGNAL    Done queue + checkout queue match triggers dep_set:
             - Local: increment counter in target cluster's dep matrix
             - Remote: AXI-Lite write to target chiplet's H2H mailbox
```

### Extensions on this lifecycle

- **CERF gating:** at step 3, a task with `cond_exec_en=1` is skipped if its CERF group bit is unset; the skipped task still propagates `dep_set` (step 7).
- **JIT-DFG:** a `task_type=2'b11, is_bind=0` (RESERVE) descriptor parks at step 3 on a synthetic `WAIT_FOR_BIND_COL` dependency. The host issues a matching BIND descriptor; `bind_resolver` merges the executable fields and pulses the WAIT_FOR_BIND counter, unblocking step 4.
- **RVDB:** a RESERVE with `rvdb_chain_en=1` arms a `rvdb_config[]` entry at push time. When some prior task completes (step 6) with a return value, `rvdb_lookup` indexes the per-cluster `bind_table` and synthesises a BIND that feeds the same `bind_resolver` as a host-issued JIT bind — completing the chain with **zero host involvement**.

## Counter-Based Dependency Matrix

Each cluster has a dependency matrix with `N_CORES x N_CORES` cells, where each cell is an **8-bit saturating counter** (not a single bit).

```
             Column (signal source core)
             core 0    core 1    core 2
Row 0 (co0)  [cnt]     [cnt]     [cnt]    <- what core 0 waits for
Row 1 (co1)  [cnt]     [cnt]     [cnt]    <- what core 1 waits for
Row 2 (co2)  [cnt]     [cnt]     [cnt]    <- what core 2 waits for
```

**Operations:**
- `set_column(col, mask)`: For each row in mask, increment `counter[row][col]`. **Always succeeds** (no overlap rejection, `dep_set_ready = '1`).
- `check_row(row, mask)`: True if `counter[row][c] >= 1` for every column `c` in the mask.
- `clear_row(row, mask)`: Decrement `counter[row][c]` by 1 for each column `c` in the mask.

This design eliminates the deadlock caused by the old 1-bit overlap detection, where a second `set` to an already-set bit was rejected, creating circular backpressure through the done queue.

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
                          && checkout[core][cluster].task_type == NORMAL
                          && arbiter_ready[core + cluster * N_CORES]
```

No cross-core or cross-cluster dependency in the pop logic. This eliminates head-of-line blocking where one core's completion stalls behind another core's entry in a shared FIFO.

## Module Hierarchy

```
bingo_hw_manager_top
 |
 +-- Task Queue (1x)
 |    +-- write_mailbox (AXI-Lite slave mode) OR
 |    +-- task_queue_master (AXI-Lite master mode)
 |
 +-- Per-Core Pipeline (NUM_CORES_PER_CLUSTER instances)
 |    +-- fifo_v3 (waiting_dep_check_queue, depth=8)
 |    +-- dep_check_manager (4-state FSM)
 |    +-- stream_filter (dep_check_en bypass)
 |    +-- stream_demux (route to cluster)
 |    +-- stream_filter (dummy task filter)
 |    +-- stream_demux (route to cluster, ready+checkout path)
 |
 +-- Per-Cluster Dep Matrix (NUM_CLUSTERS_PER_CHIPLET instances)
 |    +-- dep_matrix (counter-based, 8-bit cells)
 |
 +-- Per-(Core, Cluster) Queues (N_CORES x N_CLUSTERS instances each)
 |    +-- Ready Queue: read_mailbox or fifo_v3
 |    +-- Checkout Queue: fifo_v3 (depth=CheckoutQueueDepth)
 |    +-- Done Queue: fifo_v3 (depth=DoneQueueDepth)
 |    +-- stream_demux (local vs H2H dep_set routing)
 |    +-- stream_filter (dep_set_en filtering)
 |
 +-- Dep Matrix Set Arbiter (1x)
 |    +-- stream_arbiter (N_CORES*N_CLUSTERS + 1 inputs)
 |    +-- stream_demux (route to cluster dep matrix)
 |    +-- stream_demux (route to core within cluster)
 |
 +-- H2H Communication
 |    +-- Chiplet Dep Set Master (AXI-Lite master, 1x)
 |    +-- stream_arbiter (chiplet dep set, from all cores)
 |    +-- Chiplet Done Queue (write_mailbox, 1x)
 |
 +-- Power Manager (1x)
      +-- bingo_hw_manager_pm (idle-based clock gating)
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `NUM_CORES_PER_CLUSTER` | 4 | Execution cores per cluster |
| `NUM_CLUSTERS_PER_CHIPLET` | 2 | Clusters per chiplet |
| `TaskIdWidth` | 12 | Task ID width (max 4096 tasks) |
| `ChipIdWidth` | 8 | Chiplet ID width (max 256 chiplets) |
| `HostAxiLiteAddrWidth` | 48 | Host-side AXI address width |
| `HostAxiLiteDataWidth` | 64 | Host-side AXI data width (task descriptor) |
| `DeviceAxiLiteAddrWidth` | 48 | Device-side AXI address width |
| `DeviceAxiLiteDataWidth` | 32 | Device-side AXI data width (done info) |
| `TaskQueueDepth` | 32 | Incoming task FIFO depth |
| `DoneQueueDepth` | 32 | Per-(core,cluster) done FIFO depth |
| `CheckoutQueueDepth` | 8 | Per-(core,cluster) checkout FIFO depth |
| `ReadyQueueDepth` | 8 | Per-(core,cluster) ready FIFO depth |
| `TASK_QUEUE_TYPE` | 1 | 0: AXI-Lite slave, 1: AXI-Lite master |
| `READY_AND_DONE_QUEUE_INTERFACE_TYPE` | 1 | 0: AXI-Lite, 1: CSR req/resp |

## Interface Modes

**Task Queue:**
- **Mode 0 (Slave):** Host pushes task descriptors via AXI-Lite writes to a mailbox
- **Mode 1 (Master):** HW manager fetches task descriptors from host memory at `task_list_base_addr_i`

**Ready/Done Queues:**
- **Mode 0 (AXI-Lite):** Cores read ready tasks and write completions via AXI-Lite
- **Mode 1 (CSR):** Cores use lightweight CSR req/resp interface (lower latency)

## Cross-Chiplet Communication

When a task's `dep_set_chiplet_id != chip_id_i`, the dependency signal is routed to a remote chiplet via the H2H path:

1. Checkout queue entry routed to chiplet dep_set arbiter
2. `bingo_hw_manager_chiplet_dep_set` module sends AXI-Lite write to remote chiplet's mailbox
3. Remote chiplet receives via `from_remote_axi_lite_req_i` into its chiplet done queue
4. Remote chiplet processes the signal through its dep matrix set arbiter

Broadcast mode (`dep_set_all_chiplet = 1`) sends the signal to all chiplets simultaneously.

## Dependencies

- [AXI](https://github.com/pulp-platform/axi) v0.39.1 — AXI-Lite definitions, crossbar
- [common_cells](https://github.com/pulp-platform/common_cells) v1.37.0 — FIFO, stream arbiter/demux/filter, counters

## Conditional-DFG Hardware Extensions

The base scheduler is extended with **four** hardware features that let it execute data-dependent AI workloads (MoE, speculative decoding, early exit, Mixture of Depths) without going back to the host between branches. All are pure hardware — no on-chip learning, no host-in-the-loop.

### CERF — Conditional Execution Register File

A 32-entry CERF per chiplet enables runtime task skipping. A "gating" task (e.g. an MoE router) writes the CERF on completion; downstream tasks tagged with a CERF group are either dispatched or skipped depending on the bit:

```python
dfg.bingo_add_edge(router, expert_0, cond=True)   # conditional edge
dfg.bingo_add_edge(expert_0, aggregator)           # unconditional
compile_dfg(dfg)                                    # auto-assigns CERF groups
run_sim(dfg, config, active_nodes={expert_0})       # user never sees group IDs
```

Skipped tasks still propagate their `dep_set` so downstream consumers do not deadlock.

### Task-Slot Scoreboard (GPU-style dependency decoupling)

The host writes only `assigned_core_id`; HW synthesizes a logical `slot_id := assigned_core_id` at the AXI decode point, and the dependency matrix is indexed by the synthesized `slot_id`. A per-cluster scoreboard maintains the slot↔core mapping (identity at reset) so a future fault-recovery controller can rebind a slot to a different core without touching any dependency encoding the host already produced — analogous to GPU warp-ID vs SM-ID decoupling. `slot_id` is a HW-internal concept; no SW programmer ever sets it.

### JIT-DFG — Streaming partial-DFG dispatch (`task_type=2'b11`)

The host can push a **RESERVE** descriptor (`task_type=2'b11, is_bind=0`) for a slot whose executable fields are not yet known. The slot parks in `dep_check_manager` blocked on a synthetic `WAIT_FOR_BIND_COL` dependency. Later, the host issues a **BIND** descriptor (`task_type=2'b11, is_bind=1`) carrying the kernel + args + dep_set; `bind_resolver` matches the BIND to its RESERVE by `(cluster, assigned_core_id)` (which HW maps to the internal `slot_id`), merges the bind fields into a shadow flop, and pulses the `WAIT_FOR_BIND` counter — the slot dispatches in the next cycle as if it had been a normal task. Eliminates DFG re-issue cost for streaming workloads.

The mechanism is verified end-to-end across 4 testbenches (basic, bind-before-reserve, double-bind SVA, orphan force-drain). 

### RVDB — Return-Value-Driven Binding

Extends JIT-DFG so the HW reads a completed task's **return value** and uses it to look up the next task's bind from a host-installed **bind table** — **without going through the host runtime**. The kernel return value is forwarded via the device CSR (`{return_value[7:0], task_id[11:0]}` packed into CSR `0x5ff`), captured in `done_info.return_value`, and indexed by `rvdb_lookup` into a per-cluster 64×64-bit `bind_table` SRAM. The synthesised BIND feeds the same `bind_resolver` as a host-issued bind via a 3-way input mux (priority: local > rvdb > remote).

A RESERVE marks itself RVDB-driven by setting **repurposed bits** in `dep_set_info`:
```
dep_set_info.dep_set_en              → rvdb_chain_en       (1 bit)
dep_set_info.dep_set_code[1:0]       → rvdb_source_slot    (which slot's return value drives the chain)
dep_set_info.dep_set_chiplet_id[5:0] → rvdb_table_base     (offset into the shared bind table)
```
No new descriptor flavour, no new task_type. When `rvdb_chain_en=1`, the reserve push side-effects a write to the per-cluster `rvdb_config[]` register. When the source slot completes, `rvdb_lookup` synthesises the bind autonomously.

Verified end-to-end on `tb_bingo_hw_manager_rvdb_basic`. Eliminates the per-iteration host round-trip in autoregressive workloads (decoder loops, MoE routing, KV-eviction).

## Source Files

| Level | File | Description |
|-------|------|-------------|
| 0 | `bingo_hw_manager_mailbox_adapter.sv` | AXI-Lite to mailbox adapter |
| 0 | `bingo_hw_manager_read_mailbox.sv` | FIFO-to-AXI-Lite read bridge |
| 0 | `bingo_hw_manager_write_mailbox.sv` | AXI-Lite-to-FIFO write bridge |
| 0 | `bingo_hw_manager_task_queue_master.sv` | AXI-Lite master for task fetching |
| 0 | `bingo_hw_manager_csr_to_fifo*.sv` | CSR interface adapters (RVDB return_value extraction) |
| 1 | `bingo_hw_manager_dep_matrix.sv` | Counter-based dependency matrix (with WAIT_FOR_BIND col for JIT-DFG) |
| 1 | `bingo_hw_manager_chiplet_dep_set.sv` | H2H AXI-Lite master |
| 1 | `bingo_hw_manager_dep_check_manager.sv` | Dependency check FSM (exposes `state_o` for bind_resolver observation) |
| 1 | `bingo_hw_manager_pm.sv` | Power manager |
| 1 | `bingo_hw_manager_cond_exec_controller.sv` | CERF (conditional execution) |
| 1 | `bingo_hw_manager_scoreboard.sv` | Task-slot scoreboard |
| 1 | `bingo_hw_manager_bind_resolver.sv` | **JIT-DFG** per-core bind merge unit |
| 1 | `bingo_hw_manager_bind_table.sv` | **RVDB** per-cluster 64×64-bit bind-descriptor SRAM |
| 1 | `bingo_hw_manager_rvdb_lookup.sv` | **RVDB** per-cluster lookup unit |
| 2 | `bingo_hw_manager_top.sv` | Top-level integration |

## Testing

The test infrastructure includes:

- **RTL testbench harness** (`test/tb_bingo_hw_manager_harness.svh`) with deadlock detection, counter monitoring, structured trace logging, and a per-task `task_return_value_lut` for RVDB stim
- **Structured DFG patterns:** serial chain, parallel fork-join, double buffer, diamond, stacked GEMM, multi-chiplet chain
- **Random DAG stress tests:** 10–40 tasks, 1–4 chiplets, sparse/dense edge configurations
- **CERF testbenches:** `tb_bingo_hw_manager_cerf_basic` (skip + propagate dep_set), `tb_bingo_hw_manager_cerf_skip`
- **JIT-DFG testbenches:** basic reserve→bind, bind-before-reserve (pending buffer), double-bind SVA, orphan force-drain
- **RVDB testbenches:** basic chain (`tb_bingo_hw_manager_rvdb_basic`) — chain dispatches autonomously with no host bind round-trip
- **Cycle-accurate Python model** (`model/`) mirroring the RTL pipeline behavior
- **DFG compiler** (`sw/bingo_dfg.py`) with automatic dummy task insertion

Current regression: **8/8 testbenches pass** (top, 2 CERF, 4 JIT-DFG, 1 RVDB).

```bash
# Compile and simulate (requires Questa)
source /users/micas/fkong/no_backup/src_hemaia_eda.sh
make clean && make compile.log

# Run any one TB
cd build && ../scripts/run_vsim.sh --random-seed bingo_hw_manager_rvdb_basic

# Run Python model tests
source ../.venv/bin/activate
python3 scripts/run_all_tests.py --stress 200

# Run the conditional-DFG evaluation suite (8 experiments)
python3 scripts/eval_conditional.py
```