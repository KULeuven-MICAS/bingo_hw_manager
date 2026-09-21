"""Tag allocation must be reproducible across processes.

Python randomises string hashing per process, so any dict or set keyed on a
string -- or on a node object, which hashes by id -- iterates in a different
order in every run. An allocator that depends on such an order emits DIFFERENT
TAGS, and therefore different firmware, from one compile to the next. That is
invisible in a single-process test suite: the seed is fixed for the life of the
process, so compiling twice in one test always agrees.

This test therefore spawns real subprocesses with different PYTHONHASHSEED
values. It is the only way this class of bug is observable.
"""
import os
import subprocess
import sys
import textwrap

_HERE = os.path.dirname(__file__)
_ROOT = os.path.abspath(os.path.join(_HERE, "..", ".."))

_PROG = textwrap.dedent(
    """
    import sys
    sys.path.insert(0, {root!r})
    sys.path.insert(0, {sw!r})
    from bingo_dfg import BingoDFG
    from bingo_node import BingoNode
    import contextlib, io

    def build():
        d = BingoDFG(num_clusters_per_chiplet=2, num_cores_per_cluster=3,
                     dep_tag_width=4, num_chiplets=1)
        nodes = []
        for i in range(24):
            n = BingoNode(0, i % 2, i % 3, node_name="n%d" % i)
            d.bingo_add_node(n)
            nodes.append(n)
        # a mix of chains and fan-outs, so the cover has real choices to make
        for i in range(len(nodes) - 1):
            d.bingo_add_edge(nodes[i], nodes[i + 1])
        for i in range(0, len(nodes) - 6, 6):
            d.bingo_add_edge(nodes[i], nodes[i + 5])
        return d

    d = build()
    with contextlib.redirect_stdout(io.StringIO()):
        d.bingo_compile_conditional_regions()
        d.bingo_transform_dfg_add_dummy_set_nodes()
        d.bingo_transform_dfg_add_dummy_check_nodes()
        d.bingo_assign_normal_node_dep_check_info()
        d.bingo_assign_normal_node_dep_set_info()
        d.bingo_transform_dfg_allocate_dep_tags(tag_width=4)
        d.bingo_validate_no_hang(tag_width=4)
    out = []
    for n in d.bingo_stream_order():
        out.append("%s:%s:%s" % (n.node_name, n.dep_set_tag, n.dep_check_tag))
    print("|".join(out))
    """
).format(root=_ROOT, sw=os.path.join(_ROOT, "sw"))


def _compile_with_seed(seed):
    env = dict(os.environ, PYTHONHASHSEED=str(seed))
    r = subprocess.run([sys.executable, "-c", _PROG], capture_output=True,
                       text=True, env=env, cwd=_ROOT)
    assert r.returncode == 0, f"seed {seed} failed:\n{r.stderr[-2000:]}"
    return r.stdout.strip()


def test_tags_are_identical_across_hash_seeds():
    """The regression: keying the matching graph on tuples containing a string
    made every compile produce different tags."""
    results = {seed: _compile_with_seed(seed) for seed in (0, 1, 12345, 99991)}
    assert all(v for v in results.values()), "a subprocess produced no output"
    distinct = set(results.values())
    assert len(distinct) == 1, (
        f"tag allocation differs across PYTHONHASHSEED: {len(distinct)} distinct "
        f"results from {len(results)} seeds -- the compile is not reproducible")


def test_the_check_would_notice_a_difference():
    """Guards the test itself: two genuinely different strings must not compare
    equal, i.e. the assertion above is not vacuous."""
    a = _compile_with_seed(0)
    assert len(a.split("|")) > 10, "graph too small to be a meaningful check"
    assert a != a.replace(":0:", ":7:", 1), "sentinel comparison is broken"
