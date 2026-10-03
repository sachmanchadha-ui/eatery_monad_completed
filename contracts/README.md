# CanteenOrders contract

Fund-free order state machine (spec section 5). Deviations from the spec skeleton are listed in [docs/P1_NOTES.md](../docs/P1_NOTES.md).

```bash
forge build
forge test                  # unit, fuzz, invariant and gas snapshot tests
forge test --mc InvariantTest
INV_METRICS=true FOUNDRY_INVARIANT_RUNS=1 forge test --mc InvariantTest -vv   # per-action success counts
```

The TypeScript signing helpers and the hash parity test live in `packages/sdk` (`npm run test:sdk` from the repo root). That test boots anvil and deploys the build from `out/`, so run `forge build` first.
