"""Gantt chart and dependency matrix timeline visualization."""

from __future__ import annotations

from typing import Optional

from .bingo_sim_trace import EventTrace, SimEvent


def plot_gantt(
    trace: EventTrace,
    num_chiplets: int,
    num_clusters: int,
    num_cores: int,
    output_path: str = "gantt_chart.png",
    figsize: tuple[int, int] = (16, 8),
):
    """Generate a Gantt chart showing per-core task execution timelines.

    X = time, Y = core (grouped by chiplet/cluster).
    Each bar = [TASK_DISPATCHED, TASK_DONE] window.
    """
    try:
        import matplotlib.pyplot as plt
        import matplotlib.patches as mpatches
    except ImportError:
        print("matplotlib not available, skipping Gantt chart generation")
        return

    # Build execution windows: (core_key, task_id, start, end)
    windows = []
    dispatch_times: dict[tuple[int, int, int, int], int] = {}

    for event in trace.events:
        key = (event.chiplet_id, event.cluster_id, event.core_id, event.task_id)
        if event.event_type == "TASK_DISPATCHED":
            dispatch_times[key] = event.time
        elif event.event_type == "TASK_DONE":
            start = dispatch_times.pop(key, event.time)
            windows.append((
                (event.chiplet_id, event.cluster_id, event.core_id),
                event.task_id,
                start,
                event.time,
            ))

    if not windows:
        print("No execution windows found in trace")
        return

    # Build Y-axis labels
    core_labels = []
    core_y_map = {}
    y = 0
    for chip in range(num_chiplets):
        for cl in range(num_clusters):
            for co in range(num_cores):
                label = f"Chip{chip}/Cl{cl}/Co{co}"
                core_labels.append(label)
                core_y_map[(chip, cl, co)] = y
                y += 1

    fig, ax = plt.subplots(figsize=figsize)

    colors = plt.cm.Set3.colors  # noqa

    for core_key, task_id, start, end in windows:
        y_pos = core_y_map.get(core_key, 0)
        color = colors[task_id % len(colors)]
        ax.barh(y_pos, end - start, left=start, height=0.6,
                color=color, edgecolor='black', linewidth=0.5)
        ax.text(start + (end - start) / 2, y_pos, str(task_id),
                ha='center', va='center', fontsize=7)

    ax.set_yticks(range(len(core_labels)))
    ax.set_yticklabels(core_labels, fontsize=8)
    ax.set_xlabel("Time (cycles)")
    ax.set_title("Bingo HW Manager — Task Execution Gantt Chart")
    ax.invert_yaxis()
    ax.grid(axis='x', alpha=0.3)

    # Compute and display total latency
    total = trace.total_latency()
    ax.text(0.99, 0.01, f"Total latency: {total} cycles",
            transform=ax.transAxes, ha='right', va='bottom', fontsize=10,
            bbox=dict(boxstyle='round', facecolor='wheat', alpha=0.5))

    plt.tight_layout()
    plt.savefig(output_path, dpi=150)
    plt.close()
    print(f"Gantt chart saved to {output_path}")


def plot_dep_matrix_timeline(
    trace: EventTrace,
    num_clusters: int,
    num_cores: int,
    output_path: str = "dep_matrix_timeline.png",
    figsize: tuple[int, int] = (14, 6),
):
    """Heatmap showing dep matrix state over time for each cluster.

    Reconstructs dep matrix state from DEP_CHECK_PASS and DEP_SET events.
    """
    try:
        import matplotlib.pyplot as plt
        import numpy as np
    except ImportError:
        print("matplotlib/numpy not available, skipping dep matrix timeline")
        return

    # Reconstruct dep matrix evolution from events
    # This is a simplified view — shows when deps are set and cleared
    dep_set_events = [e for e in trace.events if e.event_type in ("DEP_SET", "DEP_SET_CHIPLET_RECV")]
    dep_check_events = [e for e in trace.events if e.event_type == "DEP_CHECK_PASS"]

    if not dep_set_events and not dep_check_events:
        print("No dependency events found")
        return

    fig, axes = plt.subplots(1, num_clusters, figsize=figsize, squeeze=False)

    for cl in range(num_clusters):
        ax = axes[0][cl]
        cl_set = [e for e in dep_set_events if e.cluster_id == cl]
        cl_check = [e for e in dep_check_events if e.cluster_id == cl]

        # Plot set events as upward arrows, check events as downward
        set_times = [e.time for e in cl_set]
        set_cores = [e.core_id for e in cl_set]
        check_times = [e.time for e in cl_check]
        check_cores = [e.core_id for e in cl_check]

        ax.scatter(set_times, set_cores, marker='^', c='red', s=30, label='DEP_SET')
        ax.scatter(check_times, check_cores, marker='v', c='green', s=30, label='DEP_CHECK_PASS')

        ax.set_xlabel("Time (cycles)")
        ax.set_ylabel("Core ID")
        ax.set_title(f"Cluster {cl}")
        ax.set_yticks(range(num_cores))
        ax.legend(fontsize=7)
        ax.grid(alpha=0.3)

    plt.suptitle("Dependency Events Timeline")
    plt.tight_layout()
    plt.savefig(output_path, dpi=150)
    plt.close()
    print(f"Dep matrix timeline saved to {output_path}")
