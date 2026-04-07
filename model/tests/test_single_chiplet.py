"""Integration tests: single-chiplet DFG scenarios."""

import sys
import os

# Add parent directories to path for imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..'))

from model.bingo_sim import BingoSimulator, SimConfig, QueueDepths
from model.bingo_sim_chiplet import TaskDescriptor


def make_task(task_id, cluster, core, dep_check_en=False, dep_check_code=0,
              dep_set_en=False, dep_set_code=0, dep_set_cluster=0,
              task_type=0, dep_set_chiplet=0):
    return TaskDescriptor(
        task_type=task_type,
        task_id=task_id,
        assigned_chiplet_id=0,
        assigned_cluster_id=cluster,
        assigned_core_id=core,
        dep_check_en=dep_check_en,
        dep_check_code=dep_check_code,
        dep_set_en=dep_set_en,
        dep_set_all_chiplet=False,
        dep_set_chiplet_id=dep_set_chiplet,
        dep_set_cluster_id=dep_set_cluster,
        dep_set_code=dep_set_code,
    )


class TestSerialChain:
    """Test A → B → C linear chain on alternating cores within one cluster."""

    def test_simple_chain_3_tasks(self):
        config = SimConfig(
            num_chiplets=1,
            num_clusters_per_chiplet=1,
            num_cores_per_cluster=3,
            work_delay_range=(10, 10),  # fixed delay for determinism
            random_seed=42,
        )
        sim = BingoSimulator(config)

        # Task 1 on core 0 → sets core 1
        # Task 2 on core 1 (checks core 0) → sets core 2
        # Task 3 on core 2 (checks core 1) → no dep set
        tasks = [
            make_task(1, 0, 0, dep_set_en=True, dep_set_code=0b010, dep_set_cluster=0),
            make_task(2, 0, 1, dep_check_en=True, dep_check_code=0b001,
                      dep_set_en=True, dep_set_code=0b100, dep_set_cluster=0),
            make_task(3, 0, 2, dep_check_en=True, dep_check_code=0b010),
        ]
        sim.load_tasks({0: tasks})
        result = sim.run()

        assert not result.deadlock_detected
        assert result.completed_task_ids == {1, 2, 3}

        # Verify ordering: task 1 done before task 2, task 2 before task 3
        done_order = result.trace.task_completion_order()
        assert done_order.index(1) < done_order.index(2)
        assert done_order.index(2) < done_order.index(3)


class TestParallelFork:
    """Test fork: A → B, A → C (B and C are independent)."""

    def test_two_parallel_tasks(self):
        config = SimConfig(
            num_chiplets=1,
            num_clusters_per_chiplet=1,
            num_cores_per_cluster=3,
            work_delay_range=(10, 10),
            random_seed=42,
        )
        sim = BingoSimulator(config)

        # Task 1 on core 0, sets core 1 (via dummy set for local multi-successor)
        # Task 2 on core 1 (checks core 0)
        # Task 3 on core 2 (checks core 0)
        # Dummy set from core 0 to core 2
        tasks = [
            make_task(1, 0, 0, dep_set_en=True, dep_set_code=0b010, dep_set_cluster=0),
            make_task(10, 0, 0, task_type=1, dep_set_en=True, dep_set_code=0b100,
                      dep_set_cluster=0, dep_set_chiplet=0),
            make_task(2, 0, 1, dep_check_en=True, dep_check_code=0b001),
            make_task(3, 0, 2, dep_check_en=True, dep_check_code=0b001),
        ]
        sim.load_tasks({0: tasks})
        result = sim.run()

        assert not result.deadlock_detected
        assert result.completed_task_ids == {1, 2, 3}

        # Task 1 must complete before task 2 and task 3
        done_order = result.trace.task_completion_order()
        assert done_order.index(1) < done_order.index(2)
        assert done_order.index(1) < done_order.index(3)


class TestNoDependency:
    """Test tasks with no dependencies (should all execute immediately)."""

    def test_independent_tasks(self):
        config = SimConfig(
            num_chiplets=1,
            num_clusters_per_chiplet=1,
            num_cores_per_cluster=3,
            work_delay_range=(5, 5),
            random_seed=0,
        )
        sim = BingoSimulator(config)

        tasks = [
            make_task(1, 0, 0),
            make_task(2, 0, 1),
            make_task(3, 0, 2),
        ]
        sim.load_tasks({0: tasks})
        result = sim.run()

        assert not result.deadlock_detected
        assert result.completed_task_ids == {1, 2, 3}


class TestDummyCheckNode:
    """Test dummy check node handling."""

    def test_dummy_check(self):
        config = SimConfig(
            num_chiplets=1,
            num_clusters_per_chiplet=1,
            num_cores_per_cluster=3,
            work_delay_range=(10, 10),
            random_seed=42,
        )
        sim = BingoSimulator(config)

        # Task 1 on core 0 → sets core 1
        # Task 2 on core 1 → sets core 0
        # Dummy check on core 0 (checks core 1)
        # Task 3 on core 0 (checks core 1) — after dummy check clears
        tasks = [
            make_task(1, 0, 0, dep_set_en=True, dep_set_code=0b010, dep_set_cluster=0),
            make_task(2, 0, 1, dep_check_en=True, dep_check_code=0b001,
                      dep_set_en=True, dep_set_code=0b001, dep_set_cluster=0),
            make_task(10, 0, 0, task_type=1, dep_check_en=True, dep_check_code=0b010),
            make_task(3, 0, 0, dep_check_en=True, dep_check_code=0b010),
        ]
        sim.load_tasks({0: tasks})
        result = sim.run()

        assert not result.deadlock_detected
        assert result.completed_task_ids == {1, 2, 3}
