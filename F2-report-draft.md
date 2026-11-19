# Morpheus Bug Bounty — Report Draft (Variant F2)

**Title:** Direct-payment sessions charge the user the FULL provider reward at close while the provider is paid only up to its 365-day limiter cap — the shortfall strands in the diamond

**Severity: Low** — No funds are stolen and none are permanently lost: the shortfall remains in the diamond and is recoverable by the provider over time (or faster by topping up stake). Impact is user/provider funds practically stranded — the user pays for a reward the provider cannot receive, with no reclaim path for the user — plus a ~26-year recovery tail at minimum stake. This fits Low (funds locked/inefficiently held, small value, recoverable); it is not Medium because the value is small, no party profits, and a recovery path exists.

**Affected contracts (live, Base mainnet):**
- Lumerin Diamond (EIP-2535): `0x6aBE1d282f72B474E54527D93b979A4f64d3030a`
- SessionRouter facet: `0x3a3952f0E57b343F00b31F7dA039eF16389B7260` (verified via DiamondLoupe at block 58461106; code equals repo HEAD, unchanged since fix #835, 31 Jul 2026)
- Reference code: `contracts/diamond/facets/SessionRouter.sol`, `_rewardUserAfterClose` L293–320 vs `_claimForProvider` L374–390 (repo: MorpheusAIs/Morpheus-Lumerin-Node)

**Root cause:** the two sides of a direct-payment close disagree about the limiter. `_rewardUserAfterClose` deducts the FULL provider reward from the user's stake (`userStakeToProvider = _getProviderRewards(session, bid, false)`, no limiter awareness). `_claimForProvider` caps what the provider actually receives at `provider.stake - limitPeriodEarned` per 365-day period (`PROVIDER_REWARD_LIMITER_PERIOD`). When the session reward exceeds the provider's stake, the difference is charged to the user, paid to nobody, and has no reclaim path for the user — it sits in the diamond until the provider's limiter allows it.

**Reproduction (Foundry fork, pinned block 58461106, public RPC, no wallet):**
1. Provider registers with the minimum stake **0.2 MOR** + model + bid (price 9e12 wei/s).
2. User opens a DIRECT-payment session (`isDirectPaymentFromUser=true`) with **2000 MOR** stake (7-day session).
3. Warp past `endsAt`; user closes late with a valid provider receipt.
4. Observe: provider paid **0.2 MOR** at close (limiter cap); user refund **1966.8587 MOR** (= 2000 − 5.4432 full reward − 27.6981 day-lock) — charged the FULL reward; **shortfall 5.2432 MOR** remains in the diamond.
5. Warp +366 days (one limiter reset); provider claims again → only **0.2 MOR** more. Full recovery needs **27 annual periods (~26 years)** at minimum stake.

**Measured impact (fork, block 58461106):** full provider reward 5.4432 MOR; provider paid at close 0.2 MOR; user lock 27.6981 MOR; user immediate refund 1966.8587 MOR; shortfall stranded 5.2432 MOR (= full reward − paid); late claim after one limiter reset 0.2 MOR; provider total after 2 periods 0.4 MOR; periods to fully recover 27 (~26 years). At MOR ≈ $0.72 the measured shortfall is ≈ $3.78; it scales with (session reward − provider stake). Faster recovery exists but is costly: the provider can top up stake (`providerRegister` adds stake without resetting the period), i.e. lock additional collateral equal to the shortfall to unlock its own reward — the user still has no reclaim path.

**Suggested fix:** at close, deduct from the user's stake only the amount the provider can actually receive under the limiter (compute the capped payout first, charge the user that amount), and either refund the remainder to the user immediately or hold it as an explicit provider-receivable that reverts to the user if unclaimed after the limiter period. Alternatively, reject direct-payment sessions at open when the full reward exceeds the provider's current limiter headroom.

**PoC:** Foundry fork test, pinned block 58461106 — https://github.com/zfamsz/morpheus-sessionrouter-claim-variants-poc (`forge test --match-contract VariantF2DirectLimiter -vv`; 1/1 test passes). Self-contained single test file + minimal diamond interface; reproduced independently by the coordinator.

**Note on distinctness:** this is a *different* mechanism from the day-lock refund issue (SessionRouter.sol:306, final-day-only user lock). A limiter/accounting mismatch, not a day-lock scoping error. It is not a variant of that finding.
