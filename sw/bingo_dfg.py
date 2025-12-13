# Fanchen Kong <fanchen.kong@kuleuven.be>

from bingo_utils import DiGraphWrapper
from bingo_node import BingoNode
import networkx as nx
MAX_NUM_CHIPLETS = 8
class BingoDFG(DiGraphWrapper[BingoNode]):
    """Data Flow Graph (DFG) for Bingo."""

    def __init__(self) -> None:
        super().__init__()
        self.id = 0
    def bingo_add_node(self, node_obj: BingoNode) -> None:
        """Add a node to the DFG."""

        # Assign a unique ID to the node
        self.id += 1
        node_obj.node_id = self.id
        # Add the node to the graph and the lookup dictionaries
        self.add_node(node_obj)
    def bingo_add_edge(self, from_node_obj: BingoNode, to_node_obj: BingoNode) -> None:
        """Add an edge to the DFG using node objects."""
        self.add_edge(from_node_obj, to_node_obj)

    def bingo_insert_node_between(self, from_node_obj: BingoNode, to_node_obj: BingoNode, new_node_obj: BingoNode) -> None:
        """Insert a new node between two existing nodes in the DFG."""
        # Ensure the edge exists between the two nodes
        if not self.has_edge(from_node_obj, to_node_obj):
            raise ValueError(f"No edge exists between {from_node_obj.node_name} and {to_node_obj.node_name}")

        # Add the new node to the DFG
        self.bingo_add_node(new_node_obj)

        # Remove the edge between the two existing nodes
        self.remove_edge(from_node_obj, to_node_obj)

        # Add edges to connect the new node between the two existing nodes
        self.add_edge(from_node_obj, new_node_obj)
        self.add_edge(new_node_obj, to_node_obj)
        
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
            # If there are more then 1 successors, we need to insert #succ-1 dummy set nodes between the cur_node and 
            if len(succs_list) >=2:
                # We have the special situation that this node is a broadcast node to set all chiplets

                remote_succ_list = [
                    succ for succ in succs_list
                    if succ.assigned_chiplet_id != cur_node.assigned_chiplet_id
                ]
                # All the chiplets id except the current chiplet id happens only once
                if len(set(remote_succ.assigned_chiplet_id for remote_succ in remote_succ_list)) == (MAX_NUM_CHIPLETS -1):
                    # All the remote successors must have the same core id
                    if len(set(remote_succ.assigned_core_id for remote_succ in remote_succ_list)) == 1:
                        print(f"Node {cur_node.node_name} is a broadcast node to set all chiplets.")
                        dummy_set_node = BingoNode(
                            assigned_chiplet_id=cur_node.assigned_chiplet_id,
                            assigned_cluster_id=cur_node.assigned_cluster_id, # should be fine since it will not be executed
                            assigned_core_id=cur_node.assigned_core_id,       # must be the same type of the cur_node to block the execution
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
                # Now the normal case
                # We need local_successors-1 dummy set nodes
                print(f"Adding dummy set nodes for {cur_node.node_name} with local successors {[succ.node_name for succ in succs_list]}")
                for i in range(len(succs_list)-1):
                    dummy_set_node = BingoNode(
                        assigned_chiplet_id=cur_node.assigned_chiplet_id,
                        assigned_cluster_id=succs_list[i].assigned_cluster_id, # should be fine since it will not be executed
                        assigned_core_id=cur_node.assigned_core_id,            # must be the same type of the cur_node to block the execution
                        node_name=f"dummy_set_{cur_node.node_name}_{i}"
                    )
                    dummy_set_node.node_type = "dummy"
                    dummy_set_node.dep_set_enable = True
                    dummy_set_node.dep_set_list = [succs_list[i].assigned_core_id]
                    dummy_set_node.dep_set_cluster_id = succs_list[i].assigned_cluster_id
                    dummy_set_node.dep_set_chiplet_id = succs_list[i].assigned_chiplet_id
                    dummy_set_node.dep_check_enable = False
                    dummy_set_node.dep_check_list = []
                    dummy_set_node.remote_dep_set_all = False
                    # Add the dummy set node to the graph
                    self.bingo_insert_node_between(cur_node, succs_list[i], dummy_set_node)
                    
    def bingo_transform_dfg_add_dummy_check_nodes(self) -> None:
        '''Transform the DFG to add dummy check nodes.'''
        # The idea of the dummy check nodes is to solve the problem of this kind
        #         dma(Cl0)    dma(Cl1)
        #          |           |
        #           \         /
        #            v       v
        #            gemm(Cl0)
        # that a node depends on two (more than 1) nodes with same assigned core
        for cur_node in self.node_list:
            # find all the predecessors
            predecessors = [
                pred for pred in self.predecessors(cur_node)
            ]
            # find if there are more than 1 predecessor with same assigned core
            local_predecessor_core_dict = {}
            for pred in predecessors:
                if pred.assigned_core_id not in local_predecessor_core_dict:
                    local_predecessor_core_dict[pred.assigned_core_id] = []
                local_predecessor_core_dict[pred.assigned_core_id].append(pred)
            for core_id, preds in local_predecessor_core_dict.items():
                if len(preds) >= 2:
                    print(f"Adding dummy check node for {cur_node.node_name} with predecessors {[pred.node_name for pred in preds]}")
                    for i in range(len(preds)-1):
                        dummy_check_node = BingoNode(
                            assigned_chiplet_id=cur_node.assigned_chiplet_id,
                            assigned_cluster_id=cur_node.assigned_cluster_id, # should be fine since it will not be executed
                            assigned_core_id=cur_node.assigned_core_id,    # should be the same type of the cur_node to block the execution
                            node_name=f"dummy_check_{cur_node.node_name}_{core_id}"
                        )
                        dummy_check_node.node_type = "dummy"
                        dummy_check_node.dep_check_enable = True
                        dummy_check_node.dep_check_list = [preds[i].assigned_core_id]
                        dummy_check_node.dep_set_enable = False
                        dummy_check_node.dep_set_list = []
                        dummy_check_node.dep_set_cluster_id = 0
                        # Add the dummy check node to the graph
                        self.bingo_insert_node_between(preds[i], cur_node, dummy_check_node)


    def bingo_assign_normal_node_dep_check_info(self) -> None:
        """Assign the dep check info for normal nodes."""
        # Iterate over all nodes in the graph
        for cur_node in self.node_list:
            # Check if the node's task_type is "normal"
            if cur_node.node_type == "normal":
                # Find local predecessors (same chiplet ID) 
                # And not dummy check
                # And not chiplet dep check
                local_predecessors = [
                    pred for pred in self.predecessors(cur_node)
                    if pred.assigned_chiplet_id == cur_node.assigned_chiplet_id and not (pred.node_type == "dummy" and pred.dep_check_enable) and not (pred.node_type == "chiplet_dep_check")
                ]

                # If there are local predecessors, assign dep_check info
                if local_predecessors:
                    cur_node.dep_check_enable = True
                    cur_node.local_dep_check_list = [pred.assigned_core_id for pred in local_predecessors]
                    # Sanity check if there are multiple same core_id
                    if len(cur_node.local_dep_check_list) != len(set(cur_node.local_dep_check_list)):
                        print(f"Warning: Multiple local predecessors with the same core_id for node {cur_node.node_name}. This is not expected, go back to DFG transformation stage!")
                    print(f"Assigned dep_check_info for node {cur_node.node_name}: "
                          f"dep_check_enable=True, dep_check_list={cur_node.local_dep_check_list}")
                else:
                    # If no local predecessors, disable dep_check
                    cur_node.dep_check_enable = False
                    cur_node.local_dep_check_list = []
                    print(f"No local predecessors for node {cur_node.node_name}. "
                          f"dep_check_enable=False")

    def bingo_assign_normal_node_dep_set_info(self) -> None:
        """Assign the dep set info for normal nodes."""
        # Iterate over all nodes in the graph
        for cur_node in self.node_list:
           # Check if the node's task_type is "normal"
           if cur_node.node_type == "normal":
                # Find local succs (same chiplet ID) 
                # And not dummy set
                # And not chiplet dep set
                local_successors = [
                    succ for succ in self.successors(cur_node)
                    if succ.assigned_chiplet_id == cur_node.assigned_chiplet_id and not (succ.node_type == "dummy" and succ.dep_set_enable) and not (succ.node_type == "chiplet_dep_set")
                ]
                if len(local_successors)>1:
                    print(f"Warning: More than one local successor for node {cur_node.node_name}. This is not expected, go back to DFG transformation stage!")
                elif len(local_successors)==1:
                    cur_node.dep_set_enable = True
                    cur_node.local_dep_set_list = [succ.assigned_core_id for succ in local_successors]
                    cur_node.local_dep_set_cluster_id = local_successors[0].assigned_cluster_id
                else:
                    cur_node.dep_set_enable = False
                    cur_node.local_dep_set_list = []
                    cur_node.local_dep_set_cluster_id = 0

    def bingo_visualize_dfg(self, filename: str = "dfg_visualization.png", figsize: tuple = (10, 8)) -> None:
        """Visualize the DFG with different shapes for task types and colors for chiplets."""
        import matplotlib.pyplot as plt
        from matplotlib.lines import Line2D

        # Define shapes for different task types
        task_type_shapes = {
            "normal": "o",  # Circle
            "dummy_set": "s",   # Square
            "dummy_check": "v",  # Downward Triangle
            "chiplet_dep_set": "D",  # Diamond
            "chiplet_dep_check": "^"  # Triangle
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
            labels[node] = f"Cluster{cur_cluster_id}Core{cur_core_id}\n{cur_task_type}\nChiplet: {cur_chiplet_id}"
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

    def bingo_emit_push_task_sv(self) -> str:
        """Emit the SystemVerilog string to push tasks for all nodes in the DFG."""
        sv_strings = []

        # Iterate over each chiplet
        for chiplet_id in range(MAX_NUM_CHIPLETS):
            # Check if there are any nodes for this chiplet_id
            chiplet_nodes = [node for node in self.node_list if node.assigned_chiplet_id == chiplet_id]
            if not chiplet_nodes:
                continue  # Skip this chiplet if no nodes exist

            chiplet_sv = []
            chiplet_sv.append(f"  // Host pushes tasks for chiplet {chiplet_id}")
            chiplet_sv.append(f"  initial begin : chip{chiplet_id}_push_sequence")
            chiplet_sv.append(f"    automatic axi_pkg::resp_t resp_chip{chiplet_id};")
            chiplet_sv.append(f"    wait (rst_ni);")
            chiplet_sv.append(f"    @(posedge clk_i);")
            chiplet_sv.append("")

            # Perform a topological sort of the graph to ensure dependency order
            topo_sorted_nodes = list(nx.topological_sort(self))

            # Filter nodes for the current chiplet and sort them by priority
            def node_priority(node):
                # Assign priorities based on node type
                if node.node_type == "chiplet_dep_set":
                    return 3  # Lowest priority (pushed last)
                elif node.node_type == "dummy_check":
                    return 1  # High priority (pushed early)
                else:
                    return 2  # Default priority for normal tasks

            chiplet_nodes_sorted = sorted(
                [node for node in topo_sorted_nodes if node.assigned_chiplet_id == chiplet_id],
                key=node_priority
            )

            # Generate the SystemVerilog push sequence for the sorted nodes
            for node in chiplet_nodes_sorted:
                chiplet_sv.append("    fork")
                chiplet_sv.append(f"      local_task_drv_chip{chiplet_id}.send_aw(TASK_QUEUE_BASE, '0);")
                chiplet_sv.append(f"      local_task_drv_chip{chiplet_id}.send_w({node.node_name}, {{HOST_DW/8{{1'b1}}}});")
                chiplet_sv.append(f"      local_task_drv_chip{chiplet_id}.recv_b(resp_chip{chiplet_id});")
                chiplet_sv.append("    join_none")
                chiplet_sv.append("    #50;")

            chiplet_sv.append("  end")
            sv_strings.append("\n".join(chiplet_sv))

        # Combine all chiplet strings
        return "\n\n".join(sv_strings)