// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Vm} from "forge-std/Test.sol";
import {AuthCaptureEscrow} from "commerce-payments/AuthCaptureEscrow.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {DeliveryCourtCallback} from "../../src/DeliveryCourtCallback.sol";
import {DeliveryCourtReactive} from "../../src/DeliveryCourtReactive.sol";
import {CourtCallbackBase} from "../../src/CourtCallbackBase.sol";
import {CourtReactiveBase} from "../../src/CourtReactiveBase.sol";
import {ICourtCallback} from "../../src/interfaces/ICourtCallback.sol";
import {
    IIdentityRegistry, IReputationRegistry, IValidationRegistry
} from "../../src/interfaces/IERC8004.sol";
import {CourtTestBase} from "../utils/CourtTestBase.sol";

interface IUSDC {
    function balanceOf(address) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);
}

/// @notice Runs against a Base Sepolia fork: the deployed AuthCaptureEscrow v1.1, the deployed
/// ERC3009PaymentCollector, real USDC, and the deployed ERC-8004 registries. The Lasna system
/// contract is a mock etched at 0x8888 and the callback proxy is impersonated at its real address.
/// RPC: BASE_SEPOLIA_RPC_URL, default https://sepolia.base.org (public).
contract DeliveryCourtForkTest is CourtTestBase {
    // Base Sepolia (STAGE0_FACTS, re-read on chain with cast before use)
    AuthCaptureEscrow constant ESCROW = AuthCaptureEscrow(0xf96815976523E00e65Be8f34cA5e64b4f41EB19c);
    address constant ERC3009_COLLECTOR = 0x8612dfdc421f80336cd14E8EF9cb1E765dB5ab88;
    address constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address constant CALLBACK_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;
    IIdentityRegistry constant IDENTITY = IIdentityRegistry(0x8004A818BFB912233c491871b3d84c89A494BD9e);
    IReputationRegistry constant REPUTATION = IReputationRegistry(0x8004B663056A597Dffe9eCcC1965A193B7388713);
    IValidationRegistry constant VALIDATION = IValidationRegistry(0x8004Cb1BF31DAf7788923b405b754f57acEB4272);

    bytes32 constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    uint8 constant THRESHOLD = 70;
    uint256 constant PRICE = 10_000; // 0.01 USDC

    DeliveryCourtReactive rc;
    DeliveryCourtCallback court;

    uint256 buyerKey = uint256(keccak256("delivery-court test buyer (fork only)"));
    address buyer;
    address seller = makeAddr("seller");
    address validator = makeAddr("modelValidator");
    address facilitator = makeAddr("facilitator");
    uint256 agentId;
    uint256 saltCounter;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_SEPOLIA_RPC_URL", string("https://sepolia.base.org")));
        require(block.chainid == BASE_SEPOLIA, "not Base Sepolia");
        buyer = vm.addr(buyerKey);

        _etchSystem();
        rc = new DeliveryCourtReactive(BASE_SEPOLIA, address(VALIDATION), validator, THRESHOLD, CRON100_TOPIC);
        court = new DeliveryCourtCallback(
            CALLBACK_PROXY, address(rc), ESCROW, USDC, IDENTITY, REPUTATION, VALIDATION, validator
        );
        rc.setCourt(address(court));

        vm.prank(seller);
        agentId = IDENTITY.register("ipfs://delivery-court-test-seller");
        court.registerSeller(seller, agentId);

        deal(USDC, buyer, 1_000_000);
    }

    // ------------------------------------------------------------------ helpers

    function _info(uint120 amount) internal returns (AuthCaptureEscrow.PaymentInfo memory) {
        uint48 t = uint48(block.timestamp);
        return AuthCaptureEscrow.PaymentInfo({
            operator: address(court),
            payer: buyer,
            receiver: seller,
            token: USDC,
            maxAmount: amount,
            preApprovalExpiry: t + 30 minutes,
            authorizationExpiry: t + 30 minutes,
            refundExpiry: t + 30 minutes,
            minFeeBps: 0,
            maxFeeBps: 0,
            feeReceiver: address(0),
            salt: ++saltCounter
        });
    }

    /// @dev The buyer signs ERC-3009 ReceiveWithAuthorization to the collector with the
    /// payer-agnostic payment hash as nonce, exactly what ERC3009PaymentCollector replays.
    function _sign(AuthCaptureEscrow.PaymentInfo memory info) internal view returns (bytes memory) {
        // Memory structs alias, so swap the payer out and back in.
        address payer = info.payer;
        info.payer = address(0);
        bytes32 nonce = ESCROW.getHash(info);
        info.payer = payer;
        bytes32 structHash = keccak256(
            abi.encode(
                RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
                info.payer,
                ERC3009_COLLECTOR,
                uint256(info.maxAmount),
                uint256(0),
                uint256(info.preApprovalExpiry),
                nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IUSDC(USDC).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(buyerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Facilitator relays the collect call. Returns paymentId and feeds Deposited to the reactive contract.
    function _pay(uint120 amount) internal returns (bytes32 id) {
        AuthCaptureEscrow.PaymentInfo memory info = _info(amount);
        bytes memory sig = _sign(info);
        vm.recordLogs();
        vm.prank(facilitator);
        court.authorize(info, amount, ERC3009_COLLECTOR, sig);
        id = ESCROW.getHash(info);
        _feed(address(court), rc.DEPOSITED_TOPIC());
    }

    /// @dev Finds the first recorded log from `emitter` with `topic0` and passes it to react().
    function _feed(address emitter, uint256 topic0) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && uint256(logs[i].topics[0]) == topic0) {
                IReactive.LogRecord memory r =
                    _fromVmLog(logs[i], BASE_SEPOLIA, uint256(keccak256(abi.encode(block.number, i))), i);
                _react(address(rc), r);
                return;
            }
        }
        revert("log not found");
    }

    /// @dev Seller asks the model to judge (requestHash = paymentId), the model answers on chain with
    /// the body hash and the facts tag, exactly as offchain/src/judge.mjs writes them.
    function _judge(bytes32 id, uint8 score, bytes32 responseHash, string memory tag) internal {
        vm.prank(seller);
        VALIDATION.validationRequest(validator, agentId, "ipfs://request", id);
        vm.recordLogs();
        vm.prank(validator);
        VALIDATION.validationResponse(id, score, "ipfs://response", responseHash, tag);
        _feed(address(VALIDATION), VALIDATION_RESPONSE_TOPIC);
    }

    /// @dev The deliver seller's JSON body: 200, 180 bytes, 2781 ms (on-chain metadata score 100).
    function _judge(bytes32 id, uint8 score) internal {
        _judge(id, score, sha256("{\"network\":\"eip155:84532\"}"), "dc1:200:180:2781");
    }

    /// @dev The empty seller: 200 with a 0-byte body.
    function _judgeEmpty(bytes32 id, uint8 score) internal {
        _judge(id, score, sha256(""), "dc1:200:0:3000");
    }

    function _deliverLast() internal returns (bool ok, bytes memory ret) {
        return _deliver(sys.callbackCount() - 1, CALLBACK_PROXY, address(rc));
    }

    // ------------------------------------------------------------------ wiring on chain

    function test_fork_deployedContractsMatchExpectations() public view {
        assertGt(address(ESCROW).code.length, 0);
        assertGt(ERC3009_COLLECTOR.code.length, 0);
        assertGt(CALLBACK_PROXY.code.length, 0);
        assertEq(
            ESCROW.PAYMENT_INFO_TYPEHASH(),
            keccak256(
                "PaymentInfo(address operator,address payer,address receiver,address token,uint120 maxAmount,uint48 preApprovalExpiry,uint48 authorizationExpiry,uint48 refundExpiry,uint16 minFeeBps,uint16 maxFeeBps,address feeReceiver,uint256 salt)"
            )
        );
        assertEq(IDENTITY.ownerOf(agentId), seller);
    }

    // ------------------------------------------------------------------ the three demo scenes

    function test_fork_deliveringSeller_getsPaid() public {
        uint256 buyerBefore = IUSDC(USDC).balanceOf(buyer);
        bytes32 id = _pay(uint120(PRICE));
        address store = ESCROW.getTokenStore(address(court));
        assertEq(IUSDC(USDC).balanceOf(buyer), buyerBefore - PRICE);
        (, uint120 capturable,) = ESCROW.paymentState(id);
        assertEq(capturable, PRICE);
        uint256 storeHeld = IUSDC(USDC).balanceOf(store);

        _judge(id, 92);
        assertEq(sys.callbackCount(), 1);
        assertEq(_selectorOf(0), ICourtCallback.courtCapture.selector);

        (bool ok,) = _deliverLast();
        assertTrue(ok, "capture callback");
        assertEq(IUSDC(USDC).balanceOf(seller), PRICE);
        assertEq(IUSDC(USDC).balanceOf(store), storeHeld - PRICE);
        assertEq(uint8(court.status(id)), uint8(CourtCallbackBase.Status.Captured));
        (, capturable,) = ESCROW.paymentState(id);
        assertEq(capturable, 0);
    }

    function test_fork_emptyBodySeller_refundsBuyer_andWritesFeedback() public {
        uint256 buyerBefore = IUSDC(USDC).balanceOf(buyer);
        bytes32 id = _pay(uint120(PRICE));

        _judgeEmpty(id, 3);
        assertEq(_selectorOf(0), ICourtCallback.courtVoid.selector);
        (bool ok,) = _deliverLast();
        assertTrue(ok, "void callback");

        assertEq(IUSDC(USDC).balanceOf(buyer), buyerBefore);
        assertEq(IUSDC(USDC).balanceOf(seller), 0);
        assertEq(REPUTATION.getLastIndex(agentId, address(court)), 1, "feedback on ERC-8004 Reputation");
    }

    function test_fork_silentSeller_refundedOnCron() public {
        uint256 buyerBefore = IUSDC(USDC).balanceOf(buyer);
        bytes32 id = _pay(uint120(PRICE));

        _react(address(rc), _cronLog());
        assertEq(sys.callbackCount(), 0, "not expired yet");

        vm.warp(block.timestamp + 30 minutes);
        _react(address(rc), _cronLog());
        assertEq(sys.callbackCount(), 1);
        (bool ok,) = _deliverLast();
        assertTrue(ok, "expiry void callback");
        assertEq(IUSDC(USDC).balanceOf(buyer), buyerBefore);
        assertEq(uint8(court.status(id)), uint8(CourtCallbackBase.Status.Voided));
        assertEq(REPUTATION.getLastIndex(agentId, address(court)), 1, "silence is on record (registered agent)");
    }

    /// @notice Review 2026-11-22: a third party files the first validation request for the paymentId, the
    /// seller's own request is refused ("exists"), nobody can answer, the cron voids it. The buyer is refunded,
    /// and the seller who delivered gets no "silent" review.
    function test_fork_frontRunRequest_noSilentReviewForTheSeller() public {
        uint256 buyerBefore = IUSDC(USDC).balanceOf(buyer);
        bytes32 id = _pay(uint120(PRICE));
        address attacker = address(0xBAD);
        vm.startPrank(attacker);
        uint256 attackerAgent = IDENTITY.register("ipfs://x");
        VALIDATION.validationRequest(attacker, attackerAgent, "x", id);
        vm.stopPrank();
        vm.prank(seller);
        vm.expectRevert(bytes("exists"));
        VALIDATION.validationRequest(validator, agentId, "ipfs://request", id);

        vm.warp(block.timestamp + 30 minutes);
        _react(address(rc), _cronLog());
        assertEq(sys.callbackCount(), 1);
        (bool ok,) = _deliverLast();
        assertTrue(ok, "expiry void callback");
        assertEq(IUSDC(USDC).balanceOf(buyer), buyerBefore, "buyer refunded");
        assertEq(REPUTATION.getLastIndex(agentId, address(court)), 0, "no silent review on the seller");
    }

    // ------------------------------------------------------------------ v2: the reactive contract checks the judge

    /// @notice The video scene: the judge key writes 99 for an empty body, the reactive contract voids it.
    function test_fork_v2_emptyBody_isVoidedEvenIfJudgeSays99() public {
        uint256 buyerBefore = IUSDC(USDC).balanceOf(buyer);
        bytes32 id = _pay(uint120(PRICE));
        vm.prank(seller);
        VALIDATION.validationRequest(validator, agentId, "ipfs://request", id);
        vm.recordLogs();
        vm.prank(validator);
        VALIDATION.validationResponse(id, 99, "ipfs://response", EMPTY_SHA256, "dc1:200:0:3000");
        // reported 99, on-chain 0, final 0, guard 1 (empty body hash)
        vm.expectEmit(true, false, false, true, address(rc));
        emit CourtReactiveBase.ScoreChecked(id, 99, 0, 0, 1);
        _feed(address(VALIDATION), VALIDATION_RESPONSE_TOPIC);
        bytes memory expected = abi.encodeCall(ICourtCallback.courtVoid, (address(0), id, agentId, uint8(0), uint8(3)));
        assertEq(sys.callbackAt(0).payload, expected);
        (bool ok,) = _deliverLast();
        assertTrue(ok);
        assertEq(IUSDC(USDC).balanceOf(buyer), buyerBefore);
        assertEq(IUSDC(USDC).balanceOf(seller), 0);
    }

    function test_fork_v2_judgeCannotRaiseA404() public {
        bytes32 id = _pay(uint120(PRICE));
        _judge(id, 99, sha256("not found"), "dc1:404:9:120");
        assertEq(_selectorOf(0), ICourtCallback.courtVoid.selector);
        (bool ok,) = _deliverLast();
        assertTrue(ok);
        assertEq(IUSDC(USDC).balanceOf(seller), 0);
        assertEq(REPUTATION.getLastIndex(agentId, address(court)), 0, "a low score alone writes no reputation");
    }

    /// @notice The callback's second look reads the real ERC-8004 ValidationRegistry (ABI checked here).
    function test_fork_v2_registryReadBeforeCapture() public {
        bytes32 id = _pay(uint120(PRICE));
        _judge(id, 92);
        (address v,, uint8 response, bytes32 h,, uint256 lastUpdate) = VALIDATION.getValidationStatus(id);
        assertEq(v, validator);
        assertEq(response, 92);
        assertEq(h, sha256("{\"network\":\"eip155:84532\"}"));
        assertGt(lastUpdate, 0);
        (bool ok,) = _deliverLast();
        assertTrue(ok);
        assertEq(uint8(court.status(id)), uint8(CourtCallbackBase.Status.Captured));
    }

    function test_fork_v2_authorizeRefusesUnregisteredSeller() public {
        court.removeSeller(seller);
        AuthCaptureEscrow.PaymentInfo memory info = _info(uint120(PRICE));
        bytes memory sig = _sign(info);
        vm.prank(facilitator);
        vm.expectRevert(abi.encodeWithSelector(DeliveryCourtCallback.SellerNotRegistered.selector, seller));
        court.authorize(info, PRICE, ERC3009_COLLECTOR, sig);
    }

    // ------------------------------------------------------------------ permissions on chain

    function test_fork_onlyProxyWithPairedReactive_canResolve() public {
        bytes32 id = _pay(uint120(PRICE));

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, seller, CALLBACK_PROXY));
        court.courtCapture(address(rc), id, agentId, 100);

        address impostor = makeAddr("impostorReactive");
        vm.prank(CALLBACK_PROXY);
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, impostor, address(rc)));
        court.courtCapture(impostor, id, agentId, 100);

        AuthCaptureEscrow.PaymentInfo memory info = court.paymentInfoOf(id);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(AuthCaptureEscrow.InvalidSender.selector, seller, address(court)));
        ESCROW.capture(info, PRICE, 0, address(0));

        // The buyer's own escape hatch on the escrow stays closed until authorizationExpiry.
        vm.prank(buyer);
        vm.expectRevert();
        ESCROW.reclaim(info);
    }

    function test_fork_doubleResolution_isRejected() public {
        bytes32 id = _pay(uint120(PRICE));
        _judge(id, 92);
        (bool ok,) = _deliverLast();
        assertTrue(ok);
        // Replaying the same callback fails.
        (ok,) = _deliverLast();
        assertFalse(ok, "replayed capture must fail");
        // A void after capture fails too.
        vm.prank(CALLBACK_PROXY);
        vm.expectRevert(
            abi.encodeWithSelector(CourtCallbackBase.NotPending.selector, id, CourtCallbackBase.Status.Captured)
        );
        court.courtVoid(address(rc), id, agentId, 0, 2);
        assertEq(IUSDC(USDC).balanceOf(seller), PRICE);
    }

    function test_fork_signatureCannotBeReplayed() public {
        AuthCaptureEscrow.PaymentInfo memory info = _info(uint120(PRICE));
        bytes memory sig = _sign(info);
        vm.prank(facilitator);
        court.authorize(info, PRICE, ERC3009_COLLECTOR, sig);
        vm.prank(facilitator);
        vm.expectRevert();
        court.authorize(info, PRICE, ERC3009_COLLECTOR, sig);
    }

    // ------------------------------------------------------------------ conservation

    function test_fork_conservation_acrossAllScenes() public {
        uint256 buyerStart = IUSDC(USDC).balanceOf(buyer);
        address store = ESCROW.getTokenStore(address(court));
        uint256 storeStart = IUSDC(USDC).balanceOf(store);

        bytes32 a = _pay(uint120(PRICE)); // delivered
        bytes32 b = _pay(uint120(PRICE * 2)); // empty body
        bytes32 c = _pay(uint120(PRICE * 3)); // silent
        uint256 deposited = PRICE * 6;
        assertEq(IUSDC(USDC).balanceOf(store), storeStart + deposited);

        _judge(a, 92);
        (bool ok,) = _deliverLast();
        assertTrue(ok);
        _judgeEmpty(b, 3);
        (ok,) = _deliverLast();
        assertTrue(ok);
        vm.warp(block.timestamp + 30 minutes);
        _react(address(rc), _cronLog());
        (ok,) = _deliverLast();
        assertTrue(ok);

        uint256 toSeller = IUSDC(USDC).balanceOf(seller);
        uint256 returned = IUSDC(USDC).balanceOf(buyer) - (buyerStart - deposited);
        assertEq(toSeller, PRICE);
        assertEq(returned, PRICE * 5);
        assertEq(toSeller + returned, deposited, "deposited == paid + returned");
        assertEq(IUSDC(USDC).balanceOf(store), storeStart, "escrow back to where it started");
        assertEq(IUSDC(USDC).balanceOf(address(court)), 0);
        c;
    }
}
