"""Hardware-calibrated latency profiles for DARTS evaluation.

This module centralises every delay parameter used by the evaluation
pipeline.  Each workload (MoE, early exit, speculative decoding,
Mixture of Depths) has a dedicated profile dataclass.  Two top-level
profile sets are provided:

  * ``SYNTHETIC`` — the current magic-number defaults (for regression).
  * ``CALIBRATED`` — **TO BE FILLED IN** from ZigZag / SNAX RTL / Banshee
    simulation results.  Every field that still needs measurement is
    marked with a ``# TODO(calibrate)`` comment and tagged with the
    simulation recipe required to obtain the number.

Usage::

    from hw_profiles import get_profile, HWConfig

    hw  = HWConfig()                      # default HeMAiA config
    moe = get_profile("calibrated").moe   # or "synthetic"
    work_delays["expert_0"] = moe.expert_delay

Simulation recipes (how to obtain each number):

  ZigZag:
    Define HeMAiA tile arch → run per-layer mapping → read cycle count.
    See ``docs/calibration.md`` for step-by-step.

  SNAX RTL (Verilator / QuestaSim):
    Compile SNAX cluster → load compiled GEMM kernel → read perf counter.

  Banshee:
    Run compiled RISC-V ELF on Banshee ISA sim → read instruction count.

  Roofline (analytical):
    cycles = max(FLOPS / peak_throughput, bytes / bandwidth).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional


# ════════════════════════════════════════════════════════════════
#  Hardware Platform Configuration
# ════════════════════════════════════════════════════════════════


@dataclass
class HWConfig:
    """HeMAiA hardware configuration.

    These parameters are fixed by the RTL and should match
    ``bingo_hw_manager_top.sv`` parameters.
    """

    # ── Topology ───────────────────────────────────────────────
    n_chiplets: int = 1
    n_clusters_per_chiplet: int = 2
    n_cores_per_cluster: int = 4          # NUM_CORES_PER_CLUSTER in RTL

    # ── Compute tile (VersaCore / SNAX GEMM accelerator) ──────
    gemm_array_rows: int = 8              # systolic array height
    gemm_array_cols: int = 8              # systolic array width
    clock_freq_mhz: int = 1000           # TODO(calibrate): post-synthesis fmax

    # ── Memory hierarchy ──────────────────────────────────────
    tcdm_size_kb: int = 512               # per-cluster scratchpad
    l3_size_kb: int = 4096                # shared L3 (if present)
    dram_bw_gbps: float = 32.0            # TODO(calibrate): off-chip bandwidth

    # ── Interconnect ──────────────────────────────────────────
    h2h_latency: int = 10                 # inter-chiplet message (cycles)
    # TODO(calibrate): measure actual H2H round-trip on HeMAiA testchip
    # Recipe: SNAX RTL sim with 2-chiplet config, measure mailbox latency

    # ── Queue depths (must match RTL parameters) ──────────────
    task_queue_depth: int = 32
    done_queue_depth: int = 32
    checkout_queue_depth: int = 8
    ready_queue_depth: int = 8

    @property
    def n_cores(self) -> int:
        return self.n_clusters_per_chiplet * self.n_cores_per_cluster

    @property
    def total_slots(self) -> int:
        return self.n_chiplets * self.n_cores


# ════════════════════════════════════════════════════════════════
#  Per-Workload Latency Profiles
# ════════════════════════════════════════════════════════════════


@dataclass
class MoEProfile:
    """Latency profile for Mixture-of-Experts workloads.

    Reference model: Mixtral-8x7B (d_model=4096, d_ff=14336, 8 experts)

    Each expert FFN is two GEMMs + activation:
      up_proj:   (batch, 4096) x (4096, 14336)  →  (batch, 14336)
      act:       SiLU element-wise
      down_proj: (batch, 14336) x (14336, 4096)  →  (batch, 4096)

    The router/gating network is a small linear layer:
      gate:      (batch, 4096) x (4096, 8)  →  (batch, 8)  + softmax + topk
    """

    # ── Expert FFN (the big kernel — dominates total latency) ──
    expert_delay: int = 200
    # TODO(calibrate): Expert FFN cycle count on VersaCore
    # GEMM dimensions: up_proj (B,4096)x(4096,14336) + down_proj (B,14336)x(4096)
    # Recipe: ZigZag with HeMAiA tile config, or SNAX RTL GEMM kernel
    # Expected: 5,000 – 50,000 cycles depending on array size and batch
    # Sweep batch = {1, 4, 8, 16, 32}
    #
    # Measurement table (fill in after simulation):
    # | batch | up_proj (cy) | act (cy) | down_proj (cy) | total (cy) | tool |
    # |-------|-------------|----------|----------------|-----------|------|
    # |   1   |             |          |                |           |      |
    # |   4   |             |          |                |           |      |
    # |   8   |             |          |                |           |      |
    # |  16   |             |          |                |           |      |
    # |  32   |             |          |                |           |      |

    # ── Router / gating network ────────────────────────────────
    router_delay: int = 50
    # TODO(calibrate): Router cycle count
    # GEMM: (B, 4096) x (4096, 8) = small, likely compute-bound
    # + softmax (element-wise, 8 values) + topk (trivial)
    # Recipe: ZigZag small-GEMM or Banshee ISA sim for softmax+topk on CVA6
    # Expected: 200 – 2,000 cycles
    #
    # | batch | linear (cy) | softmax+topk (cy) | total (cy) | tool |
    # |-------|------------|-------------------|-----------|------|
    # |   1   |            |                   |           |      |
    # |   8   |            |                   |           |      |

    # ── Aggregator (weighted sum of expert outputs) ────────────
    aggregator_delay: int = 100
    # TODO(calibrate): Aggregator cycle count
    # Operation: weighted sum of k expert outputs, each (B, 4096)
    # For top-2: 2 x scale + add, (B, 4096) element-wise
    # Recipe: Banshee ISA sim or roofline (memory-bound: 2*B*4096*4 bytes)
    # Expected: 100 – 1,000 cycles
    #
    # | batch | k | cycles | tool |
    # |-------|---|--------|------|
    # |   1   | 2 |        |      |
    # |   8   | 2 |        |      |

    # ── Input preprocessing (embedding / layernorm) ────────────
    input_delay: int = 50
    # TODO(calibrate): LayerNorm + embedding lookup
    # Recipe: Banshee ISA sim for LayerNorm on Snitch core
    # Expected: 50 – 500 cycles

    # ── Attention block (per-layer, before MoE) ────────────────
    attention_delay: int = 300
    # TODO(calibrate): Multi-head attention cycle count
    # Mixtral: 32 heads, d_head=128, d_model=4096
    # QKV projection: 3 x (B, 4096) x (4096, 4096)  ← 3 large GEMMs
    # Attention scores: (B, 32, L, 128) x (B, 32, 128, L)
    # Output projection: (B, 4096) x (4096, 4096)
    # Recipe: ZigZag for QKV+output GEMMs, Banshee for softmax+score
    # Expected: 10,000 – 100,000 cycles (depends heavily on seq_len L)
    #
    # | batch | seq_len | QKV (cy) | score (cy) | out_proj (cy) | total (cy) |
    # |-------|---------|----------|-----------|--------------|-----------|
    # |   1   |   128   |          |           |              |           |
    # |   1   |   512   |          |           |              |           |
    # |   1   |  2048   |          |           |              |           |

    def work_delays(self, n_experts: int = 8) -> dict[str, int]:
        """Generate work_delays dict for a single MoE layer."""
        d = {
            "input_prep": self.input_delay,
            "router": self.router_delay,
            "aggregator": self.aggregator_delay,
        }
        for i in range(n_experts):
            d[f"expert_{i}"] = self.expert_delay
        return d


@dataclass
class EarlyExitProfile:
    """Latency profile for early-exit networks.

    Reference model: multi-stage classifier (e.g., BranchyNet, BERT
    with early exit heads).
    """

    # ── Per-stage compute (transformer block or ResNet stage) ──
    stage_delay: int = 200
    # TODO(calibrate): One transformer block or ResNet stage
    # Transformer block = attention + FFN ≈ attention_delay + expert_delay
    # ResNet stage = 2-3 Conv3x3 + BN + ReLU
    # Recipe: ZigZag for transformer block, or SCALE-Sim for conv stages
    # Expected: 5,000 – 50,000 cycles (transformer), 1,000 – 10,000 (ResNet)
    #
    # | model     | stage | cycles | tool |
    # |-----------|-------|--------|------|
    # | BERT-base |   0   |        |      |
    # | BERT-base |   6   |        |      |
    # | BERT-base |  11   |        |      |

    # ── Classifier head (small linear + softmax) ───────────────
    classifier_delay: int = 50
    # TODO(calibrate): Early exit classifier
    # Operation: (B, d_model) x (d_model, n_classes) + softmax + threshold
    # Recipe: Banshee or roofline
    # Expected: 100 – 1,000 cycles

    # ── Output (final aggregation / decision) ──────────────────
    output_delay: int = 50

    def work_delays(self, n_stages: int = 4) -> dict[str, int]:
        """Generate work_delays dict for early-exit network."""
        d: dict[str, int] = {"output": self.output_delay}
        for s in range(n_stages):
            d[f"stage_{s}"] = self.stage_delay
            d[f"classifier_{s}"] = self.classifier_delay
        return d


@dataclass
class SpecDecodeProfile:
    """Latency profile for speculative decoding.

    Reference: target = Llama-2-70B (or Mixtral), draft = Llama-2-7B.
    Each draft step = one forward pass of the small model.
    Verify step = one forward pass of the large model on K+1 tokens.
    """

    # ── Draft model: one autoregressive step ───────────────────
    draft_delay: int = 100
    # TODO(calibrate): Draft model single-token forward pass
    # Model: e.g., Llama-2-7B — 32 layers x (attn + FFN)
    # On HeMAiA this would be a sequence of GEMM dispatches
    # Recipe: ZigZag full-model mapping with layer-by-layer breakdown
    # Expected: 5,000 – 20,000 cycles per token
    #
    # | draft_model   | tokens | cycles/token | total (cy) | tool |
    # |---------------|--------|-------------|-----------|------|
    # | Llama-2-7B    |   1    |             |           |      |
    # | TinyLlama-1B  |   1    |             |           |      |

    # ── Verify: target model forward pass on K+1 candidates ───
    verify_delay: int = 500
    # TODO(calibrate): Target model batch-verify forward pass
    # Model: e.g., Llama-2-70B on K+1 tokens (parallel verification)
    # This is the dominant cost — one full forward pass
    # Recipe: ZigZag for batch GEMM with K+1 tokens on target model
    # Expected: 50,000 – 500,000 cycles
    #
    # | target_model  | K+1 tokens | cycles | tool |
    # |---------------|-----------|--------|------|
    # | Llama-2-70B   |     4     |        |      |
    # | Llama-2-70B   |     6     |        |      |
    # | Llama-2-70B   |     8     |        |      |
    # | Mixtral-8x7B  |     4     |        |      |

    # ── Accept: commit token to KV cache ───────────────────────
    accept_delay: int = 50
    # TODO(calibrate): KV cache update per accepted token
    # Operation: copy K,V vectors (2 x d_model x n_layers floats) into cache
    # Recipe: Banshee or roofline (pure memory bandwidth)
    # Expected: 50 – 500 cycles per token

    # ── Output ─────────────────────────────────────────────────
    output_delay: int = 50

    def work_delays(self, n_draft: int = 5) -> dict[str, int]:
        """Generate work_delays dict for speculative decoding."""
        d: dict[str, int] = {
            "verify": self.verify_delay,
            "output": self.output_delay,
        }
        for i in range(n_draft):
            d[f"draft_{i}"] = self.draft_delay
            d[f"accept_{i}"] = self.accept_delay
        return d


@dataclass
class MoDProfile:
    """Latency profile for Mixture-of-Depths workloads.

    Reference: Raposo et al. 2024 — per-layer router decides whether
    to execute the full transformer block or skip (residual only).
    """

    # ── Transformer block (attention + FFN) ────────────────────
    block_delay: int = 500
    # TODO(calibrate): Full transformer block (attn + FFN)
    # This is attention_delay + expert_delay (for dense FFN)
    # Recipe: ZigZag full block mapping
    # Expected: 15,000 – 100,000 cycles
    #
    # | model        | layer | block (cy) | tool |
    # |--------------|-------|-----------|------|
    # | Llama-2-7B   |   0   |           |      |
    # | Mixtral-8x7B |   0   |           |      |

    # ── Per-layer router (tiny classifier) ─────────────────────
    router_delay: int = 50
    # TODO(calibrate): MoD router — (B, d_model) x (d_model, 1) + sigmoid
    # Very small, likely <100 cycles
    # Recipe: Banshee or analytical

    # ── Merge (residual addition) ──────────────────────────────
    merge_delay: int = 50
    # TODO(calibrate): Element-wise add of (B, d_model)
    # Recipe: roofline (memory-bound: 3 x B x d_model x 4 bytes)
    # Expected: 50 – 200 cycles

    def work_delays(self, n_layers: int = 12) -> dict[str, int]:
        """Generate work_delays dict for Mixture-of-Depths."""
        d: dict[str, int] = {}
        for l in range(n_layers):
            d[f"router_{l}"] = self.router_delay
            d[f"block_{l}"] = self.block_delay
            d[f"merge_{l}"] = self.merge_delay
        return d


@dataclass
class SWBaselineProfile:
    """Latency for the software conditional dispatch path (Gate I).

    This measures the overhead of doing conditional execution in
    software (on CVA6 host core) instead of hardware (CERF).

    Software path:
      1. Core completes gating kernel
      2. Core writes result to memory / CSR
      3. CVA6 host reads gating result (poll or interrupt)
      4. CVA6 computes which experts to activate
      5. CVA6 writes task descriptors for active experts via CSR
      6. Experts start executing

    Hardware path (CERF):
      1. Core completes gating kernel
      2. Core writes CERF via CSR (combinational, same cycle)
      3. Downstream experts check CERF in waiting queue (0 extra cycles)
    """

    # ── CVA6 host poll latency (read gating result from core) ──
    host_poll_cycles: int = 0
    # TODO(calibrate): CVA6 CSR read latency
    # Recipe: Banshee ISA sim — measure CSR read instruction cycles
    # Or SNAX RTL sim — measure AXI-Lite read round-trip
    # Expected: 5 – 50 cycles

    # ── CVA6 conditional dispatch (per-expert decision) ────────
    host_dispatch_per_expert_cycles: int = 0
    # TODO(calibrate): CVA6 cycles to push one task descriptor via CSR
    # Recipe: Banshee — compile a C loop that writes N task descriptors
    # Count total cycles / N
    # Expected: 10 – 30 cycles per expert

    # ── Total SW overhead per conditional decision ─────────────
    # total = host_poll + k * host_dispatch_per_expert
    # For k=2 of N=8: total ≈ poll + 2*dispatch ≈ 25–110 cycles
    # This is what CERF saves: 0 cycles (combinational) vs X cycles (SW)

    def total_overhead(self, k: int = 2) -> int:
        return self.host_poll_cycles + k * self.host_dispatch_per_expert_cycles


# ════════════════════════════════════════════════════════════════
#  Profile Sets
# ════════════════════════════════════════════════════════════════


@dataclass
class ProfileSet:
    """A complete set of workload profiles + hardware config."""
    name: str
    hw: HWConfig
    moe: MoEProfile
    early_exit: EarlyExitProfile
    spec_decode: SpecDecodeProfile
    mod: MoDProfile
    sw_baseline: SWBaselineProfile


# ── Synthetic (current magic numbers — for regression testing) ──

SYNTHETIC = ProfileSet(
    name="synthetic",
    hw=HWConfig(),
    moe=MoEProfile(
        expert_delay=200,
        router_delay=50,
        aggregator_delay=100,
        input_delay=50,
        attention_delay=300,
    ),
    early_exit=EarlyExitProfile(
        stage_delay=200,
        classifier_delay=50,
        output_delay=50,
    ),
    spec_decode=SpecDecodeProfile(
        draft_delay=100,
        verify_delay=500,
        accept_delay=50,
        output_delay=50,
    ),
    mod=MoDProfile(
        block_delay=500,
        router_delay=50,
        merge_delay=50,
    ),
    sw_baseline=SWBaselineProfile(
        host_poll_cycles=0,
        host_dispatch_per_expert_cycles=0,
    ),
)


# ── Calibrated (TO BE FILLED after simulation runs) ────────────
#
# Instructions:
#   1. Run ZigZag with HeMAiA tile config for each GEMM shape
#   2. Run SNAX RTL sim for 3-5 key kernels to validate ZigZag
#   3. Run Banshee for CVA6 host operations (Gate I)
#   4. Fill in the numbers below
#   5. Switch eval scripts to use "calibrated" profile
#
# Every field below with value 0 needs to be measured.
# Fields copied from SYNTHETIC are fallbacks — replace them.

CALIBRATED = ProfileSet(
    name="calibrated",
    hw=HWConfig(
        n_chiplets=1,
        n_clusters_per_chiplet=2,
        n_cores_per_cluster=4,
        gemm_array_rows=8,                # TODO(calibrate): actual VersaCore config
        gemm_array_cols=8,                 # TODO(calibrate): actual VersaCore config
        clock_freq_mhz=1000,              # TODO(calibrate): post-synthesis fmax
        tcdm_size_kb=512,
        dram_bw_gbps=32.0,                # TODO(calibrate): measured DRAM BW
        h2h_latency=10,                   # TODO(calibrate): measured H2H latency
    ),
    moe=MoEProfile(
        expert_delay=0,                    # TODO(calibrate): ZigZag / SNAX RTL
        router_delay=0,                    # TODO(calibrate): ZigZag / Banshee
        aggregator_delay=0,                # TODO(calibrate): Banshee / roofline
        input_delay=0,                     # TODO(calibrate): Banshee
        attention_delay=0,                 # TODO(calibrate): ZigZag
    ),
    early_exit=EarlyExitProfile(
        stage_delay=0,                     # TODO(calibrate): ZigZag
        classifier_delay=0,                # TODO(calibrate): Banshee / roofline
        output_delay=0,                    # TODO(calibrate): Banshee
    ),
    spec_decode=SpecDecodeProfile(
        draft_delay=0,                     # TODO(calibrate): ZigZag (draft model)
        verify_delay=0,                    # TODO(calibrate): ZigZag (target model)
        accept_delay=0,                    # TODO(calibrate): Banshee / roofline
        output_delay=0,                    # TODO(calibrate): Banshee
    ),
    mod=MoDProfile(
        block_delay=0,                     # TODO(calibrate): ZigZag
        router_delay=0,                    # TODO(calibrate): Banshee
        merge_delay=0,                     # TODO(calibrate): roofline
    ),
    sw_baseline=SWBaselineProfile(
        host_poll_cycles=0,                # TODO(calibrate): Banshee / SNAX RTL
        host_dispatch_per_expert_cycles=0, # TODO(calibrate): Banshee / SNAX RTL
    ),
)


# ── Profile registry ───────────────────────────────────────────

_PROFILES: dict[str, ProfileSet] = {
    "synthetic": SYNTHETIC,
    "calibrated": CALIBRATED,
}


def get_profile(name: str = "synthetic") -> ProfileSet:
    """Look up a named profile set.

    Args:
        name: ``"synthetic"`` or ``"calibrated"``.

    Returns:
        The corresponding :class:`ProfileSet`.

    Raises:
        KeyError: if *name* is not registered.
    """
    if name not in _PROFILES:
        raise KeyError(
            f"Unknown profile {name!r}. "
            f"Available: {sorted(_PROFILES.keys())}"
        )
    profile = _PROFILES[name]
    # Warn if calibrated profile still has zeros
    if name == "calibrated":
        _warn_uncalibrated(profile)
    return profile


def register_profile(name: str, profile: ProfileSet) -> None:
    """Register a custom profile (e.g., for a different model or HW config)."""
    _PROFILES[name] = profile


def _warn_uncalibrated(profile: ProfileSet) -> None:
    """Print warnings for any zero-valued delays in a calibrated profile."""
    import warnings
    zeros = []
    for wl_name in ("moe", "early_exit", "spec_decode", "mod", "sw_baseline"):
        wl = getattr(profile, wl_name)
        for fname, val in wl.__dict__.items():
            if isinstance(val, int) and val == 0 and "delay" in fname or "cycles" in fname:
                zeros.append(f"{wl_name}.{fname}")
    if zeros:
        warnings.warn(
            f"Calibrated profile has {len(zeros)} uncalibrated fields "
            f"(value=0): {', '.join(zeros[:5])}{'...' if len(zeros) > 5 else ''}. "
            f"Run simulation to fill these in.",
            stacklevel=3,
        )


# ════════════════════════════════════════════════════════════════
#  Quick summary (run this file directly to see current state)
# ════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    for name, ps in _PROFILES.items():
        print(f"\n{'='*60}")
        print(f"Profile: {name}")
        print(f"{'='*60}")
        print(f"Hardware: {ps.hw.n_chiplets} chiplets, "
              f"{ps.hw.n_clusters_per_chiplet} clusters, "
              f"{ps.hw.n_cores_per_cluster} cores, "
              f"GEMM {ps.hw.gemm_array_rows}x{ps.hw.gemm_array_cols}, "
              f"TCDM {ps.hw.tcdm_size_kb}KB")
        for wl_name in ("moe", "early_exit", "spec_decode", "mod", "sw_baseline"):
            wl = getattr(ps, wl_name)
            print(f"\n  {wl_name}:")
            for fname, val in sorted(wl.__dict__.items()):
                status = "  " if val > 0 else "!!"
                label = "TODO" if val == 0 else f"{val:,}"
                print(f"    {status} {fname:40s} = {label:>10}")

        # Count calibration status
        total = 0
        done = 0
        for wl_name in ("moe", "early_exit", "spec_decode", "mod", "sw_baseline"):
            wl = getattr(ps, wl_name)
            for fname, val in wl.__dict__.items():
                if isinstance(val, int):
                    total += 1
                    if val > 0:
                        done += 1
        print(f"\n  Calibration: {done}/{total} fields populated")
