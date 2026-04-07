#!/usr/bin/env python3
"""Generate a DFG pattern, emit SV testbench, and run Python model simulation."""

import argparse
import os
import sys

# Add paths
_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_bingo_root = os.path.dirname(_root)
sys.path.insert(0, os.path.join(_root, 'sw'))
sys.path.insert(0, _bingo_root)

from codegen.test_dfg_patterns import PATTERN_CATALOG
from codegen.emit_sv_testbench import emit_sv_testbench, emit_sv_top_wrapper


def main():
    parser = argparse.ArgumentParser(description="Generate DFG pattern + SV testbench")
    parser.add_argument("--pattern", required=True, choices=list(PATTERN_CATALOG.keys()),
                        help="DFG pattern name")
    parser.add_argument("--output-dir", default=os.path.join(_root, "test", "generated"),
                        help="Output directory for generated files")
    parser.add_argument("--deadlock-threshold", type=int, default=2000,
                        help="Deadlock detection threshold in cycles")
    args = parser.parse_args()

    factory, kwargs = PATTERN_CATALOG[args.pattern]
    dfg = factory(**kwargs)

    stim_name = f"tb_stimulus_{args.pattern}.svh"
    emit_sv_testbench(
        dfg, args.output_dir, stim_name,
        deadlock_threshold=args.deadlock_threshold,
        dfg_name=args.pattern,
    )
    emit_sv_top_wrapper(
        dfg, args.output_dir, args.pattern, stim_name,
    )

    print(f"\nTo simulate:\n  cd {_root}")
    print(f"  make sim-dfg TB=bingo_hw_manager_{args.pattern}")


if __name__ == "__main__":
    main()
