"""Frontend: PyTorch model → Conditional DFG.

Provides two paths for generating conditional DFGs:

1. **FX graph analysis** — trace a PyTorch model with ``torch.fx``, detect
   MoE gating patterns (``topk`` + expert fan-out), and extract a model
   descriptor automatically.

2. **Config-driven generation** — directly specify model architecture
   (Mixtral, early exit, speculative decoding) and generate the DFG.

Both paths produce a :class:`BingoDFG` with conditional edges ready for
``compile_dfg()``.

Usage::

    # Path 1: from a real PyTorch model
    import torch
    model = MyMoEModel(...)
    desc = analyze_fx_graph(model, torch.randn(1, 64))
    dfg, meta = from_model_descriptor(desc, chiplet_cfg)

    # Path 2: from a config
    dfg, meta = from_mixtral_config(n_layers=32, n_experts=8, top_k=2, ...)
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Optional

from bingo_dfg import BingoDFG
from bingo_node import BingoNode


# ════════════════════════════════════════════════════════════
#  Model Descriptors
# ════════════════════════════════════════════════════════════


@dataclass
class MoELayerDescriptor:
    """Description of one MoE layer extracted from FX graph or config."""
    n_experts: int
    top_k: int
    gate_latency: int = 50
    expert_latency: int = 200
    aggregator_latency: int = 100


@dataclass
class AttentionDescriptor:
    """Placeholder for attention layer parameters."""
    latency: int = 300


@dataclass
class ModelDescriptor:
    """Full model architecture descriptor."""
    n_layers: int = 1
    moe_layers: list[MoELayerDescriptor] = field(default_factory=list)
    attention_layers: list[AttentionDescriptor] = field(default_factory=list)
    # Indices of layers that have MoE (vs dense FFN)
    moe_layer_indices: list[int] = field(default_factory=list)
    input_latency: int = 50
    output_latency: int = 50


@dataclass
class ChipletConfig:
    """Hardware configuration."""
    n_chiplets: int = 1
    n_clusters: int = 2
    n_cores: int = 3


@dataclass
class DFGMeta:
    """Metadata returned alongside the generated DFG."""
    expert_nodes: dict[int, list[BingoNode]] = field(default_factory=dict)
    """layer_idx → list of expert BingoNode references."""
    gating_nodes: dict[int, BingoNode] = field(default_factory=dict)
    """layer_idx → gating BingoNode reference."""
    n_cerf_groups_used: int = 0


# ════════════════════════════════════════════════════════════
#  FX Graph Analysis
# ════════════════════════════════════════════════════════════


def analyze_fx_graph(model, example_input) -> ModelDescriptor:
    """Trace a PyTorch model and detect MoE/conditional structure.

    Uses ``torch.fx.symbolic_trace`` to produce an FX graph, then
    pattern-matches for MoE gating structures (``topk`` + expert modules).

    Args:
        model: A ``torch.nn.Module`` (must be symbolically traceable).
        example_input: An example input tensor for tracing.

    Returns:
        A :class:`ModelDescriptor` summarising the detected architecture.
    """
    import torch.fx

    traced = torch.fx.symbolic_trace(model)
    graph = traced.graph

    # --- Detect topk nodes (MoE gating indicator) ---
    topk_nodes = [
        n for n in graph.nodes
        if n.op == "call_function" and "topk" in str(n.target)
    ]

    # --- Detect gate modules ---
    gate_modules = [
        n for n in graph.nodes
        if n.op == "call_module" and "gate" in str(n.target)
    ]

    # --- Detect expert modules and group by expert index ---
    expert_pattern = re.compile(r"experts[\._](\d+)")
    expert_groups: dict[int, list[str]] = {}
    for n in graph.nodes:
        if n.op == "call_module":
            m = expert_pattern.search(str(n.target))
            if m:
                idx = int(m.group(1))
                expert_groups.setdefault(idx, []).append(str(n.target))

    n_experts = len(expert_groups)
    top_k = int(topk_nodes[0].args[1]) if topk_nodes else 2

    # --- Build descriptor ---
    moe_desc = MoELayerDescriptor(n_experts=n_experts, top_k=top_k)
    desc = ModelDescriptor(
        n_layers=1,
        moe_layers=[moe_desc],
        attention_layers=[AttentionDescriptor()],
        moe_layer_indices=[0],
    )

    print(f"[frontend] Detected MoE structure: "
          f"{n_experts} experts, top-{top_k}, "
          f"{len(gate_modules)} gate module(s), "
          f"{sum(len(v) for v in expert_groups.values())} expert sub-modules")

    return desc


# ════════════════════════════════════════════════════════════
#  Config-Driven DFG Generation
# ════════════════════════════════════════════════════════════


def from_model_descriptor(
    desc: ModelDescriptor,
    hw: ChipletConfig,
    auto_place: bool = False,
) -> tuple[BingoDFG, DFGMeta]:
    """Generate a conditional DFG from a model descriptor.

    Produces one DFG covering all layers.  MoE layers get conditional edges
    (one CERF group per expert); dense layers are unconditional.

    Args:
        auto_place: If True, use the conditional-aware auto-scheduler to
                    assign tasks to cores.  If False, use round-robin.

    Returns:
        (dfg, meta) where meta contains node references for simulation.
    """
    dfg = BingoDFG()
    meta = DFGMeta()
    work_delays: dict[str, int] = {}

    prev_node: Optional[BingoNode] = None

    for layer_idx in range(desc.n_layers):
        is_moe = layer_idx in desc.moe_layer_indices
        moe_pos = desc.moe_layer_indices.index(layer_idx) if is_moe else -1

        # --- Attention ---
        attn_desc = (desc.attention_layers[layer_idx]
                     if layer_idx < len(desc.attention_layers)
                     else AttentionDescriptor())
        attn = BingoNode(node_name=f"attn_{layer_idx}")
        dfg.bingo_add_node(attn)
        work_delays[attn.node_name] = attn_desc.latency
        if prev_node is not None:
            dfg.bingo_add_edge(prev_node, attn)

        if is_moe:
            moe_desc = desc.moe_layers[moe_pos]

            # --- Router (gating) ---
            router = BingoNode(node_name=f"router_{layer_idx}")
            dfg.bingo_add_node(router)
            dfg.bingo_add_edge(attn, router)
            work_delays[router.node_name] = moe_desc.gate_latency
            meta.gating_nodes[layer_idx] = router

            # --- Experts (conditional) ---
            experts = []
            for i in range(moe_desc.n_experts):
                exp = BingoNode(node_name=f"expert_{layer_idx}_{i}")
                dfg.bingo_add_node(exp)
                dfg.bingo_add_edge(router, exp, cond=True)
                work_delays[exp.node_name] = moe_desc.expert_latency
                experts.append(exp)
            meta.expert_nodes[layer_idx] = experts

            # --- Aggregator ---
            agg = BingoNode(node_name=f"agg_{layer_idx}")
            dfg.bingo_add_node(agg)
            for exp in experts:
                dfg.bingo_add_edge(exp, agg)
            work_delays[agg.node_name] = moe_desc.aggregator_latency

            prev_node = agg
        else:
            # Dense FFN (unconditional)
            ffn = BingoNode(node_name=f"ffn_{layer_idx}")
            dfg.bingo_add_node(ffn)
            dfg.bingo_add_edge(attn, ffn)
            work_delays[ffn.node_name] = 200
            prev_node = ffn

    # Assign tasks to cores
    if auto_place:
        dfg.bingo_auto_assign(
            n_chiplets=hw.n_chiplets,
            n_clusters=hw.n_clusters,
            n_cores=hw.n_cores,
            work_delays=work_delays,
        )
    else:
        # Round-robin fallback
        n_slots = hw.n_chiplets * hw.n_clusters * hw.n_cores
        for i, node in enumerate(dfg.node_list):
            if node.assigned_core_id == -1:
                chip = i % hw.n_chiplets
                rem = i // hw.n_chiplets
                cl = (rem // hw.n_cores) % hw.n_clusters
                co = rem % hw.n_cores
                node.assigned_chiplet_id = chip
                node.assigned_cluster_id = cl
                node.assigned_core_id = co

    dfg._work_delays = work_delays
    return dfg, meta


# ════════════════════════════════════════════════════════════
#  Convenience: Named Model Configs
# ════════════════════════════════════════════════════════════


def from_mixtral_config(
    n_layers: int = 32,
    n_experts: int = 8,
    top_k: int = 2,
    expert_latency: int = 200,
    attention_latency: int = 300,
    gate_latency: int = 50,
    aggregator_latency: int = 100,
    hw: Optional[ChipletConfig] = None,
    auto_place: bool = False,
) -> tuple[BingoDFG, DFGMeta]:
    """Generate a conditional DFG for a Mixtral-style MoE transformer.

    Every layer has attention + MoE.  CERF groups are reused across layers
    (the compiler assigns groups 0..N-1 per layer; clear-before-set in the
    gating task handles reuse).

    Example::

        dfg, meta = from_mixtral_config(n_layers=32, n_experts=8, top_k=2)
        compile_dfg(dfg)
        active = set(meta.expert_nodes[0][:2])  # top-2 for layer 0
        per_chiplet = dfg_to_task_descriptors(dfg, dfg._work_delays, active)
    """
    hw = hw or ChipletConfig()
    desc = ModelDescriptor(
        n_layers=n_layers,
        moe_layers=[
            MoELayerDescriptor(n_experts, top_k, gate_latency,
                               expert_latency, aggregator_latency)
            for _ in range(n_layers)
        ],
        attention_layers=[
            AttentionDescriptor(attention_latency) for _ in range(n_layers)
        ],
        moe_layer_indices=list(range(n_layers)),
    )
    return from_model_descriptor(desc, hw, auto_place=auto_place)


def from_early_exit_config(
    n_layers: int = 12,
    stage_latency: int = 200,
    classifier_latency: int = 50,
    hw: Optional[ChipletConfig] = None,
) -> tuple[BingoDFG, DFGMeta]:
    """Generate a conditional DFG for an early-exit classifier network.

    Each layer has a classifier that gates the next layer.
    """
    hw = hw or ChipletConfig()
    dfg = BingoDFG()
    meta = DFGMeta()
    work_delays: dict[str, int] = {}
    prev = None

    stage_nodes = []
    for s in range(n_layers):
        co = s % hw.n_cores
        stage = BingoNode(0, 0, co, f"stage_{s}")
        dfg.bingo_add_node(stage)
        work_delays[stage.node_name] = stage_latency
        if prev is not None:
            dfg.bingo_add_edge(prev, stage)

        cls_co = (co + 1) % hw.n_cores
        classifier = BingoNode(0, 0, cls_co, f"classifier_{s}")
        dfg.bingo_add_node(classifier)
        dfg.bingo_add_edge(stage, classifier)
        work_delays[classifier.node_name] = classifier_latency

        stage_nodes.append((stage, classifier))
        prev = classifier

    # Conditional edges: classifier_i gates stage_{i+1} and classifier_{i+1}
    for s in range(n_layers - 1):
        _, gating_cls = stage_nodes[s]
        next_stage, next_cls = stage_nodes[s + 1]
        dfg.bingo_add_edge(gating_cls, next_stage, cond=True)
        dfg.bingo_add_edge(gating_cls, next_cls, cond=True)

    # Output
    output = BingoNode(0, 0, 0, "output")
    dfg.bingo_add_node(output)
    dfg.bingo_add_edge(prev, output)
    work_delays["output"] = 50

    dfg._work_delays = work_delays
    meta.expert_nodes = {s: [stage_nodes[s][0], stage_nodes[s][1]]
                         for s in range(n_layers)}
    return dfg, meta


def from_spec_decode_config(
    n_draft: int = 5,
    draft_latency: int = 100,
    verify_latency: int = 500,
    accept_latency: int = 50,
    hw: Optional[ChipletConfig] = None,
) -> tuple[BingoDFG, DFGMeta]:
    """Generate a conditional DFG for speculative decoding."""
    hw = hw or ChipletConfig()
    dfg = BingoDFG()
    meta = DFGMeta()
    work_delays: dict[str, int] = {}

    # Draft chain
    prev = None
    for i in range(n_draft):
        co = i % hw.n_cores
        d = BingoNode(0, 0, co, f"draft_{i}")
        dfg.bingo_add_node(d)
        work_delays[d.node_name] = draft_latency
        if prev is not None:
            dfg.bingo_add_edge(prev, d)
        prev = d

    # Verify (gating)
    verify = BingoNode(0, 0, n_draft % hw.n_cores, "verify")
    dfg.bingo_add_node(verify)
    dfg.bingo_add_edge(prev, verify)
    work_delays["verify"] = verify_latency
    meta.gating_nodes[0] = verify

    # Accept nodes (conditional)
    accepts = []
    for i in range(n_draft):
        co = i % hw.n_cores
        a = BingoNode(0, 0, co, f"accept_{i}")
        dfg.bingo_add_node(a)
        dfg.bingo_add_edge(verify, a, cond=True)
        work_delays[a.node_name] = accept_latency
        accepts.append(a)
    meta.expert_nodes[0] = accepts

    # Output
    output = BingoNode(0, 0, 0, "output")
    dfg.bingo_add_node(output)
    for a in accepts:
        dfg.bingo_add_edge(a, output)
    work_delays["output"] = 50

    dfg._work_delays = work_delays
    return dfg, meta
