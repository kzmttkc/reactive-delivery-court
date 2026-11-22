// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {DeliveryCourtReactive} from "../../src/DeliveryCourtReactive.sol";
import {CourtReactiveBase} from "../../src/CourtReactiveBase.sol";
import {ICourtCallback} from "../../src/interfaces/ICourtCallback.sol";
import {MockSystem} from "../mocks/Mocks.sol";
import {CourtTestBase} from "../utils/CourtTestBase.sol";

/// @notice react() is driven with hand-built LogRecords. The system contract is a mock etched at 0x8888.
contract DeliveryCourtReactiveTest is CourtTestBase {
    DeliveryCourtReactive rc;
    address registry = makeAddr("validationRegistry");
    address validator = makeAddr("modelValidator");
    address court = makeAddr("court");
    uint8 constant THRESHOLD = 70;
    uint256 constant AGENT = 7;
    address constant PAYER = address(0xA11CE);
    address constant SELLER = address(0x5E11E7);

    function setUp() public {
        vm.warp(1_800_000_000);
        _etchSystem();
        rc = new DeliveryCourtReactive(BASE_SEPOLIA, registry, validator, THRESHOLD, CRON100_TOPIC);
        rc.setCourt(court);
    }

    function _depositLog(bytes32 id, uint48 deadline) internal view returns (IReactive.LogRecord memory) {
        return _log(
            BASE_SEPOLIA,
            court,
            rc.DEPOSITED_TOPIC(),
            uint256(id),
            uint256(uint160(PAYER)),
            uint256(uint160(SELLER)),
            abi.encode(uint256(10_000), deadline)
        );
    }

    function _open(bytes32 id) internal {
        _react(address(rc), _depositLog(id, uint48(block.timestamp + 1 hours)));
    }

    function _score(bytes32 id, uint8 score) internal {
        _react(address(rc), _validationLog(registry, validator, AGENT, id, score));
    }

    // ------------------------------------------------------------------ wiring

    function test_constructorAndSetCourt_subscribeExactly() public view {
        assertEq(sys.subCount(), 3);
        MockSystem.Sub memory v = sys.sub(0);
        assertEq(v.chainId, BASE_SEPOLIA);
        assertEq(v.target, registry);
        assertEq(v.topic0, VALIDATION_RESPONSE_TOPIC);
        assertEq(v.topic1, uint256(uint160(validator)));
        assertEq(v.topic2, REACTIVE_IGNORE);
        MockSystem.Sub memory c = sys.sub(1);
        assertEq(c.target, CRON_ORIGIN);
        assertEq(c.topic0, CRON100_TOPIC);
        MockSystem.Sub memory d = sys.sub(2);
        assertEq(d.chainId, BASE_SEPOLIA);
        assertEq(d.target, court);
        assertEq(d.topic0, rc.DEPOSITED_TOPIC());
        assertEq(d.topic1, REACTIVE_IGNORE);
    }

    function test_depositedTopic_matchesCallbackEvent() public view {
        assertEq(rc.DEPOSITED_TOPIC(), uint256(keccak256("Deposited(bytes32,address,address,uint256,uint48)")));
    }

    function test_setCourt_onlyOnce_onlyOwner() public {
        vm.expectRevert(CourtReactiveBase.CourtAlreadySet.selector);
        rc.setCourt(address(1));
        vm.prank(makeAddr("x"));
        vm.expectRevert(CourtReactiveBase.NotOwner.selector);
        rc.setCourt(address(1));
    }

    function test_react_onlySystem() public {
        IReactive.LogRecord memory l = _depositLog(keccak256("a"), uint48(block.timestamp + 1));
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYSTEM));
        rc.react(l);
    }

    function test_constructor_rejectsBadThreshold() public {
        vm.expectRevert(CourtReactiveBase.BadThreshold.selector);
        new DeliveryCourtReactive(BASE_SEPOLIA, registry, validator, 0, CRON100_TOPIC);
        vm.expectRevert(CourtReactiveBase.BadThreshold.selector);
        new DeliveryCourtReactive(BASE_SEPOLIA, registry, validator, 101, CRON100_TOPIC);
    }

    function test_pauseResumeCron() public {
        rc.pauseCron();
        assertEq(sys.activeSubCount(), 2);
        vm.expectRevert(CourtReactiveBase.CronState.selector);
        rc.pauseCron();
        rc.resumeCron();
        assertEq(sys.activeSubCount(), 3);
        vm.prank(makeAddr("x"));
        vm.expectRevert(CourtReactiveBase.NotOwner.selector);
        rc.pauseCron();
    }

    // ------------------------------------------------------------------ decisions

    function test_threshold_boundary() public {
        bytes32 a = keccak256("69");
        bytes32 b = keccak256("70");
        bytes32 c = keccak256("71");
        _open(a);
        _open(b);
        _open(c);
        _score(a, THRESHOLD - 1);
        _score(b, THRESHOLD);
        _score(c, THRESHOLD + 1);
        assertEq(sys.callbackCount(), 3);
        assertEq(_selectorOf(0), ICourtCallback.courtVoid.selector);
        assertEq(_selectorOf(1), ICourtCallback.courtCapture.selector);
        assertEq(_selectorOf(2), ICourtCallback.courtCapture.selector);
    }

    function testFuzz_scoreDecides(uint8 score) public {
        score = uint8(bound(score, 0, 100));
        bytes32 id = keccak256(abi.encode(score));
        _open(id);
        _score(id, score);
        assertEq(sys.callbackCount(), 1);
        bytes4 expected = score >= THRESHOLD ? ICourtCallback.courtCapture.selector : ICourtCallback.courtVoid.selector;
        assertEq(_selectorOf(0), expected);
    }

    function test_callbackPayload_isWellFormed() public {
        bytes32 id = keccak256("p");
        _open(id);
        _score(id, 3);
        ISystemContract.CallbackConfiguration_V_1_0 memory cb = sys.callbackAt(0);
        assertEq(cb.chainId, BASE_SEPOLIA);
        assertEq(cb.recipient, court);
        assertEq(cb.gasLimit, rc.CALLBACK_GAS_LIMIT());
        bytes memory expected = abi.encodeCall(ICourtCallback.courtVoid, (address(0), id, AGENT, uint8(3), uint8(1)));
        assertEq(cb.payload, expected);
    }

    function test_responseFromOtherValidator_isIgnored() public {
        bytes32 id = keccak256("p");
        _open(id);
        _react(address(rc), _validationLog(registry, makeAddr("sellerOwnValidator"), AGENT, id, 100));
        assertEq(sys.callbackCount(), 0);
    }

    function test_responseFromOtherRegistry_isIgnored() public {
        bytes32 id = keccak256("p");
        _open(id);
        _react(address(rc), _validationLog(makeAddr("fakeRegistry"), validator, AGENT, id, 100));
        assertEq(sys.callbackCount(), 0);
    }

    function test_depositFromOtherContract_isIgnored() public {
        bytes32 id = keccak256("p");
        IReactive.LogRecord memory l = _depositLog(id, uint48(block.timestamp + 1 hours));
        l.contractAddress = makeAddr("fakeCourt");
        _react(address(rc), l);
        (CourtReactiveBase.State st,) = rc.payments(id);
        assertEq(uint8(st), uint8(CourtReactiveBase.State.None));
    }

    function test_secondResponse_isIgnored() public {
        bytes32 id = keccak256("p");
        _open(id);
        _score(id, 95);
        _score(id, 1);
        assertEq(sys.callbackCount(), 1);
        assertEq(_selectorOf(0), ICourtCallback.courtCapture.selector);
    }

    function test_duplicateDeposit_isIgnored() public {
        bytes32 id = keccak256("p");
        _open(id);
        _open(id);
        assertEq(rc.queueLength(), 1);
    }

    function test_earlyScore_isAppliedWhenDepositArrives() public {
        bytes32 id = keccak256("p");
        _score(id, 88);
        assertEq(sys.callbackCount(), 0);
        _open(id);
        assertEq(sys.callbackCount(), 1);
        assertEq(_selectorOf(0), ICourtCallback.courtCapture.selector);
        (bool present,,,) = rc.earlyScores(id);
        assertFalse(present);
    }

    function test_scoreAfterDeadline_voidsAsLate() public {
        bytes32 id = keccak256("p");
        _open(id);
        vm.warp(block.timestamp + 1 hours);
        _score(id, 100);
        // v2: a late score is REASON_LATE (6), not the silent-seller expiry (2), so it writes no reputation.
        bytes memory expected =
            abi.encodeCall(ICourtCallback.courtVoid, (address(0), id, AGENT, uint8(100), uint8(6)));
        assertEq(sys.callbackAt(0).payload, expected);
    }

    // ------------------------------------------------------------------ expiry

    function test_cron_voidsExpiredOnly() public {
        bytes32 early = keccak256("early");
        bytes32 late = keccak256("late");
        _react(address(rc), _depositLog(early, uint48(block.timestamp + 10 minutes)));
        _react(address(rc), _depositLog(late, uint48(block.timestamp + 2 hours)));

        _react(address(rc), _cronLog());
        assertEq(sys.callbackCount(), 0, "nothing expired yet");

        vm.warp(block.timestamp + 10 minutes);
        _react(address(rc), _cronLog());
        assertEq(sys.callbackCount(), 1);
        bytes memory expected = abi.encodeCall(ICourtCallback.courtVoid, (address(0), early, 0, uint8(0), uint8(2)));
        assertEq(sys.callbackAt(0).payload, expected);

        // A later tick does not void it again. The decided entry left the queue.
        _react(address(rc), _cronLog());
        assertEq(sys.callbackCount(), 1);
        assertEq(rc.queueLength(), 1);
        assertEq(rc.queue(0), late);
    }

    function test_cron_doesNotTouchDecided() public {
        bytes32 id = keccak256("p");
        _open(id);
        _score(id, 90);
        vm.warp(block.timestamp + 2 hours);
        _react(address(rc), _cronLog());
        assertEq(sys.callbackCount(), 1);
    }

    function test_cron_boundsWorkPerTick() public {
        for (uint256 i; i < 10; ++i) {
            _react(address(rc), _depositLog(bytes32(i + 1), uint48(block.timestamp + 1)));
        }
        vm.warp(block.timestamp + 1);
        _react(address(rc), _cronLog());
        assertEq(sys.callbackCount(), rc.MAX_EXPIRE_PER_TICK());
        _react(address(rc), _cronLog());
        _react(address(rc), _cronLog());
        assertEq(sys.callbackCount(), 10);
        assertEq(rc.queueLength(), 0, "decided entries are removed");
        _react(address(rc), _cronLog());
        assertEq(sys.callbackCount(), 10);
    }

    function test_otherCronTopic_isIgnored() public {
        _react(address(rc), _depositLog(keccak256("p"), uint48(block.timestamp)));
        IReactive.LogRecord memory l = _cronLog();
        l.topic0 = 0xf02d6ea5c22a71cffe930a4523fcb4f129be6c804db50e4202fb4e0b07ccb514; // Cron1
        _react(address(rc), l);
        assertEq(sys.callbackCount(), 0);
    }
}
