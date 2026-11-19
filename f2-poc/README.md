# PoC — Morpheus SessionRouter: direct-payment session strands the provider-reward shortfall in the diamond

Foundry fork test against **live Base bytecode, pinned block 58461106**.

- Diamond (live, Base): `0x6aBE1d282f72B474E54527D93b979A4f64d3030a`
- SessionRouter facet (live): `0x3a3952f0E57b343F00b31F7dA039eF16389B7260`
- MOROFT (Base): `0x7431aDa8a591C955a994a21710752EF9b882b8e3`

## Run

```bash
forge test --match-contract VariantF2DirectLimiter -vv
```

No key, no wallet, no mainnet transaction — the test forks public Base RPC
(`https://mainnet.base.org`) at the pinned block and uses `deal`/`warp` only.

## What it proves

`test_directPaymentLimiterMismatch` — direct-payment session, 2000 MOR stake,
provider stake 0.2 MOR (the minimum), price 9e12 wei/s:

- Full provider reward: **5.4432 MOR**. Provider paid at close: **0.2 MOR**
  (365-day limiter cap). User refund: **1966.8587 MOR**
  (= 2000 − 5.4432 − day-lock 27.6981) — the user is charged the FULL reward.
- **Shortfall stranded in the diamond: 5.2432 MOR** (= full reward − paid).
- After ONE limiter reset (+366 days) the provider can claim only **0.2 MOR**
  more. Recovering the shortfall needs **27 annual periods (~26 years)** at
  minimum stake.

## Root cause (one paragraph)

`_rewardUserAfterClose` (SessionRouter.sol:293-320) deducts the FULL provider
reward from the user's stake, while `_claimForProvider` (SessionRouter.sol:
374-390) caps what the provider actually receives at
`provider.stake - limitPeriodEarned` per 365-day period. The difference has
no reclaim path for the user: it sits in the diamond until the provider's
limiter allows it. The only faster path is the provider locking additional
stake equal to the shortfall (`providerRegister` tops stake up without
resetting the period) — i.e. locking matching collateral to unlock its own
reward.
