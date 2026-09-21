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
    d.enable_multi_row_set = multi_edge
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
        d.enable_multi_row_set = multi_edge
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


def _fanout_dfg(n_consumers, multi_edge, n_cores=4, n_clusters=1):
    """One producer on core 0 -> n_consumers on distinct cores."""
    d = BingoDFG(num_clusters_per_chiplet=n_clusters, num_cores_per_cluster=n_cores,
                 dep_tag_width=3, num_chiplets=1)
    d.enable_multi_col_check = multi_edge
    d.enable_multi_row_set = multi_edge
    prod = BingoNode(0, 0, 0, node_name="fork")
    d.bingo_add_node(prod)
    cons = []
    for i in range(n_consumers):
        c = BingoNode(0, 0, 1 + i, node_name=f"c{i}")
        d.bingo_add_node(c)
        d.bingo_add_edge(prod, c)
        cons.append(c)
    return d, prod, cons


class TestMultiRowSet:
    def test_split_fanout_is_the_default(self):
        d, prod, cons = _fanout_dfg(3, multi_edge=False)
        _compile(d)
        dummies = [n for n in d.nodes() if n.node_type == "dummy"]
        assert len(dummies) == 2
        assert len(prod.dep_set_list) == 1

    def test_multi_row_fanout_is_one_descriptor(self):
        """All consumers share one (chiplet, cluster), so ONE set op covers them."""
        d, prod, cons = _fanout_dfg(3, multi_edge=True)
        _compile(d)
        assert [n for n in d.nodes() if n.node_type == "dummy"] == []
        assert sorted(prod.dep_set_list) == [1, 2, 3]

    @pytest.mark.parametrize("k", [2, 3, 4, 5, 6, 7])
    def test_every_consumer_waits_for_the_producer(self, k):
        d, prod, cons = _fanout_dfg(k, multi_edge=True, n_cores=k + 1)
        _compile(d)
        _res, disp, done = _run(d, n_cores=k + 1)
        for c in cons:
            assert c.node_id in disp, f"{c.node_name} never dispatched"
            assert disp[c.node_id] >= done[prod.node_id], (
                f"{c.node_name} dispatched at {disp[c.node_id]} before the fork "
                f"finished at {done[prod.node_id]}")

    def test_cross_cluster_fanout_still_splits(self):
        """dep_set_cluster_id is SCALAR, so a fan-out spanning two clusters
        cannot be one op -- it must still emit a dummy per extra cluster."""
        d = BingoDFG(num_clusters_per_chiplet=2, num_cores_per_cluster=3,
                     dep_tag_width=3, num_chiplets=1)
        d.enable_multi_col_check = True
        d.enable_multi_row_set = True
        prod = BingoNode(0, 0, 0, node_name="fork")
        d.bingo_add_node(prod)
        for cl in (0, 1):
            for co in (1, 2):
                c = BingoNode(0, cl, co, node_name=f"c{cl}{co}")
                d.bingo_add_node(c)
                d.bingo_add_edge(prod, c)
        _compile(d)
        dummies = [n for n in d.nodes() if n.node_type == "dummy"]
        assert len(dummies) == 1, [n.node_name for n in dummies]
        # each op covers BOTH cores of its cluster
        assert sorted(prod.dep_set_list) == [1, 2]
        assert sorted(dummies[0].dep_set_list) == [1, 2]
        assert dummies[0].dep_set_cluster_id != prod.dep_set_cluster_id


class TestForkJoin:
    def _fork_join(self, width, multi_edge):
        """fork -> width workers -> join, all in one cluster."""
        d = BingoDFG(num_clusters_per_chiplet=1, num_cores_per_cluster=width + 2,
                     dep_tag_width=3, num_chiplets=1)
        d.enable_multi_col_check = multi_edge
        d.enable_multi_row_set = multi_edge
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
    def test_fork_join_ordering(self, width):
        d, fork, workers, join = self._fork_join(width, multi_edge=True)
        _compile(d)
        _res, disp, done = _run(d, n_cores=width + 2, delays=(5, 80))
        for w in workers:
            assert disp[w.node_id] >= done[fork.node_id], w.node_name
            assert disp[join.node_id] >= done[w.node_id], w.node_name

    @pytest.mark.parametrize("width", [2, 3, 4, 5])
    def test_fork_join_descriptor_count(self, width):
        split, *_ = self._fork_join(width, multi_edge=False)
        merged, *_ = self._fork_join(width, multi_edge=True)
        _compile(split); _compile(merged)
        assert merged.number_of_nodes() == width + 2       # no scaffolding at all
        assert split.number_of_nodes() == width + 2 + 2 * (width - 1)


class TestRowCollision:
    """Two consumers on the SAME (cluster, core) cannot share one set op.

    A set writes ONE presence bit per row. If two consumers share a row and one
    set op, the first to check drains the bit and the second starves forever.
    Found by running the real fa_decode_4cluster graph on the model: the entry
    node fanned out to WarmZero_cl2 (core 2), Geom0_cl2 (core 1) and Geom1_cl2
    (core 1 again), and Geom1 never dispatched.
    """

    def _same_core_fanout(self, multi_edge):
        # fork -> {a, b} both on core 1, plus c on core 2
        d = BingoDFG(num_clusters_per_chiplet=1, num_cores_per_cluster=3,
                     dep_tag_width=3, num_chiplets=1)
        d.enable_multi_col_check = multi_edge
        d.enable_multi_row_set = multi_edge
        fork = BingoNode(0, 0, 0, node_name="fork")
        d.bingo_add_node(fork)
        a = BingoNode(0, 0, 1, node_name="a")
        b = BingoNode(0, 0, 1, node_name="b")
        c = BingoNode(0, 0, 2, node_name="c")
        for n in (a, b, c):
            d.bingo_add_node(n)
            d.bingo_add_edge(fork, n)
        return d, fork, (a, b, c)

    def test_no_set_op_targets_a_row_twice(self):
        d, fork, _ = self._same_core_fanout(multi_edge=True)
        _compile(d)
        for n in d.nodes():
            if not n.dep_set_enable:
                continue
            rows = n.dep_set_list or []
            assert len(set(rows)) == len(rows), (
                f"{n.node_name} sets row {rows} more than once")

    def test_both_same_core_consumers_run(self):
        """The regression itself: with one shared bit, `b` never dispatches."""
        d, fork, (a, b, c) = self._same_core_fanout(multi_edge=True)
        _compile(d)
        _res, disp, done = _run(d, n_cores=3)
        for n in (a, b, c):
            assert n.node_id in disp, f"{n.node_name} never dispatched"
            assert disp[n.node_id] >= done[fork.node_id], n.node_name

    @pytest.mark.parametrize("dup", [2, 3, 4])
    def test_many_consumers_on_one_core(self, dup):
        d = BingoDFG(num_clusters_per_chiplet=1, num_cores_per_cluster=3,
                     dep_tag_width=3, num_chiplets=1)
        d.enable_multi_col_check = True
        d.enable_multi_row_set = True
        fork = BingoNode(0, 0, 0, node_name="fork")
        d.bingo_add_node(fork)
        cons = []
        for i in range(dup):
            n = BingoNode(0, 0, 1, node_name=f"same{i}")
            d.bingo_add_node(n); d.bingo_add_edge(fork, n); cons.append(n)
        other = BingoNode(0, 0, 2, node_name="other")
        d.bingo_add_node(other); d.bingo_add_edge(fork, other); cons.append(other)
        _compile(d)
        _res, disp, done = _run(d, n_cores=3)
        for n in cons:
            assert n.node_id in disp, f"{n.node_name} never dispatched"
            assert disp[n.node_id] >= done[fork.node_id], n.node_name

    def test_same_core_consumers_get_distinct_tags(self):
        """They are in different slots, so different ops, so different tags."""
        d, fork, (a, b, c) = self._same_core_fanout(multi_edge=True)
        _compile(d)
        assert a.dep_check_tag != b.dep_check_tag, (
            "two consumers on one row must not expect the same tag bit")


class TestOneBitPerCellGuard:
    """The detector itself, not just the violations it found.

    A dep-matrix cell holds ONE presence bit per tag and a tag group holds ONE
    tag, so two edges of a group that are live at the same time must not land in
    the same cell -- they would be the same bit, and the second consumer to check
    would wait forever. Merging ops links groups transitively, which is how a
    graph reaches that state.

    `bingo_transform_dfg_allocate_dep_tags` refuses such a graph instead of
    emitting one that hangs. Nothing else pins that refusal, and the failure it
    prevents is silent, so it is pinned here.
    """

    def _merge_violating_dfg(self, multi_edge):
        """Smallest graph found that trips the guard (4 nodes, 5 edges).

            n0(core1) -> n2(core1), n3(core0)
            n1(core2) -> n2(core1), n3(core0)
            n2(core1) -> n3(core0)

        With multi-row set on, n0's fan-out links n2 and n3 into one tag group,
        and n2 -> n3 drags n2's own edge in with it. Both `n0 -> n3` and
        `n2 -> n3` then sit in cell (consumer core 0, producer core 1), neither
        ordered before the other -- one bit, two live edges.
        """
        d = BingoDFG(num_clusters_per_chiplet=1, num_cores_per_cluster=3,
                     dep_tag_width=4, num_chiplets=1)
        d.enable_multi_col_check = multi_edge
        d.enable_multi_row_set = multi_edge
        n = []
        for i, core in enumerate((1, 2, 1, 0)):
            nd = BingoNode(0, 0, core, node_name=f"n{i}")
            d.bingo_add_node(nd)
            n.append(nd)
        for a, b in ((0, 2), (0, 3), (1, 2), (1, 3), (2, 3)):
            d.bingo_add_edge(n[a], n[b])
        return d

    def test_guard_refuses_the_merge(self):
        d = self._merge_violating_dfg(multi_edge=True)
        with pytest.raises(ValueError, match="concurrently-live edges on cell"):
            _compile(d, tag_width=4)

    def test_error_names_both_edges_and_the_cell(self):
        """A compile error is only useful if it says which two ops collided."""
        d = self._merge_violating_dfg(multi_edge=True)
        with pytest.raises(ValueError) as exc:
            _compile(d, tag_width=4)
        msg = str(exc.value)
        assert "edge A:" in msg and "edge B:" in msg
        assert "consumer core, producer core" in msg

    def test_same_graph_is_fine_unmerged(self):
        """Proves the merge causes it, not the graph: with one op per edge the
        colliding edges get distinct tags and it compiles and runs."""
        d = self._merge_violating_dfg(multi_edge=False)
        _compile(d, tag_width=4)          # must not raise
        _res, disp, done = _run(d, n_cores=3)
        for a, b in ((0, 2), (0, 3), (1, 2), (1, 3), (2, 3)):
            pa, pb = f"n{a}", f"n{b}"
            ida = next(x.node_id for x in d.nodes() if x.node_name == pa)
            idb = next(x.node_id for x in d.nodes() if x.node_name == pb)
            assert disp[idb] >= done[ida], f"{pb} dispatched before {pa} finished"

    def test_guard_does_not_reject_valid_merges(self):
        """It must not be a blanket refusal -- a clean join/fan-out still
        compiles with merging on."""
        d, _prods, _cons = _join_dfg(3, multi_edge=True)
        _compile(d)                        # must not raise
        d2, _fork, _cons2 = _fanout_dfg(3, multi_edge=True)
        _compile(d2)                       # must not raise
