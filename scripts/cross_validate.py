#!/usr/bin/env python3
"""Cross-validate Python model trace against RTL simulation trace.

For a given DFG:
1. Run Python model → trace CSV
2. Parse RTL vsim.log → trace CSV
3. Compare event sequences
4. Report exact match or divergences
"""

import argparse
import os
import sys

_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _root)

from model.bingo_sim_trace import EventTrace


def main():
    parser = argparse.ArgumentParser(description="Cross-validate Python model vs RTL traces")
    parser.add_argument("--model-trace", required=True,
                        help="Path to Python model trace CSV")
    parser.add_argument("--rtl-log", required=True,
                        help="Path to RTL vsim.log file")
    parser.add_argument("--compare-types", default="TASK_DISPATCHED,TASK_DONE",
                        help="Comma-separated event types to compare (default: TASK_DISPATCHED,TASK_DONE)")
    args = parser.parse_args()

    # Load traces
    model_trace = EventTrace.from_csv(args.model_trace)
    rtl_trace = EventTrace.from_rtl_log(args.rtl_log)

    # Filter to comparable event types
    compare_types = set(args.compare_types.split(","))
    model_filtered = model_trace.filter_by_type(*compare_types)
    rtl_filtered = rtl_trace.filter_by_type(*compare_types)

    print(f"Model trace: {len(model_trace.events)} total, "
          f"{len(model_filtered.events)} {compare_types}")
    print(f"RTL trace:   {len(rtl_trace.events)} total, "
          f"{len(rtl_filtered.events)} {compare_types}")

    # Compare
    result = model_filtered.compare_exact(rtl_filtered)
    print(f"\n{result.summary()}")

    # Also compare task completion order
    model_order = model_filtered.task_completion_order()
    rtl_order = rtl_filtered.task_completion_order()

    if model_order == rtl_order:
        print(f"\nTask completion order: MATCH ({len(model_order)} tasks)")
    else:
        print(f"\nTask completion order: MISMATCH")
        print(f"  Model: {model_order}")
        print(f"  RTL:   {rtl_order}")

    return 0 if result.match else 1


if __name__ == "__main__":
    sys.exit(main())
