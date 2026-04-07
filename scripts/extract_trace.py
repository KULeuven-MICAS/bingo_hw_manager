#!/usr/bin/env python3
"""Extract [TRACE] lines from vsim simulation log into a clean CSV."""

import argparse
import re
import sys


def extract_trace(input_path: str, output_path: str):
    """Parse [TRACE] lines from vsim.log and write clean CSV."""
    pattern = re.compile(r"\[TRACE\]\s*(.+)")
    count = 0

    with open(input_path) as fin, open(output_path, "w") as fout:
        fout.write("# time,event_type,chiplet,cluster,core,task_id\n")
        for line in fin:
            m = pattern.search(line)
            if m:
                fout.write(m.group(1).strip() + "\n")
                count += 1

    print(f"Extracted {count} trace events from {input_path} → {output_path}")


def main():
    parser = argparse.ArgumentParser(description="Extract RTL trace from vsim log")
    parser.add_argument("input", help="Path to vsim.log or simulation log")
    parser.add_argument("-o", "--output", default="rtl_trace.csv",
                        help="Output CSV path (default: rtl_trace.csv)")
    args = parser.parse_args()
    extract_trace(args.input, args.output)


if __name__ == "__main__":
    main()
