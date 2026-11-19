# PoC — Morpheus SessionRouter: same-day `claimForProvider` reverts with Panic(0x11) after a non-disputed close

Foundry fork test against **live Base bytecode, pinned block 58461106**.

- Diamond (live, Base): `0x6aBE1d282f72B474E54527D93b979A4f64d3030a`
- SessionRouter facet (live): `0x3a3952f0E57b343F00b31F7dA039eF16389B7260`
- MOROFT (Base): `0x7431aDa8a591C955a994a21710752EF9b882b8e3`

## Run

```bash
forge test --match-contract VariantF1ClaimRevert -vv
```

No key, no wallet, no mainnet transaction — the test forks public Base RPC
(`https://mainnet.base.org`) at the pinned block and uses `deal`/`warp` only.

## What it proves

1. `test_postCloseSameDayClaimReverts` — 7-day session, 2000 MOR stake,
   price 9e12 wei/s, expected provider reward 5.4432 MOR. The provider claims
   the full 5.4432 MOR **before** close; the late close pays the provider 0
   more. A `claimForProvider` call in the **same UTC day** then **reverts with
   `Panic(0x11)`** (arithmetic underflow) instead of returning 0. The next UTC
   day the same call returns 0 cleanly.
2. `test_revertMatrixEarlyClose` — (a) early close without dispute: same-day
   claim reverts the same way; (b) early close **with** dispute (invalid
   receipt signer): same-day claim returns 0, no revert.

## Root cause (one paragraph)

`_getProviderOnHoldAmount` (SessionRouter.sol:267-277) computes
`(closedAt - max(startOfTheDay(closedAt), openedAt)) * pricePerSecond` using
`closedAt` **without capping it at `endsAt`**, and `claimForProvider`
(SessionRouter.sol:358-370) computes
`_getProviderRewards(..., true) - _getProviderOnHoldAmount(...)` with no zero
floor. After a non-disputed close the provider has already been paid in full,
so `rewards - withdrawn == 0`, but the phantom on-hold is still > 0 — the
subtraction underflows and panics. The hold is also subtracted a second time:
it was never withheld in the no-dispute case.
