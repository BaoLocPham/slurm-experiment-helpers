"""Dependency-free wiring example: estimate E[X²] for a standard normal X.

Replace this with your actual experiment. This does not train a model.
"""

import argparse
import json
import random
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--samples", type=int, default=1000)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.samples < 1:
        parser.error("--samples must be positive")
    rng = random.Random(args.seed)
    result = {
        "seed": args.seed,
        "samples": args.samples,
        "mean_square": sum(rng.gauss(0, 1) ** 2 for _ in range(args.samples)) / args.samples,
    }
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "metrics.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
