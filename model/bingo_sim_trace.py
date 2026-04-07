"""Event trace recording, CSV export, and RTL comparison."""

from __future__ import annotations

import csv
import re
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class SimEvent:
    """A single simulation event matching the RTL [TRACE] format."""
    time: int
    event_type: str  # TASK_PUSHED, DEP_CHECK_PASS, TASK_DISPATCHED, TASK_DONE, DEP_SET
    chiplet_id: int
    cluster_id: int
    core_id: int
    task_id: int
    extra: dict = field(default_factory=dict)

    def to_csv_row(self) -> str:
        extra_str = ""
        if self.extra:
            extra_str = "," + ",".join(f"{k}={v}" for k, v in self.extra.items())
        return (f"{self.time},{self.event_type},{self.chiplet_id},"
                f"{self.cluster_id},{self.core_id},{self.task_id}{extra_str}")

    def key(self) -> tuple:
        """Comparison key (ignoring time for ordering comparison)."""
        return (self.event_type, self.chiplet_id, self.cluster_id,
                self.core_id, self.task_id)


@dataclass
class ComparisonResult:
    """Result of comparing two event traces."""
    match: bool
    num_events_compared: int
    first_divergence_index: Optional[int] = None
    first_divergence_detail: Optional[str] = None
    rtl_only_events: list[SimEvent] = field(default_factory=list)
    model_only_events: list[SimEvent] = field(default_factory=list)

    def summary(self) -> str:
        if self.match:
            return f"MATCH: {self.num_events_compared} events compared, all identical."
        lines = [f"MISMATCH at event index {self.first_divergence_index}:"]
        if self.first_divergence_detail:
            lines.append(f"  {self.first_divergence_detail}")
        if self.rtl_only_events:
            lines.append(f"  RTL-only events: {len(self.rtl_only_events)}")
        if self.model_only_events:
            lines.append(f"  Model-only events: {len(self.model_only_events)}")
        return "\n".join(lines)


class EventTrace:
    """Records simulation events and supports CSV export/comparison."""

    def __init__(self):
        self.events: list[SimEvent] = []

    def record(self, event: SimEvent):
        self.events.append(event)

    def to_csv(self, path: str):
        """Write trace to CSV file in the same format as RTL [TRACE] lines."""
        with open(path, "w", newline="") as f:
            f.write("# time,event_type,chiplet,cluster,core,task_id\n")
            for event in self.events:
                f.write(event.to_csv_row() + "\n")

    @staticmethod
    def from_csv(path: str) -> EventTrace:
        """Read trace from CSV file."""
        trace = EventTrace()
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split(",")
                if len(parts) >= 6:
                    trace.events.append(SimEvent(
                        time=int(parts[0]),
                        event_type=parts[1],
                        chiplet_id=int(parts[2]),
                        cluster_id=int(parts[3]),
                        core_id=int(parts[4]),
                        task_id=int(parts[5]),
                    ))
        return trace

    @staticmethod
    def from_rtl_log(vsim_log_path: str) -> EventTrace:
        """Parse [TRACE] lines from vsim simulation log."""
        trace = EventTrace()
        pattern = re.compile(
            r"\[TRACE\]\s*(\d+),(\w+),(\d+),(\d+),(\d+),(\d+)"
        )
        with open(vsim_log_path) as f:
            for line in f:
                m = pattern.search(line)
                if m:
                    trace.events.append(SimEvent(
                        time=int(m.group(1)),
                        event_type=m.group(2),
                        chiplet_id=int(m.group(3)),
                        cluster_id=int(m.group(4)),
                        core_id=int(m.group(5)),
                        task_id=int(m.group(6)),
                    ))
        return trace

    def filter_by_type(self, *event_types: str) -> EventTrace:
        """Return a new trace with only the specified event types."""
        filtered = EventTrace()
        for e in self.events:
            if e.event_type in event_types:
                filtered.events.append(e)
        return filtered

    def compare_exact(self, other: EventTrace) -> ComparisonResult:
        """Compare two traces for exact event sequence match.

        Events are compared by: event_type, chiplet, cluster, core, task_id.
        Times are compared relatively (ordering must match, absolute values may differ).
        """
        n = min(len(self.events), len(other.events))

        for i in range(n):
            a, b = self.events[i], other.events[i]
            if a.key() != b.key():
                return ComparisonResult(
                    match=False,
                    num_events_compared=i,
                    first_divergence_index=i,
                    first_divergence_detail=(
                        f"Self:  {a.to_csv_row()}\n"
                        f"  Other: {b.to_csv_row()}"
                    ),
                )

        if len(self.events) != len(other.events):
            longer = self if len(self.events) > len(other.events) else other
            is_self_longer = len(self.events) > len(other.events)
            extra = longer.events[n:]
            return ComparisonResult(
                match=False,
                num_events_compared=n,
                first_divergence_index=n,
                first_divergence_detail=f"Length mismatch: {len(self.events)} vs {len(other.events)}",
                rtl_only_events=extra if not is_self_longer else [],
                model_only_events=extra if is_self_longer else [],
            )

        return ComparisonResult(match=True, num_events_compared=n)

    def task_completion_order(self) -> list[int]:
        """Return task_ids in the order they completed (TASK_DONE events)."""
        return [e.task_id for e in self.events if e.event_type == "TASK_DONE"]

    def total_latency(self) -> int:
        """Time from first event to last TASK_DONE event."""
        done_events = [e for e in self.events if e.event_type == "TASK_DONE"]
        if not done_events or not self.events:
            return 0
        return done_events[-1].time - self.events[0].time
