"""FIFO Queue Model with depth constraints and backpressure."""

from collections import deque
from typing import Any, Optional


class FifoQueue:
    """Models a hardware FIFO queue with configurable depth."""

    def __init__(self, name: str, depth: int):
        self.name = name
        self.depth = depth
        self.items: deque = deque()

    def push(self, item: Any) -> bool:
        """Push item. Returns False if full (backpressure)."""
        if len(self.items) >= self.depth:
            return False
        self.items.append(item)
        return True

    def pop(self) -> Optional[Any]:
        """Pop head item. Returns None if empty."""
        if not self.items:
            return None
        return self.items.popleft()

    def peek(self) -> Optional[Any]:
        """Look at head without removing. Returns None if empty."""
        if not self.items:
            return None
        return self.items[0]

    @property
    def full(self) -> bool:
        return len(self.items) >= self.depth

    @property
    def empty(self) -> bool:
        return len(self.items) == 0

    @property
    def count(self) -> int:
        return len(self.items)

    def __repr__(self) -> str:
        return f"FifoQueue({self.name}, {self.count}/{self.depth})"
