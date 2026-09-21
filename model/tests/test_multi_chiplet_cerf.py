"""Multi-chiplet conditional execution: can a routing decision on one die
safely gate work on another?

THE HAZARD. Locally, CERF is race-free for a structural reason: a gated consumer
depends on the gating task through the dep matrix, so it cannot dispatch until
that task completes -- and the CERF write happens at that completion. The
dependency edge orders the write against the read.

Across a die that ordering evaporates if the predicate travels as its own
message. Two messages, two paths, no ordering: the remote task can see its
dependency satisfied while its CERF bit is still stale. It then skips an expert
the router selected. Measured below: up to ~45% of seeds, and it is SILENT --
the task still propagates its dep_set, so nothing deadlocks and no watchdog
fires. The model output is simply wrong.

THE FIX. Carry the predicate inside the cross-chiplet dep-set message
(``cerf_scope="carried"``). One message, one wire, in-order, so the predicate
cannot arrive after the signal that releases the task it gates. The race is
eliminated by construction rather than by a barrier.

THE COMPILER OBLIGATION that makes it work, and which this test pins: a gating
node's remote successors are NOT reached by the gating node's own descriptor.
The dummy-set pass inserts a proxy ``dummy_set`` on the gating node's core, and
that proxy is what crosses the die. It must inherit the gating node's CERF
payload, or the predicate never rides the edge at all (see the proxy_cerf block
in scripts/eval_darts.py).
"""
import os
import sys

import pytest

_HERE = os.path.dirname(__file__)
_ROOT = os.path.abspath(os.path.join(_HERE, "..", ".."))
for _p in (_ROOT, os.path.join(_ROOT, "sw"), os.path.join(_ROOT, "scripts")):
    if _p not in sys.path:
        sys.path.insert(0, _p)

from bingo_dfg import BingoDFG                                   # noqa: E402
from bingo_node import BingoNode                                 # noqa: E402
from eval_darts import compile_dfg, dfg_to_task_descriptors      # noqa: E402
from model.bingo_sim import BingoSimulator, SimConfig            # noqa: E402


def _moe(n_experts=4, n_chiplets=2, n_cores=3):
    """Router (gating) on chiplet 0; experts SPREAD across dies; aggregator."""
    d = BingoDFG(num_clusters_per_chiplet=1, num_cores_per_cluster=n_cores,
                 dep_tag_width=4, num_chiplets=n_chiplets)
    inp = BingoNode(0, 0, 0, node_name="input")
    router = BingoNode(0, 0, 0, node_name="router")
    agg = BingoNode(0, 0, 0, node_name="agg")
    for n in (inp, router, agg):
        d.bingo_add_node(n)
    d.bingo_add_edge(inp, router)
    experts = []
    for i in range(n_experts):
        chip = i % n_chiplets
        e = BingoNode(chip, 0, 1 + (i // n_chiplets) % (n_cores - 1),
                      node_name=f"e{i}_chip{chip}")
        d.bingo_add_node(e)
        d.bingo_add_edge(router, e, cond=True)
        d.bingo_add_edge(e, agg)
        experts.append(e)
    return d, router, experts, agg


def _run(scope, jitter, active_idx, seed):
    d, _router, experts, _agg = _moe()
    compile_dfg(d, dep_tag_width=4)
    active = {experts[i] for i in active_idx}
    per = dfg_to_task_descriptors(d, work_delays=None, active_nodes=active)
    sim = BingoSimulator(SimConfig(
        num_chiplets=2, num_clusters_per_chiplet=1, num_cores_per_cluster=3,
        work_delay_range=(20, 60), h2h_latency=10, h2h_latency_jitter=jitter,
        push_interval=3, random_seed=seed, cerf_scope=scope))
    sim.load_tasks(per)
    r = sim.run(max_cycles=200000)
    disp = {e.task_id for e in r.trace.events if e.event_type == "TASK_DISPATCHED"}
    skipped = {e.task_id for e in r.trace.events if e.event_type == "TASK_SKIPPED"}
    bad = []
    for i, e in enumerate(experts):
        want, ran = i in active_idx, e.node_id in disp
        if want and not ran:
            bad.append(f"e{i}(chip{e.assigned_chiplet_id}) active but did not run")
        if (not want) and ran:
            bad.append(f"e{i}(chip{e.assigned_chiplet_id}) INACTIVE but RAN")
        if want and e.node_id in skipped:
            bad.append(f"e{i}(chip{e.assigned_chiplet_id}) active but was skipped")
    return r, bad


ACTIVE = (0, 1)          # e0 local to the router, e1 on the REMOTE die


class TestCarriedPredicateIsRaceFree:
    """The property the design exists to provide."""

    @pytest.mark.parametrize("jitter", [0, 10, 20, 40, 80])
    def test_no_violation_at_any_jitter(self, jitter):
        for seed in range(12):
            r, bad = _run("carried", jitter, ACTIVE, seed)
            assert not r.deadlock_detected, f"deadlock jitter={jitter} seed={seed}"
            assert not bad, f"jitter={jitter} seed={seed}: {bad}"

    def test_remote_expert_actually_runs(self):
        """Guards against the test passing because nothing crossed the die."""
        d, _router, experts, _agg = _moe()
        assert any(e.assigned_chiplet_id == 1 for e in experts)
        r, bad = _run("carried", 40, ACTIVE, seed=0)
        disp = {e.task_id for e in r.trace.events
                if e.event_type == "TASK_DISPATCHED"}
        remote = experts[1]
        assert remote.assigned_chiplet_id == 1
        assert remote.node_id in disp, "the remote expert never ran at all"
        assert not bad


class TestNaiveSeparateMessageRaces:
    """Pins the hazard, so a regression cannot quietly reintroduce it."""

    def test_race_appears_under_jitter(self):
        bad_seeds = 0
        for seed in range(40):
            _r, bad = _run("separate_msg", 40, ACTIVE, seed)
            if bad:
                bad_seeds += 1
        assert bad_seeds > 0, (
            "expected the separate-message CERF broadcast to race under D2D "
            "jitter; if this now passes cleanly the hazard model has changed")

    def test_failure_is_silent_not_a_hang(self):
        """The race drops selected work; it never deadlocks and never runs an
        unselected expert, so no watchdog can catch it."""
        saw_bad = False
        for seed in range(40):
            r, bad = _run("separate_msg", 40, ACTIVE, seed)
            assert not r.deadlock_detected, f"unexpected deadlock seed={seed}"
            for b in bad:
                assert "INACTIVE but RAN" not in b, (
                    f"unexpected direction: {b} -- CERF defaults inactive, so a "
                    "late write can only UNDER-activate")
                saw_bad = True
        assert saw_bad


class TestGlobalInstantHidesIt:
    """The historical model assumed a zero-latency global CERF the RTL has no
    register for. Kept so it is documented rather than forgotten."""

    def test_idealised_model_never_races(self):
        for seed in range(12):
            r, bad = _run("global_instant", 80, ACTIVE, seed)
            assert not r.deadlock_detected
            assert not bad
