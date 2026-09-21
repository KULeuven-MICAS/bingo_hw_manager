# Fanchen Kong <fanchen.kong@kuleuven.be>
from __future__ import annotations

import random
from bingo_utils import DiGraphWrapper
from bingo_node import (
    BingoNode,
    BINGO_DEP_TAG_WIDTH,
    BINGO_NUM_CLUSTERS_PER_CHIPLET,
    BINGO_NUM_CORES_PER_CLUSTER,
    BINGO_TASK_DESC_WIDTH,
    BINGO_TASK_DESC_WORD_WIDTH,
    BINGO_TASK_ID_WIDTH,
    bingo_task_desc_fields,
)
import networkx as nx
MAX_NUM_CHIPLETS = 8
# The device DMA core: iDMA load/store + every xDMA convert/reshuffle/reduce is HW-bound
# here, so it is the busiest column of the per-cluster dep matrix. A CROSS-cluster producer
# on this core aliases the consumer cluster's own core-1 traffic (the column is the BARE
# producer core, not cluster-qualified) -> see bingo_assert_no_cross_cluster_samecore_handoff.
DMA_CORE = 1
class BingoDFG(DiGraphWrapper[BingoNode]):
    """Data Flow Graph (DFG) for Bingo."""

    def __init__(
        self,
        num_clusters_per_chiplet: int = BINGO_NUM_CLUSTERS_PER_CHIPLET,
        num_cores_per_cluster: int = BINGO_NUM_CORES_PER_CLUSTER,
        dep_tag_width: int = BINGO_DEP_TAG_WIDTH,
        task_desc_width: int = BINGO_TASK_DESC_WIDTH,
        num_chiplets: int = MAX_NUM_CHIPLETS,
    ) -> None:
        super().__init__()
        self.id = 0
        self._next_cerf_group = 0
        # Chiplet geometry and descriptor container width. These three decide
        # every variable-width field in the descriptor, so they must match the
        # parameters the DUT is elaborated with (NUM_CLUSTERS_PER_CHIPLET,
        # NUM_CORES_PER_CLUSTER, DepTagWidth, TaskDescBusWidth).
        self.num_clusters_per_chiplet = num_clusters_per_chiplet
        self.num_cores_per_cluster = num_cores_per_cluster
        self.dep_tag_width = dep_tag_width
        self.task_desc_width = task_desc_width
        # How many chiplets this DFG targets. The broadcast dep-set detection in
        # bingo_transform_dfg_add_dummy_set_nodes needs the REAL count: assuming
        # MAX_NUM_CHIPLETS there mis-classifies a point-to-point remote edge on a
        # 2-chiplet part as a broadcast, and the RTL then multicasts to EVERY
        # chiplet including the producer's own -- a stray tagged set with no
        # consumer to drain it, i.e. a hang.
        self.num_chiplets = num_chiplets
        # MULTI-EDGE DEP OPS. False keeps the historical lowering: one set target
        # and one check column per descriptor, every fan-in/fan-out split into
        # extra dummy task descriptors. True lets ONE descriptor name a join --
        # the dep matrix already AND-reduces dep_check_code atomically and only
        # clears on a full match, so a multi-column check needs no RTL change;
        # what it needs is a shared tag across the join's producers, which the
        # tag allocator's general path provides. Off by default until the RTL
        # regression has run against it.
        # (B) MULTI-COLUMN CHECK: one descriptor checks every producer column
        # of a join. Structurally safe on its own -- with (A) off each producer
        # has exactly one consumer, so a tag group is {one consumer + its
        # producers} and its edges occupy distinct cells by construction.
        self.enable_multi_col_check = False
        # (A) MULTI-ROW SET: one descriptor releases every consumer sharing a
        # target (chiplet, cluster). This one MERGES tag groups -- a producer
        # feeding several consumers links them, and the component can grow until
        # two of its edges share a cell. The allocator rejects that (see
        # bingo_transform_dfg_allocate_dep_tags), so leaving this off is safe and
        # turning it on is checked, never silent.
        self.enable_multi_row_set = False
        self._stream_order_cache = None
    def bingo_add_node(self, node_obj: BingoNode) -> None:
        """Add a node to the DFG."""

        # Assign a unique ID to the node
        self.id += 1
        node_obj.node_id = self.id
        # Add the node to the graph and the lookup dictionaries
        self.add_node(node_obj)
    def bingo_add_edge(self, from_node_obj: BingoNode, to_node_obj: BingoNode, cond: bool = False) -> None:
        """Add an edge to the DFG.

        Args:
            cond: If True, marks this as a conditional execution edge. The
                  source node will be auto-promoted to a gating task and the
                  destination will be conditionally gated during compilation.
        """
        self.add_edge(from_node_obj, to_node_obj, cond=cond)

    def bingo_insert_node_between(self, from_node_obj: BingoNode, to_node_obj: BingoNode, new_node_obj: BingoNode) -> None:
        """Insert a new node between two existing nodes in the DFG."""
        if not self.has_edge(from_node_obj, to_node_obj):
            raise ValueError(f"No edge exists between {from_node_obj.node_name} and {to_node_obj.node_name}")

        # Preserve edge attributes (e.g. cond) before removal
        edge_data = dict(self[from_node_obj][to_node_obj])

        self.bingo_add_node(new_node_obj)
        self.remove_edge(from_node_obj, to_node_obj)

        # src → new_node: unconditional (dummy nodes must always execute)
        self.add_edge(from_node_obj, new_node_obj)
        # new_node → dst: inherit original edge attributes
        self.add_edge(new_node_obj, to_node_obj, **edge_data)

    def bingo_insert_node_after(self, existing_node_obj: BingoNode, new_node_obj: BingoNode, successors_to_move: list[BingoNode] = None) -> None:
        """Insert a new node after an existing node in the DFG."""
        if successors_to_move is None:
            successors_to_move = list(self.successors(existing_node_obj))

        # Preserve edge attributes before removal
        succ_edge_data = {}
        for succ in successors_to_move:
            succ_edge_data[succ] = dict(self[existing_node_obj][succ])

        self.bingo_add_node(new_node_obj)

        for succ in successors_to_move:
            self.remove_edge(existing_node_obj, succ)

        # existing → new_node: unconditional
        self.add_edge(existing_node_obj, new_node_obj)

        # new_node → successors: inherit original edge attributes
        for succ in successors_to_move:
            self.add_edge(new_node_obj, succ, **succ_edge_data[succ])

    def bingo_assert_no_cross_cluster_samecore_handoff(self) -> None:
        """Compile-time guard for the UNQUALIFIED (main-branch) HW dep matrix.

        The per-cluster dependency matrix's column is the BARE producer core id (not
        cluster-qualified). Every cluster's core-1 DMA/convert/load/store ops therefore
        collapse onto the consumer cluster's counter[*][1] cell, so a CROSS-cluster
        producer on core 1 is indistinguishable from the consumer cluster's own core-1
        traffic: the consumer can pass its counter>=1 check on an unrelated increment and
        dispatch before its true remote producer wrote L3 -> DMAWriteDataCorrect / hang.

        This guard FAILS compilation if any producer->consumer data edge is a cross-cluster
        hand-off whose producer is on the DMA core (core 1). The bingo-framework placement
        must keep such chains intra-cluster (co-locate them; single-cluster is the simplest).
        Common case: core1->core1; a core1->host(core2) store->dequant is also caught.
        """
        bad = []
        for u, v in self.edges():
            if (getattr(u, "node_type", "normal") != "normal"
                    or getattr(v, "node_type", "normal") != "normal"):
                continue
            if (u.assigned_chiplet_id == v.assigned_chiplet_id
                    and u.assigned_cluster_id != v.assigned_cluster_id
                    and u.assigned_core_id == DMA_CORE):
                bad.append((u, v))
        if bad:
            lines = "\n".join(
                f"  {u.node_name} @ (chiplet {u.assigned_chiplet_id}, cluster "
                f"{u.assigned_cluster_id}, core {u.assigned_core_id})  ->  "
                f"{v.node_name} @ (chiplet {v.assigned_chiplet_id}, cluster "
                f"{v.assigned_cluster_id}, core {v.assigned_core_id})"
                for u, v in bad)
            raise ValueError(
                f"[bingo] {len(bad)} cross-cluster DMA-core (core {DMA_CORE}) hand-off(s) "
                "detected. On the unqualified HW dep matrix the producer's column aliases "
                "the consumer cluster's own core-1 traffic -> the RTL hangs "
                "(DMAWriteDataCorrect). Co-locate each chain on one cluster in the "
                "bingo-framework placement. Offending edges:\n" + lines)

    def bingo_transform_dfg_add_dummy_set_nodes(self) -> None:
        """Transform the DFG to add dummy nodes."""
        # The idea of the dummy set nodes is to solve the problem of this kind
        #            simd(Cl0)
        #           /         \
        #          |           |
        #          v           v
        #         dma(Cl0)    gemm(Cl1)
        # We need the dummy set task
        #            simd(Cl0)
        #           /         \\
        #          |           || <--  notice the double line here, it is a fake edge 
        #          |           ||      since we explicitly create the dummy task with the same type of the simd task
        #          v           vv      all we need to do is to push the dummy task after the simd task to describe this dependency
        #         dma(Cl0)    dummy dep set simd task(Cl1)
        #                      |
        #                      v
        #                    gemm(Cl1)
        for cur_node in self.node_list:
            # First find all the successors
            succs_list = [
                succ for succ in self.successors(cur_node)
            ]
            # For all the remote successors, we insert a dummy set node
            remote_succ_list = [
                succ for succ in succs_list
                if succ.assigned_chiplet_id != cur_node.assigned_chiplet_id
            ]
            local_succ_list = [
                succ for succ in succs_list
                if succ.assigned_chiplet_id == cur_node.assigned_chiplet_id
            ]
            if remote_succ_list:
                # Group remote successors by target cluster and core. A broadcast
                # dep-set has one (cluster, target_core, source_core) position
                # replicated across chiplets, so mixing clusters in one group
                # cannot be represented by a single dependency tag.
                remote_succs_by_cluster_core: dict[tuple[int, int], list[BingoNode]] = {}
                for remote_succ in remote_succ_list:
                    key = (remote_succ.assigned_cluster_id, remote_succ.assigned_core_id)
                    remote_succs_by_cluster_core.setdefault(key, []).append(remote_succ)

                for (_cluster_id, core_id), group in remote_succs_by_cluster_core.items():
                    chiplets_in_group = set(s.assigned_chiplet_id for s in group)
                    # A genuine broadcast covers ALL other chiplets AND there are at
                    # least two of them. The `num_chiplets > 2` guard is essential:
                    # at num_chiplets==2 a single point-to-point remote edge trivially
                    # "covers all (one) other chiplets" and would be mis-flagged as a
                    # broadcast -> the RTL multicasts (AW=0xFF) to EVERY chiplet,
                    # including the producer's own, leaving a stray (tagged) set with
                    # no consumer to drain it. Such a single edge must use a targeted
                    # dummy_set instead.
                    if self.num_chiplets > 2 and len(chiplets_in_group) == (self.num_chiplets - 1):
                        # Broadcast: one dummy_set blocks cur_node's core and sets the bit on all chiplets
                        print(f"Node {cur_node.node_name} is a broadcast node to set all chiplets for core {core_id}.")
                        dummy_set_node = BingoNode(
                            assigned_chiplet_id=cur_node.assigned_chiplet_id,
                            assigned_cluster_id=cur_node.assigned_cluster_id,      # must be the same type of the cur_node to block the execution
                            assigned_core_id=cur_node.assigned_core_id,            # must be the same type of the cur_node to block the execution
                            node_name=f"dummy_set_bcast_{cur_node.node_name}_co{core_id}"
                        )
                        dummy_set_node.node_type = "dummy"
                        dummy_set_node.dep_set_enable = True
                        dummy_set_node.dep_set_list = [group[0].assigned_core_id]
                        dummy_set_node.dep_set_cluster_id = group[0].assigned_cluster_id
                        dummy_set_node.dep_set_chiplet_id = group[0].assigned_chiplet_id # should be fine since it is a broadcast type
                        dummy_set_node.dep_check_enable = False
                        dummy_set_node.dep_check_list = []
                        dummy_set_node.remote_dep_set_all = True
                        # Add the dummy set node after cur_node for remote successors in this core group
                        self.bingo_insert_node_after(cur_node, dummy_set_node, group)
                    else:
                        # Normal case: one dummy_set per remote successor
                        for remote_succ in group:
                            print(f"Adding dummy set node for {cur_node.node_name} to remote successor {remote_succ.node_name}")
                            dummy_set_node = BingoNode(
                                assigned_chiplet_id=cur_node.assigned_chiplet_id,
                                assigned_cluster_id=cur_node.assigned_cluster_id,      # must be the same type of the cur_node to block the execution
                                assigned_core_id=cur_node.assigned_core_id,            # must be the same type of the cur_node to block the execution
                                node_name=f"dummy_set_{cur_node.node_name}_to_{remote_succ.node_name}"
                            )
                            dummy_set_node.node_type = "dummy"
                            dummy_set_node.dep_set_enable = True
                            dummy_set_node.dep_set_list = [remote_succ.assigned_core_id]
                            dummy_set_node.dep_set_cluster_id = remote_succ.assigned_cluster_id
                            dummy_set_node.dep_set_chiplet_id = remote_succ.assigned_chiplet_id
                            dummy_set_node.dep_check_enable = False
                            dummy_set_node.dep_check_list = []
                            dummy_set_node.remote_dep_set_all = False
                            # Add the dummy set node to the graph
                            self.bingo_insert_node_between(cur_node, remote_succ, dummy_set_node)
            if len(local_succ_list) > 1 and self.enable_multi_row_set:
                # (A) MULTI-ROW SET. dep_set_code is already a bitmask over
                # consumer ROWS, so ONE op releases every successor that shares a
                # target (chiplet, cluster) -- only dep_set_cluster_id and
                # dep_set_chiplet_id are scalar, so those are what actually force
                # a split. Emit one op per distinct target group instead of one
                # per successor.
                # ONE PRESENCE BIT PER ROW. A row is a (cluster, core) pair, and
                # a set writes a single bit there -- so two successors on the SAME
                # row cannot share one op: the first to check drains the bit and
                # the second starves. Partition each (chiplet, cluster) target
                # into SLOTS, slot j taking the j-th successor of each core, so
                # every op covers each row at most once. Successors that collide
                # on a row land in different slots and therefore get different
                # tags, exactly as the one-op-per-edge lowering gave them.
                by_row: dict = {}
                for succ in local_succ_list:
                    by_row.setdefault(
                        (succ.assigned_chiplet_id, succ.assigned_cluster_id,
                         succ.assigned_core_id), []).append(succ)
                groups: dict = {}
                for (chip, cl, _co), row_succs in by_row.items():
                    for slot, succ in enumerate(row_succs):
                        groups.setdefault((chip, cl, slot), []).append(succ)
                # Keep the group holding a same-core successor on cur_node's own
                # descriptor (that edge is ordered by the core queue anyway);
                # every other group becomes one dummy_set covering the WHOLE group.
                keys = sorted(groups, key=lambda k: (
                    not any(sc.assigned_core_id == cur_node.assigned_core_id
                            for sc in groups[k]), k))
                for gi, k in enumerate(keys[1:]):
                    grp = groups[k]
                    assert len({(sc.assigned_cluster_id, sc.assigned_core_id)
                                for sc in grp}) == len(grp), (
                        f"multi-row dep_set for {cur_node.node_name} would write "
                        f"one presence bit for two consumers on the same row")
                    dummy_set_node = BingoNode(
                        assigned_chiplet_id=cur_node.assigned_chiplet_id,
                        assigned_cluster_id=cur_node.assigned_cluster_id,
                        assigned_core_id=cur_node.assigned_core_id,
                        node_name=f"dummy_set_grp_{cur_node.node_name}_{gi}"
                    )
                    dummy_set_node.node_type = "dummy"
                    dummy_set_node.dep_set_enable = True
                    dummy_set_node.dep_set_list = sorted(
                        {sc.assigned_core_id for sc in grp})
                    dummy_set_node.dep_set_chiplet_id = k[0]
                    dummy_set_node.dep_set_cluster_id = k[1]
                    dummy_set_node.dep_check_enable = False
                    dummy_set_node.dep_check_list = []
                    dummy_set_node.remote_dep_set_all = False
                    self.bingo_insert_node_after(cur_node, dummy_set_node, grp)
            elif len(local_succ_list) > 1:
                # Now the local multiple successor case
                # We need local_successors-1 dummy set nodes
                print(f"Adding dummy set nodes for {cur_node.node_name} with local successors {[succ.node_name for succ in local_succ_list]}")

                # Prioritize edges where the successor node has the same assigned core as cur_node
                prioritized_indices = [i for i, succ in enumerate(local_succ_list)
                                      if succ.assigned_core_id == cur_node.assigned_core_id]
                other_indices = [i for i in range(len(local_succ_list)) if i not in prioritized_indices]
                # Combine prioritized first, then others
                ordered_indices = prioritized_indices + other_indices

                # Only need local_successors-1 dummy set nodes
                for idx in ordered_indices[:len(local_succ_list)-1]:
                    succ = local_succ_list[idx]
                    dummy_set_node = BingoNode(
                        assigned_chiplet_id=cur_node.assigned_chiplet_id,
                        assigned_cluster_id=cur_node.assigned_cluster_id,      # must be the same type of the cur_node to block the execution
                        assigned_core_id=cur_node.assigned_core_id,            # must be the same type of the cur_node to block the execution
                        node_name=f"dummy_set_{cur_node.node_name}_{idx}"
                    )
                    dummy_set_node.node_type = "dummy"
                    dummy_set_node.dep_set_enable = True
                    dummy_set_node.dep_set_list = [succ.assigned_core_id]
                    dummy_set_node.dep_set_cluster_id = succ.assigned_cluster_id
                    dummy_set_node.dep_set_chiplet_id = succ.assigned_chiplet_id
                    dummy_set_node.dep_check_enable = False
                    dummy_set_node.dep_check_list = []
                    dummy_set_node.remote_dep_set_all = False
                    # Add the dummy set node to the graph
                    self.bingo_insert_node_between(cur_node, succ, dummy_set_node)
                    
    def bingo_transform_dfg_add_dummy_check_nodes(self) -> None:
        '''Transform the DFG to add dummy check nodes.

        Two cases require dummy_check insertion:

        Case 1 (same-core): A node has 2+ predecessors on the SAME core
        (different clusters). Both write to the same dep_matrix column.
        Insert dummy_checks to serialize consumption of that column.

        Case 2 (multi-core): A node has predecessors from 2+ DIFFERENT cores.
        Without dummy_checks, the node's dep_check_code would be a multi-bit
        mask (e.g., 0b110 for core 1 + core 2). This holds one column set
        while waiting for the other, creating a deadlock window when combined
        with the dep_matrix overlap detection and done queue HOL blocking.

        Solution: each dep_check (whether dummy or final normal task) must
        check exactly ONE core column. For N distinct predecessor cores,
        insert N-1 dummy_check nodes, each consuming one core's signal.
        The final normal task checks only the last remaining core.
        '''
        for cur_node in self.node_list:
            preds_list = [
                pred for pred in self.predecessors(cur_node)
            ]
            # Group predecessors by core_id
            predecessor_core_dict = {}
            for pred in preds_list:
                if pred.assigned_core_id not in predecessor_core_dict:
                    predecessor_core_dict[pred.assigned_core_id] = []
                predecessor_core_dict[pred.assigned_core_id].append(pred)

            # ---- Case 1: same-core groups with 2+ predecessors ----
            # For each such group, insert len(preds)-1 dummy_checks so that
            # only one signal per core column remains for the final check.
            for core_id, preds in predecessor_core_dict.items():
                if len(preds) >= 2:
                    print(f"Adding dummy check nodes for {cur_node.node_name} "
                          f"with same-core predecessors {[p.node_name for p in preds]} (core {core_id})")
                    for i in range(len(preds) - 1):
                        dummy_check_node = BingoNode(
                            assigned_chiplet_id=cur_node.assigned_chiplet_id,
                            assigned_cluster_id=cur_node.assigned_cluster_id,
                            assigned_core_id=cur_node.assigned_core_id,
                            node_name=f"dummy_check_{cur_node.node_name}_{core_id}_{i}"
                        )
                        dummy_check_node.node_type = "dummy"
                        dummy_check_node.dep_check_enable = True
                        dummy_check_node.dep_check_list = [preds[i].assigned_core_id]
                        dummy_check_node.dep_set_enable = False
                        dummy_check_node.dep_set_list = []
                        dummy_check_node.dep_set_cluster_id = 0
                        dummy_check_node.dep_set_chiplet_id = 0
                        dummy_check_node.remote_dep_set_all = False
                        self.bingo_insert_node_between(preds[i], cur_node, dummy_check_node)

            # ---- Case 2: multi-core predecessors ----
            # After Case 1, re-read predecessors. Exclude dummy_check nodes
            # (already handled) and only look at original predecessors from
            # DIFFERENT cores than cur_node.
            remaining_preds = [
                pred for pred in self.predecessors(cur_node)
                if not (pred.node_type == "dummy" and pred.dep_check_enable)
            ]
            # Distinct core_ids from the remaining non-dummy predecessors
            remaining_core_ids = sorted(set(pred.assigned_core_id for pred in remaining_preds))

            if len(remaining_core_ids) >= 2 and self.enable_multi_col_check:
                # (B) MULTI-COLUMN CHECK. One descriptor checks every producer
                # column at once. The matrix check is all-or-nothing -- a check
                # that cannot pass consumes nothing -- so the partially-arrived
                # column is left intact for the retry and no deadlock window
                # exists. (The historical justification for splitting here cited
                # "dep_matrix overlap detection", which was removed with the
                # counter matrix: dep_set_ready_o is now unconditionally 1.)
                print(f"Multi-column dep_check for {cur_node.node_name}: "
                      f"cores {remaining_core_ids} in ONE op")
            elif len(remaining_core_ids) >= 2:
                # Keep only the LAST core as cur_node's direct predecessor.
                # Insert dummy_checks for all other cores so each dep_check
                # checks exactly one core column.
                cores_to_split = remaining_core_ids[:-1]
                for split_core in cores_to_split:
                    core_preds = [p for p in self.predecessors(cur_node)
                                  if p.assigned_core_id == split_core
                                  and not (p.node_type == "dummy" and p.dep_check_enable)]
                    if not core_preds:
                        continue
                    pred = core_preds[0]
                    print(f"Adding multi-core dummy check for {cur_node.node_name}: "
                          f"splitting {pred.node_name} (core {split_core})")
                    dummy_check_node = BingoNode(
                        assigned_chiplet_id=cur_node.assigned_chiplet_id,
                        assigned_cluster_id=cur_node.assigned_cluster_id,
                        assigned_core_id=cur_node.assigned_core_id,
                        node_name=f"dummy_check_{cur_node.node_name}_mc_{split_core}"
                    )
                    dummy_check_node.node_type = "dummy"
                    dummy_check_node.dep_check_enable = True
                    dummy_check_node.dep_check_list = [split_core]
                    dummy_check_node.dep_set_enable = False
                    dummy_check_node.dep_set_list = []
                    dummy_check_node.dep_set_cluster_id = 0
                    dummy_check_node.dep_set_chiplet_id = 0
                    dummy_check_node.remote_dep_set_all = False
                    self.bingo_insert_node_between(pred, cur_node, dummy_check_node)

    def bingo_transform_add_core_sequencing_edges(self) -> int:
        """Add edges between consecutive tasks on the same core.

        Ensures deterministic execution order for tasks sharing a core,
        even when no explicit data dependency exists between them.
        Without these edges, the HW scheduler could dispatch same-core
        tasks in any topological order, leading to non-deterministic
        behavior and harder-to-debug timing.

        Algorithm:
          1. Topologically sort all nodes (respects existing dependencies).
          2. Group by (chiplet_id, cluster_id, core_id).
          3. Within each group, add an edge from node[i] to node[i+1]
             if no path already connects them (avoids redundant edges).

        Must be called AFTER entry/exit/conditional/dummy transforms
        (which insert infrastructure nodes on specific cores) and
        BEFORE dep info assignment.

        Returns:
            Number of sequencing edges added.
        """
        from collections import defaultdict

        topo_order = list(nx.topological_sort(self))

        # Group nodes by their (chiplet, cluster, core) assignment
        core_groups: dict[tuple, list[BingoNode]] = defaultdict(list)
        for node in topo_order:
            key = (node.assigned_chiplet_id, node.assigned_cluster_id, node.assigned_core_id)
            core_groups[key].append(node)

        edges_added = 0
        for (chip, cl, core), nodes in core_groups.items():
            # nodes are already in topological order
            for i in range(len(nodes) - 1):
                prev_node = nodes[i]
                next_node = nodes[i + 1]
                # Skip if an edge (direct or transitive path) already exists
                if not self.has_edge(prev_node, next_node) and not nx.has_path(self, prev_node, next_node):
                    self.add_edge(prev_node, next_node)
                    edges_added += 1

        if edges_added > 0:
            print(f"Core sequencing: added {edges_added} edges across "
                  f"{len(core_groups)} core groups")
        return edges_added

    def bingo_stream_order(self, chiplet_id: int | None = None) -> list:
        """The ONE per-core order the manager will actually see, used by everything.

        The manager fetches the descriptor list in order and demuxes each entry into its
        assigned core's FIFO waiting queue, so this list IS the per-core execution order.
        Two things must agree on it:

          * the dep-tag allocator, whose min chain-cover decides which edges may SHARE a
            tag from a happens-before order that includes same-core sequencing;
          * this emitter.

        They are not independent. Emitting an order the allocator did not assume can leave
        two simultaneously-live edges holding one tag, and the run deadlocks. The converse
        holds as well: strip the tags and even the plain topological order deadlocks. The
        tags are what make a particular order safe, so the order and the tags have to be
        derived from the same sequence -- which is why this is computed once, here.

        The order is a PRIORITY topological sort: always a valid topological order, but
        among the currently-ready nodes it prefers the one anchored earliest, so a dummy
        lands next to the real task it serves. That placement matters because a dummy
        occupies a slot in the CONSUMER's waiting queue: a plain topological sort can put
        one belonging to a later task ahead of an earlier one, and the FIFO then makes the
        earlier task inherit a wait it has no dependency on.
        """
        if getattr(self, "_stream_order_cache", None) is not None:
            seq = self._stream_order_cache
            return ([n for n in seq if n.assigned_chiplet_id == chiplet_id]
                    if chiplet_id is not None else seq)

        import heapq
        topo_nodes = list(nx.topological_sort(self))
        pos = {n: i for i, n in enumerate(topo_nodes)}

        def _anchor(node):
            seen, cur, side = set(), node, 1
            while cur.node_type == "dummy" and cur.node_id not in seen:
                seen.add(cur.node_id)
                if cur.dep_check_enable:
                    nxt, side = list(self.successors(cur)), 0    # a check gates its consumer
                elif cur.dep_set_enable:
                    nxt, side = list(self.predecessors(cur)), 2  # a set follows its producer
                else:
                    break
                if not nxt:
                    break
                cur = min(nxt, key=lambda x: pos[x])
            return pos.get(cur, pos[node]), side

        def _key(node):
            if node.node_type == "dummy":
                a, side = _anchor(node)
                return (a, side, pos[node])
            return (pos[node], 1, 0)

        indeg = {n: self.in_degree(n) for n in self.nodes()}
        ready = [(_key(n), i, n) for i, n in enumerate(topo_nodes) if indeg[n] == 0]
        heapq.heapify(ready)
        seq, tie = [], len(topo_nodes)
        while ready:
            _, _, n = heapq.heappop(ready)
            seq.append(n)
            for succ in self.successors(n):
                indeg[succ] -= 1
                if indeg[succ] == 0:
                    heapq.heappush(ready, (_key(succ), tie, succ)); tie += 1
        assert len(seq) == len(topo_nodes), "priority topological sort dropped nodes"
        self._stream_order_cache = seq
        return ([n for n in seq if n.assigned_chiplet_id == chiplet_id]
                if chiplet_id is not None else seq)

    def bingo_assign_normal_node_dep_check_info(self) -> None:
        """Assign the dep check info for normal and gating nodes."""
        # Iterate over all nodes in the graph
        for cur_node in self.node_list:
            if cur_node.node_type in ("normal", "gating"):
                # Find predecessors
                # And not dummy check
                preds = [
                    pred for pred in self.predecessors(cur_node)
                    if not (pred.node_type == "dummy" and pred.dep_check_enable)
                ]
                # If there are local predecessors, assign dep_check info
                if preds:
                    cur_node.dep_check_enable = True
                    cur_node.dep_check_list = [pred.assigned_core_id for pred in preds]
                    # Sanity check if there are multiple same core_id
                    if len(cur_node.dep_check_list) != len(set(cur_node.dep_check_list)):
                        print(f"Warning: Multiple local predecessors with the same core_id for node {cur_node.node_name}. This is not expected, go back to DFG transformation stage!")
                    print(f"Assigned dep_check_info for node {cur_node.node_name}: "
                          f"dep_check_enable=True, dep_check_list={cur_node.dep_check_list}")
                else:
                    # If no local predecessors, disable dep_check
                    cur_node.dep_check_enable = False
                    cur_node.dep_check_list = []
                    print(f"No local predecessors for node {cur_node.node_name}. "
                          f"dep_check_enable=False")

    def bingo_assign_normal_node_dep_set_info(self) -> None:
        """Assign the dep set info for normal and gating nodes."""
        # Iterate over all nodes in the graph
        for cur_node in self.node_list:
           if cur_node.node_type in ("normal", "gating"):
                # Find succs
                # And not dummy set
                succs = [
                    succ for succ in self.successors(cur_node)
                    if not (succ.node_type == "dummy" and succ.dep_set_enable)
                ]
                if len(succs) > 1 and self.enable_multi_row_set:
                    # (A) one multi-row set op. The dummy-set pass already split
                    # every OTHER target (chiplet, cluster) off, so what is left
                    # must share one -- assert it rather than silently emitting a
                    # set aimed at the wrong cluster.
                    targets = {(sc.assigned_chiplet_id, sc.assigned_cluster_id)
                               for sc in succs}
                    assert len(targets) == 1, (
                        f"multi-row dep_set for {cur_node.node_name} spans "
                        f"{targets}; the dummy-set pass should have split these")
                    rows = [(sc.assigned_cluster_id, sc.assigned_core_id)
                            for sc in succs]
                    assert len(set(rows)) == len(rows), (
                        f"multi-row dep_set for {cur_node.node_name} targets the "
                        f"same row twice ({rows}) -- one presence bit cannot "
                        f"release two consumers")
                    chip, cl = targets.pop()
                    cur_node.dep_set_enable = True
                    cur_node.dep_set_list = sorted(
                        {sc.assigned_core_id for sc in succs})
                    cur_node.remote_dep_set_all = False
                    cur_node.dep_set_chiplet_id = chip
                    cur_node.dep_set_cluster_id = cl
                elif len(succs)>1:
                    print(f"Warning: More than one local successor for node {cur_node.node_name}. This is not expected, go back to DFG transformation stage!")
                elif len(succs)==1:
                    cur_node.dep_set_enable = True
                    cur_node.dep_set_list = [succ.assigned_core_id for succ in succs]
                    cur_node.remote_dep_set_all = False
                    cur_node.dep_set_chiplet_id = succs[0].assigned_chiplet_id
                    cur_node.dep_set_cluster_id = succs[0].assigned_cluster_id
                else:
                    cur_node.dep_set_enable = False
                    cur_node.dep_set_list = []
                    cur_node.remote_dep_set_all = False
                    cur_node.dep_set_cluster_id = 0
                    cur_node.dep_set_chiplet_id = 0

    def bingo_transform_dfg_allocate_dep_tags(self, tag_width: int | None = None) -> None:
        """Assign per-edge identity tags so a consumer drains only ITS
        producer's set, never a stray that happens to share the same
        dep-matrix cell.

        Must run LAST -- after the dummy-set / dummy-check passes and the
        dep-info assignment -- when every set/check operation is final. By then
        each dependency is a single DIRECT edge ``set_node -> check_node`` (the
        dummy passes split every fork/multi-producer into single-edge ops), so
        one ``dep_set_tag`` and one ``dep_check_tag`` per node suffice.

        Physical cell = ``(consumer_chiplet, consumer_cluster, R, C)`` with
        ``R = consumer core`` and ``C = producer core`` (the bare-core column, so
        cross-cluster / cross-chiplet producers fold onto the same cell -- and the
        tag is exactly what keeps them apart). Within a cell, two edges may share
        a tag iff a DFG happens-before path links one edge's CONSUMER to the
        other's PRODUCER (``has_path(consumerA, producerB)``): then B's set can
        only fire after A has dispatched and freed the tag, regardless of work
        delays. Tags are assigned by greedy coloring that exploits this reuse.

        ``tag_width`` is the fixed HW knob (``DepTagWidth``): a cell may hold at
        most ``2**tag_width`` concurrently-live edges. If coloring needs more we
        raise rather than silently reintroduce the aliasing bug -- the workload
        must reduce a cell's concurrency (co-locate / serialize the offending
        producers in placement) or ``DepTagWidth`` must be widened.
        """
        # Default to the DFG's configured DepTagWidth rather than a literal: the
        # descriptor reserves exactly that many bits per tag, so a hardcoded
        # default here is a second, silently disagreeing source of truth.
        if tag_width is None:
            tag_width = self.dep_tag_width
        max_tags = 1 << tag_width
        # MUST be the same order the emitter uses. Allocating tags against
        # nx.topological_sort while the emitters walked a DIFFERENT per-core order
        # (_core_balanced_topological_sort) is how two simultaneously-live edges
        # end up sharing one tag -- the run then deadlocks with no visible tag
        # mismatch to catch it. One order, derived once. See bingo_stream_order.
        topo = self.bingo_stream_order()
        pos = {n: i for i, n in enumerate(topo)}

        # 1. Collect dep-matrix set/check edges, grouped by physical cell.
        cells: dict = {}                      # (chip, cl, R, C) -> [(set_node, check_node), ...]
        pairs: list = []                      # (set_node, check_node, cell)
        for u, v in self.edges():
            if not (u.dep_set_enable and v.dep_check_enable):
                continue
            C, R = u.assigned_core_id, v.assigned_core_id
            if C not in v.dep_check_list or R not in u.dep_set_list:
                continue                      # u sets / v checks, but not THIS pair
            cell = (v.assigned_chiplet_id, v.assigned_cluster_id, R, C)
            cells.setdefault(cell, []).append((u, v))
            pairs.append((u, v, cell))

        # TAG GROUPS. A descriptor carries ONE dep_set_tag and ONE dep_check_tag,
        # and every set->check edge requires u.dep_set_tag == v.dep_check_tag. So
        # the tag is a property of the NODE, and any set/check ops linked by an
        # edge must agree: a "tag group" is a connected component of the
        # set-node <-> check-node bipartite graph. Today almost every group is a
        # single edge touching a single cell. A broadcast dep_set, or (once the
        # descriptor carries a mask) a multi-column join / multi-row fan-out, is
        # a group spanning several cells that must hold ONE tag in all of them.
        bip = nx.Graph()
        for su, cv, _cell in pairs:
            bip.add_edge(("S", su), ("C", cv))
        gid = {}
        n_groups = 0
        for i, comp in enumerate(nx.connected_components(bip)):
            for key in comp:
                gid[key] = i
            n_groups = i + 1

        setters: dict = {}
        drainers: dict = {}
        cells_of: dict = {}
        edges_of: dict = {}
        for su, cv, cell in pairs:
            gi = gid[("S", su)]
            setters.setdefault(gi, set()).add(su)
            drainers.setdefault(gi, set()).add(cv)
            cells_of.setdefault(gi, set()).add(cell)
            edges_of.setdefault(gi, []).append((su, cv))

        # Same-core HOL reachability: at runtime each core dispatches its tasks in
        # topological (= push) order, so a same-core node that comes later is
        # effectively reachable from an earlier one. Add those consecutive same-core
        # edges to a SCRATCH graph used only for tag-reuse reachability (no real
        # edges, dep info unchanged). This collapses same-core (diagonal R==C) cells
        # -- which are serialized by the core queue -- to a chain, so they need few
        # tags instead of one per edge.
        hb = nx.DiGraph()
        hb.add_nodes_from(self.nodes())
        hb.add_edges_from(self.edges())
        by_core: dict = {}
        for nd in topo:
            by_core.setdefault((nd.assigned_chiplet_id, nd.assigned_cluster_id,
                                nd.assigned_core_id), []).append(nd)
        for seq in by_core.values():
            for i in range(len(seq) - 1):
                hb.add_edge(seq[i], seq[i + 1])

        _desc: dict = {}

        def _descendants(n):
            if n not in _desc:
                _desc[n] = nx.descendants(hb, n)
            return _desc[n]

        def _precedes(a, b):
            """Group a may hand its tag on to b: every drain of a happens-before
            every set of b. They may meet at one node (a's consumer IS b's
            producer -- a node dispatches/drains before it completes/sets)."""
            for cv in drainers[a]:
                for su in setters[b]:
                    if cv is not su and su not in _descendants(cv):
                        return False
            return True

        # INVARIANT: a tag group holds ONE tag, and a cell holds ONE presence
        # bit per tag. So two edges of the same group may land in the same cell
        # only if they are ORDERED -- otherwise the first consumer to check
        # drains the single bit and the second starves forever, silently.
        # Merging ops (multi-row set / multi-column check) links groups
        # transitively through shared producers, and a big enough component will
        # eventually fold two concurrent edges onto one cell. Catch it here: a
        # compile error naming the two edges beats a hang in silicon.
        for gi in range(n_groups):
            per_cell: dict = {}
            for (su, cv) in edges_of[gi]:
                cell = (cv.assigned_chiplet_id, cv.assigned_cluster_id,
                        cv.assigned_core_id, su.assigned_core_id)
                per_cell.setdefault(cell, []).append((su, cv))
            for cell, el in per_cell.items():
                for a in range(len(el)):
                    for b in range(a + 1, len(el)):
                        (sa, ca), (sb, cb) = el[a], el[b]
                        fwd = (sb is ca) or (sb in _descendants(ca))
                        bwd = (sa is cb) or (sa in _descendants(cb))
                        if not fwd and not bwd:
                            raise ValueError(
                                "dep-tag allocation: tag group would put TWO "
                                f"concurrently-live edges on cell {cell}, which "
                                "is one presence bit -- the first consumer to "
                                "check would drain it and the second would hang."
                                f"\n  edge A: {sa.node_name} -> {ca.node_name}"
                                f"\n  edge B: {sb.node_name} -> {cb.node_name}"
                                "\n  cell = (chiplet, cluster, consumer core, "
                                "producer core)\n  These two ops must not be "
                                "merged into one descriptor; split them (that is "
                                "what enable_multi_row_set=False does).")

        # FAST PATH -- every group is one edge in one cell, which is what the
        # dummy passes guarantee today. Per cell the conflict graph is the
        # incomparability graph of a partial order, so by Dilworth the minimum
        # number of tags is the largest antichain, and a min chain cover
        # (bipartite matching) attains it EXACTLY. Keep using it: it is optimal,
        # and it is the path every existing graph takes, so nothing moves.
        single_edge = all(len(edges_of[g]) == 1 and len(cells_of[g]) == 1
                          for g in range(n_groups))
        if single_edge:
            for key, edges in cells.items():
                edges.sort(key=lambda e: (pos[e[0]], pos[e[1]]))
                n = len(edges)
                reach = [_descendants(cv) for (_su, cv) in edges]
                B = nx.Graph()
                for a in range(n):
                    B.add_node(("L", a)); B.add_node(("R", a))
                for a in range(n):
                    for b in range(n):
                        if a == b:
                            continue
                        if edges[b][0] is edges[a][1] or edges[b][0] in reach[a]:
                            B.add_edge(("L", a), ("R", b))
                match = (nx.algorithms.bipartite.hopcroft_karp_matching(
                             B, top_nodes=[("L", a) for a in range(n)])
                         if B.number_of_edges() else {})
                succ, has_pred = {}, set()
                for node, m in match.items():
                    if node[0] == "L":
                        succ[node[1]] = m[1]; has_pred.add(m[1])
                tag_of, n_chains = {}, 0
                for a in range(n):
                    if a in has_pred:
                        continue                       # not a chain head
                    cur = a
                    while True:
                        tag_of[cur] = n_chains
                        if cur in succ:
                            cur = succ[cur]
                        else:
                            break
                    n_chains += 1
                if n_chains > max_tags:
                    raise ValueError(
                        f"dep-tag allocation: cell {key} needs {n_chains} > {max_tags} "
                        f"concurrent tags (tag_width={tag_width}); reduce this cell's "
                        f"concurrency in placement or widen DepTagWidth.")
                for i, (su, cv) in enumerate(edges):
                    su.dep_set_tag = tag_of[i]
                    cv.dep_check_tag = tag_of[i]
            return

        # GENERAL PATH -- some group spans several edges or several cells (a
        # broadcast dep_set, or a multi-edge op). Tags are no longer independent
        # per cell: the group needs one tag free in EVERY cell it touches, so
        # this is a graph colouring. Conflict edges exist only between groups
        # that share a cell AND are incomparable, which is why two groups in
        # disjoint cells can still reuse the same tag.
        #
        # Merging edges into multi-edge ops tends to LOWER tag pressure rather
        # than raise it, because the merged edges share one tag instead of one
        # each. DSATUR is not provably optimal on this subgraph, so the capacity
        # check below stays.
        import itertools as _it
        groups_in_cell: dict = {}
        for gi, cs in cells_of.items():
            for cell in cs:
                groups_in_cell.setdefault(cell, []).append(gi)
        H = nx.Graph()
        H.add_nodes_from(range(n_groups))
        for cell, gs in groups_in_cell.items():
            for a, b in _it.combinations(gs, 2):
                if not _precedes(a, b) and not _precedes(b, a):
                    H.add_edge(a, b)
        colour = nx.coloring.greedy_color(H, strategy="DSATUR")
        n_tags = (max(colour.values()) + 1) if colour else 0
        if n_tags > max_tags:
            busiest = max(groups_in_cell.items(),
                          key=lambda kv: len(kv[1]))
            detail = "\n".join(
                f"    group {g}: " + ", ".join(
                    f"{su.node_name}->{cv.node_name}" for su, cv in edges_of[g][:3])
                + (f" (+{len(edges_of[g]) - 3} more)" if len(edges_of[g]) > 3 else "")
                for g in sorted(busiest[1])[:8])
            raise ValueError(
                f"dep-tag allocation: needs {n_tags} > {max_tags} tags "
                f"(tag_width={tag_width}).\n"
                f"  cell = (chiplet, cluster, consumer core, producer core)\n"
                f"  busiest cell {busiest[0]} holds {len(busiest[1])} groups:\n{detail}\n"
                f"  Fix by serializing those producers against each other (an edge "
                f"between them lets two groups share a tag), or widen DepTagWidth "
                f"-- the descriptor carries TWO tags, so each step up costs 2 bits.")
        for su, cv, _cell in pairs:
            t = colour[gid[("S", su)]]
            su.dep_set_tag = t
            cv.dep_check_tag = t

    # ----------------------------------------------------------------
    # DARTS Tier 1: Conditional Execution helpers
    # ----------------------------------------------------------------
    def bingo_annotate_conditional_subgraph(
        self,
        nodes: list,
        group_id: int,
        invert: bool = False,
    ) -> None:
        """Mark nodes as conditionally executable based on CERF group.

        When the CERF group is INACTIVE (default), these tasks are skipped.
        They still propagate dep_set signals but are never dispatched to a core.

        Args:
            nodes: List of BingoNode objects to annotate
            group_id: CERF group index (0-15)
            invert: If True, execute when group is INACTIVE (skip when active)
        """
        for node in nodes:
            node.cond_exec_en = True
            node.cond_exec_group_id = group_id
            node.cond_exec_invert = invert

    def bingo_add_gating_node(
        self,
        assigned_chiplet_id: int,
        assigned_cluster_id: int,
        assigned_core_id: int,
        node_name: str = "gating",
    ):
        """Create and add a gating task node.

        A gating task executes on a core (like a normal task) and on completion
        writes CERF entries to activate conditional execution groups.
        In the DFG, it has task_type='gating' (2'b10 in RTL).
        """
        node = BingoNode(
            assigned_chiplet_id=assigned_chiplet_id,
            assigned_cluster_id=assigned_cluster_id,
            assigned_core_id=assigned_core_id,
            node_name=node_name,
        )
        node.node_type = "gating"
        self.bingo_add_node(node)
        return node

    def bingo_compile_conditional_regions(self) -> dict:
        """Compile conditional edges into CERF group assignments.

        Also validates that all nodes have valid core assignments
        (catches missing ``bingo_auto_assign()`` calls).

        Scans every edge for the ``cond`` attribute set by
        ``bingo_add_edge(..., cond=True)``.  For each gating node (a node
        with at least one outgoing conditional edge):

        1. Collect the set of conditional targets.
        2. Build an undirected subgraph of *unconditional* edges among those
           targets and find connected components — targets connected by
           unconditional edges share one CERF group.
        3. Assign one CERF group per component and annotate the target nodes.
        4. Promote the gating node to ``node_type="gating"`` and record its
           ``cerf_write_groups``.

        Must be called **before** the dummy-node transforms.

        Returns:
            dict mapping each conditionally-gated BingoNode to its CERF
            group id.  Also stored in ``self._node_to_cerf_group``.
        """
        # -- Validate core assignments ----------------------------------------
        unassigned = [n for n in self.node_list if n.assigned_core_id < 0]
        if unassigned:
            names = ", ".join(n.node_name for n in unassigned[:5])
            suffix = f" (and {len(unassigned)-5} more)" if len(unassigned) > 5 else ""
            raise ValueError(
                f"{len(unassigned)} node(s) have no core assignment: "
                f"{names}{suffix}. "
                f"Call bingo_auto_assign() before compile, or provide "
                f"explicit (chiplet, cluster, core) in BingoNode()."
            )

        # -- Step 1: identify gating nodes and their conditional targets ------
        gating_to_targets: dict[BingoNode, set[BingoNode]] = {}
        for u, v, data in self.edges(data=True):
            if data.get("cond", False):
                gating_to_targets.setdefault(u, set()).add(v)

        if not gating_to_targets:
            self._node_to_cerf_group = {}
            return {}

        # -- WF1: Acyclicity (only checked when conditional edges exist) ------
        if not nx.is_directed_acyclic_graph(self):
            raise ValueError(
                "Conditional DFG is not a DAG — it contains a cycle. "
                "Well-formedness condition WF1 violated."
            )

        # -- WF2: validate single-gating-source per target --------------------
        target_to_gating: dict[BingoNode, BingoNode] = {}
        for gating_node, targets in gating_to_targets.items():
            for t in targets:
                if t in target_to_gating:
                    raise ValueError(
                        f"Node '{t.node_name}' is conditionally gated by both "
                        f"'{target_to_gating[t].node_name}' and "
                        f"'{gating_node.node_name}'.  Hardware supports only "
                        f"one CERF group per task (WF2 violated)."
                    )
                target_to_gating[t] = gating_node

        # -- WF5: gating precedence (each gating node is ancestor of targets) -
        for gating_node, targets in gating_to_targets.items():
            for t in targets:
                if not nx.has_path(self, gating_node, t):
                    raise ValueError(
                        f"Gating node '{gating_node.node_name}' is not an "
                        f"ancestor of conditional target '{t.node_name}'. "
                        f"Well-formedness condition WF5 violated."
                    )

        # -- Step 3: per gating node — connected-component grouping -----------
        #
        # Within one gating node, targets connected by unconditional edges must
        # share a group (skipping one without the other would starve inputs);
        # the connected components of the unconditional-edge subgraph are the
        # minimal such groups (see 05_formal_ir.md Proposition 1).
        for gating_node in gating_to_targets:
            gating_node.node_type = "gating"

        region_components: dict[BingoNode, list] = {}
        for gating_node, targets in gating_to_targets.items():
            unc = nx.Graph()
            unc.add_nodes_from(targets)
            for t in targets:
                for _, v, d in self.out_edges(t, data=True):
                    if v in targets and not d.get("cond", False):
                        unc.add_edge(t, v)
                for u, _, d in self.in_edges(t, data=True):
                    if u in targets and not d.get("cond", False):
                        unc.add_edge(u, t)
            # Sort components deterministically by lowest node_id so that
            # expert_i always gets the same CERF group across reused layers.
            region_components[gating_node] = sorted(
                nx.connected_components(unc),
                key=lambda c: min(n.node_id for n in c),
            )

        # Naive baseline for the compiler ablation (M-G): the group count a
        # non-reuse-aware allocator would need -- one fresh group per
        # component, no cross-region sharing at all. Computed BEFORE the
        # reuse pass below so it reflects the true "no reuse" cost, not a
        # side effect of the chain-cover bookkeeping.
        naive_groups_by_chiplet: dict[int, int] = {}
        for gating_node, components in region_components.items():
            cid = gating_node.assigned_chiplet_id
            naive_groups_by_chiplet[cid] = naive_groups_by_chiplet.get(cid, 0) + len(components)

        # -- Step 4: cross-region CERF-group-pool reuse via minimum chain cover
        #
        # Two gating regions can safely reuse the same CERF-group numbering iff
        # they can never be simultaneously live. Region a "happens-before"
        # region b iff EVERY target of a has a DFG path to b's gating node —
        # i.e. a's guarded targets have all resolved (dispatched or CERF-skipped)
        # before b's gate can fire. This is exactly the same happens-before
        # argument used for the dep-matrix tag allocator
        # (bingo_transform_dfg_allocate_dep_tags): a strict partial order over
        # the gating regions (transitive because each gating node is, by WF5, an
        # ancestor of all its own targets — chain two such precedences through
        # that ancestor edge and transitivity of DAG reachability gives the
        # third; acyclic because a 2-cycle in the order would require a directed
        # cycle in the DFG). By Dilworth's theorem the minimum number of
        # CERF-group pools needed equals the size of the largest antichain
        # (the max number of simultaneously-live regions) — found here via
        # minimum chain-cover through bipartite matching, the same construction
        # as the tag allocator. This generalizes the old "all gating nodes form
        # one global chain, or no reuse at all" rule: independent chains reuse
        # within themselves even when the whole graph isn't one total order.
        #
        # CERF is instantiated ONCE PER CHIPLET (bingo_hw_manager_cond_exec_
        # controller lives inside bingo_hw_manager_top), so group N on chiplet
        # 0 and group N on chiplet 1 are different physical registers. The
        # min-chain-cover -- and the group counter -- must therefore be scoped
        # PER CHIPLET: two regions on different chiplets never need to be
        # temporally ordered at all, they simply never contend for the same
        # register. Pooling them into one global 32-wide counter would waste
        # budget across chiplet boundaries for no reason.
        node_to_group: dict[BingoNode, int] = {}
        topo_pos = {node: i for i, node in enumerate(nx.topological_sort(self))}

        def region_precedes(a: BingoNode, b: BingoNode) -> bool:
            return all(nx.has_path(self, t, b) for t in gating_to_targets[a])

        gating_by_chiplet: dict[int, list[BingoNode]] = {}
        for g in gating_to_targets:
            gating_by_chiplet.setdefault(g.assigned_chiplet_id, []).append(g)

        n_chains = 0
        actual_groups_by_chiplet: dict[int, int] = {}
        for chiplet_id, chiplet_gating_nodes in gating_by_chiplet.items():
            gating_ordered = sorted(chiplet_gating_nodes, key=lambda n: topo_pos[n])
            n = len(gating_ordered)

            B = nx.Graph()
            for i in range(n):
                B.add_node(("L", i)); B.add_node(("R", i))
            for i in range(n):
                for j in range(n):
                    if i != j and region_precedes(gating_ordered[i], gating_ordered[j]):
                        B.add_edge(("L", i), ("R", j))
            match = (nx.algorithms.bipartite.hopcroft_karp_matching(
                         B, top_nodes=[("L", i) for i in range(n)])
                     if B.number_of_edges() else {})
            succ, has_pred = {}, set()
            for node, m in match.items():
                if node[0] == "L":
                    succ[node[1]] = m[1]; has_pred.add(m[1])

            next_group = 0  # fresh 32-wide counter for THIS chiplet's CERF
            for i in range(n):
                if i in has_pred:
                    continue  # not a chain head
                n_chains += 1
                pool_start = next_group
                chain_peak = pool_start
                cur = i
                while True:
                    gating_node = gating_ordered[cur]
                    next_group = pool_start  # reuse: reset to this chain's pool
                    group_ids = []
                    for component in region_components[gating_node]:
                        gid = next_group
                        next_group += 1
                        if gid >= 32:
                            raise ValueError(
                                f"CERF group overflow on chiplet {chiplet_id}: gating region "
                                f"'{gating_node.node_name}' needs group {gid} but max is 32 "
                                f"(WF4 violated). This region's peak concurrent target count "
                                f"exceeds the 32-group budget on this chiplet even with "
                                f"cross-region reuse. Reduce this region's fan-out, split it "
                                f"with a barrier task, or co-locate/serialize with another chain."
                            )
                        for node in component:
                            node.cond_exec_en = True
                            node.cond_exec_group_id = gid
                            node.cond_exec_invert = False
                            node_to_group[node] = gid
                        group_ids.append(gid)
                    gating_node.cerf_write_groups = sorted(set(
                        gating_node.cerf_write_groups + group_ids
                    ))
                    chain_peak = max(chain_peak, next_group)
                    if cur in succ:
                        cur = succ[cur]
                    else:
                        break
                # Next independent chain (on this chiplet) starts after this
                # chain's PEAK width, not wherever the last region in the chain
                # happened to land -- chains can have regions of unequal width,
                # and the pool must be sized to the widest one actually used.
                next_group = chain_peak
            actual_groups_by_chiplet[chiplet_id] = next_group

        self._node_to_cerf_group = node_to_group
        self._n_cerf_chains = n_chains  # exposed for the compiler ablation (M-G)
        # Compiler ablation (M-G): actual (reuse-aware) vs. naive (no-reuse)
        # CERF group count, per chiplet and total. The gap between them is the
        # reuse pass's real, measured saving -- not a theoretical claim.
        self._cerf_groups_actual = dict(actual_groups_by_chiplet)
        self._cerf_groups_naive = dict(naive_groups_by_chiplet)
        # Snapshot gating_node -> its own conditional targets NOW. The later
        # dummy-set-insertion pass rewires cond=True edges away from a gating
        # node the moment it has more than one successor (any gating node with
        # both a conditional target and an unconditional path -- e.g. an MoD
        # router's residual merge edge): bingo_insert_node_between splices a
        # dummy in as router -> dummy (uncond) -> block (cond=True, inherited),
        # so a post-transform re-scan of the graph for cond=True edges would
        # find the DUMMY as the apparent gating source, not this node. Runtime
        # activation resolution (e.g. dfg_to_task_descriptors's active_nodes
        # handling) must key off THIS mapping, not re-derive it from edges
        # after the transforms have run.
        self._gating_to_targets = {g: set(t) for g, t in gating_to_targets.items()}
        return node_to_group

    def bingo_define_conditional_region(
        self,
        gating_node: BingoNode,
        guarded_nodes: list,
        group_per_node: bool = False,
        invert: bool = False,
    ) -> list[int]:
        """Define a conditional execution region controlled by a gating task.

        The gating_node is marked as type 'gating' (task_type=2 in RTL).
        When it completes on a core, the hardware writes the assigned CERF
        groups, causing guarded_nodes to either execute or be skipped.

        Args:
            gating_node:    The node whose completion activates the CERF groups.
            guarded_nodes:  Nodes whose execution depends on the CERF state.
            group_per_node: If True, each guarded node gets its own CERF group
                            (MoE: each expert independently gated).
                            If False, all guarded nodes share one CERF group
                            (early exit: entire stage gated together).
            invert:         If True, guarded nodes execute when group is INACTIVE.

        Returns:
            List of assigned CERF group IDs. Length equals len(guarded_nodes)
            when group_per_node=True, or [single_id] when False.
        """
        gating_node.node_type = "gating"

        if group_per_node:
            group_ids = []
            for node in guarded_nodes:
                gid = self._next_cerf_group
                self._next_cerf_group += 1
                if gid >= 32:
                    raise ValueError(f"CERF group overflow: {gid} >= 32 (max 32 groups)")
                node.cond_exec_en = True
                node.cond_exec_group_id = gid
                node.cond_exec_invert = invert
                group_ids.append(gid)
        else:
            gid = self._next_cerf_group
            self._next_cerf_group += 1
            if gid >= 32:
                raise ValueError(f"CERF group overflow: {gid} >= 32 (max 32 groups)")
            for node in guarded_nodes:
                node.cond_exec_en = True
                node.cond_exec_group_id = gid
                node.cond_exec_invert = invert
            group_ids = [gid]

        gating_node.cerf_write_groups = sorted(set(
            gating_node.cerf_write_groups + group_ids
        ))
        return group_ids

    # ----------------------------------------------------------------
    # Conditional-Aware Auto-Scheduler
    # ----------------------------------------------------------------
    def bingo_auto_assign(
        self,
        n_chiplets: int = 1,
        n_clusters: int = 2,
        n_cores: int = 3,
        work_delays: dict | None = None,
        activation_weights: dict | None = None,
    ) -> None:
        """Automatically assign tasks to (chiplet, cluster, core).

        Uses a conditional-aware HEFT-style scheduler that distinguishes
        between tasks that always execute and tasks that may be skipped.
        The key optimisation: for **slot selection**, conditional tasks
        use *expected* cost (``p * delay``), favouring cores that already
        carry mutually-exclusive conditional tasks.  For **slot EFT
        tracking**, *full* cost is charged (pessimistic) to prevent
        over-packing.

        Must be called **before** ``bingo_compile_conditional_regions()``.

        Args:
            n_chiplets, n_clusters, n_cores: Hardware dimensions.
            work_delays: Optional ``{node_name: cycles}`` dict.
            activation_weights: Optional ``{BingoNode: float}`` with
                per-node activation probability.  If *None*, ``k/N``
                is derived from the conditional edge fan-out.
        """
        work_delays = work_delays or {}
        default_delay = 100

        def _delay(n):
            return work_delays.get(n.node_name, default_delay)

        # -- Derive activation probabilities --------------------------
        act_w: dict = {}
        if activation_weights is not None:
            act_w = dict(activation_weights)
        else:
            gating_to_targets: dict = {}
            for u, v, d in self.edges(data=True):
                if d.get("cond", False):
                    gating_to_targets.setdefault(u, set()).add(v)
            for _, targets in gating_to_targets.items():
                k = min(2, len(targets))
                p = k / max(len(targets), 1)
                for t in targets:
                    act_w[t] = p
        for node in self.node_list:
            act_w.setdefault(node, 1.0)

        # -- Slot bookkeeping -----------------------------------------
        slots: list[tuple[int, int, int]] = []
        for chip in range(n_chiplets):
            for cl in range(n_clusters):
                for co in range(n_cores):
                    slots.append((chip, cl, co))
        n_slots = len(slots)

        slot_eft = [0.0] * n_slots       # pessimistic (full-cost) EFT
        slot_exp_eft = [0.0] * n_slots    # expected (conditional-discount) EFT
        assignment: dict = {}
        H2H_LATENCY = 10

        # -- Schedule in topological order ----------------------------
        for node in nx.topological_sort(self):
            delay = _delay(node)
            p = act_w[node]               # activation probability

            best_slot = 0
            best_score = float("inf")

            for s_idx in range(n_slots):
                chip = slots[s_idx][0]

                # Earliest this node can start: max of slot availability
                # and all predecessors' finish times (+H2H if cross-chip).
                pred_ready = 0.0
                for pred in self.predecessors(node):
                    if pred in assignment:
                        ps = assignment[pred]
                        pf = slot_eft[ps]
                        if slots[ps][0] != chip:
                            pf += H2H_LATENCY
                        pred_ready = max(pred_ready, pf)

                # For slot selection: use EXPECTED EFT.
                # Conditional tasks discount their own delay by p.
                avail = slot_exp_eft[s_idx]
                start = max(avail, pred_ready)
                score = start + p * delay

                # Tie-break: among equal scores, prefer the least-loaded
                # slot (lowest pessimistic EFT) → spreads tasks across cores.
                if (score < best_score
                        or (score == best_score
                            and slot_eft[s_idx] < slot_eft[best_slot])):
                    best_score = score
                    best_slot = s_idx

            # Assign to best slot.
            assignment[node] = best_slot

            # Compute actual start (using pessimistic slot EFT).
            pred_ready = 0.0
            for pred in self.predecessors(node):
                if pred in assignment:
                    ps = assignment[pred]
                    pf = slot_eft[ps]
                    if slots[ps][0] != slots[best_slot][0]:
                        pf += H2H_LATENCY
                    pred_ready = max(pred_ready, pf)
            actual_start = max(slot_eft[best_slot], pred_ready)

            # Update pessimistic EFT: conditional-aware.
            # Hot tasks (p~1.0) charge full delay.  Cold tasks (p~0) charge
            # only a small skip-processing cost (pipeline overhead for
            # dep_set propagation), freeing the core for hot tasks.
            SKIP_FRACTION = 0.05  # skipped task ≈ 5% of full execution
            effective_delay = max(p, SKIP_FRACTION) * delay
            slot_eft[best_slot] = actual_start + effective_delay
            # Update expected EFT: discounted delay (guides future choices).
            exp_start = max(slot_exp_eft[best_slot], pred_ready)
            slot_exp_eft[best_slot] = exp_start + p * delay

            chip, cl, co = slots[best_slot]
            node.assigned_chiplet_id = chip
            node.assigned_cluster_id = cl
            node.assigned_core_id = co

    # ----------------------------------------------------------------
    # High-Level Model Primitives
    # ----------------------------------------------------------------
    def bingo_add_moe_layer(
        self,
        input_node: BingoNode,
        n_experts: int = 8,
        top_k: int = 2,
        layer_name: str = "moe",
    ):
        """Add a complete MoE layer to the DFG.

        Creates: ``input → router_compute → gating_op → experts → aggregator``

        The compiler automatically inserts a **gating_op** node between
        the router computation and the experts.  This cleanly decouples
        data flow (router computes logits) from control flow (gating_op
        writes CERF).  The user never writes ``cond=True``.

        Args:
            input_node: The predecessor node (e.g., attention output).
            n_experts: Number of expert FFNs.
            top_k: Number of experts activated per token.
            layer_name: Name prefix for generated nodes.

        Returns:
            An object with ``.router``, ``.gating_op``, ``.experts``,
            ``.aggregator`` attributes.

        Example::

            moe = dfg.bingo_add_moe_layer(attn, n_experts=8, top_k=2)
            dfg.bingo_add_edge(moe.aggregator, next_layer)
        """
        # Router compute: FFN + softmax + topk (pure data, task_type=normal)
        router = BingoNode(node_name=f"{layer_name}_router")
        self.bingo_add_node(router)
        self.bingo_add_edge(input_node, router)

        # Gating op: reads router output → writes CERF (task_type=gating)
        # Compiler-inserted — decouples computation from control.
        gating_op = BingoNode(node_name=f"{layer_name}_gate")
        self.bingo_add_node(gating_op)
        self.bingo_add_edge(router, gating_op)

        # Experts: conditionally activated by gating_op
        experts = []
        for i in range(n_experts):
            exp = BingoNode(node_name=f"{layer_name}_expert_{i}")
            self.bingo_add_node(exp)
            self.bingo_add_edge(gating_op, exp, cond=True)
            experts.append(exp)

        # Aggregator: weighted sum of active expert outputs
        aggregator = BingoNode(node_name=f"{layer_name}_agg")
        self.bingo_add_node(aggregator)
        for exp in experts:
            self.bingo_add_edge(exp, aggregator)

        class MoELayer:
            pass
        layer = MoELayer()
        layer.router = router
        layer.gating_op = gating_op
        layer.experts = experts
        layer.aggregator = aggregator
        layer.n_experts = n_experts
        layer.top_k = top_k
        return layer

    def bingo_add_early_exit_stage(
        self,
        input_node: BingoNode,
        prev_stage=None,
        stage_name: str = "stage",
    ):
        """Add one stage of an early-exit network.

        Creates: ``input → compute → gating_op``

        If ``prev_stage`` is provided, inserts conditional edges from
        the previous stage's gating_op to this stage's compute and
        gating_op — the previous classifier gates whether this stage
        executes.

        Returns:
            An object with ``.compute`` and ``.gating_op`` attributes.
        """
        compute = BingoNode(node_name=f"{stage_name}_compute")
        gating_op = BingoNode(node_name=f"{stage_name}_gate")
        self.bingo_add_node(compute)
        self.bingo_add_node(gating_op)
        self.bingo_add_edge(input_node, compute)
        self.bingo_add_edge(compute, gating_op)

        # Previous stage's gating_op controls whether this stage runs
        if prev_stage is not None:
            self.bingo_add_edge(prev_stage.gating_op, compute, cond=True)
            self.bingo_add_edge(prev_stage.gating_op, gating_op, cond=True)

        class Stage:
            pass
        s = Stage()
        s.compute = compute
        s.gating_op = gating_op
        return s

    def bingo_visualize_dfg(self, filename: str = "dfg_visualization.png", figsize: tuple = (10, 8)) -> None:
        """Visualize the DFG with different shapes for task types and colors for chiplets."""
        import matplotlib.pyplot as plt
        from matplotlib.lines import Line2D

        # Define shapes for different task types
        task_type_shapes = {
            "normal": "o",  # Circle
            "dummy_set": "s",   # Square
            "dummy_check": "v",  # Downward Triangle
        }

        # Define a color map for chiplets
        chiplet_colors = [
            "red", "blue", "green", "orange", "purple", "brown", "pink", "gray", "olive", "cyan"
        ]

        # Select a start node for BFS layout
        start_node = next(iter(self.nodes), None)  # Get the first node in the graph
        if start_node is None:
            raise ValueError("The graph is empty. Cannot visualize an empty graph.")

        # Create a BFS layout for the graph
        pos = nx.bfs_layout(self, start_node, align="horizontal")

        # Separate nodes by task type and chiplet
        node_shapes = {shape: [] for shape in task_type_shapes.values()}
        node_colors = {}

        for node in self.nodes:
            task_type = node.node_type  # Get the task type as a string
            if task_type == "dummy":
                if node.dep_set_enable:
                    task_type = "dummy_set"
                elif node.dep_check_enable:
                    task_type = "dummy_check"
            assigned_chiplet = node.assigned_chiplet_id

            # Get the shape for the task type
            shape = task_type_shapes.get(task_type, "o")  # Default to circle if task_type is unknown
            node_shapes[shape].append(node)

            # Get the color for the chiplet
            color = chiplet_colors[assigned_chiplet % len(chiplet_colors)]
            node_colors[node] = color

        # Set the figure size
        plt.figure(figsize=figsize)

        # Draw nodes with different shapes
        for shape, nodes in node_shapes.items():
            nx.draw_networkx_nodes(
                self, pos, nodelist=nodes,
                node_shape=shape,
                node_color=[node_colors[node] for node in nodes],
                node_size=500
            )

        # Draw edges
        nx.draw_networkx_edges(self, pos)

        # Draw labels
        labels = {}
        for node in self.nodes:
            cur_chiplet_id = node.assigned_chiplet_id
            cur_cluster_id = node.assigned_cluster_id
            cur_core_id = node.assigned_core_id
            cur_task_type = node.node_type
            if cur_task_type == "dummy":
                if node.dep_set_enable:
                    cur_task_type = "dummy_set"
                elif node.dep_check_enable:
                    cur_task_type = "dummy_check"
            labels[node] = f"Cluster{cur_cluster_id}Core{cur_core_id}\n{cur_task_type}\nChiplet: {cur_chiplet_id}\nID: {node.node_id}"
        nx.draw_networkx_labels(self, pos, labels=labels, font_size=8)

        # Create a legend for task types
        legend_elements = [
            Line2D([0], [0], marker=shape, color="w", label=task_type, markerfacecolor="black", markersize=10)
            for task_type, shape in task_type_shapes.items()
        ]
        plt.legend(handles=legend_elements, loc="best")

        # Save the visualization to a file
        plt.savefig(filename)
        plt.show()
        
    # ----------------------------------------------------------------
    # Task descriptor packing / unpacking
    # ----------------------------------------------------------------
    def bingo_task_desc_layout(self) -> list[tuple[str, int]]:
        """THE field table for this DFG's geometry, ``(name, width)`` LSB -> MSB.

        Same name and same shape as the HeMAiA copy's method so the two
        mini-compilers stay diffable; the widths themselves come from
        bingo_task_desc_fields() in bingo_node.py.

        The one deliberate exception to that name-for-name correspondence is
        bingo_task_desc_word_count() below -- see the note in its docstring.
        """
        return bingo_task_desc_fields(
            num_clusters_per_chiplet=self.num_clusters_per_chiplet,
            num_cores_per_cluster=self.num_cores_per_cluster,
            dep_tag_width=self.dep_tag_width,
        )

    def bingo_task_desc_offsets(self) -> list[tuple[str, int, int]]:
        """The field table resolved to ``(name, lsb, width)``.

        The one place shifts are computed; pack, unpack and any report of the
        layout all read it, so none of them can drift apart.
        """
        offsets = []
        shift = 0
        for name, width in self.bingo_task_desc_layout():
            offsets.append((name, shift, width))
            shift += width
        return offsets

    def bingo_task_desc_bits(self) -> int:
        """Bits the descriptor actually occupies, below the zero padding."""
        return sum(width for _, width in self.bingo_task_desc_layout())

    def bingo_task_desc_word_count(self) -> int:
        """Number of host-bus words (AXI-Lite beats) in one descriptor.

        NOT named bingo_task_desc_words(): the HeMAiA mini-compiler has a method
        of that name which takes a packed descriptor and returns the LIST of its
        words. Same name for a count and for a splitter is how a line copied
        between the two copies ends up meaning the other thing without failing,
        so this side carries the count under a name that says count.

        The width must be a whole number of beats. Rounding up instead would let
        SW emit an image that no elaborated design can consume, because the RTL
        refuses the same value outright; see the raise below.
        """
        if self.task_desc_width % BINGO_TASK_DESC_WORD_WIDTH:
            rounded = (
                (self.task_desc_width + BINGO_TASK_DESC_WORD_WIDTH - 1)
                // BINGO_TASK_DESC_WORD_WIDTH
            ) * BINGO_TASK_DESC_WORD_WIDTH
            raise ValueError(
                f"task_desc_width={self.task_desc_width} is not a multiple of the "
                f"{BINGO_TASK_DESC_WORD_WIDTH}-bit host beat, so a descriptor cannot be "
                f"fetched as whole beats. The RTL refuses exactly this at elaboration "
                f"(gen_task_desc_beat_check in bingo_hw_manager_top.sv: "
                f"TaskDescBusWidth % HostAxiLiteDataWidth != 0), so rounding up here would "
                f"only produce a task list no elaborated design accepts. Use "
                f"task_desc_width={rounded} (and the matching TaskDescBusWidth in the RTL)."
            )
        return self.task_desc_width // BINGO_TASK_DESC_WORD_WIDTH

    def bingo_task_desc_bytes(self) -> int:
        """Address stride of one descriptor in the task list, in bytes.

        Derived from the same container width as the words themselves, so a
        header comment can never advertise a stride the image under it does not
        use.
        """
        return self.bingo_task_desc_word_count() * (BINGO_TASK_DESC_WORD_WIDTH // 8)

    def bingo_pack_node(self, node: BingoNode) -> int:
        """Pack a node into a task descriptor of ``self.task_desc_width`` bits.

        The container width is a parameter, not the 64 bits that a descriptor
        happened to fit in while it was the same size as a host AXI-Lite beat.
        The RTL makes the same distinction (TaskDescBusWidth vs
        HostAxiLiteDataWidth), so the two sides now fail, or fit, together.
        """
        values = node.task_desc_field_values(self.num_cores_per_cluster)
        packed_val = 0
        for name, shift, width in self.bingo_task_desc_offsets():
            value = values[name]
            if not 0 <= value < (1 << width):
                raise ValueError(
                    f"Node '{node.node_name}': field '{name}' = {value} does not fit in "
                    f"{width} bits. Overflowing it would corrupt every field above it."
                )
            packed_val |= value << shift

        used = self.bingo_task_desc_bits()
        if used > self.task_desc_width:
            # Same condition the RTL checks (TaskDescWidth > TaskDescBusWidth makes
            # ReservedBitsForTaskDesc negative and elaboration fails), so report the
            # breakdown and name the knobs that absorb it.
            raise ValueError(
                f"Packed task descriptor needs {used} bits but the container is "
                f"{self.task_desc_width} (BINGO_TASK_DESC_WIDTH / TaskDescBusWidth).\n"
                + "".join(
                    f"  {name:<22s} lsb {shift:>4d}  width {width}\n"
                    for name, shift, width in self.bingo_task_desc_offsets()
                )
                + "Raise BINGO_TASK_DESC_WIDTH here and TaskDescBusWidth in the RTL "
                "together (it must stay a multiple of the 64-bit host beat), or lower "
                "DepTagWidth -- each step down frees 2 bits."
            )
        return packed_val

    def bingo_unpack_node(self, packed_val: int) -> dict:
        """Inverse of bingo_pack_node, off the same resolved layout."""
        fields = {}
        for name, shift, width in self.bingo_task_desc_offsets():
            fields[name] = (packed_val >> shift) & ((1 << width) - 1)
        return fields

    def bingo_pack_node_words(self, node: BingoNode) -> list[int]:
        """A packed descriptor split into host-bus words, LEAST-SIGNIFICANT FIRST.

        The fetch master reads beat 0 from the lower address into the low bits
        of the descriptor, so ascending address means ascending significance.
        Emitting the halves the other way round swaps every descriptor.
        """
        packed_val = self.bingo_pack_node(node)
        mask = (1 << BINGO_TASK_DESC_WORD_WIDTH) - 1
        return [
            (packed_val >> (i * BINGO_TASK_DESC_WORD_WIDTH)) & mask
            for i in range(self.bingo_task_desc_word_count())
        ]

    def bingo_emit_task_desc_sv(self) -> str:
        """Emit the SystemVerilog string for all nodes in the DFG."""
        sv_strings = []

        # Iterate over all nodes in the graph
        for node in self.node_list:
            # Call the emit_sv function of each node, with THIS DFG's geometry so
            # the emitted literals are as wide as the DUT's types.
            sv_strings.append(
                node.emit_sv(
                    num_cores_per_cluster=self.num_cores_per_cluster,
                    task_id_width=BINGO_TASK_ID_WIDTH,
                )
            )

        # Combine all the SystemVerilog strings with newlines
        return "\n\n".join(sv_strings)

    def _core_balanced_topological_sort(self, chiplet_id: int) -> list:
        """SUPERSEDED by bingo_stream_order -- kept only for comparison.

        Do NOT use this to emit a descriptor list. The dep-tag allocator derives
        its happens-before order from bingo_stream_order, and emitting a
        different per-core order than the one tags were allocated against can
        leave two simultaneously-live edges sharing a tag, which deadlocks with
        nothing visible to catch it. One order, derived once.

        Topological sort that interleaves tasks across cores.

        The standard topological sort may dump many tasks for the same core
        consecutively (e.g., a task + its dummy_set/check children). This
        overflows the per-core waiting queue (depth 8) in the RTL, causing
        the task_queue demux to stall and block tasks for other cores.

        This sort maintains topological validity while spreading tasks across
        cores round-robin: pick the ready task whose core was least recently
        used.
        """
        # Filter nodes for this chiplet
        chiplet_nodes = set(
            node for node in self.nodes
            if node.assigned_chiplet_id == chiplet_id
        )
        if not chiplet_nodes:
            return []

        # Compute in-degree within chiplet subgraph
        in_degree = {}
        for node in chiplet_nodes:
            in_degree[node] = 0
        for node in chiplet_nodes:
            for succ in self.successors(node):
                if succ in chiplet_nodes:
                    in_degree[succ] = in_degree.get(succ, 0) + 1

        # Ready set: nodes with in_degree == 0
        from collections import defaultdict
        ready_by_core = defaultdict(list)
        for node in chiplet_nodes:
            if in_degree[node] == 0:
                ready_by_core[node.assigned_core_id].append(node)

        result = []
        last_core = -1
        num_cores = max(n.assigned_core_id for n in chiplet_nodes) + 1

        while any(ready_by_core.values()):
            # Pick a core round-robin, preferring one different from last_core
            chosen_node = None
            for offset in range(1, num_cores + 1):
                try_core = (last_core + offset) % num_cores
                if ready_by_core[try_core]:
                    chosen_node = ready_by_core[try_core].pop(0)
                    break

            if chosen_node is None:
                # Fallback: pick any ready node
                for core_id in ready_by_core:
                    if ready_by_core[core_id]:
                        chosen_node = ready_by_core[core_id].pop(0)
                        break
                if chosen_node is None:
                    break

            result.append(chosen_node)
            last_core = chosen_node.assigned_core_id

            # Update in-degrees
            for succ in self.successors(chosen_node):
                if succ in chiplet_nodes:
                    in_degree[succ] -= 1
                    if in_degree[succ] == 0:
                        ready_by_core[succ.assigned_core_id].append(succ)

        return result

    def bingo_emit_push_task_sv(self) -> str:
        """Emit the SystemVerilog push sequences, one AXI-Lite write per descriptor.

        This stimulus drives the AXI-Lite SLAVE task queue (TASK_QUEUE_TYPE==0),
        which commits one FIFO entry per W beat and cannot reassemble a wider
        descriptor from several writes. So it is valid only while the container
        is exactly one host beat, which is what the harness elaborates
        (TaskDescBusWidth ( HOST_DW ) in test/tb_bingo_hw_manager_harness.svh).

        Splitting a wide descriptor into `name[63:0]` / `name[127:64]` writes
        here does not fail anywhere: it compiles, and it pushes TWO tasks per
        descriptor into a queue elaborated for one. Refuse instead -- a
        multi-beat descriptor is fetched from memory by the MASTER task queue
        (TASK_QUEUE_TYPE==1), i.e. by bingo_emit_task_list_hex().
        """
        num_words = self.bingo_task_desc_word_count()
        if num_words != 1:
            raise ValueError(
                f"bingo_emit_push_task_sv() targets the AXI-Lite slave task queue "
                f"(TASK_QUEUE_TYPE==0), which commits one descriptor per "
                f"{BINGO_TASK_DESC_WORD_WIDTH}-bit W beat, but this DFG's "
                f"task_desc_width={self.task_desc_width} needs {num_words} beats.\n"
                f"The RTL refuses the same combination at elaboration "
                f"(gen_task_desc_slave_width_check in bingo_hw_manager_top.sv: "
                f"TASK_QUEUE_TYPE==0 requires TaskDescBusWidth == HostAxiLiteDataWidth).\n"
                f"Either build the DFG with task_desc_width={BINGO_TASK_DESC_WORD_WIDTH} to match "
                f"a TB that elaborates TaskDescBusWidth ( HOST_DW ), or emit the task list with "
                f"bingo_emit_task_list_hex() for a TASK_QUEUE_TYPE==1 master queue."
            )
        sv_strings = []
        # Iterate over each chiplet
        for chiplet_id in range(MAX_NUM_CHIPLETS):
            chiplet_nodes = self.bingo_stream_order(chiplet_id)
            if not chiplet_nodes:
                continue  # Skip this chiplet if no nodes exist

            chiplet_sv = []
            chiplet_sv.append(f"  // Host pushes tasks for chiplet {chiplet_id}")
            chiplet_sv.append(f"  initial begin : chip{chiplet_id}_push_sequence")
            chiplet_sv.append(f"    automatic axi_pkg::resp_t resp_chip{chiplet_id};")
            chiplet_sv.append(f"    wait (rst_ni);")
            chiplet_sv.append(f"    @(posedge clk_i);")
            chiplet_sv.append(f"    task_queue_master[{chiplet_id}].reset();")
            chiplet_sv.append(f"    done_queue_master[{chiplet_id}].reset();")
            chiplet_sv.append("")
            # Generate the SystemVerilog push sequence for the sorted nodes: one
            # AXI-Lite write per descriptor, because that is the only shape the
            # slave task queue has. See the single-beat check above.
            for node in chiplet_nodes:
                chiplet_sv.append(f"      task_queue_master[{chiplet_id}].write(task_queue_base[{chiplet_id}], '0, {node.node_name}, '1, resp_chip{chiplet_id});")
                chiplet_sv.append("    #50;")

            chiplet_sv.append("  end")
            sv_strings.append("\n".join(chiplet_sv))

        # Combine all chiplet strings
        return "\n\n".join(sv_strings)

    def bingo_emit_task_list_hex(self, chiplet_id: int) -> str:
        """Emit one chiplet's task list as a $readmemh image of host-bus words.

        This is the memory the MASTER task queue (TASK_QUEUE_TYPE==1, the path
        HeMAiA uses) fetches from, so the file has bingo_task_desc_word_count()
        words per descriptor, least-significant word at the lower address, and a
        descriptor stride of bingo_task_desc_bytes().

        Both numbers in the header comment are derived from THIS DFG's container
        width, the same value the words below were packed from. A module-level
        constant here would have printed the default width's stride over an image
        packed at another one, and a reader trusting the header would place every
        descriptor after the first at the wrong address.
        """
        digits = BINGO_TASK_DESC_WORD_WIDTH // 4
        lines = [
            f"// chiplet {chiplet_id}: {self.bingo_task_desc_word_count()} x "
            f"{BINGO_TASK_DESC_WORD_WIDTH}-bit words per descriptor, LSW first, "
            f"stride {self.bingo_task_desc_bytes()} B"
        ]
        for node in self.bingo_stream_order(chiplet_id):
            lines.append(f"// task {node.node_id}: {node.node_name}")
            for word in self.bingo_pack_node_words(node):
                lines.append(f"{word:0{digits}x}")
        return "\n".join(lines)
