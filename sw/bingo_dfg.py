# Fanchen Kong <fanchen.kong@kuleuven.be>

from bingo_utils import DiGraphWrapper
from bingo_node import BingoNode
import networkx as nx
MAX_NUM_CHIPLETS = 8
MAX_NUM_CHIPLETS_PER_CHIPLET_DEP_SET = 4
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
        
    def bingo_insert_node_after(self, existing_node_obj: BingoNode, new_node_obj: BingoNode) -> None:
        """Insert a new node after an existing node in the DFG."""
        existing_node = existing_node_obj
        # Get all outgoing edges from the existing node
        outgoing_edges = list(self.out_edges(existing_node))

        # Add the new node to the DFG
        self.bingo_add_node(new_node_obj)

        # Remove outgoing edges from the existing node
        for _, to_node in outgoing_edges:
            self.remove_edge(existing_node, to_node)

        # Add edge from existing node to new node
        self.add_edge(existing_node, new_node_obj)

        # Add edges from new node to the original destination nodes
        for _, to_node in outgoing_edges:
            self.add_edge(new_node_obj, to_node)
            
    def bingo_insert_node_before(self, existing_node_obj: BingoNode, new_node_obj: BingoNode) -> None:
        """Insert a new node before an existing node in the DFG."""
        existing_node = existing_node_obj

        # Get all incoming edges to the existing node
        incoming_edges = list(self.in_edges(existing_node))

        # Add the new node to the DFG
        self.bingo_add_node(new_node_obj)

        # Remove incoming edges to the existing node
        for from_node, _ in incoming_edges:
            self.remove_edge(from_node, existing_node)

        # Add edge from new node to existing node
        self.add_edge(new_node_obj, existing_node)

        # Add edges from original source nodes to the new node
        for from_node, _ in incoming_edges:
            self.add_edge(from_node, new_node_obj)
    def bingo_transform_dfg_add_chiplet_dep_set_nodes(self) -> None:
        """Transform the DFG to add chiplet dep set nodes."""
        # Iterate over all nodes in the graph
        for cur_node in self.node_list:
            cur_node_assigned_chiplet = cur_node.assigned_chiplet_id

            # Find successors with a different assigned_chiplet_id
            remote_successors = [
                succ for succ in self.successors(cur_node)
                if succ.assigned_chiplet_id != cur_node_assigned_chiplet
            ]
            if remote_successors:
                print(f"Adding chiplet dep set node for {cur_node.node_name} with remote successors {[succ.node_name for succ in remote_successors]}")
                if len(remote_successors) == MAX_NUM_CHIPLETS:
                    dep_set_node = BingoNode(
                        assigned_chiplet_id=cur_node_assigned_chiplet,
                        assigned_cluster_id=99, # Dummy cluster ID
                        assigned_core_id=99,    # Dummy core ID
                        node_name=f"dep_set_{cur_node.node_name}"
                    )
                    dep_set_node.node_type = "chiplet_dep_set"
                    dep_set_node.remote_dep_set_all = True

                    # Add the chiplet dep set node to the graph
                    self.bingo_add_node(dep_set_node)

                    # Redirect remote edges to the chiplet dep set node
                    for succ in remote_successors:
                        self.remove_edge(cur_node, succ)
                        self.bingo_add_edge(dep_set_node, succ)

                    # Add an edge from the current node to the chiplet dep set node
                    self.bingo_add_edge(cur_node, dep_set_node)
                else:
                    # Split remote successors into chunks
                    for i in range(0, len(remote_successors), MAX_NUM_CHIPLETS_PER_CHIPLET_DEP_SET):
                        chunk = remote_successors[i:i + MAX_NUM_CHIPLETS_PER_CHIPLET_DEP_SET]
                        dep_set_node = BingoNode(
                            assigned_chiplet_id=cur_node_assigned_chiplet,
                            assigned_cluster_id=99, # Dummy cluster ID
                            assigned_core_id=99,    # Dummy core ID
                            node_name=f"dep_set_{cur_node.node_name}_{i//MAX_NUM_CHIPLETS_PER_CHIPLET_DEP_SET}"
                        )
                        dep_set_node.node_type = "chiplet_dep_set"
                        dep_set_node.remote_dep_set_chiplet_id = [succ.assigned_chiplet_id for succ in chunk]

                        # Add the chiplet dep set node to the graph
                        self.bingo_add_node(dep_set_node)

                        # Redirect remote edges to the chiplet dep set node
                        for succ in chunk:
                            self.remove_edge(cur_node, succ)
                            self.bingo_add_edge(dep_set_node, succ)

                        # Add an edge from the current node to the chiplet dep set node
                        self.bingo_add_edge(cur_node, dep_set_node)
        
    
    def bingo_transform_dfg_add_chiplet_dep_check_nodes(self) -> None:
        """Transform the DFG to add chiplet dep check nodes."""
        # Iterate over all nodes in the graph
        for cur_node in self.node_list:
            cur_node_assigned_chiplet = cur_node.assigned_chiplet_id

            # Find predecessors with a different assigned_chiplet_id
            remote_predecessors = [
                pred for pred in self.predecessors(cur_node)
                if pred.assigned_chiplet_id != cur_node_assigned_chiplet
            ]

            # If there are remote predecessors, create a chiplet dep check node
            if remote_predecessors:
                print(f"Adding chiplet dep check node for {cur_node.node_name} with remote predecessors {[pred.node_name for pred in remote_predecessors]}")
                # Create the chiplet dep check node
                dep_check_node = BingoNode(
                    assigned_chiplet_id=cur_node_assigned_chiplet,
                    assigned_cluster_id=99, # Dummy cluster ID
                    assigned_core_id=99,    # Dummy core ID
                    node_name=f"dep_check_{cur_node.node_name}"
                )
                dep_check_node.node_type = "chiplet_dep_check"
                dep_check_node.dep_check_sum = len(remote_predecessors)

                # Add the chiplet dep check node to the graph
                self.bingo_add_node(dep_check_node)

                # Redirect remote edges to the chiplet dep check node
                for pred in remote_predecessors:
                    self.remove_edge(pred, cur_node)
                    self.bingo_add_edge(pred, dep_check_node)

                # Add an edge from the chiplet dep check node to the current node
                self.bingo_add_edge(dep_check_node, cur_node)
            
    def bingo_transform_dfg_add_dummy_set_nodes(self) -> None:
        """Transform the DFG to add dummy nodes."""
        # The idea of the dummy set nodes is to solve the problem of this kind
        #            simd(Cl0)
        #           /         \
        #          |           |
        #          v           v
        #         dma(Cl0)    gemm(Cl1)
        for cur_node in self.node_list:
            local_successors = [
                succ for succ in self.successors(cur_node)
                if succ.assigned_chiplet_id == cur_node.assigned_chiplet_id
            ]
            if len(local_successors) >=2:
                # We need local_successors-1 dummy set nodes
                print(f"Adding dummy set nodes for {cur_node.node_name} with local successors {[succ.node_name for succ in local_successors]}")
                for i in range(len(local_successors)-1):
                    dummy_set_node = BingoNode(
                        assigned_chiplet_id=cur_node.assigned_chiplet_id,
                        assigned_cluster_id=local_successors[i].assigned_cluster_id, # should be fine since it will not be executed
                        assigned_core_id=cur_node.assigned_core_id,    # should be the same type of the cur_node to block the execution
                        node_name=f"dummy_set_{cur_node.node_name}_{i}"
                    )
                    dummy_set_node.node_type = "dummy"
                    dummy_set_node.dep_set_enable = True
                    # Add the dummy set node to the graph
                    self.bingo_add_node(dummy_set_node)
                    # Redirect edges
                    self.remove_edge(cur_node, local_successors[i])
                    # Add edge from cur_node to dummy_set_node
                    self.bingo_add_edge(cur_node, dummy_set_node)
                    # Add edge from dummy_set_node to local_successors[i]
                    self.bingo_add_edge(dummy_set_node, local_successors[i])
                    
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
            local_predecessors = [
                pred for pred in self.predecessors(cur_node)
                if pred.assigned_chiplet_id == cur_node.assigned_chiplet_id
            ]
            # find if there are more than 1 predecessor with same assigned core
            local_predecessor_core_dict = {}
            for pred in local_predecessors:
                if pred.assigned_core_id not in local_predecessor_core_dict:
                    local_predecessor_core_dict[pred.assigned_core_id] = []
                local_predecessor_core_dict[pred.assigned_core_id].append(pred)
            for core_id, preds in local_predecessor_core_dict.items():
                if len(preds) >= 2:
                    print(f"Adding dummy check node for {cur_node.node_name} with local predecessors {[pred.node_name for pred in preds]}")
                    for i in range(len(preds)-1):
                        dummy_check_node = BingoNode(
                            assigned_chiplet_id=cur_node.assigned_chiplet_id,
                            assigned_cluster_id=cur_node.assigned_cluster_id, # should be fine since it will not be executed
                            assigned_core_id=cur_node.assigned_core_id,    # should be the same type of the cur_node to block the execution
                            node_name=f"dummy_check_{cur_node.node_name}_{core_id}"
                        )
                        dummy_check_node.node_type = "dummy"
                        dummy_check_node.dep_check_enable = True
                        # Add the dummy check node to the graph
                        self.bingo_add_node(dummy_check_node)
                        # Redirect edges
                        self.remove_edge(preds[i], cur_node)
                        # Add edge from pred to dummy_check_node
                        self.bingo_add_edge(preds[i], dummy_check_node)
                        # Add edge from dummy_check_node to cur_node
                        self.bingo_add_edge(dummy_check_node, cur_node)


    def bingo_visualize_dfg(self, filename: str = "dfg_visualization.png", figsize: tuple = (10, 8)) -> None:
        """Visualize the DFG with different shapes for task types and colors for chiplets."""
        import matplotlib.pyplot as plt
        from matplotlib.lines import Line2D

        # Define shapes for different task types
        task_type_shapes = {
            "normal": "o",  # Circle
            "dummy": "s",   # Square
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
        labels = {node: f"Cluster{node.assigned_cluster_id}Core{node.assigned_core_id}\n{node.node_type}\nChiplet: {node.assigned_chiplet_id}"
                  for node in self.nodes}
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
