#!/usr/bin/env python3
"""Oracle vs COND-HEFT comparison — validates scheduling theory.

Runs brute-force optimal placement on small DFG instances and compares
against COND-HEFT to measure the optimality gap.

Workloads:
  1. MoE (N=4, k=1): 7 nodes, 4 conditional experts
  2. MoE (N=4, k=2): 7 nodes, 4 conditional experts, higher activation
  3. Early exit (K=3): 10 nodes, 3 conditional stages
  4. Independent tasks (N=6): baseline P||C_max instance

Output:
  - Per-workload: optimal makespan, HEFT makespan, gap %
  - CSV in eval_results/oracle_comparison.csv
"""

import csv
import os
import sys

_script_dir = os.path.dirname(os.path.abspath(__file__))
_root = os.path.dirname(_script_dir)
sys.path.insert(0, os.path.join(_root, "sw"))

from bingo_dfg import BingoDFG
from bingo_node import BingoNode
from hw_profiles import get_profile

# ─── Delay Parameters (from hw_profiles) ──────────────────────
_profile = get_profile("synthetic")
EXPERT_DELAY = _profile.moe.expert_delay
ROUTER_DELAY = _profile.moe.router_delay
GATE_DELAY = 10  # gate op is cheap (topk selection)
AGG_DELAY = _profile.moe.aggregator_delay
INPUT_DELAY = _profile.moe.input_delay
STAGE_DELAY = _profile.early_exit.stage_delay
CLASSIFIER_DELAY = _profile.early_exit.classifier_delay

N_SLOTS = 4  # Keep small for brute-force feasibility


def make_moe_dfg(n_experts: int, top_k: int) -> tuple[BingoDFG, dict]:
    """Build a small MoE DFG: input → router → gate → experts → agg."""
    dfg = BingoDFG()
    delays = {}

    inp = BingoNode(node_name="input")
    dfg.bingo_add_node(inp)
    delays["input"] = INPUT_DELAY

    router = BingoNode(node_name="router")
    dfg.bingo_add_node(router)
    dfg.bingo_add_edge(inp, router)
    delays["router"] = ROUTER_DELAY

    gate = BingoNode(node_name="gate")
    dfg.bingo_add_node(gate)
    dfg.bingo_add_edge(router, gate)
    delays["gate"] = GATE_DELAY

    experts = []
    for i in range(n_experts):
        exp = BingoNode(node_name=f"expert_{i}")
        dfg.bingo_add_node(exp)
        dfg.bingo_add_edge(gate, exp, cond=True)
        experts.append(exp)
        delays[f"expert_{i}"] = EXPERT_DELAY

    agg = BingoNode(node_name="agg")
    dfg.bingo_add_node(agg)
    for exp in experts:
        dfg.bingo_add_edge(exp, agg)
    delays["agg"] = AGG_DELAY

    # Set activation weights: each expert has p = top_k / n_experts
    act_w = {}
    for node in dfg.node_list:
        act_w[node] = 1.0
    for exp in experts:
        act_w[exp] = top_k / n_experts

    return dfg, delays, act_w


def make_early_exit_dfg(n_stages: int) -> tuple[BingoDFG, dict]:
    """Build a small early exit DFG."""
    dfg = BingoDFG()
    delays = {}

    inp = BingoNode(node_name="input")
    dfg.bingo_add_node(inp)
    delays["input"] = INPUT_DELAY

    prev = inp
    for i in range(n_stages):
        stage = BingoNode(node_name=f"stage_{i}")
        dfg.bingo_add_node(stage)
        delays[f"stage_{i}"] = STAGE_DELAY

        classifier = BingoNode(node_name=f"classifier_{i}")
        dfg.bingo_add_node(classifier)
        delays[f"classifier_{i}"] = CLASSIFIER_DELAY

        if i == 0:
            dfg.bingo_add_edge(prev, stage)
            dfg.bingo_add_edge(stage, classifier)
        else:
            # Stages after 0 are conditional on previous classifier
            dfg.bingo_add_edge(prev, stage, cond=True)
            dfg.bingo_add_edge(stage, classifier)

        prev = classifier

    output = BingoNode(node_name="output")
    dfg.bingo_add_node(output)
    dfg.bingo_add_edge(prev, output)
    delays["output"] = 10

    # Activation weights: each stage has 50% chance of continuing
    act_w = {}
    for node in dfg.node_list:
        act_w[node] = 1.0
    p = 0.5
    for i in range(1, n_stages):
        for name in [f"stage_{i}", f"classifier_{i}"]:
            for n in dfg.node_list:
                if n.node_name == name:
                    act_w[n] = p ** i

    return dfg, delays, act_w


def make_independent_dfg(n_tasks: int) -> tuple[BingoDFG, dict]:
    """Build independent tasks (P||C_max baseline)."""
    dfg = BingoDFG()
    delays = {}

    for i in range(n_tasks):
        t = BingoNode(node_name=f"task_{i}")
        dfg.bingo_add_node(t)
        delays[f"task_{i}"] = 50 + i * 30  # Varying delays

    act_w = {n: 1.0 for n in dfg.node_list}
    return dfg, delays, act_w


def make_moe_hetero_dfg(n_experts: int, top_k: int) -> tuple[BingoDFG, dict]:
    """MoE with heterogeneous expert delays (some experts are heavier)."""
    dfg = BingoDFG()
    delays = {}

    inp = BingoNode(node_name="input")
    dfg.bingo_add_node(inp)
    delays["input"] = INPUT_DELAY

    router = BingoNode(node_name="router")
    dfg.bingo_add_node(router)
    dfg.bingo_add_edge(inp, router)
    delays["router"] = ROUTER_DELAY

    gate = BingoNode(node_name="gate")
    dfg.bingo_add_node(gate)
    dfg.bingo_add_edge(router, gate)
    delays["gate"] = GATE_DELAY

    experts = []
    for i in range(n_experts):
        exp = BingoNode(node_name=f"expert_{i}")
        dfg.bingo_add_node(exp)
        dfg.bingo_add_edge(gate, exp, cond=True)
        experts.append(exp)
        # Heterogeneous: experts 0,1 are 2x heavier than experts 2,3
        delays[f"expert_{i}"] = 400 if i < n_experts // 2 else 100

    agg = BingoNode(node_name="agg")
    dfg.bingo_add_node(agg)
    for exp in experts:
        dfg.bingo_add_edge(exp, agg)
    delays["agg"] = AGG_DELAY

    act_w = {}
    for node in dfg.node_list:
        act_w[node] = 1.0
    for exp in experts:
        act_w[exp] = top_k / n_experts

    return dfg, delays, act_w


def make_moe_multichiplet_dfg() -> tuple[BingoDFG, dict]:
    """MoE across 2 chiplets: input/router on chip 0, experts split."""
    dfg = BingoDFG()
    delays = {}

    inp = BingoNode(node_name="input")
    dfg.bingo_add_node(inp)
    delays["input"] = INPUT_DELAY

    router = BingoNode(node_name="router")
    dfg.bingo_add_node(router)
    dfg.bingo_add_edge(inp, router)
    delays["router"] = ROUTER_DELAY

    gate = BingoNode(node_name="gate")
    dfg.bingo_add_node(gate)
    dfg.bingo_add_edge(router, gate)
    delays["gate"] = GATE_DELAY

    experts = []
    for i in range(4):
        exp = BingoNode(node_name=f"expert_{i}")
        dfg.bingo_add_node(exp)
        dfg.bingo_add_edge(gate, exp, cond=True)
        experts.append(exp)
        delays[f"expert_{i}"] = EXPERT_DELAY

    agg = BingoNode(node_name="agg")
    dfg.bingo_add_node(agg)
    for exp in experts:
        dfg.bingo_add_edge(exp, agg)
    delays["agg"] = AGG_DELAY

    act_w = {}
    for node in dfg.node_list:
        act_w[node] = 1.0
    for exp in experts:
        act_w[exp] = 0.5  # k=2 of N=4

    return dfg, delays, act_w


def make_chain_fork_dfg() -> tuple[BingoDFG, dict]:
    """Chain with a conditional fork: A → B → gate → {C, D, E} → F.

    More constrained than pure MoE: B is a heavy compute node on the
    critical path.
    """
    dfg = BingoDFG()
    delays = {}

    a = BingoNode(node_name="A")
    dfg.bingo_add_node(a)
    delays["A"] = 100

    b = BingoNode(node_name="B")
    dfg.bingo_add_node(b)
    dfg.bingo_add_edge(a, b)
    delays["B"] = 300  # Heavy computation

    gate = BingoNode(node_name="gate")
    dfg.bingo_add_node(gate)
    dfg.bingo_add_edge(b, gate)
    delays["gate"] = GATE_DELAY

    branches = []
    for i, (name, delay) in enumerate([("C", 150), ("D", 200), ("E", 100)]):
        n = BingoNode(node_name=name)
        dfg.bingo_add_node(n)
        dfg.bingo_add_edge(gate, n, cond=True)
        branches.append(n)
        delays[name] = delay

    f = BingoNode(node_name="F")
    dfg.bingo_add_node(f)
    for br in branches:
        dfg.bingo_add_edge(br, f)
    delays["F"] = 50

    act_w = {}
    for node in dfg.node_list:
        act_w[node] = 1.0
    for br in branches:
        act_w[br] = 1.0 / 3.0  # One of three branches active

    return dfg, delays, act_w


def run_oracle_comparison():
    """Run all oracle comparisons and print results."""
    # Each entry: (name, dfg, delays, act_w, hw_config)
    # hw_config: (n_chiplets, n_clusters, n_cores)
    single_chip = (1, 1, N_SLOTS)
    dual_chip = (2, 1, 2)  # 2 chiplets x 1 cluster x 2 cores = 4 slots

    workloads = [
        ("MoE(N=4,k=1)", *make_moe_dfg(4, 1), single_chip),
        ("MoE(N=4,k=2)", *make_moe_dfg(4, 2), single_chip),
        ("MoE(N=4,k=1)hetero", *make_moe_hetero_dfg(4, 1), single_chip),
        ("EarlyExit(K=3)", *make_early_exit_dfg(3), single_chip),
        ("ChainFork(3br)", *make_chain_fork_dfg(), single_chip),
        ("MoE(2chip,N=4,k=2)", *make_moe_multichiplet_dfg(), dual_chip),
        ("Independent(N=6)", *make_independent_dfg(6), single_chip),
    ]

    results = []

    print("=" * 70)
    print("Oracle vs COND-HEFT Comparison")
    print("=" * 70)

    for name, dfg, delays, act_w, hw_cfg in workloads:
        n_chips, n_cls, n_cos = hw_cfg
        total_slots = n_chips * n_cls * n_cos
        print(f"\n--- {name} ---")
        print(f"  Nodes: {len(dfg.node_list)}, Slots: {total_slots} "
              f"({n_chips}chip x {n_cls}cl x {n_cos}co)")

        try:
            result = dfg.bingo_oracle_placement(
                n_chiplets=n_chips,
                n_clusters=n_cls,
                n_cores=n_cos,
                work_delays=delays,
                activation_weights=act_w,
            )

            print(f"  Optimal E[makespan]: {result['opt_makespan']:.1f}")
            print(f"  HEFT E[makespan]:    {result['heft_makespan']:.1f}")
            print(f"  Gap:                 {result['gap_pct']:.1f}%")
            print(f"  Masks enumerated:    {result['n_masks']}")
            print(f"  CERF groups:         {result['n_groups']}")
            print(f"  Optimal placement:   {result['opt_placement']}")
            print(f"  HEFT placement:      {result['heft_placement']}")

            results.append({
                "workload": name,
                "n_nodes": result["n_nodes"],
                "n_slots": result["n_slots"],
                "n_groups": result["n_groups"],
                "n_masks": result["n_masks"],
                "opt_makespan": result["opt_makespan"],
                "heft_makespan": result["heft_makespan"],
                "gap_pct": result["gap_pct"],
            })
        except ValueError as e:
            print(f"  SKIPPED: {e}")

    # -- Summary --
    print("\n" + "=" * 70)
    print("Summary")
    print("=" * 70)
    print(f"{'Workload':<20} {'Nodes':>5} {'Slots':>5} "
          f"{'OPT':>8} {'HEFT':>8} {'Gap%':>6}")
    print("-" * 60)
    for r in results:
        print(f"{r['workload']:<20} {r['n_nodes']:>5} {r['n_slots']:>5} "
              f"{r['opt_makespan']:>8.1f} {r['heft_makespan']:>8.1f} "
              f"{r['gap_pct']:>5.1f}%")

    avg_gap = sum(r["gap_pct"] for r in results) / max(len(results), 1)
    print(f"\nAverage optimality gap: {avg_gap:.1f}%")
    print(f"Theoretical bound: {(2 - 1/N_SLOTS) * 100 - 100:.0f}% "
          f"(Graham's (2-1/m) ratio for m={N_SLOTS})")

    # -- Write CSV --
    out_dir = os.path.join(_root, "eval_results")
    os.makedirs(out_dir, exist_ok=True)
    csv_path = os.path.join(out_dir, "oracle_comparison.csv")
    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=[
            "workload", "n_nodes", "n_slots", "n_groups", "n_masks",
            "opt_makespan", "heft_makespan", "gap_pct",
        ])
        writer.writeheader()
        writer.writerows(results)
    print(f"\nResults written to {csv_path}")


if __name__ == "__main__":
    run_oracle_comparison()
