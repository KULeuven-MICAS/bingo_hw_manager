"""Multi-edge dependency ops: one descriptor naming a JOIN instead of a chain
of serialised ``dummy_check`` tasks.

``BingoDFG.enable_multi_col_check`` turns off the Case-2 split in
``bingo_transform_dfg_add_dummy_check_nodes``, so a consumer with producers on
several cores emits ONE multi-column check. No RTL change is needed for this:
``dep_check_code`` is already an atomically AND-reduced column bitmask whose
clear fires only on a full match. What it needs is a shared tag across the
join's producers, which the allocator's group path provides.

These tests pin both halves: the compiler output (fewer descriptors, one shared
tag, correct columns) and the behaviour (the consumer never dispatches before
ALL of its producers are done, and nothing deadlocks).
"""
import os
import sys

import networkx as nx
import pytest

_HERE = os.path.dirname(__file__)
_ROOT = os.path.abspath(os.path.join(_HERE, "..", ".."))
sys.path.insert(0, _ROOT)
sys.path.insert(0, os.path.join(_ROOT, "sw"))

from bingo_dfg import BingoDFG                     # noqa: E402
from bingo_node import BingoNode                   # noqa: E402
from model.bingo_sim import BingoSimulator, SimConfig   # noqa: E402
from model.bingo_sim_chiplet import TaskDescriptor      # noqa: E402


def _compile(d, tag_width=3):
    d.bingo_compile_conditional_regions()
    d.bingo_transform_dfg_add_dummy_set_nodes()
    d.bingo_transform_dfg_add_dummy_check_nodes()
    d.bingo_assign_normal_node_dep_check_info()
    d.bingo_assign_normal_node_dep_set_info()
    d.bingo_transform_dfg_allocate_dep_tags(tag_width=tag_width)
    return d


def _join_dfg(n_producers, multi_edge, n_cores=4):
    """n_producers on distinct cores -> one consumer on core 0."""
    d = BingoDFG(num_clusters_per_chiplet=1, num_cores_per_cluster=n_cores,
                 dep_tag_width=3, num_chiplets=1)
    d.enable_multi_col_check = multi_edge
    cons = BingoNode(0, 0, 0, node_name="join")
    d.bingo_add_node(cons)
    prods = []
    for i in range(n_producers):
        p = BingoNode(0, 0, 1 + i, node_name=f"p{i}")
        d.bingo_add_node(p)
        d.bingo_add_edge(p, cons)
        prods.append(p)
    return d, prods, cons


def _mask(cores):
    m = 0
    for c in cores:
        m |= 1 << c
    return m


def _descriptors(d):
    per = {}
    for n in d.bingo_stream_order():
        per.setdefault(n.assigned_chiplet_id, []).append(TaskDescriptor(
            task_type={"dummy": 1, "gating": 2}.get(n.node_type, 0),
            task_id=n.node_id,
            assigned_chiplet_id=n.assigned_chiplet_id,
            assigned_cluster_id=n.assigned_cluster_id,
            assigned_core_id=n.assigned_core_id,
            dep_check_en=n.dep_check_enable,
            dep_check_code=_mask(n.dep_check_list),
            dep_set_en=n.dep_set_enable,
            dep_set_all_chiplet=n.remote_dep_set_all,
            dep_set_chiplet_id=n.dep_set_chiplet_id,
            dep_set_cluster_id=n.dep_set_cluster_id,
            dep_set_code=_mask(n.dep_set_list),
            dep_check_tag=n.dep_check_tag,
            dep_set_tag=n.dep_set_tag))
    return per


def _run(d, n_cores=4, seed=7, delays=(5, 25)):
    sim = BingoSimulator(SimConfig(
        num_chiplets=1, num_clusters_per_chiplet=1, num_cores_per_cluster=n_cores,
        work_delay_range=delays, random_seed=seed))
    sim.load_tasks(_descriptors(d))
    res = sim.run(max_cycles=50000)
    assert not res.deadlock_detected, "multi-edge dep graph deadlocked"
    disp, done = {}, {}
    for e in res.trace.events:
        if e.event_type == "TASK_DISPATCHED":
            disp.setdefault(e.task_id, e.time)
        if e.event_type == "TASK_DONE":
            done.setdefault(e.task_id, e.time)
    return res, disp, done


class TestLoweringShape:
    def test_split_join_is_the_default(self):
        """Without the flag, a 3-way join still becomes 2 dummy_checks."""
        d, prods, cons = _join_dfg(3, multi_edge=False)
        _compile(d)
        dummies = [n for n in d.nodes() if n.node_type == "dummy"]
        assert len(dummies) == 2, [n.node_name for n in dummies]
        assert len(cons.dep_check_list) == 1, "split join checks ONE column"

    def test_multi_edge_join_is_one_descriptor(self):
        """With the flag, the same join is a single multi-column check."""
        d, prods, cons = _join_dfg(3, multi_edge=True)
        _compile(d)
        assert [n for n in d.nodes() if n.node_type == "dummy"] == []
        assert sorted(cons.dep_check_list) == [1, 2, 3]

    def test_join_producers_share_one_tag(self):
        """A descriptor carries ONE tag, so every producer of the join must
        write the tag the consumer checks."""
        d, prods, cons = _join_dfg(3, multi_edge=True)
        _compile(d)
        tags = {p.dep_set_tag for p in prods}
        assert len(tags) == 1, f"producers disagree on the tag: {tags}"
        assert cons.dep_check_tag == tags.pop()

    @pytest.mark.parametrize("k", [2, 3, 4, 5, 6, 7])
    def test_descriptor_count_drops(self, k):
        split, _, _ = _join_dfg(k, multi_edge=False, n_cores=k + 1)
        merged, _, _ = _join_dfg(k, multi_edge=True, n_cores=k + 1)
        _compile(split)
        _compile(merged)
        assert merged.number_of_nodes() == k + 1          # producers + consumer
        assert split.number_of_nodes() == k + 1 + (k - 1)  # + k-1 dummy_checks


class TestBehaviour:
    @pytest.mark.parametrize("k", [2, 3, 4, 5, 6, 7])
    def test_consumer_waits_for_every_producer(self, k):
        """The property the dummy_checks used to enforce, now enforced by one
        all-or-nothing multi-column check."""
        d, prods, cons = _join_dfg(k, multi_edge=True, n_cores=k + 1)
        _compile(d)
        _res, disp, done = _run(d, n_cores=k + 1)
        assert cons.node_id in disp, "the join never dispatched"
        for p in prods:
            assert disp[cons.node_id] >= done[p.node_id], (
                f"join dispatched at {disp[cons.node_id]} before producer "
                f"{p.node_name} finished at {done[p.node_id]}")

    @pytest.mark.parametrize("seed", range(12))
    def test_skewed_producer_latency(self, seed):
        """One very slow producer must still hold the join back.

        The interesting case for an all-or-nothing check: the fast producers'
        columns arrive early and sit there, and the check must neither pass nor
        consume them until the slow one lands.
        """
        d, prods, cons = _join_dfg(4, multi_edge=True, n_cores=5)
        _compile(d)
        _res, disp, done = _run(d, n_cores=5, seed=seed, delays=(5, 400))
        for p in prods:
            assert disp[cons.node_id] >= done[p.node_id], p.node_name

    def test_split_and_merged_agree(self):
        """Both lowerings of the same graph must respect the same ordering."""
        for multi in (False, True):
            d, prods, cons = _join_dfg(4, multi_edge=multi, n_cores=5)
            _compile(d)
            _res, disp, done = _run(d, n_cores=5)
            for p in prods:
                assert disp[cons.node_id] >= done[p.node_id], (multi, p.node_name)


class TestChainedJoins:
    def _diamond_chain(self, depth, width, multi_edge):
        """width producers -> join -> width producers -> join -> ...

        Exercises tag REUSE across stages: each stage's group must be able to
        take a tag back once the previous stage has drained, or a long chain
        would exhaust the tag space.
        """
        d = BingoDFG(num_clusters_per_chiplet=1, num_cores_per_cluster=width + 1,
                     dep_tag_width=3, num_chiplets=1)
        d.enable_multi_col_check = multi_edge
        prev = None
        joins = []
        for s in range(depth):
            stage = []
            for i in range(width):
                n = BingoNode(0, 0, 1 + i, node_name=f"s{s}p{i}")
                d.bingo_add_node(n)
                if prev is not None:
                    d.bingo_add_edge(prev, n)
                stage.append(n)
            j = BingoNode(0, 0, 0, node_name=f"s{s}join")
            d.bingo_add_node(j)
            for n in stage:
                d.bingo_add_edge(n, j)
            joins.append((stage, j))
            prev = j
        return d, joins

    @pytest.mark.parametrize("depth,width", [(3, 3), (5, 2), (4, 4)])
    def test_chained_joins_run_clean(self, depth, width):
        d, joins = self._diamond_chain(depth, width, multi_edge=True)
        _compile(d)
        _res, disp, done = _run(d, n_cores=width + 1, delays=(5, 60))
        for stage, j in joins:
            for p in stage:
                assert disp[j.node_id] >= done[p.node_id], (
                    f"{j.node_name} dispatched before {p.node_name}")

    def test_tag_reuse_keeps_a_long_chain_in_budget(self):
        """A 10-stage chain must still fit in 2**3 tags: consecutive stages are
        ordered, so their groups share a tag."""
        d, _joins = self._diamond_chain(10, 3, multi_edge=True)
        _compile(d, tag_width=3)     # must not raise
        tags = {n.dep_set_tag for n in d.nodes() if n.dep_set_enable}
        assert max(tags) < 8


class TestForkJoin:
    """A fork and a join in one graph.

    Only the JOIN side merges now -- the fan-out is still split into one
    dummy_set per successor, because a multi-row set would merge tag groups and
    can fold two concurrent edges onto one presence bit. So this checks the
    ordering still holds in a shape where both appear.
    """

    def _fork_join(self, width, multi_edge):
        d = BingoDFG(num_clusters_per_chiplet=1, num_cores_per_cluster=width + 2,
                     dep_tag_width=4, num_chiplets=1)
        d.enable_multi_col_check = multi_edge
        fork = BingoNode(0, 0, 0, node_name="fork")
        join = BingoNode(0, 0, width + 1, node_name="join")
        d.bingo_add_node(fork); d.bingo_add_node(join)
        workers = []
        for i in range(width):
            w = BingoNode(0, 0, 1 + i, node_name=f"w{i}")
            d.bingo_add_node(w)
            d.bingo_add_edge(fork, w)
            d.bingo_add_edge(w, join)
            workers.append(w)
        return d, fork, workers, join

    @pytest.mark.parametrize("width", [2, 3, 4, 5])
    def test_ordering_holds(self, width):
        d, fork, workers, join = self._fork_join(width, multi_edge=True)
        _compile(d)
        _res, disp, done = _run(d, n_cores=width + 2, delays=(5, 80))
        for w in workers:
            assert disp[w.node_id] >= done[fork.node_id], w.node_name
            assert disp[join.node_id] >= done[w.node_id], w.node_name

    @pytest.mark.parametrize("width", [2, 3, 4, 5])
    def test_join_side_merges_fork_side_does_not(self, width):
        split, *_ = self._fork_join(width, multi_edge=False)
        merged, *_ = self._fork_join(width, multi_edge=True)
        _compile(split); _compile(merged)
        # the fork still costs width-1 dummy_sets in BOTH; only the join's
        # width-1 dummy_checks collapse.
        assert split.number_of_nodes() == width + 2 + 2 * (width - 1)
        assert merged.number_of_nodes() == width + 2 + (width - 1)
