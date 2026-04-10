"""
Counter-Based Dependency Matrix Model — mirrors bingo_hw_manager_dep_matrix.sv.

Each cell is an 8-bit saturating counter (not a 1-bit flag). Multiple
set_column operations accumulate without rejection, eliminating the
deadlock caused by overlap detection in the original 1-bit design.

Operations:
  - check_row(row, check_code): True if counter[row][c] >= 1 for all c in check_code
  - set_column(col, set_code): increment counter[r][col] for each r in set_code (always succeeds)
  - clear_row(row, check_code): decrement counter[row][c] for each c in check_code
"""


class DepMatrix:
    def __init__(self, rows: int, cols: int):
        self.rows = rows
        self.cols = cols
        # 8-bit saturating counter per cell
        self.counters: list[list[int]] = [[0] * cols for _ in range(rows)]

    def check_row(self, row: int, check_code: int) -> bool:
        """Check if all required dependencies are satisfied (counter >= 1).

        Mirrors dep_matrix.sv:
          dep_check_result_o[r] = all(counter_q[r][c] >= 1 for c where check_code[c]=1)
        """
        for c in range(self.cols):
            if (check_code >> c) & 1:
                if self.counters[row][c] < 1:
                    return False
        return True

    def set_column(self, col: int, set_code: int) -> bool:
        """Increment counters. Always succeeds (no overlap rejection).

        Mirrors dep_matrix.sv:
          counter_d[r][col] = counter_q[r][col] + 1  (saturating at 255)
          dep_set_ready_o = '1  (always ready)
        """
        for r in range(self.rows):
            if (set_code >> r) & 1:
                if self.counters[r][col] < 255:
                    self.counters[r][col] += 1
        return True  # Always ready

    def clear_row(self, row: int, check_code: int):
        """Decrement counters for the checked bits.

        Mirrors dep_matrix.sv:
          counter_d[r][c] = counter_q[r][c] - 1
        """
        for c in range(self.cols):
            if (check_code >> c) & 1:
                if self.counters[row][c] > 0:
                    self.counters[row][c] -= 1

    def dump_state(self) -> str:
        """Human-readable matrix state."""
        lines = []
        for r in range(self.rows):
            vals = " ".join(f"{self.counters[r][c]:3d}" for c in range(self.cols))
            lines.append(f"  Row {r} (Core {r} depends on): [{vals}]")
        return "\n".join(lines)

    def is_empty(self) -> bool:
        """Check if all entries are zero."""
        return all(
            self.counters[r][c] == 0
            for r in range(self.rows)
            for c in range(self.cols)
        )
