// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

/// @title Morpheus SessionRouter — direct-payment sessions: user charged the FULL
///         provider reward at close, but the provider is paid only up to its
///         365-day limiter cap; the shortfall strands in the diamond
/// @notice Foundry fork test against LIVE Base bytecode, pinned block 58461106.
///         Diamond (live): 0x6aBE1d282f72B474E54527D93b979A4f64d3030a
///         SessionRouter facet (live): 0x3a3952f0E57b343F00b31F7dA039eF16389B7260
///         MOROFT (Base): 0x7431aDa8a591C955a994a21710752EF9b882b8e3
///         Run: forge test --match-contract VariantF2DirectLimiter -vv
///         (RPC is the public Base endpoint; no key, no wallet, no mainnet tx.)
///
/// FINDING (Low): for a DIRECT-payment session (isDirectPaymentFromUser=true),
/// _rewardUserAfterClose (L293-320) deducts the FULL provider reward from the
/// user's stake, while _claimForProvider (L374-390) caps what the provider
/// actually receives at provider.stake - limitPeriodEarned (365-day limiter).
/// When the reward exceeds the provider's stake, the difference stays in the
/// diamond: the user has paid for a reward the provider cannot receive, and
/// the user has no path to reclaim it.
/// Measured (2000 MOR direct session, provider stake 0.2 MOR = minimum):
/// full reward 5.4432 MOR; provider paid 0.2 MOR at close; user refund =
/// 2000 - 5.4432 - lock(27.6981) = 1966.8587 MOR (charged in full);
/// shortfall 5.2432 MOR stranded. After ONE limiter reset (+366 days) the
/// provider can claim only 0.2 MOR more; recovering the shortfall needs
/// ceil(5.2432/0.2) = 27 annual periods (~26 years) at minimum stake.
/// The shortfall is not permanently lost, but it is practically stranded:
/// the only faster path is the provider locking additional stake equal to the
/// shortfall (providerRegister tops stake up without resetting the period),
/// i.e. locking matching collateral to unlock its own reward.
/// This is a DIFFERENT mechanism from the day-lock refund issue (L306):
/// a limiter/accounting mismatch, not a day-lock scoping error.

interface IDiamondF2 {
    struct Session {
        address user;
        bytes32 bidId;
        uint256 stake;
        bytes closeoutReceipt;
        uint256 closeoutType;
        uint256 providerWithdrawnAmount;
        uint128 openedAt;
        uint128 endsAt;
        uint128 closedAt;
        bool isActive;
        bool isDirectPaymentFromUser;
    }
    function providerRegister(address provider_, uint256 amount_, string calldata endpoint_) external;
    function modelRegister(address modelOwner_, bytes32 baseModelId_, bytes32 ipfsCID_, uint256 fee_, uint256 amount_, string calldata name_, string[] memory tags_) external;
    function getModelId(address account_, bytes32 baseModelId_) external pure returns (bytes32);
    function postModelBid(address provider_, bytes32 modelId_, uint256 pricePerSecond_) external returns (bytes32);
    function openSession(address user_, uint256 amount_, bool isDirectPaymentFromUser_, bytes calldata approvalEncoded_, bytes calldata signature_) external returns (bytes32);
    function closeSession(bytes calldata receiptEncoded_, bytes calldata signature_) external;
    function claimForProvider(bytes32 sessionId_) external;
    function getSession(bytes32 sessionId_) external view returns (Session memory);
    function getUserStakesOnHold(address user_, uint8 iterations_) external view returns (uint256, uint256);
}

interface IERC20F2 {
    function balanceOf(address a) external view returns (uint256);
    function approve(address s, uint256 a) external returns (bool);
}

contract VariantF2DirectLimiter is Test {
    IDiamondF2 constant D = IDiamondF2(0x6aBE1d282f72B474E54527D93b979A4f64d3030a);
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    uint256 constant CHAIN_ID = 8453;

    function setUp() external {
        uint256 forkId = vm.createFork("https://mainnet.base.org", 58461106);
        vm.selectFork(forkId);
    }

    function _sign(uint256 pk, bytes memory payload) internal pure returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", keccak256(payload)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ts is a plain uint256 captured from block.timestamp right after each warp
    // (avoids a Foundry quirk where uint128(block.timestamp) can read stale).
    function _openAt(bytes32 bidId, uint256 stake, bool direct, address user, uint256 signerPk, uint256 ts) internal returns (bytes32 sessionId) {
        bytes memory approval = abi.encode(bidId, CHAIN_ID, user, ts);
        bytes memory sig = _sign(signerPk, approval);
        vm.prank(user);
        sessionId = D.openSession(user, stake, direct, approval, sig);
    }

    function _closeAt(bytes32 sessionId, address caller, uint256 signerPk, uint256 ts) internal {
        bytes memory receipt = abi.encode(sessionId, CHAIN_ID, ts, uint32(1000), uint32(100));
        bytes memory sig = _sign(signerPk, receipt);
        vm.prank(caller);
        D.closeSession(receipt, sig);
    }

    function _morBal(address a) internal view returns (uint256) {
        return IERC20F2(MOR).balanceOf(a);
    }

    /// Direct session, 2000 MOR stake, provider stake 0.2 MOR (minimum):
    /// user charged the FULL 5.4432 MOR reward; provider paid only 0.2 MOR;
    /// 5.2432 MOR stranded; one limiter reset buys only 0.2 MOR more.
    function test_directPaymentLimiterMismatch() external {
        uint256 pk2 = 0xBEEF5678;
        address actor2 = vm.addr(pk2);
        vm.deal(actor2, 10 ether);
        deal(MOR, actor2, 10_000 ether);
        vm.startPrank(actor2);
        IERC20F2(MOR).approve(address(D), type(uint256).max);
        D.providerRegister(actor2, 0.2 ether, "f2-small.test:1234");
        string[] memory tags = new string[](0);
        D.modelRegister(actor2, keccak256("f2-small-model"), bytes32(0), 0, 0.1 ether, "f2-small", tags);
        bytes32 m = D.getModelId(actor2, keccak256("f2-small-model"));
        bytes32 bidSmall = D.postModelBid(actor2, m, 9e12);
        vm.stopPrank();

        // open DIRECT session, 2000 MOR
        uint256 tsNow = block.timestamp;
        bytes32 sid = _openAt(bidSmall, 2000 ether, true, actor2, pk2, tsNow);
        IDiamondF2.Session memory s = D.getSession(sid);
        uint256 fullReward = (uint256(s.endsAt) - s.openedAt) * 9e12;
        emit log_named_uint("direct full provider reward", fullReward);
        assertGt(fullReward, 0.2 ether, "reward must exceed small provider stake");

        // close late, valid receipt
        vm.warp(uint256(s.endsAt) + 60);
        tsNow = block.timestamp;
        uint256 userBefore = _morBal(actor2);
        _closeAt(sid, actor2, pk2, tsNow);
        assertEq(uint256(D.getSession(sid).closedAt), tsNow, "closedAt == warped time");
        uint256 paid = D.getSession(sid).providerWithdrawnAmount;
        (uint256 avail, uint256 hold) = D.getUserStakesOnHold(actor2, 10);
        // actor2 is BOTH user and provider: delta = user refund + provider pay
        uint256 totalOut = _morBal(actor2) - userBefore;
        uint256 userRefund = totalOut - paid;
        emit log_named_uint("provider paid at close (limiter-capped)", paid);
        emit log_named_uint("user lock", hold);
        emit log_named_uint("user immediate refund", userRefund);
        assertEq(paid, 0.2 ether, "provider paid only up to its 0.2 MOR stake (365d limiter)");
        assertEq(userRefund, 2000 ether - fullReward - hold, "user charged FULL reward despite provider cap");
        uint256 shortfall = 2000 ether - userRefund - paid - hold;
        emit log_named_uint("shortfall stranded in diamond", shortfall);
        assertEq(shortfall, fullReward - paid, "shortfall = fullReward - paid");

        // After ONE limiter reset the provider can claim only ONE more period's
        // cap (0.2 MOR): the limiter caps EVERY 365d period at provider.stake.
        // Recovering the 5.2432 MOR shortfall needs ceil(5.2432/0.2) = 27 periods
        // (~26 years of annual claims). The shortfall is effectively stranded.
        vm.warp(block.timestamp + 366 days);
        uint256 b = _morBal(actor2);
        vm.prank(actor2);
        D.claimForProvider(sid);
        uint256 latePay = _morBal(actor2) - b;
        emit log_named_uint("provider late claim after ONE limiter reset", latePay);
        assertEq(latePay, 0.2 ether, "one reset buys only one more 0.2 MOR period cap");
        assertEq(D.getSession(sid).providerWithdrawnAmount, 0.4 ether, "provider total after 2 periods");
        uint256 periodsToRecover = (shortfall + 0.2 ether - 1) / 0.2 ether;
        emit log_named_uint("limiter periods to fully recover shortfall", periodsToRecover);
        assertEq(periodsToRecover, 27, "27 annual periods (~26y) to recover 5.2432 MOR");
        avail;
    }
}
