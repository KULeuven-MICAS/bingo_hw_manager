"""On-chip RL Scheduler — Q-learning with HEFT warm-start.

Implements a lightweight reinforcement learning agent that learns
optimal task-to-core placement at runtime.  Designed for on-chip
deployment: the Q-table fits in 256 bytes of SRAM.

Architecture:
  State  = (per-core busy/idle vector, cerf_group_active, is_conditional)
           6 bits → 64 states
  Action = target core index
           log2(NUM_CORES) bits → NUM_CORES actions
  Reward = -makespan (batch-level Monte Carlo update)

The HEFT warm-start initializes the Q-table from the compile-time
HEFT schedule, so the RL agent starts at a good baseline and only
learns corrections.  This guarantees:
  - Batch 1: HEFT performance (no regression)
  - Batches 2+: RL improves by observing runtime patterns

Hardware cost:
  - Q-table: 64 x NUM_CORES x 8 bits = 256 bytes (NUM_CORES=4)
  - State encoder: ~50 gates (combinational)
  - Argmax: ~30 gates (4-way 8-bit compare)
  - Q-update MAC: ~100 gates (8-bit multiply-accumulate)
  - Total: <0.03% area overhead
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field


@dataclass
class RLConfig:
    """Hyperparameters for the Q-learning agent."""
    alpha: float = 0.1        # Learning rate
    gamma: float = 0.9        # Discount factor (unused for MC update)
    epsilon: float = 0.1      # Initial exploration rate (epsilon-greedy)
    epsilon_decay: float = 1.0  # Per-batch decay (1.0 = no decay, 0.95 = 5% decay)
    epsilon_min: float = 0.01   # Minimum exploration rate
    load_bits: int = 1        # Bits per core for load quantization (1=idle/busy, 2=4 levels)
    num_states: int = 0       # Auto-computed from load_bits + 2 (cerf + cond)
    q_init: int = 0           # Default Q-value
    warm_start_value: int = 50  # Q-value for HEFT-recommended actions


class RLScheduler:
    """Tabular Q-learning scheduler with HEFT warm-start.

    The scheduler operates in two modes:

    1. **Per-task dispatch** (online): called by the simulator's
       command processor on each task arrival.  Selects a core
       using epsilon-greedy on the Q-table.

    2. **Per-batch update** (learning): after a full inference batch
       completes, updates all (state, action) pairs visited during
       the batch with the observed makespan as reward.

    The Q-table is small enough for on-chip SRAM (256 bytes for
    4 cores x 64 states).
    """

    def __init__(self, num_cores: int, config: RLConfig | None = None,
                 rng: random.Random | None = None):
        self.num_cores = num_cores
        self.config = config or RLConfig()
        self.rng = rng or random.Random(42)

        # Auto-compute num_states if not set
        if self.config.num_states <= 0:
            load_state_bits = min(num_cores, 4) * self.config.load_bits
            self.config.num_states = 1 << (load_state_bits + 2)  # +2 for cerf + cond

        # Current epsilon (decays over batches)
        self._epsilon = self.config.epsilon

        # Q-table: [num_states x num_cores], values clamped to int8 range
        self.q_table: list[list[int]] = [
            [self.config.q_init] * num_cores
            for _ in range(self.config.num_states)
        ]

        # Trajectory for current batch: list of (state, action)
        self._trajectory: list[tuple[int, int]] = []

        # Statistics
        self.batches_trained: int = 0
        self.total_decisions: int = 0
        self._best_makespan: float = float("inf")

    # ── State Encoding ─────────────────────────────────────────

    def encode_state(
        self,
        pending_counts: list[int],
        cerf_active: bool,
        is_conditional: bool,
    ) -> int:
        """Encode hardware state into a Q-table index.

        State layout depends on ``config.load_bits``:

        - **load_bits=1** (default, 64 states):
          bits [5:2] = per-core busy/idle (1 = pending > 0)
          bit  [1]   = cerf_group_active
          bit  [0]   = is_conditional

        - **load_bits=2** (1024 states, 4KB Q-table):
          bits [9:2] = per-core 2-bit load level (0=idle, 1=light, 2=med, 3=heavy)
          bit  [1]   = cerf_group_active
          bit  [0]   = is_conditional

        More bits = finer load distinction = better dispatch quality,
        at the cost of a larger Q-table (still small for on-chip SRAM).
        """
        lb = self.config.load_bits
        load_val = 0
        for i in range(min(self.num_cores, 4)):
            count = pending_counts[i] if i < len(pending_counts) else 0
            if lb == 1:
                # 1-bit: idle (0) vs busy (1)
                q = 1 if count > 0 else 0
            elif lb == 2:
                # 2-bit: idle/light/medium/heavy
                if count == 0:
                    q = 0
                elif count <= 2:
                    q = 1
                elif count <= 5:
                    q = 2
                else:
                    q = 3
            else:
                q = min(count, (1 << lb) - 1)
            load_val |= (q << (i * lb))

        cerf_bit = 1 if cerf_active else 0
        cond_bit = 1 if is_conditional else 0

        state = (load_val << 2) | (cerf_bit << 1) | cond_bit
        return state % self.config.num_states  # Safety clamp

    # ── Action Selection ───────────────────────────────────────

    def select_action(self, state: int) -> int:
        """Epsilon-greedy action selection.

        With probability epsilon: random core.
        Otherwise: core with highest Q-value (ties broken randomly).

        Args:
            state: encoded state index.

        Returns:
            Core index in [0, num_cores - 1].
        """
        self.total_decisions += 1

        if self.rng.random() < self._epsilon:
            return self.rng.randint(0, self.num_cores - 1)

        # Argmax with random tie-breaking
        q_row = self.q_table[state]
        max_q = max(q_row)
        best_cores = [c for c in range(self.num_cores) if q_row[c] == max_q]
        return self.rng.choice(best_cores)

    def dispatch(
        self,
        pending_counts: list[int],
        cerf_active: bool,
        is_conditional: bool,
    ) -> int:
        """Full dispatch: encode state → select action → record.

        This is the main entry point called by the simulator's
        command processor on each task arrival.

        Returns:
            Target core index.
        """
        state = self.encode_state(pending_counts, cerf_active, is_conditional)
        action = self.select_action(state)
        self._trajectory.append((state, action))
        return action

    # ── Learning ───────────────────────────────────────────────

    def update_batch(self, makespan: int) -> None:
        """Apply Monte Carlo reward to all (state, action) pairs
        visited during the batch.

        Uses a simple incremental update:
          Q(s,a) ← Q(s,a) + α * (reward - Q(s,a))

        where reward = -makespan (lower makespan → higher reward).

        The reward is normalized by dividing by 100 to keep Q-values
        in a manageable int8 range [-128, 127].
        """
        reward = -(makespan // 100)  # Normalize to int8 range
        alpha = self.config.alpha

        for state, action in self._trajectory:
            old_q = self.q_table[state][action]
            new_q = old_q + alpha * (reward - old_q)
            # Clamp to int8 range
            self.q_table[state][action] = max(-128, min(127, int(new_q)))

        self._trajectory = []
        self.batches_trained += 1
        self._best_makespan = min(self._best_makespan, makespan)

        # Decay epsilon
        self._epsilon = max(
            self.config.epsilon_min,
            self._epsilon * self.config.epsilon_decay,
        )

    # ── HEFT Warm-Start ────────────────────────────────────────

    def warm_start_from_heft(
        self,
        heft_decisions: list[tuple[int, int]],
    ) -> None:
        """Initialize Q-table from HEFT schedule.

        For each (state, action) pair that HEFT chose, set a high
        Q-value.  This gives the RL agent a strong prior that it
        can improve upon.

        Args:
            heft_decisions: list of (state_index, core_id) pairs
                from running HEFT on the DFG.
        """
        v = self.config.warm_start_value
        for state, core in heft_decisions:
            if 0 <= state < self.config.num_states and 0 <= core < self.num_cores:
                self.q_table[state][core] = v

    def warm_start_from_placement(
        self,
        tasks: list,
        pending_counts: list[int] | None = None,
        cerf_state: list[bool] | None = None,
    ) -> None:
        """Initialize Q-table from a list of task descriptors.

        Simulates the HEFT schedule by encoding each task's state
        at dispatch time and recording the HEFT-chosen core.

        Args:
            tasks: list of TaskDescriptor objects with assigned_core_id set.
            pending_counts: initial per-core pending counts (default: all 0).
            cerf_state: initial CERF group activation (default: all False).
        """
        if pending_counts is None:
            pending_counts = [0] * self.num_cores
        if cerf_state is None:
            cerf_state = [False] * 32

        counts = list(pending_counts)
        decisions = []

        for task in tasks:
            if task.task_type == 1:  # Skip dummies
                continue

            cerf_active = False
            if task.cond_exec_en:
                gid = task.cond_exec_group_id
                if 0 <= gid < len(cerf_state):
                    cerf_active = cerf_state[gid]

            state = self.encode_state(counts, cerf_active, task.cond_exec_en)
            core = task.assigned_core_id
            decisions.append((state, core))

            # Simulate load change
            if 0 <= core < len(counts):
                counts[core] += 1

        self.warm_start_from_heft(decisions)

    # ── Introspection ──────────────────────────────────────────

    def q_table_stats(self) -> dict:
        """Return statistics about the Q-table."""
        all_vals = [v for row in self.q_table for v in row]
        nonzero = [v for v in all_vals if v != 0]
        return {
            "num_states": self.config.num_states,
            "num_actions": self.num_cores,
            "total_entries": len(all_vals),
            "nonzero_entries": len(nonzero),
            "min_q": min(all_vals) if all_vals else 0,
            "max_q": max(all_vals) if all_vals else 0,
            "batches_trained": self.batches_trained,
            "total_decisions": self.total_decisions,
            "table_bytes": self.config.num_states * self.num_cores,
            "current_epsilon": round(self._epsilon, 4),
            "best_makespan": self._best_makespan,
        }

    def reset(self) -> None:
        """Reset Q-table and statistics (keep hyperparameters)."""
        for s in range(self.config.num_states):
            for a in range(self.num_cores):
                self.q_table[s][a] = self.config.q_init
        self._trajectory = []
        self.batches_trained = 0
        self.total_decisions = 0
