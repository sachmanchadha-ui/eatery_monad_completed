# CanteenPOS

Paid pre-orders for a campus canteen, with a student-signed check-in at the counter recorded on Monad. Rupees never touch the contract: it is the public rulebook and ledger, and refunds are paid off-chain and logged on-chain. The full design is in [CanteenPOS_SPEC_v2.md](CanteenPOS_SPEC_v2.md).

**Live on Monad testnet:** [`0x83edd38e28e43c608c0d30b60a03adac1eacbc33`](https://testnet.monadvision.com/address/0x83edd38e28e43c608c0d30b60a03adac1eacbc33) (source verified).

## Layout

| Path | What it is |
| :--- | :--- |
| `contracts/` | `CanteenOrders.sol` and its Foundry tests (unit, fuzz, invariant, gas) |
| `packages/sdk` | EIP-712 types and signing helpers, ABI, chain and canteen config |
| `packages/ops` | Key generation, deploy, funding |
| `packages/indexer` | Postgres schema, chain indexer and CLI, end-to-end test, testnet smoke script |
| `config/canteen.json` | Slots, items, prices, capacity, college email domain |
| `deployments/` | Deployed addresses and deploy blocks |
| `tools/v2-offline-signing` | Phone test for offline session-key signing |
| `docs/` | Phase status and decisions: start with `P0_STATUS.md` |

## Setup

Needs Node 23.6+ (TypeScript runs directly, no build step), [Foundry](https://getfoundry.sh), and Docker Desktop for Postgres.

```bash
git clone --recurse-submodules https://github.com/sachmanchadha-ui/eatery_monad_completed.git
cd eatery_monad_completed
npm install
cd contracts && forge build && cd ..
```

If you cloned without `--recurse-submodules`, run `git submodule update --init --recursive` before `forge build`.

## Tests

```bash
cd contracts && forge test && cd ..     # contract: 89 tests
npm run test -w @canteenpos/sdk          # TS signatures accepted by the contract (boots anvil)
npm run test -w @canteenpos/indexer      # indexer end to end (anvil + in-memory Postgres)
```

## Running against testnet

```bash
docker compose up -d                                    # Postgres on 127.0.0.1:5433
npm run indexer -w @canteenpos/indexer -- sync          # index the live contract
npm run indexer -w @canteenpos/indexer -- status        # today's orders
```

Anything that sends transactions (`deploy`, `fund`, `smoke`) needs `.env.testnet` with the server keys. It is gitignored and must never be committed. Get it from the repo owner over a private channel, not through GitHub.
