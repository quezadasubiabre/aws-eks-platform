"""
Sustained load test: for ~7 minutes, repeatedly fire a RANDOM number of
concurrent requests (1 to MAX_BATCH_SIZE) at the vLLM endpoint, back to back,
with no pause between rounds. Every individual request's timing and token
counts are logged to a CSV file for graphing afterward - this script doesn't
draw any charts itself, it just produces the raw data.

Why random batch sizes, repeated over several minutes, instead of one fixed
comparison (see chat.py for the simpler sequential-vs-single-shot version):
this is meant to approximate bursty, uneven real traffic rather than a single
clean A/B measurement, and to run long enough to see how vLLM's queue and
latency behave as load keeps varying round after round - not just a single
snapshot. Concurrency in each round ranges 1-8, matching the 8 distinct
prompts in chat.py's PROMPTS list.

What gets logged per request (one row per request, not per round):
    timestamp        - wall-clock time the request was sent (ISO 8601)
    round            - which round (1, 2, 3, ...) this request belongs to
    batch_size       - how many concurrent requests were in this round
    prompt           - the prompt text sent
    elapsed_seconds  - this request's own latency
    prompt_tokens    - input token count
    completion_tokens- output token count

Round batch_size is what you'd plot against elapsed_seconds/completion_tokens
to see how per-request latency and throughput respond to concurrency over
time - and it's also the client-side number to compare against
vllm:num_requests_waiting / num_requests_running in Prometheus
(gitops/apps/vlmm/podmonitor.yaml) for the same time window.

Usage:
    python scripts/load_test.py                  # ~7 minutes, default
    python scripts/load_test.py --duration 120    # 2 minutes instead
    python scripts/load_test.py --max-batch 4     # cap concurrency at 4
"""

import argparse
import csv
import random
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

from chat import PROMPTS, chat

DEFAULT_DURATION_SECONDS = 7 * 60
DEFAULT_MAX_BATCH_SIZE = 8
OUTPUT_CSV = "load_test_results.csv"

FIELDNAMES = [
    "timestamp",
    "round",
    "batch_size",
    "prompt",
    "elapsed_seconds",
    "prompt_tokens",
    "completion_tokens",
]


def run_round(round_num: int, batch_size: int, writer: csv.DictWriter) -> None:
    """Fire `batch_size` concurrent requests (random prompts, with
    repetition allowed within the round) and log each one as it completes."""

    prompts = [random.choice(PROMPTS) for _ in range(batch_size)]

    with ThreadPoolExecutor(max_workers=batch_size) as pool:
        futures = [pool.submit(chat, p) for p in prompts]

        for prompt, future in zip(prompts, futures):
            result = future.result()
            usage = result["usage"]

            writer.writerow({
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "round": round_num,
                "batch_size": batch_size,
                "prompt": prompt,
                "elapsed_seconds": round(result["_elapsed_seconds"], 3),
                "prompt_tokens": usage["prompt_tokens"],
                "completion_tokens": usage["completion_tokens"],
            })

    print(f"Round {round_num}: batch_size={batch_size}, "
          f"{batch_size} requests completed")


def main(duration_seconds: int, max_batch_size: int, output_path: str) -> None:
    print("Warm-up request (not logged)...")
    chat("This is a warm-up request.")

    print(f"Running for ~{duration_seconds}s, "
          f"random batch size 1-{max_batch_size} per round, "
          f"logging to {output_path}\n")

    with open(output_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDNAMES)
        writer.writeheader()

        start = time.monotonic()
        round_num = 0

        while time.monotonic() - start < duration_seconds:
            round_num += 1
            batch_size = random.randint(1, max_batch_size)
            run_round(round_num, batch_size, writer)
            f.flush()  # so partial results are on disk if the run is interrupted

        total_elapsed = time.monotonic() - start

    print(f"\nDone. {round_num} rounds over {total_elapsed:.1f}s. "
          f"Results written to {output_path}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--duration", type=int, default=DEFAULT_DURATION_SECONDS,
        help=f"target run time in seconds (default: {DEFAULT_DURATION_SECONDS}, ~7 minutes)",
    )
    parser.add_argument(
        "--max-batch", type=int, default=DEFAULT_MAX_BATCH_SIZE,
        help=f"max concurrent requests per round (default: {DEFAULT_MAX_BATCH_SIZE})",
    )
    parser.add_argument(
        "--output", type=str, default=OUTPUT_CSV,
        help=f"CSV output path (default: {OUTPUT_CSV})",
    )
    args = parser.parse_args()

    main(args.duration, args.max_batch, args.output)
