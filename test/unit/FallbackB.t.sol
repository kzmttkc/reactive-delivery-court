// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {DeliveryEscrowB} from "../../src/fallback/DeliveryEscrowB.sol";
import {DeliveryCourtReactiveB} from "../../src/fallback/DeliveryCourtReactiveB.sol";
import {CourtCallbackBase} from "../../src/CourtCallbackBase.sol";
import {ICourtCallback, ICourtDepositRecorder} from "../../src/interfaces/ICourtCallback.sol";
import {IIdentityRegistry, IReputationRegistry} from "../../src/interfaces/IERC8004.sol";
import {MockERC20, ReentrantProxy, MockIdentity, MockReputation} from "../mocks/Mocks.sol";
import {CourtTestBase} from "../utils/CourtTestBase.sol";

/// @notice Fallback design B, end to end on a local chain: USDC-like Transfer(to = escrow) ->
/// react -> recordDeposit callback -> ValidationResponse -> react -> capture or void callback.
contract FallbackBTest is CourtTestBase {
    uint256 constant TRANSFER_TOPIC = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;
    uint8 constant THRESHOLD = 70;
    uint256 constant AGENT = 7;
    uint48 constant WINDOW = 30 minutes;

    MockERC20 token;
    ReentrantProxy proxy;
    MockIdentity identity;
    MockReputation reputation;
    DeliveryCourtReactiveB rc;
    DeliveryEscrowB escrow;

    address registry = makeAddr("validationRegistry");
    address validator = makeAddr("modelValidator");
    address buyer = makeAddr("buyer");
    address seller = makeAddr("seller");

    function setUp() public {
        vm.chainId(BASE_SEPOLIA);
        vm.warp(1_800_000_000);
        _etchSystem();
        token = new MockERC20();
        proxy = new ReentrantProxy();
        identity = new MockIdentity();
        reputation = new MockReputation();
        identity.setOwner(AGENT, seller);
        rc = new DeliveryCourtReactiveB(BASE_SEPOLIA, address(token), registry, validator, THRESHOLD, CRON100_TOPIC, WINDOW);
        escrow = new DeliveryEscrowB(
            address(proxy),
            address(rc),
            IERC20(address(token)),
            seller,
            WINDOW,
            IIdentityRegistry(address(identity)),
            IReputationRegistry(address(reputation))
        );
        rc.setCourt(address(escrow));
        token.mint(buyer, 1_000_000);
    }

    /// @dev Buyer pays escrow (stand-in for transferWithAuthorization), reactive sees the Transfer.
    function _pay(uint256 amount, uint256 txHash) internal returns (bytes32 id) {
        vm.prank(buyer);
        token.transfer(address(escrow), amount);
        IReactive.LogRecord memory l = _log(
            BASE_SEPOLIA,
            address(token),
            TRANSFER_TOPIC,
            uint256(uint160(buyer)),
            uint256(uint160(address(escrow))),
            0,
            abi.encode(amount)
        );
        l.txHash = txHash;
        l.logIndex = 3;
        _react(address(rc), l);
        id = rc.paymentIdOf(BASE_SEPOLIA, txHash, 3);
        (bool ok,) = _deliver(sys.callbackCount() - 1, address(proxy), address(rc));
        assertTrue(ok, "recordDeposit callback");
    }

    function _judge(bytes32 id, uint8 score) internal returns (bool ok) {
        _react(address(rc), _validationLog(registry, validator, AGENT, id, score));
        (ok,) = _deliver(sys.callbackCount() - 1, address(proxy), address(rc));
    }

    function test_subscription_isTransferToEscrowOnly() public view {
        // 0: validation, 1: cron, 2: Transfer(to = escrow)
        assertEq(sys.sub(2).target, address(token));
        assertEq(sys.sub(2).topic0, TRANSFER_TOPIC);
        assertEq(sys.sub(2).topic1, REACTIVE_IGNORE);
        assertEq(sys.sub(2).topic2, uint256(uint160(address(escrow))));
    }

    function test_delivered_paysSeller() public {
        bytes32 id = _pay(10_000, 1);
        assertEq(_selectorOf(0), ICourtDepositRecorder.recordDeposit.selector);
        assertEq(escrow.committed(), 10_000);
        assertTrue(_judge(id, 92));
        assertEq(token.balanceOf(seller), 10_000);
        assertEq(escrow.committed(), 0);
    }

    function test_lowScore_refundsBuyer_withoutFeedback() public {
        bytes32 id = _pay(10_000, 1);
        assertTrue(_judge(id, 3));
        assertEq(token.balanceOf(buyer), 1_000_000);
        assertEq(reputation.count(), 0, "M4: a low score alone writes no reputation");
    }

    function test_emptyBody_refundsBuyer_withFeedback() public {
        bytes32 id = _pay(10_000, 1);
        _react(address(rc), _validationLog(registry, validator, AGENT, id, 99, EMPTY_SHA256, "dc1:200:0:3000"));
        (bool ok,) = _deliver(sys.callbackCount() - 1, address(proxy), address(rc));
        assertTrue(ok);
        assertEq(token.balanceOf(buyer), 1_000_000);
        assertEq(reputation.count(), 1);
    }

    function test_threshold_boundary() public {
        bytes32 a = _pay(1, 1);
        bytes32 b = _pay(1, 2);
        _judge(a, THRESHOLD - 1);
        _judge(b, THRESHOLD);
        assertEq(uint8(escrow.status(a)), uint8(CourtCallbackBase.Status.Voided));
        assertEq(uint8(escrow.status(b)), uint8(CourtCallbackBase.Status.Captured));
    }

    function test_silent_refundedOnCron() public {
        bytes32 id = _pay(10_000, 1);
        vm.warp(block.timestamp + WINDOW);
        _react(address(rc), _cronLog());
        (bool ok,) = _deliver(sys.callbackCount() - 1, address(proxy), address(rc));
        assertTrue(ok);
        assertEq(uint8(escrow.status(id)), uint8(CourtCallbackBase.Status.Voided));
        assertEq(token.balanceOf(buyer), 1_000_000);
    }

    function test_reclaimExpired_safetyNet_onlyAfterDeadline_onlyToBuyer() public {
        bytes32 id = _pay(10_000, 1);
        vm.expectRevert();
        escrow.reclaimExpired(id);
        vm.warp(block.timestamp + WINDOW);
        vm.prank(seller);
        escrow.reclaimExpired(id);
        assertEq(token.balanceOf(buyer), 1_000_000);
        assertEq(token.balanceOf(seller), 0);
        // The late reactive decision can no longer move the funds.
        assertFalse(_judge(id, 100));
    }

    function test_recordDeposit_permissions() public {
        vm.prank(buyer);
        token.transfer(address(escrow), 5);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, buyer, address(proxy)));
        escrow.recordDeposit(address(rc), bytes32("x"), buyer, 5);
        vm.prank(address(proxy));
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, buyer, address(rc)));
        escrow.recordDeposit(buyer, bytes32("x"), buyer, 5);
    }

    function test_recordDeposit_cannotExceedBalance() public {
        _pay(10_000, 1);
        vm.prank(address(proxy));
        vm.expectRevert(abi.encodeWithSelector(DeliveryEscrowB.Uncovered.selector, 10_000, 10_001));
        escrow.recordDeposit(address(rc), bytes32("phantom"), buyer, 1);
    }

    function test_doubleResolution_rejected() public {
        bytes32 id = _pay(10_000, 1);
        assertTrue(_judge(id, 92));
        (bool ok,) = _deliver(sys.callbackCount() - 1, address(proxy), address(rc));
        assertFalse(ok);
        vm.prank(address(proxy));
        vm.expectRevert(
            abi.encodeWithSelector(CourtCallbackBase.NotPending.selector, id, CourtCallbackBase.Status.Captured)
        );
        escrow.courtVoid(address(rc), id, AGENT, 0, 2);
    }

    function test_sameTransferTwice_recordsOnce() public {
        _pay(10_000, 1);
        IReactive.LogRecord memory l = _log(
            BASE_SEPOLIA,
            address(token),
            TRANSFER_TOPIC,
            uint256(uint160(buyer)),
            uint256(uint160(address(escrow))),
            0,
            abi.encode(uint256(10_000))
        );
        l.txHash = 1;
        l.logIndex = 3;
        uint256 before = sys.callbackCount();
        _react(address(rc), l);
        assertEq(sys.callbackCount(), before);
    }

    function test_reentryDuringRelease_isBlocked() public {
        bytes32 id = _pay(10_000, 1);
        token.setHook(address(proxy));
        proxy.arm(address(escrow), abi.encodeCall(ICourtCallback.courtVoid, (address(rc), id, AGENT, 0, 2)));
        assertTrue(_judge(id, 92));
        assertTrue(proxy.reentryAttempted());
        assertFalse(proxy.reentrySucceeded());
        assertEq(bytes4(proxy.reentryError()), CourtCallbackBase.Reentrancy.selector);
        assertEq(token.balanceOf(seller), 10_000);
    }

    function testFuzz_conservation(uint96 a, uint96 b, uint8 sa, uint8 sb) public {
        uint256 amtA = bound(a, 1, 400_000);
        uint256 amtB = bound(b, 1, 400_000);
        bytes32 ida = _pay(amtA, 11);
        bytes32 idb = _pay(amtB, 12);
        _judge(ida, uint8(bound(sa, 0, 100)));
        _judge(idb, uint8(bound(sb, 0, 100)));
        uint256 toSeller = token.balanceOf(seller);
        uint256 returned = token.balanceOf(buyer) - (1_000_000 - amtA - amtB);
        assertEq(toSeller + returned, amtA + amtB);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(escrow.committed(), 0);
    }
}
