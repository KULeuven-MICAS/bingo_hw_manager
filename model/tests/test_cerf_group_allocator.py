"""Unit tests for the min-chain-cover CERF group allocator.

``BingoDFG.bingo_compile_conditional_regions`` assigns each gating region
(a gating node + its conditional targets, grouped into connected components)
a block of CERF groups. Two regions may reuse the same group numbering iff
one provably happens-before the other (every target of the earlier region
has a DFG path to the later region's gating node) -- otherwise they could be
live at the same time and reusing a group would let one region's skip/active
state leak into the other.

These tests check three things the old "all gating nodes must form one
global chain, or no reuse at all" rule could not:

1. Independent (incomparable) regions never reuse -- correctness floor.
2. Two regions that are pairwise ordered but are NOT part of one graph-wide
   chain still reuse -- this is the actual generalization; the old code
   would give both regions fresh groups here.
3. The chain count matches a hand-computed minimum (Dilworth: min chains ==
   max antichain) on a scenario built so the antichain size is known.

Run: PYTHONPATH=sw:. python3 -m pytest model/tests/test_cerf_group_allocator.py -q
"""
import os
import sys

_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_root, "sw"))
sys.path.insert(0, _root)

from bingo_dfg import BingoDFG
from bingo_node import BingoNode


def _gate(dfg, name, chip=0, cl=0, core=0):
    n = BingoNode(chip, cl, core, name)
    dfg.bingo_add_node(n)
    return n


def _target(dfg, name, chip=0, cl=0, core=1):
    n = BingoNode(chip, cl, core, name)
    dfg.bingo_add_node(n)
    return n


def test_single_region_gets_one_group_per_component():
    dfg = BingoDFG()
    g = _gate(dfg, "g")
    t0 = _target(dfg, "t0")
    t1 = _target(dfg, "t1")
    dfg.bingo_add_edge(g, t0, cond=True)
    dfg.bingo_add_edge(g, t1, cond=True)

    mapping = dfg.bingo_compile_conditional_regions()

    assert mapping[t0] != mapping[t1]
    assert {mapping[t0], mapping[t1]} == {0, 1}
    assert dfg._n_cerf_chains == 1


def test_totally_ordered_regions_reuse_like_the_old_behavior():
    """Two gating regions where region A fully precedes region B (A's target
    feeds into B's gate) must land in the SAME chain and reuse group numbering
    -- this is the case the old code already handled, kept as a regression
    check that the generalization didn't regress the common case.
    """
    dfg = BingoDFG()
    gA = _gate(dfg, "gA")
    tA0 = _target(dfg, "tA0")
    tA1 = _target(dfg, "tA1")
    dfg.bingo_add_edge(gA, tA0, cond=True)
    dfg.bingo_add_edge(gA, tA1, cond=True)

    gB = _gate(dfg, "gB")
    tB0 = _target(dfg, "tB0")
    dfg.bingo_add_edge(tA0, gB)  # A's target feeds B's gate -> A precedes B
    dfg.bingo_add_edge(tA1, gB)
    dfg.bingo_add_edge(gB, tB0, cond=True)

    mapping = dfg.bingo_compile_conditional_regions()

    assert dfg._n_cerf_chains == 1, "totally ordered regions must share one chain"
    assert mapping[tB0] == 0, "B's region must reuse group 0 from A's pool"


def test_independent_regions_never_share_a_group():
    """Two gating regions with NO path between them (could be concurrently
    live) must NOT reuse group numbering -- reusing here would be a real
    correctness bug (one region's skip could be mistaken for the other's).
    """
    dfg = BingoDFG()
    gA = _gate(dfg, "gA", chip=0)
    tA0 = _target(dfg, "tA0", chip=0)
    dfg.bingo_add_edge(gA, tA0, cond=True)

    gB = _gate(dfg, "gB", chip=1)
    tB0 = _target(dfg, "tB0", chip=1)
    dfg.bingo_add_edge(gB, tB0, cond=True)
    # No edge at all between the two regions -> incomparable.

    mapping = dfg.bingo_compile_conditional_regions()

    assert dfg._n_cerf_chains == 2, "incomparable regions must be separate chains"
    assert mapping[tA0] == mapping[tB0] == 0, (
        "each chain restarts its own pool at 0 -- same NUMBER is fine, "
        "they're on physically different chiplets/cells; the point is they "
        "were allocated independently, not forced to share one pool"
    )


def test_pairwise_ordered_but_not_globally_chained_still_reuses():
    """THE generalization this allocator adds over the old code: three
    regions where A precedes C and B precedes C, but A and B are themselves
    incomparable (no path either way). The old "all gating nodes must form
    ONE global chain" rule would see gating_ordered = [gA, gB, gC] (or
    [gB, gA, gC]) and immediately fail the all-pairs-ordered check between
    gA and gB, disabling reuse for the ENTIRE graph -- so A, B, and C would
    each get fresh groups (3 chains, more groups spent than necessary).

    The min-chain-cover allocator instead finds the true minimum: A and C
    can chain together (or B and C), and only the odd one out needs its own
    chain -- 2 chains, not 3.
    """
    dfg = BingoDFG()
    gA = _gate(dfg, "gA", chip=0)
    tA0 = _target(dfg, "tA0", chip=0)
    dfg.bingo_add_edge(gA, tA0, cond=True)

    gB = _gate(dfg, "gB", chip=1)
    tB0 = _target(dfg, "tB0", chip=1)
    dfg.bingo_add_edge(gB, tB0, cond=True)

    # C's gate is reachable from BOTH A's and B's targets (e.g. a barrier
    # join), so C is ordered after both -- but A and B remain incomparable.
    gC = _gate(dfg, "gC", chip=0, core=2)
    tC0 = _target(dfg, "tC0", chip=0, core=2)
    dfg.bingo_add_edge(tA0, gC)
    dfg.bingo_add_edge(tB0, gC)
    dfg.bingo_add_edge(gC, tC0, cond=True)

    mapping = dfg.bingo_compile_conditional_regions()

    assert dfg._n_cerf_chains == 2, (
        f"expected the true minimum of 2 chains (Dilworth: max antichain "
        f"size is 2, {{A,B}}), got {dfg._n_cerf_chains} -- if this is 3, the "
        f"allocator regressed to the old all-or-nothing single-chain rule"
    )


def test_antichain_of_three_needs_three_chains():
    """Three fully mutually-incomparable regions (a genuine antichain of size
    3) must need exactly 3 chains -- the allocator must not under-reuse
    (that would be a correctness bug, two live-at-once regions sharing a
    pool) nor over-allocate (that would just be a worse compiler, not wrong,
    but this pins the exact expected minimum from Dilworth's theorem).
    """
    dfg = BingoDFG()
    for i in range(3):
        g = _gate(dfg, f"g{i}", chip=i)
        t = _target(dfg, f"t{i}", chip=i)
        dfg.bingo_add_edge(g, t, cond=True)

    dfg.bingo_compile_conditional_regions()

    assert dfg._n_cerf_chains == 3


def test_moe_layer_end_to_end_uses_one_chain():
    """The real bingo_add_moe_layer builder: N experts under one gating_op.
    This is a single region (one gating node), so it must be exactly one
    chain regardless of N, and every expert gets a distinct group.
    """
    dfg = BingoDFG()
    inp = _target(dfg, "input", core=0)
    layer = dfg.bingo_add_moe_layer(inp, n_experts=8, top_k=2)
    dfg.bingo_auto_assign(n_chiplets=1, n_clusters=2, n_cores=3)

    mapping = dfg.bingo_compile_conditional_regions()

    assert dfg._n_cerf_chains == 1
    expert_groups = {mapping[e] for e in layer.experts}
    assert expert_groups == set(range(8)), "each of the 8 experts needs a distinct group"


def test_sequential_moe_layers_reuse_across_layers():
    """Two MoE layers stacked sequentially (layer2's router depends on
    layer1's aggregator) is exactly the "sequential gating reuse" scenario
    the old code's single-chain rule was designed for -- confirm the new
    allocator still gets this right (one chain, group IDs reused per-layer).
    """
    dfg = BingoDFG()
    inp = _target(dfg, "input", core=0)
    layer1 = dfg.bingo_add_moe_layer(inp, n_experts=4, layer_name="l1")
    layer2 = dfg.bingo_add_moe_layer(layer1.aggregator, n_experts=4, layer_name="l2")
    dfg.bingo_auto_assign(n_chiplets=1, n_clusters=2, n_cores=3)

    mapping = dfg.bingo_compile_conditional_regions()

    assert dfg._n_cerf_chains == 1, "sequential MoE layers must reuse one chain"
    l1_groups = {mapping[e] for e in layer1.experts}
    l2_groups = {mapping[e] for e in layer2.experts}
    assert l1_groups == l2_groups == {0, 1, 2, 3}, "layer 2 must reuse layer 1's group numbering"


def test_ablation_counts_match_hand_computation():
    """The naive (no-reuse) and actual (reuse-aware) group counts exposed for
    the compiler ablation (M-G) must match a hand-computed expectation: 3
    sequential MoE layers of 8 experts each need 24 groups with no reuse
    (8 per layer x 3) but only 8 with reuse (one chain, one shared pool).
    """
    dfg = BingoDFG()
    inp = _target(dfg, "input", core=0)
    l1 = dfg.bingo_add_moe_layer(inp, n_experts=8, layer_name="l1")
    l2 = dfg.bingo_add_moe_layer(l1.aggregator, n_experts=8, layer_name="l2")
    l3 = dfg.bingo_add_moe_layer(l2.aggregator, n_experts=8, layer_name="l3")
    dfg.bingo_auto_assign(n_chiplets=1, n_clusters=2, n_cores=3)

    dfg.bingo_compile_conditional_regions()

    assert dfg._cerf_groups_naive == {0: 24}
    assert dfg._cerf_groups_actual == {0: 8}
    assert dfg._n_cerf_chains == 1


def test_overflow_still_raises_when_no_reuse_possible():
    dfg = BingoDFG()
    g = _gate(dfg, "g")
    targets = []
    for i in range(33):
        t = _target(dfg, f"t{i}", core=(i % 4))
        dfg.bingo_add_edge(g, t, cond=True)
        targets.append(t)

    try:
        dfg.bingo_compile_conditional_regions()
        assert False, "expected CERF group overflow to raise"
    except ValueError as e:
        assert "overflow" in str(e).lower()


if __name__ == "__main__":
    import pytest
    raise SystemExit(pytest.main([__file__, "-v"]))
