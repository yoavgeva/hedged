# Hedged

> **Deprecated** — This package has been merged into [`resiliency`](https://github.com/yoavgeva/resiliency).
> Use `Resiliency.Hedged` instead. This repo is archived and will not receive further updates.

[![Hex](https://img.shields.io/hexpm/v/hedged.svg)](https://hex.pm/packages/hedged)
[![CI](https://github.com/yoavgeva/hedged/actions/workflows/ci.yml/badge.svg)](https://github.com/yoavgeva/hedged/actions/workflows/ci.yml)

> 126 tests, zero warnings, Dialyzer + Credo strict clean.

Hedged requests for Elixir — fire a backup request after a delay, take whichever finishes first, cancel the rest. A tail-latency optimization with adaptive delay tuning.

## Why hedged requests?

A single slow backend call can dominate your p99. Retries help with failures, but they don't help when the server is just *slow*. Hedged requests solve this by racing a backup against the original — your latency becomes the *minimum* of two attempts, not the maximum.

Google's ["Tail at Scale"](https://research.google/pubs/pub40801/) paper showed that issuing a redundant request after a brief delay can reduce p99 latency by up to 50% while adding only ~5% extra load.

No existing Elixir library does this. Go has `cristalhq/hedgedhttp` (HTTP-only) and gRPC has built-in hedging. We built a generic, composable version for any Elixir function.

### Hedging vs retries

| | Retries | Hedging |
|---|---|---|
| Trigger | Failure | Timeout (slow response) |
| Concurrent requests | No (sequential) | Yes (parallel) |
| Solves | Transient errors | Tail latency |
| Extra load | Only on failure | ~5-10% steady state |
| Latency impact | Additive (delay + retry) | Subtractive (min of two) |

They're complementary — use both. See [Composing with BackoffRetry](#composing-with-backoffretry) below.

## Design goals

- **Generic** — works with any `fn -> result end`, not just HTTP. Database queries, RPC calls, DNS lookups, file reads — anything
- **Adaptive delay** — auto-tunes from observed latency percentiles so you don't have to guess a static delay
- **Token bucket** — prevents hedge storms under sustained load (~10% hedge rate at defaults)
- **Non-fatal fast-forward** — transient errors like `:timeout` or `:econnrefused` immediately fire the next hedge without waiting
- **Race mode** — `delay: 0` fires all requests simultaneously, takes the fastest
- **Staggered dispatch** — fire up to N requests with configurable delays between them
- **Automatic cancellation** — losers are shut down immediately, no wasted work
- **Composable** — stateless mode for simple cases, supervised tracker for production
- **Testable** — injectable `now_fn` for deterministic, instant test suites
- **Observable** — built-in stats: total requests, hedge rate, hedge win rate, p50/p95/p99, current delay, token level
- **Zero runtime deps** — just Elixir/OTP
- **Supervision-ready** — `child_spec/1` and `start_link/1` for your supervision tree

## Installation

```elixir
def deps do
  [{:hedged, "~> 0.1.0"}]
end
```

## Quick start

### Stateless — fixed delay

```elixir
# Fire a backup after 100ms if the first hasn't responded
{:ok, body} = Hedged.run(fn -> fetch(url) end)

# With options
{:ok, body} = Hedged.run(fn -> fetch(url) end,
  delay: 50,
  max_requests: 3,
  timeout: 2_000
)
```

### Adaptive — delay auto-tunes from observed latency

```elixir
# Add to your supervision tree
children = [
  {Hedged, name: MyApp.Hedged, percentile: 95, min_delay: 5, max_delay: 500}
]

# Delay adapts automatically based on p95 latency
{:ok, body} = Hedged.run(MyApp.Hedged, fn -> fetch(url) end, [])

# Check how it's doing
Hedged.Tracker.stats(MyApp.Hedged)
# => %{total_requests: 1042, hedged_requests: 98, hedge_won: 31,
#       p50: 12, p95: 45, p99: 120, current_delay: 45, tokens: 8.2}
```

## Real-world examples

### HTTP with non-fatal errors

```elixir
Hedged.run(
  fn -> HTTPClient.get(url) end,
  delay: 50,
  max_requests: 3,
  non_fatal: fn
    :timeout -> true
    :econnrefused -> true
    _ -> false
  end,
  on_hedge: fn attempt ->
    Logger.info("Firing hedge ##{attempt}")
  end
)
```

When `non_fatal` returns true, the next hedge fires *immediately* instead of waiting for the delay — you don't waste time sleeping on errors you know are transient.

### Database query with tight deadline

```elixir
Hedged.run(fn -> Repo.query("SELECT ...") end,
  delay: 20,
  timeout: 1_000
)
```

### DNS resolution — race mode

Fire all at once, take the fastest:

```elixir
Hedged.run(fn -> dns_lookup(host) end,
  delay: 0,
  max_requests: 3
)
```

### Adaptive with multiple services

```elixir
# Each service gets its own tracker with tuned settings
children = [
  {Hedged, name: MyApp.PaymentHedge, percentile: 99, max_delay: 2_000},
  {Hedged, name: MyApp.SearchHedge, percentile: 90, max_delay: 200},
  {Hedged, name: MyApp.CacheHedge, percentile: 95, min_delay: 1, max_delay: 50}
]

# In your code
{:ok, result} = Hedged.run(MyApp.PaymentHedge, fn -> charge(card) end, [])
{:ok, results} = Hedged.run(MyApp.SearchHedge, fn -> search(query) end, [])
```

### Composing with BackoffRetry

Hedge the outer call, retry the inner:

```elixir
Hedged.run(fn ->
  BackoffRetry.retry(fn -> flaky_api_call() end,
    max_attempts: 2,
    backoff: :constant,
    base_delay: 50
  )
end, delay: 200)
```

## How adaptive delay works

The adaptive tracker solves the "what delay should I pick?" problem by learning from your traffic:

```
Request lifecycle:
1. get_config() → {delay_ms, allow_hedge?}   # Tracker computes from recent latencies
2. Runner fires request #1, waits delay_ms
3. If no response, fires hedge #2
4. Winner returns, losers cancelled
5. record(%{latency_ms, hedged?, hedge_won?}) # Tracker learns from this request
6. Next request → delay has shifted
```

**Percentile-based delay**: A circular buffer (default 1000 samples) tracks recent latencies. The delay is set to the target percentile (e.g., p95) of that buffer, clamped to `[min_delay, max_delay]`. Old samples are evicted FIFO, so the delay naturally tracks recent conditions.

```
Requests 1-9:   delay = 100ms          (cold start, not enough samples)
Request 50:     p95 = 22ms → delay 22ms (learned from traffic)
[service degrades]
Request 200:    p95 = 180ms → delay 180ms (adapted to new conditions)
[service recovers]
Request 400:    p95 = 25ms → delay 25ms  (old slow samples evicted)
```

**Token bucket**: Prevents hedge storms. Each request earns a small credit (default 0.1 tokens). Each hedge costs more (default 1.0 token). When tokens drop below threshold, hedging is disabled entirely. At defaults this naturally limits the hedge rate to ~10% under steady state. After a burst of hedging depletes tokens, normal traffic replenishes them.

## Options

### Stateless (`run/2`)

| Option | Default | Description |
|---|---|---|
| `delay` | `100` | ms before firing the next hedge |
| `max_requests` | `2` | total concurrent attempts |
| `timeout` | `5_000` | overall deadline in ms |
| `non_fatal` | `fn _ -> false end` | predicate: `true` fires next hedge immediately |
| `on_hedge` | `nil` | `fn attempt -> any` callback before each hedge |
| `now_fn` | `System.monotonic_time/1` | injectable clock for testing |

### Adaptive tracker (`start_link/1`)

| Option | Default | Description |
|---|---|---|
| `name` | *required* | registered name |
| `percentile` | `95` | target percentile for adaptive delay |
| `buffer_size` | `1000` | max latency samples to keep |
| `min_delay` | `1` | floor for adaptive delay (ms) |
| `max_delay` | `5_000` | ceiling for adaptive delay (ms) |
| `initial_delay` | `100` | delay used before enough samples collected |
| `min_samples` | `10` | samples needed before adapting |
| `token_max` | `10` | token bucket capacity |
| `token_success_credit` | `0.1` | tokens earned per request |
| `token_hedge_cost` | `1.0` | tokens spent per hedge |
| `token_threshold` | `1.0` | min tokens to allow hedging |

### Tuning the token bucket

The defaults give ~10% hedge rate. To adjust:

| Desired behavior | Configuration |
|---|---|
| More aggressive hedging (~20%) | `token_success_credit: 0.2` |
| Conservative hedging (~5%) | `token_success_credit: 0.05` |
| Always allow hedging | `token_threshold: 0` |
| Disable hedging temporarily | `token_max: 0` |
| Larger hedge budget bursts | `token_max: 20` |

## When not to hedge

Hedging adds ~5% extra load at defaults. Don't use it when:

- **Non-idempotent operations** — double-charging a credit card is bad. Only hedge reads or idempotent writes
- **Resource-constrained backends** — if your DB is at capacity, extra queries make things worse
- **Already fast** — if p99 is already acceptable, hedging adds complexity for no gain
- **Single backend instance** — hedging helps when slowness is per-request (GC pauses, network jitter), not when the entire service is slow

## Algorithm

1. Fire request #1 immediately
2. Wait `delay` ms
3. If response arrived — return it, cancel nothing else pending
4. Fire request #2 (the hedge)
5. Wait for any response: first success wins, losers cancelled
6. If a failure is `non_fatal` — fire next hedge immediately (fast-forward)
7. If all attempts fail — return `{:error, last_reason}`
8. If overall `timeout` hit — cancel everything, return `{:error, :timeout}`

Key behaviors:
- If a request fails *before* the delay expires, the next hedge fires when the delay would have normally triggered (or immediately if `non_fatal`)
- If *all* pending requests have failed but `max_requests` isn't reached, the next hedge fires immediately — no point waiting
- Raises, exits, and throws in tasks are captured via `:DOWN` messages — they don't crash the caller

## Error handling

Exceptions, exits, and throws inside hedged tasks are captured — they never crash the caller:

| Source | Wrapped as |
|---|---|
| `raise "boom"` | `{:error, %RuntimeError{}}` |
| `exit(:reason)` | `{:error, {:reason, stacktrace}}` |
| `throw(:value)` | `{:error, {{:nocatch, :value}, stacktrace}}` |

If multiple tasks are in flight and one crashes, the others keep running. You still get a result as long as any task succeeds.

## Return values

| Scenario | Return |
|---|---|
| Function returns `{:ok, value}` | `{:ok, value}` |
| Bare value (e.g. `42`) | `{:ok, 42}` |
| `:ok` | `{:ok, :ok}` |
| `{:ok, {:error, _}}` | `{:ok, {:error, _}}` (inner value preserved) |
| All attempts return `{:error, r}` | `{:error, r}` (last error) |
| Overall timeout exceeded | `{:error, :timeout}` |
| All tasks raise / exit / throw | `{:error, reason}` (from `:DOWN`) |
| `:error` | `{:error, :error}` |

## Stats & observability

```elixir
Hedged.Tracker.stats(MyApp.Hedged)
```

Returns:

| Field | Description |
|---|---|
| `total_requests` | Total requests processed |
| `hedged_requests` | Requests that triggered at least one hedge |
| `hedge_won` | Times the hedge beat the original request |
| `p50` | Median observed latency (ms) |
| `p95` | 95th percentile latency (ms) |
| `p99` | 99th percentile latency (ms) |
| `current_delay` | Current adaptive delay being used (ms) |
| `tokens` | Current token bucket level |

## Architecture

```
lib/
  hedged.ex              # Public API: run/2 (stateless), run/3 (adaptive),
                         # start_link/1, child_spec/1
  hedged/
    runner.ex            # Core engine: staggered dispatch + receive loop
    tracker.ex           # GenServer: adaptive delay + token bucket + stats
    percentile.ex        # Circular buffer + percentile calculation
```

Three layers, each independently useful:

- **Runner** — pure hedging engine, no state, no GenServer
- **Tracker** — adaptive delay + throttling, plugs into Runner
- **Percentile** — data structure, no processes, usable standalone

## License

MIT
