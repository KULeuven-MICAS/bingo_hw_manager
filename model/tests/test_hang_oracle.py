"""The compile-time hang oracle (`BingoDFG.bingo_validate_no_hang`).

A stuck dep-check is the scheduler's worst failure: it does not raise, does not
time out and corrupts nothing -- the machine just stops. The oracle re-derives,
from the LOWERED graph, the properties the passes are supposed to guarantee, so
a bug in a pass shows up as a compile error instead of dead silicon.

Every check here has a negative test. A validator nobody has watched fail is
indistinguishable from `return True`.
"""
import os
import sys

import pytest

_HERE = os.path.dirname(__file__)
_ROOT = os.path.abspath(os.path.join(_HERE, "..", ".."))
for _p in (_ROOT, os.path.join(_ROOT, "sw"), os.path.join(_ROOT, "scripts")):
    if _p not in sys.path:
        sys.path.insert(0, _p)

from bingo_dfg import BingoDFG                     # noqa: E402
from bingo_node import BingoNode                   # noqa: E402


def _compile(d, tag_width=4):
    d.bingo_compile_conditional_regions()
    d.bingo_transform_dfg_add_dummy_set_nodes()
    d.bingo_transform_dfg_add_dummy_check_nodes()
    d.bingo_assign_normal_node_dep_check_info()
    d.bingo_assign_normal_node_dep_set_info()
    d.bingo_transform_dfg_allocate_dep_tags(tag_width=tag_width)
    return d


def _chain(n_tasks=6, n_cores=3):
    """A serial chain that revisits every cell, so tag reuse is exercised."""
    d = BingoDFG(num_clusters_per_chiplet=1, num_cores_per_cluster=n_cores,
                 dep_tag_width=4, num_chiplets=1)
    prev = None
    nodes = []
    for i in range(n_tasks):
        nd = BingoNode(0, 0, i % n_cores, node_name=f"t{i}")
        d.bingo_add_node(nd)
        if prev is not None:
            d.bingo_add_edge(prev, nd)
        prev = nd
        nodes.append(nd)
    return d, nodes


def _parallel(k=4, n_cores=3):
    """One producer fanning out, then a join -- concurrent edges per cell."""
    d = BingoDFG(num_clusters_per_chiplet=1, num_cores_per_cluster=n_cores,
                 dep_tag_width=4, num_chiplets=1)
    src = BingoNode(0, 0, 0, node_name="src")
    d.bingo_add_node(src)
    mids = []
    for i in range(k):
        m = BingoNode(0, 0, 1 + (i % (n_cores - 1)), node_name=f"m{i}")
        d.bingo_add_node(m)
        d.bingo_add_edge(src, m)
        mids.append(m)
    return d, src, mids


def _one_cell(k=6):
    """k independent producer->consumer edges that ALL land in ONE cell.

    Producers on core 0, consumers on core 1, paired off. Nothing orders a
    consumer before the next producer, so every edge is live at once and the
    allocator must give each its own tag -- which is what makes the cell's tag
    count, and therefore the capacity check, meaningful.
    """
    d = BingoDFG(num_clusters_per_chiplet=1, num_cores_per_cluster=2,
                 dep_tag_width=4, num_chiplets=1)
    pairs = []
    for i in range(k):
        p = BingoNode(0, 0, 0, node_name=f"p{i}")
        c = BingoNode(0, 0, 1, node_name=f"c{i}")
        d.bingo_add_node(p); d.bingo_add_node(c)
        d.bingo_add_edge(p, c)
        pairs.append((p, c))
    return d, pairs


def _edges_with_tags(d):
    """The (set_node, check_node) pairs the dep matrix actually sees."""
    out = []
    for u, v in d.edges():
        if not (u.dep_set_enable and v.dep_check_enable):
            continue
        if (u.assigned_core_id in (v.dep_check_list or [])
                and v.assigned_core_id in (u.dep_set_list or [])):
            out.append((u, v))
    return out


class TestAcceptsValidGraphs:
    @pytest.mark.parametrize("n", [2, 3, 6, 10, 17])
    def test_serial_chain(self, n):
        d, _ = _chain(n)
        _compile(d)
        rep = d.bingo_validate_no_hang()
        assert rep["edges"] >= n - 1

    @pytest.mark.parametrize("k", [2, 3, 5, 8])
    def test_fan_out(self, k):
        d, _src, _mids = _parallel(k)
        _compile(d)
        d.bingo_validate_no_hang()

    def test_reports_peak_within_capacity(self):
        d, _src, _mids = _parallel(6)
        _compile(d)
        rep = d.bingo_validate_no_hang()
        assert rep["peak_tags_per_cell"] <= rep["tag_capacity"]


class TestCatchesTagMismatch:
    def test_producer_and_consumer_disagree(self):
        d, _ = _chain(6)
        _compile(d)
        su, _cv = _edges_with_tags(d)[0]
        su.dep_set_tag = (su.dep_set_tag + 1) % 16      # break one edge
        with pytest.raises(ValueError, match="waits on tag"):
            d.bingo_validate_no_hang()


class TestCatchesUnsatisfiableCheck:
    def test_check_column_with_no_producer(self):
        d, nodes = _chain(6)
        _compile(d)
        consumer = next(n for n in d.node_list if n.dep_check_enable)
        # Wait on a core nobody signals.
        consumer.dep_check_list = list(consumer.dep_check_list) + [2]
        if 2 in (consumer.dep_check_list[:-1]):
            consumer.dep_check_list = list(consumer.dep_check_list[:-1]) + [1]
        with pytest.raises(ValueError, match="no reachable producer"):
            d.bingo_validate_no_hang()


class TestCatchesCellAliasing:
    """The hazard per-edge tags exist to remove, checked on the OUTPUT."""

    def test_two_concurrent_edges_forced_onto_one_tag(self):
        d, _src, _mids = _parallel(4)
        _compile(d)
        # Collapse every tag to 0. The fan-out's edges are mutually
        # incomparable, so several become live on one cell at one tag.
        for u, v in _edges_with_tags(d):
            u.dep_set_tag = 0
            v.dep_check_tag = 0
        with pytest.raises(ValueError, match="live at the same time share tag"):
            d.bingo_validate_no_hang()

    def test_names_both_edges_and_the_cell(self):
        d, _src, _mids = _parallel(4)
        _compile(d)
        for u, v in _edges_with_tags(d):
            u.dep_set_tag = 0
            v.dep_check_tag = 0
        with pytest.raises(ValueError) as exc:
            d.bingo_validate_no_hang()
        msg = str(exc.value)
        assert "edge A:" in msg and "edge B:" in msg
        assert "consumer core, producer core" in msg

    def test_ordered_edges_may_share_a_tag(self):
        """Reuse along a chain is legal and must NOT be flagged -- otherwise the
        oracle would reject every graph that reuses a tag, which is all of them."""
        d, _ = _chain(12)
        _compile(d)
        d.bingo_validate_no_hang()
        tags = [u.dep_set_tag for u, _v in _edges_with_tags(d)]
        assert len(tags) > len(set(tags)), "chain should reuse at least one tag"


class TestCatchesCapacityOverflow:
    def test_more_tags_in_a_cell_than_the_descriptor_encodes(self):
        """Six concurrent edges on one cell need six tags; a 2-bit field holds
        four. Compiled at width 4, validated at width 2."""
        d, _pairs = _one_cell(6)
        _compile(d, tag_width=4)
        rep = d.bingo_validate_no_hang(tag_width=4)
        assert rep["peak_tags_per_cell"] == 6, rep
        with pytest.raises(ValueError, match="distinct tags"):
            d.bingo_validate_no_hang(tag_width=2)


class TestOracleIsNotVacuous:
    def test_every_negative_case_actually_raises(self):
        """Guards against the oracle silently degrading to a no-op."""
        raised = 0
        for setup, tw in (("mismatch", 4), ("alias", 4), ("capacity", 2)):
            if setup == "capacity":
                d, _pairs = _one_cell(6)
                _compile(d, tag_width=4)
            else:
                d, _src, _mids = _parallel(4)
                _compile(d)
            edges = _edges_with_tags(d)
            if setup == "mismatch":
                edges[0][0].dep_set_tag = (edges[0][0].dep_set_tag + 1) % 16
            elif setup == "alias":
                for u, v in edges:
                    u.dep_set_tag = 0
                    v.dep_check_tag = 0
            try:
                d.bingo_validate_no_hang(tag_width=tw)
            except ValueError:
                raised += 1
            else:
                raise AssertionError(f"{setup} corruption was NOT caught")
        assert raised == 3
