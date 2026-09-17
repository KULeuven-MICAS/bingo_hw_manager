# Fanchen Kong <fanchen.kong@kuleuven.be>
# The node types and the base class for nodes in the DFG
from __future__ import annotations
from abc import ABCMeta
from math import ceil, log2
from typing import Literal

# ---------------------------------------------------------------------------
# Task descriptor layout -- the single source of truth on the SW side
# ---------------------------------------------------------------------------
# Mirrors the RTL packed struct bingo_hw_manager_task_desc_t in
# src/bingo_hw_manager_top.sv. It lives in this module, the leaf of the SW
# import graph, so the bit packer in bingo_dfg.py and the SystemVerilog
# stimulus emitted further down read the same widths from the same place.
# Keeping a second copy of these numbers is exactly how the C header drifted
# out of sync with the RTL and computed a 50-bit layout for a 65-bit struct.

#: Width of the descriptor CONTAINER, in bits (RTL parameter TaskDescBusWidth).
#: This is the ONLY width knob -- every derived quantity below comes from it,
#: and nothing may assume a descriptor still fits in a single 64-bit word.
BINGO_TASK_DESC_WIDTH = 128

#: One host AXI-Lite beat. Fixed at 64 bit by the SoC narrow fabric
#: (HostAxiLiteDataWidth); widening the descriptor does not widen the bus.
BINGO_TASK_DESC_WORD_WIDTH = 64

# Beats/words per descriptor and the descriptor's byte stride are deliberately
# NOT module-level constants. The container width is a per-DFG argument
# (BingoDFG(task_desc_width=...)), so a constant derived from the default above
# is simply wrong for every DFG that overrides it -- and wrong in the quiet way,
# as a header comment or a stride that disagrees with the words next to it.
# Ask the DFG instead: BingoDFG.bingo_task_desc_word_count() and
# BingoDFG.bingo_task_desc_bytes(), both derived from that instance's width.

# Fixed field widths; each is the RTL parameter of the same name.
BINGO_TASK_TYPE_WIDTH = 2
BINGO_TASK_ID_WIDTH = 12              # TaskIdWidth
BINGO_CHIP_ID_WIDTH = 8               # ChipIdWidth
BINGO_COND_EXEC_GROUP_ID_WIDTH = 5
BINGO_DEP_TAG_WIDTH = 4               # DepTagWidth

# Geometry defaults, matching the RTL parameter defaults of
# bingo_hw_manager_top. NOTE: in THIS repo num_cores_per_cluster is the RTL
# NUM_CORES_PER_CLUSTER verbatim, whereas HeMAiA passes
# N_CORES_PER_CLUSTER + 1 (its host CVA6 counts as an extra core of cluster 0).
# Same symbol, different numbers on the two sides -- always pass the RTL value.
BINGO_NUM_CLUSTERS_PER_CHIPLET = 2
BINGO_NUM_CORES_PER_CLUSTER = 4

#: task_type encoding (2'b11 reserved), shared by the packer and the emitter.
BINGO_TASK_TYPE_MAP = {"normal": 0, "dummy": 1, "gating": 2}


def bingo_idx_width(n: int) -> int:
    """cf_math_pkg::idx_width -- index bits for ``n`` items, never zero.

    Plain clog2() yields 0 at n == 1, which would delete the field and shift
    every field above it down. That is one of the four layout bugs this
    contract fixes, so the floor of 1 is load-bearing, not defensive.
    """
    return int(ceil(log2(n))) if n > 1 else 1


def bingo_task_desc_fields(
    num_clusters_per_chiplet: int = BINGO_NUM_CLUSTERS_PER_CHIPLET,
    num_cores_per_cluster: int = BINGO_NUM_CORES_PER_CLUSTER,
    dep_tag_width: int = BINGO_DEP_TAG_WIDTH,
) -> list[tuple[str, int]]:
    """THE field table: ``(name, width)`` ordered LSB -> MSB.

    A packed struct's last-declared member is its LSB, so this list is
    bingo_hw_manager_task_desc_t read bottom-up. Pack and unpack both walk
    this one list, which is what makes it impossible for them to disagree.
    """
    cluster_id_width = bingo_idx_width(num_clusters_per_chiplet)
    core_id_width = bingo_idx_width(num_cores_per_cluster)
    return [
        ("cond_exec_invert",    1),
        ("cond_exec_group_id",  BINGO_COND_EXEC_GROUP_ID_WIDTH),
        ("cond_exec_en",        1),
        ("task_type",           BINGO_TASK_TYPE_WIDTH),
        ("task_id",             BINGO_TASK_ID_WIDTH),
        # The chiplet id is the ROUTING encoding (chip_id = (x << 4) | y), so
        # it is ChipIdWidth wide and NOT clog2(number of chiplets).
        ("assigned_chiplet_id", BINGO_CHIP_ID_WIDTH),
        ("assigned_cluster_id", cluster_id_width),
        ("assigned_core_id",    core_id_width),
        ("dep_check_en",        1),
        ("dep_check_code",      num_cores_per_cluster),
        ("dep_check_tag",       dep_tag_width),
        ("dep_set_en",          1),
        ("dep_set_all_chiplet", 1),
        ("dep_set_chiplet_id",  BINGO_CHIP_ID_WIDTH),
        ("dep_set_cluster_id",  cluster_id_width),
        ("dep_set_code",        num_cores_per_cluster),
        ("dep_set_tag",         dep_tag_width),
    ]


class BingoNode(metaclass=ABCMeta):
    """Abstract base class for nodes in the DFG."""
    def __init__(
        self,
        assigned_chiplet_id: int = -1,
        assigned_cluster_id: int = -1,
        assigned_core_id: int = -1,
        node_name: str = "",
    ) -> None:
        self._node_name = node_name
        self._node_id: int = 0
        self._assigned_chiplet_id = assigned_chiplet_id
        self._assigned_cluster_id = assigned_cluster_id
        self._assigned_core_id = assigned_core_id
        self._node_type: Literal['normal', 'dummy', 'gating'] = "normal"
        self._dep_check_enable: bool = False
        self._dep_check_list: list[int] = []
        self._dep_set_enable: bool = False
        self._remote_dep_set_all: bool = False
        self._dep_set_list: list[int] = []
        self._dep_set_chiplet_id: int = 0
        self._dep_set_cluster_id: int = 0
        # Per-edge identity tags, stamped by the tag-allocator pass; tag 0 for
        # ops the allocator leaves untouched (single-edge cells).
        self._dep_check_tag: int = 0
        self._dep_set_tag: int = 0
        # DARTS Tier 1: Conditional Execution
        self._cond_exec_en: bool = False
        self._cond_exec_group_id: int = 0
        self._cond_exec_invert: bool = False
        # CERF groups this gating node writes on completion
        self._cerf_write_groups: list[int] = []

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
    def node_type(self) -> Literal['normal', 'dummy', 'gating']:
        return self._node_type

    @node_type.setter
    def node_type(self, value: Literal['normal', 'dummy', 'gating']) -> None:
        self._node_type = value

    @property
    def cond_exec_en(self) -> bool:
        return self._cond_exec_en

    @cond_exec_en.setter
    def cond_exec_en(self, value: bool) -> None:
        self._cond_exec_en = value

    @property
    def cond_exec_group_id(self) -> int:
        return self._cond_exec_group_id

    @cond_exec_group_id.setter
    def cond_exec_group_id(self, value: int) -> None:
        self._cond_exec_group_id = value

    @property
    def cond_exec_invert(self) -> bool:
        return self._cond_exec_invert

    @cond_exec_invert.setter
    def cond_exec_invert(self, value: bool) -> None:
        self._cond_exec_invert = value

    @property
    def cerf_write_groups(self) -> list[int]:
        return self._cerf_write_groups

    @cerf_write_groups.setter
    def cerf_write_groups(self, value: list[int]) -> None:
        self._cerf_write_groups = value

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

    @property
    def dep_check_tag(self) -> int:
        return self._dep_check_tag

    @dep_check_tag.setter
    def dep_check_tag(self, value: int) -> None:
        self._dep_check_tag = value

    @property
    def dep_set_tag(self) -> int:
        return self._dep_set_tag

    @dep_set_tag.setter
    def dep_set_tag(self, value: int) -> None:
        self._dep_set_tag = value

    def __str__(self):
        return self._node_name if self._node_name else f"Node_{self._node_id}"

    def task_desc_field_values(
        self,
        num_cores_per_cluster: int = BINGO_NUM_CORES_PER_CLUSTER,
    ) -> dict[str, int]:
        """This node's descriptor fields as plain integers.

        Keyed by the names in bingo_task_desc_fields(); the node owns its own
        encoding and the DFG only applies the shifts.
        """
        def one_hot(core_ids: list[int]) -> int:
            code = 0
            for core_id in core_ids:
                # A core id at or above the mask width would wrap into the next
                # field, so refuse rather than silently corrupt the descriptor.
                if not 0 <= core_id < num_cores_per_cluster:
                    raise ValueError(
                        f"Node '{self._node_name}' references core {core_id}, outside "
                        f"0..{num_cores_per_cluster - 1} (num_cores_per_cluster)."
                    )
                code |= 1 << core_id
            return code

        return {
            "cond_exec_invert":    int(self._cond_exec_invert),
            "cond_exec_group_id":  int(self._cond_exec_group_id),
            "cond_exec_en":        int(self._cond_exec_en),
            "task_type":           BINGO_TASK_TYPE_MAP.get(self._node_type, 0),
            "task_id":             int(self._node_id),
            "assigned_chiplet_id": int(self._assigned_chiplet_id),
            "assigned_cluster_id": int(self._assigned_cluster_id),
            "assigned_core_id":    int(self._assigned_core_id),
            "dep_check_en":        int(self._dep_check_enable),
            "dep_check_code":      one_hot(self._dep_check_list),
            "dep_check_tag":       int(self._dep_check_tag or 0),
            "dep_set_en":          int(self._dep_set_enable),
            "dep_set_all_chiplet": int(self._remote_dep_set_all),
            "dep_set_chiplet_id":  int(self._dep_set_chiplet_id),
            "dep_set_cluster_id":  int(self._dep_set_cluster_id),
            "dep_set_code":        one_hot(self._dep_set_list),
            "dep_set_tag":         int(self._dep_set_tag or 0),
        }

    def emit_sv(
        self,
        num_cores_per_cluster: int = BINGO_NUM_CORES_PER_CLUSTER,
        task_id_width: int = BINGO_TASK_ID_WIDTH,
    ) -> str:
        """Emit the SystemVerilog string for this node."""
        # Helper function to convert a list of integers to a one-hot binary string.
        # The literal must be exactly as wide as bingo_hw_manager_dep_code_t
        # (NUM_CORES_PER_CLUSTER bits). BUGFIX: this used to be a hardcoded 8,
        # so on every configuration with fewer than 8 cores the cast silently
        # truncated a literal that was wider than its own type.
        def list_to_one_hot(lst: list[int], width: int = num_cores_per_cluster) -> str:
            if (lst==[]):
                return "'0"
            one_hot = 0
            for idx in lst:
                # Same guard as the packer's one_hot() in task_desc_field_values():
                # a core id at or above the mask width sets a bit outside the
                # literal's declared width, and SystemVerilog TRUNCATES a sized
                # literal silently -- the dependency edge just disappears from the
                # stimulus with no error anywhere. Refuse instead of emitting it.
                if not 0 <= idx < width:
                    raise ValueError(
                        f"Node '{self._node_name}' references core {idx}, outside "
                        f"0..{width - 1} (num_cores_per_cluster). A dep code bit outside "
                        f"bingo_hw_manager_dep_code_t ({width} b) is silently truncated by "
                        f"SystemVerilog, so the edge would vanish from the emitted stimulus."
                    )
                one_hot |= (1 << idx)
            return f"bingo_hw_manager_dep_code_t'({width}'b{one_hot:0{width}b})"

        # Map node_type to the 2-bit task_type value, from the shared encoding.
        task_type_sv = f"{BINGO_TASK_TYPE_WIDTH}'b{BINGO_TASK_TYPE_MAP.get(self._node_type, 0):0{BINGO_TASK_TYPE_WIDTH}b}"

        # BUGFIX: the task id used to be emitted as a hardcoded 16-bit literal
        # while bingo_hw_manager_task_id_t is TaskIdWidth (12) bits, so the
        # value was silently truncated by the port cast -- harmless only while
        # ids stayed below 4096, and invisible at the point of failure. Emit it
        # at the real width and refuse ids that do not fit.
        if not 0 <= self._node_id < (1 << task_id_width):
            raise ValueError(
                f"Node '{self._node_name}' has task id {self._node_id}, which does not fit "
                f"in TaskIdWidth={task_id_width} bits (max {(1 << task_id_width) - 1}). "
                f"Raise TaskIdWidth in bingo_hw_manager_top.sv and BINGO_TASK_ID_WIDTH here."
            )
        task_id_sv = f"{task_id_width}'d{self._node_id}"

        # Per-edge identity tag args, always emitted. For pack_normal_task the
        # args are positional (dep_check_tag, dep_set_tag).
        normal_tag_args = (f"    {self._dep_check_tag}, // dep_check_tag\n"
                           f"    {self._dep_set_tag} // dep_set_tag\n")
        dcheck_tag_arg = f"    {self._dep_check_tag} // dep_check_tag\n"
        dset_tag_arg = f"    {self._dep_set_tag} // dep_set_tag\n"

        # Determine the appropriate pack function based on the node type
        if self._node_type in ("normal", "gating"):
            pack_function = "pack_normal_task"
            dep_check_code = list_to_one_hot(self._dep_check_list)
            dep_set_code = list_to_one_hot(self._dep_set_list)
            sv_str = (
                f"bingo_hw_manager_task_desc_full_t {self._node_name} = {pack_function}(\n"
                f"    {task_type_sv}, // task_type\n"
                f"    {task_id_sv}, // task_id\n"
                f"    {self._assigned_chiplet_id}, // assigned_chiplet_id\n"
                f"    {self._assigned_cluster_id}, // assigned_cluster_id\n"
                f"    {self._assigned_core_id}, // assigned_core_id\n"
                f"    1'b{int(self._dep_check_enable)}, // dep_check_en\n"
                f"    {dep_check_code}, // dep_check_code\n"
                f"    1'b{int(self._dep_set_enable)}, // dep_set_en\n"
                f"    1'b{int(self._remote_dep_set_all)}, // dep_set_all_chiplet\n"
                f"    {self._dep_set_chiplet_id}, // dep_set_chiplet_id\n"
                f"    {self._dep_set_cluster_id}, // dep_set_cluster_id\n"
                f"    {dep_set_code}, // dep_set_code\n"
                f"{normal_tag_args}"
                f");"
            )
        elif self._node_type == "dummy":
            pack_function = "pack_dummy_check_task" if self._dep_check_enable else "pack_dummy_set_task"
            if self._dep_check_enable:
                dep_check_code = list_to_one_hot(self._dep_check_list)
                sv_str = (
                    f"bingo_hw_manager_task_desc_full_t {self._node_name} = {pack_function}(\n"
                    f"    {task_type_sv}, // task_type\n"
                    f"    {task_id_sv}, // task_id\n"
                    f"    {self._assigned_chiplet_id}, // assigned_chiplet_id\n"
                    f"    {self._assigned_cluster_id}, // assigned_cluster_id\n"
                    f"    {self._assigned_core_id}, // assigned_core_id\n"
                    f"    1'b{int(self._dep_check_enable)}, // dep_check_en\n"
                    f"    {dep_check_code}, // dep_check_code\n"
                    f"{dcheck_tag_arg}"
                    f");"
                )
            else:
                dep_set_code = list_to_one_hot(self._dep_set_list)
                sv_str = (
                    f"bingo_hw_manager_task_desc_full_t {self._node_name} = {pack_function}(\n"
                    f"    {task_type_sv}, // task_type\n"
                    f"    {task_id_sv},  // task_id\n"
                    f"    {self._assigned_chiplet_id}, // assigned_chiplet_id\n"
                    f"    {self._assigned_cluster_id}, // assigned_cluster_id\n"
                    f"    {self._assigned_core_id}, // assigned_core_id\n"
                    f"    1'b{int(self._dep_set_enable)}, // dep_set_en\n"
                    f"    1'b{int(self._remote_dep_set_all)}, // dep_set_all_chiplet\n"
                    f"    {self._dep_set_chiplet_id}, // dep_set_chiplet_id\n"
                    f"    {self._dep_set_cluster_id}, // dep_set_cluster_id\n"
                    f"    {dep_set_code}, // dep_set_code\n"
                    f"{dset_tag_arg}"
                    f");"
                )
        else:
            raise ValueError(f"Unsupported node type: {self._node_type}")

        return sv_str