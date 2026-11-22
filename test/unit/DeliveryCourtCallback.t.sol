// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {AuthCaptureEscrow} from "commerce-payments/AuthCaptureEscrow.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {DeliveryCourtCallback} from "../../src/DeliveryCourtCallback.sol";
import {CourtCallbackBase} from "../../src/CourtCallbackBase.sol";
import {IIdentityRegistry, IReputationRegistry, IValidationRegistry} from "../../src/interfaces/IERC8004.sol";
import {MockERC20, TestCollector, ReentrantProxy, MockIdentity, MockReputation, MockValidation} from "../mocks/Mocks.sol";

/// @notice Unit tests against a locally deployed copy of the official AuthCaptureEscrow v1.1.0.
contract DeliveryCourtCallbackTest is Test {
    AuthCaptureEscrow escrow;
    TestCollector collector;
    MockERC20 token;
    ReentrantProxy proxy;
    MockIdentity identity;
    MockReputation reputation;
    MockValidation validation;
    DeliveryCourtCallback court;

    address reactive = makeAddr("reactive");
    address payer = makeAddr("payer");
    address seller = makeAddr("seller");
    address facilitator = makeAddr("facilitator");
    address judge = makeAddr("judge");
    uint256 constant AGENT = 7;
    uint256 constant PRICE = 10_000; // 0.01 USDC, what the demo sellers charge
    bytes32 constant EMPTY = 0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855;

    function setUp() public {
        escrow = new AuthCaptureEscrow();
        collector = new TestCollector(address(escrow));
        token = new MockERC20();
        proxy = new ReentrantProxy();
        identity = new MockIdentity();
        reputation = new MockReputation();
        validation = new MockValidation();
        court = new DeliveryCourtCallback(
            address(proxy),
            reactive,
            escrow,
            address(token),
            IIdentityRegistry(address(identity)),
            IReputationRegistry(address(reputation)),
            IValidationRegistry(address(validation)),
            judge
        );
        identity.setOwner(AGENT, seller);
        // Registered without an agent: reputation entries go to the agent named by the judge's log.
        court.registerSeller(seller, 0);
    }

    // ------------------------------------------------------------------ helpers

    function _info(uint120 maxAmount, uint256 salt) internal view returns (AuthCaptureEscrow.PaymentInfo memory) {
        uint48 t = uint48(block.timestamp);
        return AuthCaptureEscrow.PaymentInfo({
            operator: address(court),
            payer: payer,
            receiver: seller,
            token: address(token),
            maxAmount: maxAmount,
            preApprovalExpiry: t + 1 hours,
            authorizationExpiry: t + 1 hours,
            refundExpiry: t + 1 hours,
            minFeeBps: 0,
            maxFeeBps: 0,
            feeReceiver: address(0),
            salt: salt
        });
    }

    function _deposit(uint256 amount, uint120 maxAmount, uint256 salt) internal returns (bytes32 id) {
        AuthCaptureEscrow.PaymentInfo memory info = _info(maxAmount, salt);
        token.mint(payer, maxAmount);
        vm.prank(payer);
        token.approve(address(collector), type(uint256).max);
        vm.prank(facilitator);
        court.authorize(info, amount, address(collector), "");
        id = escrow.getHash(info);
    }

    /// @dev The judge's entry in the ValidationRegistry agrees with the decision, then the proxy calls.
    function _capture(bytes32 id, uint8 score) internal {
        validation.set(id, judge, score, keccak256("body"));
        vm.prank(address(proxy));
        court.courtCapture(reactive, id, AGENT, score);
    }

    function _void(bytes32 id, uint8 score, uint8 reason) internal {
        vm.prank(address(proxy));
        court.courtVoid(reactive, id, AGENT, score, reason);
    }

    // ------------------------------------------------------------------ collect

    function test_authorize_isPermissionless_andEmitsDeposited() public {
        AuthCaptureEscrow.PaymentInfo memory info = _info(uint120(PRICE), 1);
        bytes32 id = escrow.getHash(info);
        token.mint(payer, PRICE);
        vm.prank(payer);
        token.approve(address(collector), PRICE);

        vm.expectEmit(true, true, true, true, address(court));
        emit DeliveryCourtCallback.Deposited(id, payer, seller, PRICE, info.authorizationExpiry);
        vm.prank(makeAddr("anyone"));
        court.authorize(info, PRICE, address(collector), "");

        assertEq(uint8(court.status(id)), uint8(CourtCallbackBase.Status.Pending));
        assertEq(token.balanceOf(escrow.getTokenStore(address(court))), PRICE);
        (, uint120 capturable,) = escrow.paymentState(id);
        assertEq(capturable, PRICE);
    }

    function test_authorize_rejectsWrongOperator() public {
        AuthCaptureEscrow.PaymentInfo memory info = _info(uint120(PRICE), 1);
        info.operator = facilitator;
        vm.expectRevert(abi.encodeWithSelector(DeliveryCourtCallback.WrongOperator.selector, facilitator));
        court.authorize(info, PRICE, address(collector), "");
    }

    function test_authorize_rejectsWrongToken() public {
        AuthCaptureEscrow.PaymentInfo memory info = _info(uint120(PRICE), 1);
        info.token = address(0xdead);
        vm.expectRevert(abi.encodeWithSelector(DeliveryCourtCallback.WrongToken.selector, address(0xdead)));
        court.authorize(info, PRICE, address(collector), "");
    }

    function test_authorize_rejectsFees() public {
        AuthCaptureEscrow.PaymentInfo memory info = _info(uint120(PRICE), 1);
        info.maxFeeBps = 100;
        vm.expectRevert(DeliveryCourtCallback.FeesNotAllowed.selector);
        court.authorize(info, PRICE, address(collector), "");
    }

    function test_authorize_rejectsDuplicate() public {
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        AuthCaptureEscrow.PaymentInfo memory info = _info(uint120(PRICE), 1);
        vm.expectRevert(abi.encodeWithSelector(DeliveryCourtCallback.AlreadyDeposited.selector, id));
        court.authorize(info, PRICE, address(collector), "");
    }

    function test_charge_isRefused() public {
        AuthCaptureEscrow.PaymentInfo memory info = _info(uint120(PRICE), 1);
        vm.expectRevert(DeliveryCourtCallback.ChargeNotSupported.selector);
        court.charge(info, PRICE, address(collector), "", 0, address(0));
    }

    // ------------------------------------------------------------------ permissions

    function test_capture_revertsFromAnyoneButProxy() public {
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, seller, address(proxy)));
        court.courtCapture(reactive, id, AGENT, 100);
    }

    function test_void_revertsFromAnyoneButProxy() public {
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, payer, address(proxy)));
        court.courtVoid(reactive, id, AGENT, 0, 1);
    }

    function test_capture_revertsFromReactiveAddressCallingDirectly() public {
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        vm.prank(reactive);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, reactive, address(proxy)));
        court.courtCapture(reactive, id, AGENT, 100);
    }

    function test_capture_revertsWhenProxyCarriesOtherReactiveSender() public {
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        address other = makeAddr("otherReactive");
        vm.prank(address(proxy));
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, other, reactive));
        court.courtCapture(other, id, AGENT, 100);
    }

    function test_void_revertsWhenProxyCarriesOtherReactiveSender() public {
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        vm.prank(address(proxy));
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, address(0), reactive));
        court.courtVoid(address(0), id, AGENT, 0, 1);
    }

    function test_escrowLifecycle_cannotBeDrivenAroundTheCourt() public {
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        AuthCaptureEscrow.PaymentInfo memory info = court.paymentInfoOf(id);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(AuthCaptureEscrow.InvalidSender.selector, seller, address(court)));
        escrow.capture(info, PRICE, 0, address(0));
        vm.prank(facilitator);
        vm.expectRevert(abi.encodeWithSelector(AuthCaptureEscrow.InvalidSender.selector, facilitator, address(court)));
        escrow.void(info);
    }

    // ------------------------------------------------------------------ resolution

    function test_capture_paysSeller() public {
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        _capture(id, 92);
        assertEq(token.balanceOf(seller), PRICE);
        assertEq(uint8(court.status(id)), uint8(CourtCallbackBase.Status.Captured));
        assertEq(reputation.count(), 0);
    }

    // M4: a low score alone refunds and writes nothing. Only silence and an empty body are on record.

    function test_M4_voidLowScore_refundsBuyer_withoutFeedback() public {
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        _void(id, 3, 1);
        assertEq(token.balanceOf(payer), PRICE);
        assertEq(token.balanceOf(seller), 0);
        assertEq(reputation.count(), 0, "a low score is not a public accusation");
    }

    function test_M4_voidEmptyBody_givesFeedback() public {
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        _void(id, 0, 3);
        assertEq(token.balanceOf(payer), PRICE);
        assertEq(reputation.count(), 1);
        assertEq(reputation.lastAgentId(), AGENT);
        assertEq(reputation.lastValue(), 0);
        assertEq(reputation.lastHash(), id);
        assertEq(reputation.lastTag2(), "empty-body");
    }

    function test_M4_voidExpired_givesFeedback_toTheRegisteredAgent() public {
        court.registerSeller(seller, AGENT);
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        // A cron expiry carries no agent (no judge log); the registered one is used.
        vm.prank(address(proxy));
        court.courtVoid(reactive, id, 0, 0, 2);
        assertEq(token.balanceOf(payer), PRICE);
        assertEq(reputation.count(), 1);
        assertEq(reputation.lastAgentId(), AGENT);
        assertEq(reputation.lastTag2(), "silent");
    }

    function test_M4_voidExpired_withoutAgent_refundsWithoutFeedback() public {
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        vm.prank(address(proxy));
        court.courtVoid(reactive, id, 0, 0, 2);
        assertEq(token.balanceOf(payer), PRICE);
        assertEq(reputation.count(), 0);
    }

    function test_M4_judgeSideFaults_refundWithoutFeedback() public {
        // 4 no facts, 5 inconsistent facts, 6 score after the deadline: not the seller's fault on the facts.
        for (uint8 r = 4; r <= 6; ++r) {
            bytes32 id = _deposit(PRICE, uint120(PRICE), r);
            _void(id, 0, r);
            assertEq(uint8(court.status(id)), uint8(CourtCallbackBase.Status.Voided));
        }
        assertEq(token.balanceOf(payer), 3 * PRICE);
        assertEq(reputation.count(), 0);
    }

    function test_M4_registeredAgentWinsOverTheLogsAgent() public {
        uint256 other = 42;
        identity.setOwner(other, seller);
        court.registerSeller(seller, other);
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        _void(id, 0, 3); // log names AGENT
        assertEq(reputation.lastAgentId(), other);
    }

    function test_void_rejectsUnknownReason() public {
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        uint8[3] memory bad = [uint8(0), 7, 9];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(address(proxy));
            vm.expectRevert(abi.encodeWithSelector(CourtCallbackBase.BadReason.selector, bad[i]));
            court.courtVoid(reactive, id, AGENT, 0, bad[i]);
        }
    }

    function test_feedbackSkipped_whenAgentIsNotTheReceiver() public {
        identity.setOwner(99, makeAddr("stranger"));
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        vm.prank(address(proxy));
        court.courtVoid(reactive, id, 99, 0, 3);
        assertEq(token.balanceOf(payer), PRICE);
        assertEq(reputation.count(), 0);
    }

    function test_feedbackFailure_doesNotBlockRefund() public {
        reputation.setRevert(true);
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        _void(id, 0, 3);
        assertEq(token.balanceOf(payer), PRICE);
    }

    function test_feedbackSkipped_whenAgentDoesNotExist() public {
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        vm.prank(address(proxy));
        court.courtVoid(reactive, id, 12345, 0, 3);
        assertEq(token.balanceOf(payer), PRICE);
        assertEq(reputation.count(), 0);
    }

    function test_unknownPayment_cannotBeResolved() public {
        bytes32 id = keccak256("nope");
        vm.prank(address(proxy));
        vm.expectRevert(
            abi.encodeWithSelector(CourtCallbackBase.NotPending.selector, id, CourtCallbackBase.Status.None)
        );
        court.courtCapture(reactive, id, AGENT, 100);
    }

    // ------------------------------------------------------------------ double resolution

    function test_doubleCapture_reverts() public {
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        _capture(id, 92);
        vm.prank(address(proxy));
        vm.expectRevert(
            abi.encodeWithSelector(CourtCallbackBase.NotPending.selector, id, CourtCallbackBase.Status.Captured)
        );
        court.courtCapture(reactive, id, AGENT, 92);
    }

    function test_voidAfterCapture_reverts() public {
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        _capture(id, 92);
        vm.prank(address(proxy));
        vm.expectRevert(
            abi.encodeWithSelector(CourtCallbackBase.NotPending.selector, id, CourtCallbackBase.Status.Captured)
        );
        court.courtVoid(reactive, id, AGENT, 0, 2);
    }

    function test_captureAfterVoid_reverts() public {
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        _void(id, 3, 1);
        vm.prank(address(proxy));
        vm.expectRevert(
            abi.encodeWithSelector(CourtCallbackBase.NotPending.selector, id, CourtCallbackBase.Status.Voided)
        );
        court.courtCapture(reactive, id, AGENT, 100);
    }

    function test_doubleVoid_reverts() public {
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        _void(id, 0, 2);
        vm.prank(address(proxy));
        vm.expectRevert(
            abi.encodeWithSelector(CourtCallbackBase.NotPending.selector, id, CourtCallbackBase.Status.Voided)
        );
        court.courtVoid(reactive, id, AGENT, 0, 2);
    }

    function test_captureAfterAuthorizationExpiry_revertsAndKeepsPending() public {
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        validation.set(id, judge, 100, keccak256("body"));
        vm.warp(block.timestamp + 2 hours);
        vm.prank(address(proxy));
        vm.expectRevert();
        court.courtCapture(reactive, id, AGENT, 100);
        assertEq(uint8(court.status(id)), uint8(CourtCallbackBase.Status.Pending));
        // Void still works after expiry, so the cron path can always refund.
        _void(id, 0, 2);
        assertEq(token.balanceOf(payer), PRICE);
    }

    // ------------------------------------------------------------------ reentrancy

    function test_reentryDuringVoid_isBlocked() public {
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        token.setHook(address(proxy));
        proxy.arm(address(court), abi.encodeCall(court.courtCapture, (reactive, id, AGENT, 100)));

        _void(id, 3, 1);

        assertTrue(proxy.reentryAttempted());
        assertFalse(proxy.reentrySucceeded());
        assertEq(bytes4(proxy.reentryError()), CourtCallbackBase.Reentrancy.selector);
        assertEq(token.balanceOf(payer), PRICE);
        assertEq(token.balanceOf(seller), 0);
    }

    function test_reentryDuringCapture_isBlocked() public {
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        token.setHook(address(proxy));
        proxy.arm(address(court), abi.encodeCall(court.courtVoid, (reactive, id, AGENT, 0, 2)));

        _capture(id, 92);

        assertTrue(proxy.reentryAttempted());
        assertFalse(proxy.reentrySucceeded());
        assertEq(bytes4(proxy.reentryError()), CourtCallbackBase.Reentrancy.selector);
        assertEq(token.balanceOf(seller), PRICE);
        assertEq(token.balanceOf(payer), 0);
    }

    function test_reentryIntoAuthorize_isBlocked() public {
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        AuthCaptureEscrow.PaymentInfo memory other = _info(uint120(PRICE), 2);
        token.setHook(address(proxy));
        proxy.arm(address(court), abi.encodeCall(court.authorize, (other, PRICE, address(collector), "")));

        _capture(id, 92);

        assertFalse(proxy.reentrySucceeded());
        assertEq(bytes4(proxy.reentryError()), CourtCallbackBase.Reentrancy.selector);
    }

    // ------------------------------------------------------------------ authorize limits (H2)

    function test_H2_authorize_rejectsAmountBelowMinimum() public {
        AuthCaptureEscrow.PaymentInfo memory info = _info(uint120(PRICE), 1);
        token.mint(payer, PRICE);
        vm.prank(payer);
        token.approve(address(collector), PRICE);
        vm.expectRevert(abi.encodeWithSelector(DeliveryCourtCallback.AmountTooSmall.selector, uint256(999)));
        court.authorize(info, 999, address(collector), "");
        court.authorize(info, 1000, address(collector), ""); // exactly the minimum is fine
    }

    function test_H2_authorize_rejectsDeadlineMoreThanAnHourAhead() public {
        AuthCaptureEscrow.PaymentInfo memory info = _info(uint120(PRICE), 1);
        info.authorizationExpiry = uint48(block.timestamp + 1 hours + 1);
        info.refundExpiry = info.authorizationExpiry;
        vm.expectRevert(abi.encodeWithSelector(DeliveryCourtCallback.DeadlineTooFar.selector, info.authorizationExpiry));
        court.authorize(info, PRICE, address(collector), "");
        _deposit(PRICE, uint120(PRICE), 2); // _info uses exactly now + 1 hour
    }

    function test_H2_authorize_rejectsUnregisteredSeller() public {
        AuthCaptureEscrow.PaymentInfo memory info = _info(uint120(PRICE), 1);
        address stranger = makeAddr("stranger");
        info.receiver = stranger;
        vm.expectRevert(abi.encodeWithSelector(DeliveryCourtCallback.SellerNotRegistered.selector, stranger));
        court.authorize(info, PRICE, address(collector), "");
    }

    function test_H2_removeSeller_stopsNewPayments_butPendingOnesStillResolve() public {
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        vm.expectEmit(true, false, false, false, address(court));
        emit CourtCallbackBase.SellerRemoved(seller);
        court.removeSeller(seller);
        (bool registered,) = court.sellers(seller);
        assertFalse(registered);
        AuthCaptureEscrow.PaymentInfo memory info = _info(uint120(PRICE), 2);
        vm.expectRevert(abi.encodeWithSelector(DeliveryCourtCallback.SellerNotRegistered.selector, seller));
        court.authorize(info, PRICE, address(collector), "");
        _capture(id, 90);
        assertEq(token.balanceOf(seller), PRICE);
    }

    function test_H2_sellerRegistry_onlyOwner_andEmits() public {
        address s2 = makeAddr("seller2");
        vm.prank(seller);
        vm.expectRevert(CourtCallbackBase.NotOwner.selector);
        court.registerSeller(s2, 1);
        vm.prank(seller);
        vm.expectRevert(CourtCallbackBase.NotOwner.selector);
        court.removeSeller(seller);
        vm.expectRevert(CourtCallbackBase.ZeroSeller.selector);
        court.registerSeller(address(0), 1);

        vm.expectEmit(true, true, false, false, address(court));
        emit CourtCallbackBase.SellerRegistered(s2, 5);
        court.registerSeller(s2, 5);
        (bool registered, uint256 agent) = court.sellers(s2);
        assertTrue(registered);
        assertEq(agent, 5);
        assertEq(court.owner(), address(this));
    }

    // ------------------------------------------------------------------ registry second look (#12)

    function _captureWithRegistry(bytes32 id, uint8 score) internal {
        vm.prank(address(proxy));
        court.courtCapture(reactive, id, AGENT, score);
    }

    function test_registry_agrees_paysSeller() public {
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        validation.set(id, judge, 95, keccak256("body"));
        _captureWithRegistry(id, 90); // decided on min(95, on-chain) = 90
        assertEq(token.balanceOf(seller), PRICE);
    }

    function test_registry_otherValidator_refunds() public {
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        validation.set(id, makeAddr("someoneElse"), 95, keccak256("body"));
        vm.expectEmit(true, false, false, true, address(court));
        emit CourtCallbackBase.Resolved(id, false, PRICE, 90, 7);
        _captureWithRegistry(id, 90);
        assertEq(token.balanceOf(payer), PRICE);
        assertEq(token.balanceOf(seller), 0);
        assertEq(uint8(court.status(id)), uint8(CourtCallbackBase.Status.Voided));
        assertEq(reputation.count(), 0);
    }

    function test_registry_lowerScoreThanDecided_refunds() public {
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        validation.set(id, judge, 20, keccak256("body"));
        _captureWithRegistry(id, 90);
        assertEq(token.balanceOf(payer), PRICE);
    }

    function test_registry_emptyBodyHash_refunds() public {
        bytes32 id = _deposit(PRICE, uint120(PRICE), 1);
        validation.set(id, judge, 99, EMPTY);
        _captureWithRegistry(id, 90);
        assertEq(token.balanceOf(payer), PRICE);
    }

    function test_registry_unknownOrDown_refunds() public {
        bytes32 a = _deposit(PRICE, uint120(PRICE), 1);
        _captureWithRegistry(a, 90); // never written
        assertEq(uint8(court.status(a)), uint8(CourtCallbackBase.Status.Voided));
        bytes32 b = _deposit(PRICE, uint120(PRICE), 2);
        validation.set(b, judge, 99, keccak256("body"));
        validation.setDown(true);
        _captureWithRegistry(b, 90);
        assertEq(uint8(court.status(b)), uint8(CourtCallbackBase.Status.Voided));
        assertEq(token.balanceOf(payer), 2 * PRICE);
    }

    // ------------------------------------------------------------------ conservation

    /// @notice deposited == paid to seller + returned to buyer, for any amount and any decision.
    function testFuzz_conservation(uint120 maxAmount, uint120 amountSeed, bool capture, uint8 score) public {
        maxAmount = uint120(bound(maxAmount, court.MIN_AMOUNT(), 1e15));
        uint256 amount = bound(amountSeed, court.MIN_AMOUNT(), maxAmount);
        bytes32 id = _deposit(amount, maxAmount, uint256(keccak256(abi.encode(maxAmount, amountSeed))));
        address store = escrow.getTokenStore(address(court));
        uint256 payerAfterDeposit = token.balanceOf(payer);
        assertEq(payerAfterDeposit, maxAmount - amount);
        assertEq(token.balanceOf(store), amount);

        if (capture) _capture(id, score);
        else _void(id, score, uint8(score % 6) + 1);

        uint256 toSeller = token.balanceOf(seller);
        uint256 toPayer = token.balanceOf(payer) - payerAfterDeposit;
        assertEq(toSeller + toPayer, amount, "deposited == paid + returned");
        assertEq(capture ? toSeller : toPayer, amount);
        assertEq(token.balanceOf(store), 0, "nothing left in escrow");
        assertEq(token.balanceOf(address(court)), 0, "court never holds funds");
        assertEq(token.totalSupply(), uint256(maxAmount));
    }

    function test_conservation_manyPayments() public {
        uint256 total;
        bytes32[] memory ids = new bytes32[](6);
        for (uint256 i; i < ids.length; ++i) {
            uint256 amt = (i + 1) * 1000;
            total += amt;
            ids[i] = _deposit(amt, uint120(amt), i + 100);
        }
        address store = escrow.getTokenStore(address(court));
        assertEq(token.balanceOf(store), total);
        for (uint256 i; i < ids.length; ++i) {
            if (i % 2 == 0) _capture(ids[i], 90);
            else _void(ids[i], 10, 1);
        }
        assertEq(token.balanceOf(seller) + token.balanceOf(payer), total);
        assertEq(token.balanceOf(store), 0);
    }
}
