# Fanchen Kong <fanchen.kong@kuleuven.be>
# The node types and the base class for nodes in the DFG
from abc import ABCMeta
from typing import Literal

class BingoNode(metaclass=ABCMeta):
    """Abstract base class for nodes in the DFG."""
    def __init__(
        self,
        assigned_chiplet_id: int,
        assigned_cluster_id: int,
        assigned_core_id: int,
        node_name: str,
    ) -> None:
        self._node_name = node_name
        self._node_id: int = 0
        self._assigned_chiplet_id = assigned_chiplet_id
        self._assigned_cluster_id = assigned_cluster_id
        self._assigned_core_id = assigned_core_id
        self._node_type: Literal['normal', 'dummy'] = "normal"
        self._dep_check_enable: bool = False
        self._dep_check_list: list[int] = []
        self._dep_set_enable: bool = False
        self._remote_dep_set_all: bool = False
        self._dep_set_list: list[int] = []
        self._dep_set_chiplet_id: int = 0
        self._dep_set_cluster_id: int = 0

    # Getters and Setters
    @property
    def node_name(self) -> str:
        return self._node_name

    @node_name.setter
    def node_name(self, value: str) -> None:
        self._node_name = value

    @property
    def node_id(self) -> int:
        return self._node_id

    @node_id.setter
    def node_id(self, value: int) -> None:
        self._node_id = value

    @property
    def assigned_chiplet_id(self) -> int:
        return self._assigned_chiplet_id

    @assigned_chiplet_id.setter
    def assigned_chiplet_id(self, value: int) -> None:
        self._assigned_chiplet_id = value

    @property
    def assigned_cluster_id(self) -> int:
        return self._assigned_cluster_id

    @assigned_cluster_id.setter
    def assigned_cluster_id(self, value: int) -> None:
        self._assigned_cluster_id = value

    @property
    def assigned_core_id(self) -> int:
        return self._assigned_core_id

    @assigned_core_id.setter
    def assigned_core_id(self, value: int) -> None:
        self._assigned_core_id = value

    @property
    def node_type(self) -> Literal['normal', 'dummy']:
        return self._node_type

    @node_type.setter
    def node_type(self, value: Literal['normal', 'dummy']) -> None:
        self._node_type = value

    @property
    def dep_check_enable(self) -> bool:
        """Get the dep_check_enable flag."""
        return self._dep_check_enable

    @dep_check_enable.setter
    def dep_check_enable(self, value: bool) -> None:
        """Set the dep_check_enable flag."""
        if not isinstance(value, bool):
            raise ValueError("dep_check_enable must be a boolean value.")
        self._dep_check_enable = value

    @property
    def dep_check_list(self) -> list[int]:
        return self._dep_check_list

    @dep_check_list.setter
    def dep_check_list(self, value: list[int]) -> None:
        self._dep_check_list = value

    @property
    def dep_set_enable(self) -> bool:
        """Get the dep_set_enable flag."""
        return self._dep_set_enable

    @dep_set_enable.setter
    def dep_set_enable(self, value: bool) -> None:
        """Set the dep_set_enable flag."""
        if not isinstance(value, bool):
            raise ValueError("dep_set_enable must be a boolean value.")
        self._dep_set_enable = value

    @property
    def remote_dep_set_all(self) -> bool:
        return self._remote_dep_set_all

    @remote_dep_set_all.setter
    def remote_dep_set_all(self, value: bool) -> None:
        self._remote_dep_set_all = value

    @property
    def dep_set_list(self) -> list[int]:
        return self._dep_set_list

    @dep_set_list.setter
    def dep_set_list(self, value: list[int]) -> None:
        self._dep_set_list = value

    @property
    def dep_set_chiplet_id(self) -> int:
        return self._dep_set_chiplet_id

    @dep_set_chiplet_id.setter
    def dep_set_chiplet_id(self, value: int) -> None:
        self._dep_set_chiplet_id = value

    @property
    def dep_set_cluster_id(self) -> int:
        return self._dep_set_cluster_id

    @dep_set_cluster_id.setter
    def dep_set_cluster_id(self, value: int) -> None:
        self._dep_set_cluster_id = value

    def __str__(self):
        return self._node_name if self._node_name else f"Node_{self._node_id}"

    def emit_sv(self) -> str:
        """Emit the SystemVerilog string for this node."""
        # Helper function to convert a list of integers to a one-hot binary string
        def list_to_one_hot(lst: list[int], width: int = 8) -> str:
            if (lst==[]):
                return "'0"
            one_hot = 0
            for idx in lst:
                one_hot |= (1 << idx)
            return f"bingo_hw_manager_dep_code_t'({width}'b{one_hot:0{width}b})"

        # Determine the appropriate pack function based on the node type
        if self._node_type == "normal":
            pack_function = "pack_normal_task"
            dep_check_code = list_to_one_hot(self._dep_check_list)
            dep_set_code = list_to_one_hot(self._dep_set_list)
            sv_str = (
                f"bingo_hw_manager_task_desc_full_t {self._node_name} = {pack_function}(\n"
                f"    2'b00, // task_type\n"
                f"    16'd{self._node_id}, // task_id\n"
                f"    {self._assigned_chiplet_id}, // assigned_chiplet_id\n"
                f"    {self._assigned_cluster_id}, // assigned_cluster_id\n"
                f"    {self._assigned_core_id}, // assigned_core_id\n"
                f"    1'b{int(self._dep_check_enable)}, // dep_check_en\n"
                f"    {dep_check_code}, // dep_check_code\n"
                f"    1'b{int(self._dep_set_enable)}, // dep_set_en\n"
                f"    {dep_set_code}, // dep_set_code\n"
                f"    {self._dep_set_cluster_id} // dep_set_cluster_id\n"
                f");"
            )
        elif self._node_type == "dummy":
            pack_function = "pack_dummy_check_task" if self._dep_check_enable else "pack_dummy_set_task"
            if self._dep_check_enable:
                dep_check_code = list_to_one_hot(self._dep_check_list)
                sv_str = (
                    f"bingo_hw_manager_task_desc_full_t {self._node_name} = {pack_function}(\n"
                    f"    2'b01, // task_type\n"
                    f"    16'd{self._node_id}, // task_id\n"
                    f"    {self._assigned_chiplet_id}, // assigned_chiplet_id\n"
                    f"    1'b{int(self._dep_check_enable)}, // dep_check_en\n"
                    f"    {dep_check_code} // dep_check_code\n"
                    f");"
                )
            else:
                dep_set_code = list_to_one_hot(self._dep_set_list)
                sv_str = (
                    f"bingo_hw_manager_task_desc_full_t {self._node_name} = {pack_function}(\n"
                    f"    2'b01, // task_type\n"
                    f"    16'd{self._node_id}, // task_id\n"
                    f"    {self._assigned_chiplet_id}, // assigned_chiplet_id\n"
                    f"    1'b{int(self._dep_set_enable)}, // dep_set_en\n"
                    f"    {dep_set_code}, // dep_set_code\n"
                    f"    {self._dep_set_cluster_id} // dep_set_cluster_id\n"
                )
        else:
            raise ValueError(f"Unsupported node type: {self._node_type}")

        return sv_str