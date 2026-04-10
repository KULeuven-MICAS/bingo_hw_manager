"""Unit tests for the counter-based dependency matrix model."""

import pytest
from model.bingo_sim_dep_matrix import DepMatrix


def row_bitmask(dm, row):
    """Convert a counter row to a bitmask (bit c = 1 if counter[row][c] >= 1)."""
    mask = 0
    for c in range(dm.cols):
        if dm.counters[row][c] >= 1:
            mask |= (1 << c)
    return mask


class TestDepMatrix:
    def test_initial_state(self):
        dm = DepMatrix(4, 4)
        assert dm.is_empty()
        for r in range(4):
            assert row_bitmask(dm, r) == 0

    def test_set_column_basic(self):
        dm = DepMatrix(3, 3)
        # Set column 0 with set_code = 0b010 (row 1 depends on col 0)
        result = dm.set_column(0, 0b010)
        assert result is True
        assert row_bitmask(dm, 1) == 0b001  # bit 0 set in row 1

    def test_check_row_pass(self):
        dm = DepMatrix(3, 3)
        # Set: row 0 depends on col 1 (counter[0][1] = 1)
        dm.set_column(1, 0b001)  # set_code bit 0 → row 0, col 1
        assert row_bitmask(dm, 0) == 0b010
        # Check: row 0 with check_code = 0b010 → should pass
        assert dm.check_row(0, 0b010) is True

    def test_check_row_fail(self):
        dm = DepMatrix(3, 3)
        # Row 0 is empty
        assert dm.check_row(0, 0b010) is False

    def test_check_row_partial(self):
        dm = DepMatrix(3, 3)
        # Set only col 0 bit for row 1
        dm.set_column(0, 0b010)
        # Check row 1 for both col 0 and col 1
        assert dm.check_row(1, 0b011) is False  # col 1 not set
        assert dm.check_row(1, 0b001) is True   # col 0 is set

    def test_clear_row(self):
        dm = DepMatrix(3, 3)
        dm.set_column(0, 0b010)  # row 1, col 0
        dm.set_column(1, 0b010)  # row 1, col 1
        assert row_bitmask(dm, 1) == 0b011

        # Clear only col 0 from row 1
        dm.clear_row(1, 0b001)
        assert row_bitmask(dm, 1) == 0b010  # col 1 still set

    def test_counter_accumulation(self):
        """Counter-based: duplicate set_column increments counter, always succeeds."""
        dm = DepMatrix(3, 3)
        # Set col 0, row 1
        result1 = dm.set_column(0, 0b010)
        assert result1 is True
        assert dm.counters[1][0] == 1

        # Set col 0, row 1 again → counter increments to 2
        result2 = dm.set_column(0, 0b010)
        assert result2 is True
        assert dm.counters[1][0] == 2

        # Clear once: counter goes to 1 (still satisfies check)
        dm.clear_row(1, 0b001)
        assert dm.counters[1][0] == 1
        assert dm.check_row(1, 0b001) is True

        # Clear again: counter goes to 0
        dm.clear_row(1, 0b001)
        assert dm.counters[1][0] == 0
        assert dm.check_row(1, 0b001) is False

    def test_no_overlap_different_rows(self):
        dm = DepMatrix(3, 3)
        # Set col 0, row 1
        dm.set_column(0, 0b010)
        # Set col 0, row 2 → no overlap (different row)
        result = dm.set_column(0, 0b100)
        assert result is True
        assert row_bitmask(dm, 1) == 0b001
        assert row_bitmask(dm, 2) == 0b001

    def test_accumulate_dependencies(self):
        dm = DepMatrix(4, 4)
        # Row 0 depends on col 0 and col 2
        dm.set_column(0, 0b0001)  # set row 0, col 0
        dm.set_column(2, 0b0001)  # set row 0, col 2
        assert row_bitmask(dm, 0) == 0b0101

        # Check with full dep code
        assert dm.check_row(0, 0b0101) is True
        assert dm.check_row(0, 0b0001) is True  # subset
        assert dm.check_row(0, 0b0111) is False  # col 1 not set

    def test_clear_preserves_unchecked(self):
        """Mirrors dep_matrix.sv: clear only checked bits, preserve others."""
        dm = DepMatrix(3, 3)
        dm.set_column(0, 0b001)  # row 0, col 0
        dm.set_column(1, 0b001)  # row 0, col 1
        dm.set_column(2, 0b001)  # row 0, col 2
        assert row_bitmask(dm, 0) == 0b111

        # Clear only bits 0 and 2
        dm.clear_row(0, 0b101)
        assert row_bitmask(dm, 0) == 0b010  # only col 1 remains

    def test_check_with_zero_code(self):
        """check_code=0 should always pass (no dependencies)."""
        dm = DepMatrix(3, 3)
        assert dm.check_row(0, 0) is True

    def test_dump_state(self):
        dm = DepMatrix(2, 2)
        dm.set_column(0, 0b01)
        state = dm.dump_state()
        assert "Row 0" in state
        assert "Row 1" in state
