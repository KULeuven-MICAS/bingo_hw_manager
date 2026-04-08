# Fanchen Kong <fanchen.kong@kuleuven.be>

import random
from bingo_utils import DiGraphWrapper
from bingo_node import BingoNode
import networkx as nx
MAX_NUM_CHIPLETS = 8
class BingoDFG(DiGraphWrapper[BingoNode]):
    """Data Flow Graph (DFG) for Bingo."""

    def __init__(self) -> None:
        super().__init__()
        self.id = 0
        self._next_cerf_group = 0
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
                # We have a special situation that this node is a broadcast node to set all chiplets
                if len(set(remote_succ.assigned_chiplet_id for remote_succ in remote_succ_list)) == (MAX_NUM_CHIPLETS -1):
                    # All the remote successors must have the same core id
                    if len(set(remote_succ.assigned_core_id for remote_succ in remote_succ_list)) == 1:
                        print(f"Node {cur_node.node_name} is a broadcast node to set all chiplets.")
                        dummy_set_node = BingoNode(
                            assigned_chiplet_id=cur_node.assigned_chiplet_id,
                            assigned_cluster_id=cur_node.assigned_cluster_id,      # must be the same type of the cur_node to block the execution
                            assigned_core_id=cur_node.assigned_core_id,            # must be the same type of the cur_node to block the execution
                            node_name=f"Chiplet_Dep_set_Broadcast{cur_node.node_name}"
                        )
                        dummy_set_node.node_type = "dummy"
                        dummy_set_node.dep_set_enable = True
                        dummy_set_node.dep_set_list = [remote_succ_list[0].assigned_core_id]
                        dummy_set_node.dep_set_cluster_id = remote_succ_list[0].assigned_cluster_id
                        dummy_set_node.dep_set_chiplet_id = remote_succ_list[0].assigned_chiplet_id # should be fine since it is a broadcast type
                        dummy_set_node.dep_check_enable = False
                        dummy_set_node.dep_check_list = []
                        dummy_set_node.remote_dep_set_all = True
                        # Add the dummy set node to the graph
                        for remote_succ in remote_succ_list:
                            self.bingo_insert_node_between(cur_node, remote_succ, dummy_set_node)
                else:
                    # Now the normal case
                    for remote_succ in remote_succ_list:
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
            if len(local_succ_list)>1:
                # Now the local multiple successor case
                # We need local_successors-1 dummy set nodes
                print(f"Adding dummy set nodes for {cur_node.node_name} with local successors {[succ.node_name for succ in local_succ_list]}")
                for i in range(len(local_succ_list)-1):
                    dummy_set_node = BingoNode(
                        assigned_chiplet_id=cur_node.assigned_chiplet_id,
                        assigned_cluster_id=cur_node.assigned_cluster_id,      # must be the same type of the cur_node to block the execution
                        assigned_core_id=cur_node.assigned_core_id,            # must be the same type of the cur_node to block the execution
                        node_name=f"dummy_set_{cur_node.node_name}_{i}"
                    )
                    dummy_set_node.node_type = "dummy"
                    dummy_set_node.dep_set_enable = True
                    dummy_set_node.dep_set_list = [local_succ_list[i].assigned_core_id]
                    dummy_set_node.dep_set_cluster_id = local_succ_list[i].assigned_cluster_id
                    dummy_set_node.dep_set_chiplet_id = local_succ_list[i].assigned_chiplet_id
                    dummy_set_node.dep_check_enable = False
                    dummy_set_node.dep_check_list = []
                    dummy_set_node.remote_dep_set_all = False
                    # Add the dummy set node to the graph
                    self.bingo_insert_node_between(cur_node, local_succ_list[i], dummy_set_node)
                    
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

            if len(remaining_core_ids) >= 2:
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
                if len(succs)>1:
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
        # CERF group reuse: if all gating nodes are totally ordered
        # (each is an ancestor of the next), their conditional targets
        # execute at different times and can safely share group IDs.
        # The clear-before-set protocol in the gating task ensures that
        # stale group values from a previous layer are overwritten.
        node_to_group: dict[BingoNode, int] = {}

        gating_ordered = [
            n for n in nx.topological_sort(self) if n in gating_to_targets
        ]
        reuse_groups = len(gating_ordered) > 1 and all(
            nx.has_path(self, gating_ordered[i], gating_ordered[i + 1])
            for i in range(len(gating_ordered) - 1)
        )
        pool_start = self._next_cerf_group

        for gating_node in gating_ordered:
            targets = gating_to_targets[gating_node]
            gating_node.node_type = "gating"

            # Reset group counter to pool start for reuse
            if reuse_groups:
                self._next_cerf_group = pool_start

            # Build undirected graph of unconditional edges among targets
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
            components = sorted(
                nx.connected_components(unc),
                key=lambda c: min(n.node_id for n in c),
            )

            group_ids = []
            for component in components:
                gid = self._next_cerf_group
                self._next_cerf_group += 1
                if gid >= 16:
                    hint = ("Sequential gating reuse is active — "
                            "too many experts per layer."
                            if reuse_groups else
                            "Consider reducing experts or making "
                            "gating nodes sequential for reuse.")
                    raise ValueError(
                        f"CERF group overflow: need group {gid} but "
                        f"max is 15 (WF4 violated). {hint}"
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

        self._node_to_cerf_group = node_to_group
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
                if gid >= 16:
                    raise ValueError(f"CERF group overflow: {gid} >= 16 (max 16 groups)")
                node.cond_exec_en = True
                node.cond_exec_group_id = gid
                node.cond_exec_invert = invert
                group_ids.append(gid)
        else:
            gid = self._next_cerf_group
            self._next_cerf_group += 1
            if gid >= 16:
                raise ValueError(f"CERF group overflow: {gid} >= 16 (max 16 groups)")
            for node in guarded_nodes:
                node.cond_exec_en = True
                node.cond_exec_group_id = gid
                node.cond_exec_invert = invert
            group_ids = [gid]

        gating_node.cerf_write_groups = sorted(set(
            gating_node.cerf_write_groups + group_ids
        ))
        return group_ids

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
        
    def bingo_emit_task_desc_sv(self) -> str:
        """Emit the SystemVerilog string for all nodes in the DFG."""
        sv_strings = []

        # Iterate over all nodes in the graph
        for node in self.node_list:
            # Call the emit_sv function of each node
            sv_strings.append(node.emit_sv())

        # Combine all the SystemVerilog strings with newlines
        return "\n\n".join(sv_strings)

    def _core_balanced_topological_sort(self, chiplet_id: int) -> list:
        """Topological sort that interleaves tasks across cores.

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
        """Emit the SystemVerilog string to push tasks for all nodes in the DFG."""
        sv_strings = []
        # Iterate over each chiplet
        for chiplet_id in range(MAX_NUM_CHIPLETS):
            chiplet_nodes = self._core_balanced_topological_sort(chiplet_id)
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
            # Generate the SystemVerilog push sequence for the sorted nodes
            for node in chiplet_nodes:
                chiplet_sv.append(f"      task_queue_master[{chiplet_id}].write(task_queue_base[{chiplet_id}], '0, {node.node_name}, '1, resp_chip{chiplet_id});")
                chiplet_sv.append("    #50;")

            chiplet_sv.append("  end")
            sv_strings.append("\n".join(chiplet_sv))

        # Combine all chiplet strings
        return "\n\n".join(sv_strings)