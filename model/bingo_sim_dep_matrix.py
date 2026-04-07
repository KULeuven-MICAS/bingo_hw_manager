"""
Dependency Matrix Model — mirrors bingo_hw_manager_dep_matrix.sv exactly.

The matrix has ROWS (one per core, representing consumers/dependent tasks)
and COLS (one per core, representing producers/dependency sources).

matrix[row][col] = 1 means: core `row` is waiting for a signal from core `col`.

Operations:
  - check_row(row, check_code): returns True if all bits in check_code are set in matrix[row]
  - set_column(col, set_code): OR set_code bits into rows at column col (with overlap detection)
  - clear_row(row, check_code): clears only the checked bits from matrix[row]
"""


class DepMatrix:
    def __init__(self, rows: int, cols: int):
        self.rows = rows
        self.cols = cols
        # Each row is a bitmask of width `cols`
        self.matrix: list[int] = [0] * rows

    def check_row(self, row: int, check_code: int) -> bool:
        """Check if all required dependencies are satisfied.

        Mirrors dep_matrix.sv line 101:
          dep_check_result_o[r] = ((dep_matrix_q[r] & dep_check_code_i[r]) == dep_check_code_i[r])
        """
        return (self.matrix[row] & check_code) == check_code

    def set_column(self, col: int, set_code: int) -> bool:
        """Set dependency bits in the matrix column.

        For each row r, if set_code bit r is 1, set matrix[r][col] = 1.
        Returns False if overlap detected (any target bit already 1).

        Mirrors dep_matrix.sv lines 40-70:
          overlap_find: if dep_matrix_q[r][c] && dep_set_code_i[c][r] => overlap
          dep_set_ready_o[c] = ~overlap_find[c]
          if valid && ready: dep_matrix_d[r][c] |= dep_set_code_i[c][r]
        """
        col_bit = 1 << col

        # Overlap detection: check if any target row already has the col bit set
        for r in range(self.rows):
            if (set_code >> r) & 1:
                if self.matrix[r] & col_bit:
                    return False  # Overlap: ready = 0

        # No overlap: perform the set
        for r in range(self.rows):
            if (set_code >> r) & 1:
                self.matrix[r] |= col_bit

        return True  # ready = 1

    def clear_row(self, row: int, check_code: int):
        """Clear only the bits that were checked (and satisfied).

        Mirrors dep_matrix.sv line 83:
          dep_matrix_q[r] <= dep_matrix_d[r] & ~dep_check_code_i[r]
        """
        self.matrix[row] &= ~check_code

    def dump_state(self) -> str:
        """Human-readable matrix state."""
        lines = []
        for r in range(self.rows):
            bits = format(self.matrix[r], f'0{self.cols}b')
            lines.append(f"  Row {r} (Core {r} depends on): {bits}")
        return "\n".join(lines)

    def is_empty(self) -> bool:
        """Check if all entries are zero."""
        return all(row == 0 for row in self.matrix)
