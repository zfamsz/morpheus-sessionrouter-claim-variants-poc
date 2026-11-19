# Morpheus SessionRouter — two new claim-path findings (F1 + F2)

Independent Foundry fork PoCs for two NEW, PoC-verified SessionRouter findings, submitted to the Morpheus Bug Bounty Program (v2). Both are Low severity and are **different mechanisms** from the day-lock refund issue (SessionRouter.sol:306) — different functions, different lines, different effects.

## F1 — Same-day `claimForProvider` reverts `Panic(0x11)` after a non-disputed close
- PoC: `f1-poc/` — `forge test --match-contract VariantF1ClaimRevert` (2/2 PASS)
- Report: `F1-report-draft.md`
- Root cause: `_getProviderOnHoldAmount` (SessionRouter.sol:267-277) uses `closedAt` without capping at `endsAt`; `claimForProvider` (:358-370) subtracts without a zero floor. After a non-disputed close the provider is already paid in full, so the phantom on-hold underflows and the call panics. Self-heals the next UTC day.

## F2 — Direct payment: user charged FULL reward, provider paid only to the 365-day limiter cap
- PoC: `f2-poc/` — `forge test --match-contract VariantF2DirectLimiter` (1/1 PASS)
- Report: `F2-report-draft.md`
- Root cause: `_rewardUserAfterClose` (:293-320) deducts the full reward from the user's stake, while `_claimForProvider` (:374-390) caps the payout at `provider.stake - limitPeriodEarned`. Shortfall 5.2432 MOR strands in the diamond; about 26 years to recover at minimum stake.

## Run
Each `*-poc/` is a self-contained Foundry project (forge-std vendored). From inside the folder:
```
forge test
```
Forks Base mainnet at pinned block 58461106 via public RPC (https://mainnet.base.org). No key, no wallet, no mainnet transaction.

## Target
- Diamond: `0x6aBE1d282f72B474E54527D93b979A4f64d3030a` (Base)
- SessionRouter facet: `0x3a3952f0E57b343F00b31F7dA039eF16389B7260`
- Code: Morpheus-Lumerin-Node, `contracts/diamond/facets/SessionRouter.sol` (unchanged since fix #835, 31 Jul 2026)
