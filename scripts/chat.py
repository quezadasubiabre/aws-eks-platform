"""
Send a series of DIFFERENT chat completion requests to the vLLM endpoint and
report latency + token usage per call, plus a summary.

Design notes on avoiding cache effects:
- Prompts are deliberately varied (not the same string repeated) so no run
  benefits from vLLM's automatic prefix caching (--enable-prefix-caching),
  if/when that's enabled - a repeated identical prompt would let vLLM reuse
  cached KV-cache blocks for that exact prefix, making later calls look
  artificially fast for reasons unrelated to typical request cost.
- There's no HTTP/CDN caching in play (POST requests aren't cached by
  Cloudflare/browsers), and this script does no client-side caching either.
- The first call to a freshly started vLLM pod is often slower for reasons
  that have nothing to do with prompt content (CUDA graph capture, kernel
  JIT, allocator warm-up) - that's a *cold start* effect, not a cache hit.
  A dedicated warm-up call is sent first and excluded from the reported
  stats, so the numbers reflect steady-state behavior.

Usage:
    python scripts/chat.py
"""

import statistics
import time

import requests

BASE_URL = "https://demo.quezadasubiabre.com/vllm"
MODEL = "Qwen/Qwen2.5-7B-Instruct-AWQ"

# Deliberately varied - different lengths, topics, and structures, so no two
# requests share a prompt prefix long enough to benefit from prefix caching.
PROMPTS = [
    "What's the capital of Chile?",
    "Write a haiku about Kubernetes pods restarting at 3am.",
    "Explain the difference between a Deployment and a StatefulSet in two sentences.",
    "List three reasons a GPU node might fail to schedule a pod.",
    "Translate 'the load balancer is healthy' into French.",
    "Summarize what a taint and toleration do in Kubernetes, for a beginner.",
    "What year was the Rosetta Stone discovered?",
    "Give me a short analogy for how Argo CD's selfHeal works.",
]


def chat(prompt: str) -> dict:
    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
    }

    start = time.perf_counter()
    response = requests.post(f"{BASE_URL}/v1/chat/completions", json=payload)
    elapsed = time.perf_counter() - start

    response.raise_for_status()
    data = response.json()
    data["_elapsed_seconds"] = elapsed
    return data


def run_experiment(prompts: list[str]) -> list[dict]:
    # Warm-up call, deliberately excluded from results: absorbs any cold-start
    # cost (CUDA graph capture, kernel JIT) so it doesn't skew the real trials.
    print("Warm-up request (excluded from results)...")
    chat("This is a warm-up request.")

    results = []
    for i, prompt in enumerate(prompts, start=1):
        print(f"[{i}/{len(prompts)}] {prompt!r}")
        result = chat(prompt)
        reply = result["choices"][0]["message"]["content"]
        usage = result["usage"]

        print(f"  -> {result['_elapsed_seconds']:.3f}s | "
              f"{usage['prompt_tokens']} prompt + {usage['completion_tokens']} completion tokens")
        print(f"  -> {reply[:100]}{'...' if len(reply) > 100 else ''}\n")

        results.append({
            "prompt": prompt,
            "elapsed_seconds": result["_elapsed_seconds"],
            "prompt_tokens": usage["prompt_tokens"],
            "completion_tokens": usage["completion_tokens"],
        })

    return results


def print_summary(results: list[dict]) -> None:
    latencies = [r["elapsed_seconds"] for r in results]
    completion_tokens = [r["completion_tokens"] for r in results]

    print("=" * 60)
    print(f"Requests: {len(results)}")
    print(f"Latency  min/mean/median/max: "
          f"{min(latencies):.3f}s / {statistics.mean(latencies):.3f}s / "
          f"{statistics.median(latencies):.3f}s / {max(latencies):.3f}s")
    if len(latencies) > 1:
        print(f"Latency  stdev: {statistics.stdev(latencies):.3f}s")
    print(f"Completion tokens min/mean/max: "
          f"{min(completion_tokens)} / {statistics.mean(completion_tokens):.1f} / "
          f"{max(completion_tokens)}")

    # tokens/sec per request, useful as a rough throughput signal
    per_request_tps = [
        r["completion_tokens"] / r["elapsed_seconds"]
        for r in results if r["elapsed_seconds"] > 0
    ]
    if per_request_tps:
        print(f"Approx tokens/sec (completion, per request): "
              f"mean={statistics.mean(per_request_tps):.1f}")


if __name__ == "__main__":
    results = run_experiment(PROMPTS)
    print_summary(results)
