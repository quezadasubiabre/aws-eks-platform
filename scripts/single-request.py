"""
Send a single chat completion request to the vLLM endpoint, measure the
typical client-side metrics INCLUDING time to first token (TTFT), and save
everything to a text file.

vLLM exposes an OpenAI-compatible API. To measure TTFT client-side, the
request has to be streaming ("stream": True) - a non-streaming request only
ever gives you one timestamp (when the full response arrived), so there's no
way to tell "when did the first token show up" apart from "when did
generation finish." Streaming delivers the response as a sequence of
Server-Sent Events chunks, so the first chunk with actual content marks TTFT.

Metrics measured (same shape as chat.py/load_test.py, so results are
comparable across scripts):
    ttft_seconds         - time from request sent to the first content chunk
                           arriving - the client-side equivalent of vLLM's
                           own time_to_first_token_seconds histogram
    elapsed_seconds      - total wall-clock time for the whole response
    inter_token_seconds  - average time between chunks after the first one
                           (a rough client-side stand-in for vLLM's
                           inter_token_latency_seconds)
    prompt_tokens        - input token count
    completion_tokens    - output token count
    total_tokens         - prompt_tokens + completion_tokens
    tokens_per_second    - completion_tokens / elapsed_seconds

This is a single client-side measurement, not a substitute for vLLM's own
server-side histograms - see the "API Endpoint & vLLM Metrics" Grafana
dashboard for those (queue/prefill/decode breakdown, percentiles over time).

Usage:
    python scripts/single-request.py
    python scripts/single-request.py "What's the capital of Chile?"
"""

import json
import sys
import time

import requests

BASE_URL = "https://demo.quezadasubiabre.com/vllm"
MODEL = "Qwen/Qwen2.5-7B-Instruct-AWQ"
OUTPUT_FILE = "single-request-result.txt"

prompt = sys.argv[1] if len(sys.argv) > 1 else "What is the Capital of Chile? Recommend me something to do for 3 days"

payload = {
    "model": MODEL,
    "messages": [{"role": "user", "content": prompt}],
    "stream": True,
    # asks vLLM to include a final chunk with token usage, same info a
    # non-streaming response gives for free in its top-level "usage" field
    "stream_options": {"include_usage": True},
}

reply_parts = []
usage = None
chunk_timestamps = []

start = time.perf_counter()
with requests.post(f"{BASE_URL}/v1/chat/completions", json=payload, stream=True) as response:
    response.raise_for_status()

    for line in response.iter_lines():
        if not line:
            continue
        line = line.decode("utf-8")
        if not line.startswith("data: "):
            continue

        data_str = line[len("data: "):]
        if data_str == "[DONE]":
            break

        chunk = json.loads(data_str)

        if chunk.get("usage"):
            usage = chunk["usage"]

        choices = chunk.get("choices") or []
        if not choices:
            continue

        delta = choices[0].get("delta", {})
        content = delta.get("content")
        if content:
            chunk_timestamps.append(time.perf_counter())
            reply_parts.append(content)

elapsed_seconds = time.perf_counter() - start
reply = "".join(reply_parts)

ttft_seconds = (chunk_timestamps[0] - start) if chunk_timestamps else None
if len(chunk_timestamps) > 1:
    inter_token_seconds = (chunk_timestamps[-1] - chunk_timestamps[0]) / (len(chunk_timestamps) - 1)
else:
    inter_token_seconds = None

tokens_per_second = (
    usage["completion_tokens"] / elapsed_seconds
    if usage and elapsed_seconds > 0 else 0
)

with open(OUTPUT_FILE, "w") as f:
    f.write(f"Prompt: {prompt}\n\n")
    f.write(f"Reply: {reply}\n\n")
    f.write("Metrics:\n")
    f.write(f"  Time to first token (TTFT): "
            f"{f'{ttft_seconds:.3f}s' if ttft_seconds is not None else 'n/a (no content chunks)'}\n")
    f.write(f"  Elapsed time (total): {elapsed_seconds:.3f}s\n")
    f.write(f"  Avg inter-token latency: "
            f"{f'{inter_token_seconds * 1000:.1f}ms' if inter_token_seconds is not None else 'n/a'}\n")
    if usage:
        f.write(f"  Prompt tokens: {usage['prompt_tokens']}\n")
        f.write(f"  Completion tokens: {usage['completion_tokens']}\n")
        f.write(f"  Total tokens: {usage['total_tokens']}\n")
    f.write(f"  Tokens/sec (completion): {tokens_per_second:.1f}\n")

print(f"Saved result to {OUTPUT_FILE}")
print(f"TTFT: {f'{ttft_seconds:.3f}s' if ttft_seconds is not None else 'n/a'} | "
      f"Elapsed: {elapsed_seconds:.3f}s | "
      f"{tokens_per_second:.1f} tok/s")
