# P2 notes: deploy and indexer

Status: P2 done. Deployed to Monad testnet, source verified, indexed into Docker Postgres, smoke run passed on the real chain.

## Monad testnet deployment (2026-10-03)

| | |
| :--- | :--- |
| Contract | [0x83edd38e28e43c608c0d30b60a03adac1eacbc33](https://testnet.monadvision.com/address/0x83edd38e28e43c608c0d30b60a03adac1eacbc33) |
| Deploy block | 67786289 |
| Source | Verified on MonadVision (Sourcify, exact match) |
| Owner (deployer key) | 0x0460E464485db2D2c26bD9B785D3847A0176110F |
| Demo tablet | 0x0f78BE7C8A0c51Ec454bfe7586d2557974f53A36 (authorized) |
| Cost | Deploy + config 0.57 MON; funding 0.6 MON |
| Smoke run | PASSED 14:28 IST on copy [0x8014…2cec](https://testnet.monadvision.com/address/0x801438b27d08d9e1ce70b258c159a80927a72cec): order, check-in and serve indexed as Served, token 1, 2 Vada Pav, Rs 30 (0.54 MON) |
| Planned final owner | The MetaMask wallet 0xaF14aA525676613Aa6448EcD0fcBae785c753572 (transfer in P6) |

## Pieces

| Path | What it is |
| :--- | :--- |
| `packages/ops` | Transaction helpers (gas limit = estimate + 10%, because Monad bills the limit), `deployCanteen`, key generation, funding. |
| `packages/indexer` | Postgres schema (spec 6.2), the indexer, its CLI, and the testnet smoke script. |
| `docker-compose.yml` | Local Postgres 17 on `127.0.0.1:5433` (dev credentials, localhost only). |
| `.env.testnet` | All server and demo keys. Gitignored. Never share it. |
| `deployments/<chainId>.json` | Address and deploy block, written by `deploy`, read by the indexer and apps. |

## Indexer design

- Polls `getLogs` from a cursor in batches (halves the batch if the RPC refuses the range), 2 confirmations on Monad.
- Each batch is one Postgres transaction: every log goes into `chain_events` keyed on `(tx_hash, log_index)`, and a log already there is skipped. A crash between applying logs and moving the cursor is therefore harmless.
- Order lines are read with `getOrderLines` at the latest block (they never change), so no archive node is needed.
- `rebuild` truncates the chain-derived tables and replays from the deploy block. Off-chain tables (`students`, `intents`, `payments`, `jobs`, non-chain `audit_log`) are kept.
- A database is bound to one deployment; pointing it at another contract is refused.
- `orders.intent_hash` is filled by joining `payments.payment_ref`, which P3 writes when a payment is captured.

## Tests

- `npm run test -w @canteenpos/indexer`: anvil + in-memory Postgres. Three orders (served, no-show forfeit, sold-out refund paid), then checks every row, replays from the deploy block (no change), rebuilds (identical), and refuses a foreign deployment. 6 pass.
- Same test on Docker Postgres: `TEST_DATABASE_URL=postgres://canteen:canteen@127.0.0.1:5433/canteen_test`. 6 pass. (The test wipes that database's schema; never point it at `canteen`.)
- CLI rehearsal on anvil: `gen-keys`, `deploy`, `fund`, `indexer once`, `status`, and the full smoke script all ran clean.

## Testnet runbook

```bash
docker compose up -d
npm run deploy -w @canteenpos/ops      # contract + config/canteen.json, writes deployments/10143.json
npm run fund -w @canteenpos/ops        # gas for submitter, demo tablet, refunder, relayer
npm run smoke -w @canteenpos/indexer   # short-window copy: order, check-in, serve, indexed (about 5 min)
npm run indexer -w @canteenpos/indexer -- sync
```

Cost at the 100 gwei floor (measured gas, plus the 10% limit buffer): deploy + config about 0.55 MON, funding about 0.6 MON, smoke copy about 0.55 MON. Fund the owner with about 2 MON.

## Still to do in P2

- Before the pilot: `transferOwnership` to the MD's MetaMask (or a Safe), then `acceptOwnership` from it.
