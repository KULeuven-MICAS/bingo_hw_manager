"""Core Execution Model — simulates a hardware core with configurable delays."""

import random
from typing import Optional


class CoreModel:
    """Models a single execution core (GEMM, DMA, or host)."""

    def __init__(
        self,
        chiplet_id: int,
        cluster_id: int,
        core_id: int,
        rng: random.Random,
        delay_range: tuple[int, int] = (20, 50),
    ):
        self.chiplet_id = chiplet_id
        self.cluster_id = cluster_id
        self.core_id = core_id
        self.rng = rng
        self.delay_range = delay_range
        self.state: str = "idle"  # "idle", "executing"
        self.current_task_id: Optional[int] = None

    def dispatch(self, task_id: int, current_time: int) -> int:
        """Start executing a task. Returns the completion time."""
        self.state = "executing"
        self.current_task_id = task_id
        delay = self.rng.randint(*self.delay_range)
        return current_time + delay

    def complete(self) -> int:
        """Complete execution. Returns the task_id that was completed."""
        assert self.state == "executing", f"Core {self.core_id} not executing"
        task_id = self.current_task_id
        self.state = "idle"
        self.current_task_id = None
        return task_id

    @property
    def is_idle(self) -> bool:
        return self.state == "idle"

    def __repr__(self) -> str:
        return (f"Core(chip={self.chiplet_id}, cl={self.cluster_id}, "
                f"co={self.core_id}, state={self.state}, task={self.current_task_id})")
