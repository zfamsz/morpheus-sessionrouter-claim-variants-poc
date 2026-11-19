// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

/// @title Morpheus SessionRouter — same-day claimForProvider reverts with Panic(0x11)
///         after a non-disputed close (phantom provider on-hold underflow)
/// @notice Foundry fork test against LIVE Base bytecode, pinned block 58461106.
///         Diamond (live): 0x6aBE1d282f72B474E54527D93b979A4f64d3030a
///         SessionRouter facet (live): 0x3a3952f0E57b343F00b31F7dA039eF16389B7260
///         MOROFT (Base): 0x7431aDa8a591C955a994a21710752EF9b882b8e3
///         Run: forge test --match-contract VariantF1ClaimRevert -vv
///         (RPC is the public Base endpoint; no key, no wallet, no mainnet tx.)
///
/// FINDING (Low): after a session is closed WITHOUT dispute and the provider
/// has already been paid in full, calling claimForProvider in the SAME UTC day
/// REVERTS with Panic(0x11) (arithmetic underflow) instead of returning 0.
/// Root cause (SessionRouter.sol, live code = repo HEAD, unchanged since fix #835):
///  - _getProviderOnHoldAmount (L267-277) computes
///      (closedAt - max(startOfTheDay(closedAt), openedAt)) * pricePerSecond
///    using closedAt WITHOUT capping it at endsAt, and it is applied even when
///    the provider was already paid in full at close.
///  - claimForProvider (L358-370) computes
///      amount = _getProviderRewards(session, bid, true) - _getProviderOnHoldAmount(...)
///    with no zero floor. When rewards - withdrawn == 0 but the phantom
///    on-hold is > 0, the subtraction underflows and the call panics.
/// The same-day claim reverts for EVERY non-disputed close (early or late),
/// except a close at exactly 00:00 UTC. A disputed early close does NOT
/// revert (withdrawn == rewards - onHold there, so the difference is exactly 0).
/// Impact: claim-path DoS for up to one UTC day; residual claims smaller than
/// the phantom hold (max 86400s * pricePerSecond) are blocked until midnight;
/// frontends/automation see a panic revert instead of a graceful 0.
/// The provider loses no funds already paid (they were paid in full at close);
/// the call self-heals the next UTC day (on-hold becomes 0).
/// This is a DIFFERENT mechanism from the day-lock refund issue (L306):
/// different functions, different lines, different effect.

interface IDiamondF1 {
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
    function startOfTheDay(uint128 timestamp_) external pure returns (uint128);
}

interface IERC20F1 {
    function balanceOf(address a) external view returns (uint256);
    function approve(address s, uint256 a) external returns (bool);
}

contract VariantF1ClaimRevert is Test {
    IDiamondF1 constant D = IDiamondF1(0x6aBE1d282f72B474E54527D93b979A4f64d3030a);
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    uint256 constant CHAIN_ID = 8453;

    uint256 actorPk = 0xBEEF1234;
    address actor;
    bytes32 bid7d; // price 9e12 wei/s -> 2000 MOR stake caps at 7d
    bytes32 bid2d; // price 3.4e13 wei/s -> 2000 MOR stake ~2d

    function setUp() external {
        uint256 forkId = vm.createFork("https://mainnet.base.org", 58461106);
        vm.selectFork(forkId);
        actor = vm.addr(actorPk);
        vm.deal(actor, 100 ether);
        deal(MOR, actor, 3_000_000 ether);
        vm.startPrank(actor);
        IERC20F1(MOR).approve(address(D), type(uint256).max);
        D.providerRegister(actor, 1_000_000 ether, "f1.test:1234");
        string[] memory tags = new string[](0);
        D.modelRegister(actor, keccak256("f1-model-7d"), bytes32(0), 0, 0.1 ether, "f1-7d", tags);
        D.modelRegister(actor, keccak256("f1-model-2d"), bytes32(0), 0, 0.1 ether, "f1-2d", tags);
        bytes32 m1 = D.getModelId(actor, keccak256("f1-model-7d"));
        bytes32 m2 = D.getModelId(actor, keccak256("f1-model-2d"));
        bid7d = D.postModelBid(actor, m1, 9e12);
        bid2d = D.postModelBid(actor, m2, 3.4e13);
        vm.stopPrank();
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
        return IERC20F1(MOR).balanceOf(a);
    }

    /// Late close, no dispute, provider already paid in full before close:
    /// same-day claimForProvider REVERTS with Panic(0x11); next UTC day it
    /// returns 0 cleanly.
    function test_postCloseSameDayClaimReverts() external {
        uint256 stake = 2000 ether;
        uint256 tsNow = block.timestamp;
        bytes32 sid = _openAt(bid7d, stake, false, actor, actorPk, tsNow);
        IDiamondF1.Session memory s = D.getSession(sid);
        uint256 expectedReward = (uint256(s.endsAt) - s.openedAt) * 9e12;
        emit log_named_uint("expected provider reward", expectedReward);

        // claim before endsAt -> 0
        vm.prank(actor);
        D.claimForProvider(sid);
        assertEq(D.getSession(sid).providerWithdrawnAmount, 0, "pre-end claim must be 0");

        // warp past endsAt, claim before close: paid in full
        vm.warp(uint256(s.endsAt) + 3600);
        tsNow = block.timestamp;
        uint256 provBefore = _morBal(actor);
        vm.prank(actor);
        D.claimForProvider(sid);
        uint256 preCloseClaim = _morBal(actor) - provBefore;
        emit log_named_uint("pre-close claim", preCloseClaim);
        assertEq(preCloseClaim, expectedReward, "pre-close claim must equal full reward");

        // close late (valid receipt): provider gets 0 more
        _closeAt(sid, actor, actorPk, tsNow);
        assertEq(D.getSession(sid).providerWithdrawnAmount, expectedReward, "close must not pay provider again");

        // FINDING: post-close claim in the SAME UTC day REVERTS with Panic 0x11
        // instead of returning 0 (rewards - withdrawn == 0, phantom on-hold > 0).
        vm.expectRevert(abi.encodeWithSelector(bytes4(0x4e487b71), 0x11));
        vm.prank(actor);
        D.claimForProvider(sid);

        // next UTC day: on-hold == 0, claim returns 0 cleanly
        uint128 startOfClosedDay = D.startOfTheDay(D.getSession(sid).closedAt);
        vm.warp(uint256(startOfClosedDay) + 1 days + 1);
        uint256 b2 = _morBal(actor);
        vm.prank(actor);
        D.claimForProvider(sid);
        assertEq(_morBal(actor) - b2, 0, "next-day post-close claim must be 0");
    }

    /// Revert matrix: (a) early close, NO dispute -> same-day claim reverts;
    /// (b) early close WITH dispute (invalid signer) -> same-day claim is 0.
    function test_revertMatrixEarlyClose() external {
        // (a) early close, no dispute
        uint256 tsNow = block.timestamp;
        bytes32 sidA = _openAt(bid2d, 2000 ether, false, actor, actorPk, tsNow);
        IDiamondF1.Session memory sA = D.getSession(sidA);
        vm.warp(uint256(sA.openedAt) + 1 days);
        tsNow = block.timestamp;
        _closeAt(sidA, actor, actorPk, tsNow);
        vm.expectRevert(abi.encodeWithSelector(bytes4(0x4e487b71), 0x11));
        vm.prank(actor);
        D.claimForProvider(sidA);

        // (b) early close WITH dispute -> no revert, claim is 0
        tsNow = block.timestamp;
        bytes32 sidB = _openAt(bid2d, 2000 ether, false, actor, actorPk, tsNow);
        IDiamondF1.Session memory sB = D.getSession(sidB);
        vm.warp(uint256(sB.openedAt) + 1 days);
        tsNow = block.timestamp;
        _closeAt(sidB, actor, 0xDEAD, tsNow); // invalid signer -> dispute
        uint256 b = _morBal(actor);
        vm.prank(actor);
        D.claimForProvider(sidB);
        assertEq(_morBal(actor) - b, 0, "disputed early close: same-day claim is 0, no revert");
    }
}
