# Morpheus Bug Bounty — Report Draft (Variant F1)

**Title:** `claimForProvider` reverts with Panic(0x11) on same-day claims after a non-disputed close (phantom provider on-hold underflow)

**Severity: Low** — No funds are lost or at risk: the provider has already been paid in full at close, and the call self-heals the next UTC day. Impact is a claim-path denial-of-service for up to one UTC day (a panic revert instead of a graceful 0), plus same-day residual claims smaller than the phantom hold being blocked until midnight, and same-day claims larger than the hold being underpaid by the hold amount until midnight. This fits Low (minor functional defect, no direct fund impact); it is not Medium because no value is lost, locked, or redirected.

**Affected contracts (live, Base mainnet):**
- Lumerin Diamond (EIP-2535): `0x6aBE1d282f72B474E54527D93b979A4f64d3030a`
- SessionRouter facet: `0x3a3952f0E57b343F00b31F7dA039eF16389B7260` (verified via DiamondLoupe at block 58461106; code equals repo HEAD, unchanged since fix #835, 31 Jul 2026)
- Reference code: `contracts/diamond/facets/SessionRouter.sol`, `_getProviderOnHoldAmount` L267–277 and `claimForProvider` L358–370 (repo: MorpheusAIs/Morpheus-Lumerin-Node)

**Root cause:** `_getProviderOnHoldAmount` computes `(closedAt - max(startOfTheDay(closedAt), openedAt)) * pricePerSecond` using `closedAt` **without capping it at `endsAt`**, and it is applied on every `claimForProvider` call — even when the provider was already paid in full at close. `claimForProvider` then computes `_getProviderRewards(session, bid, true) - _getProviderOnHoldAmount(session, bid)` with no zero floor. After a non-disputed close, `rewards - withdrawn == 0` while the phantom on-hold is still > 0, so the subtraction underflows and the call panics with `Panic(0x11)`. The hold is effectively subtracted twice in the no-dispute case: it was never withheld at close, yet it is subtracted again at claim time. (For a late close the phantom hold even covers time *after* `endsAt`, which the provider never earned.)

**Reproduction (Foundry fork, pinned block 58461106, public RPC, no wallet):**
1. Provider registers + model + bid (price 9e12 wei/s); user opens a 7-day session with 2000 MOR stake (self-deal in the PoC; any user/provider pair works).
2. Warp past `endsAt`; provider calls `claimForProvider` → paid **5.4432 MOR** (full reward).
3. User closes late with a valid provider receipt → provider paid **0** more.
4. Provider calls `claimForProvider` again the **same UTC day** → **reverts `Panic(0x11)`** instead of returning 0.
5. Warp to the next UTC day; the same call returns **0** cleanly.
Matrix: early close without dispute → same revert; early close **with** dispute (invalid receipt signer) → returns 0, no revert (there `withdrawn == rewards - onHold`, so the difference is exactly 0). Close at exactly 00:00 UTC is the only non-disputed case that does not revert (on-hold is 0).

**Measured impact (fork, block 58461106):** expected/full provider reward 5.4432 MOR; pre-close claim 5.4432 MOR; post-close same-day claim reverts `Panic(0x11)` (`0x4e487b71`, `0x11`); next-day claim pays 0. Phantom on-hold upper bound is `86400s * pricePerSecond` (0.78 MOR at 9e12 wei/s; 864 MOR at the maximum price 1e16 wei/s) — any residual claim below that bound is blocked until midnight UTC, and any residual above it is underpaid by the hold amount until midnight. No funds are lost: the provider was already paid in full at close.

**Suggested fix:** floor the subtraction at zero in `claimForProvider` (`amount = rewards > onHold ? rewards - onHold : 0`), and cap `closedAt` at `endsAt` inside `_getProviderOnHoldAmount` (mirroring `_getProviderRewards`' `min(closedAt, endsAt)`) so the hold never covers post-end time. Preferably, track the amount actually withheld at close and only subtract the still-withheld remainder at claim time.

**PoC:** Foundry fork test, pinned block 58461106 — https://github.com/zfamsz/morpheus-sessionrouter-claim-variants-poc (`forge test --match-contract VariantF1ClaimRevert -vv`; 2/2 tests pass). Self-contained single test file + minimal diamond interface; reproduced independently by the coordinator.

**Note on distinctness:** this is a *different* mechanism from the day-lock refund issue (SessionRouter.sol:306, final-day-only user lock). Different functions, different lines, different effect (claim revert vs. stake refund). It is not a variant of that finding.
