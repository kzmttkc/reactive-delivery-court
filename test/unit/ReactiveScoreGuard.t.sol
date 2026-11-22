// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {DeliveryCourtReactive} from "../../src/DeliveryCourtReactive.sol";
import {CourtReactiveBase} from "../../src/CourtReactiveBase.sol";
import {ICourtCallback} from "../../src/interfaces/ICourtCallback.sol";
import {MetaNet} from "../../src/scoring/MetaNet.sol";
import {CourtTestBase} from "../utils/CourtTestBase.sol";

/// @notice v2: react() re-scores the facts the judge committed (ScoreGuard + MetaNet) and decides on
/// min(judge, on-chain). The judge key can lower a score, never raise it.
contract ReactiveScoreGuardTest is CourtTestBase {
    DeliveryCourtReactive rc;
    address registry = makeAddr("validationRegistry");
    address validator = makeAddr("modelValidator");
    address court = makeAddr("court");
    uint8 constant THRESHOLD = 70;
    uint256 constant AGENT = 7;
    bytes32 constant BODY = keccak256("a non-empty body");

    function setUp() public {
        vm.warp(1_800_000_000);
        _etchSystem();
        rc = new DeliveryCourtReactive(BASE_SEPOLIA, registry, validator, THRESHOLD, CRON100_TOPIC);
        rc.setCourt(court);
    }

    function _open(bytes32 id) internal {
        _react(
            address(rc),
            _log(
                BASE_SEPOLIA,
                court,
                rc.DEPOSITED_TOPIC(),
                uint256(id),
                1,
                2,
                abi.encode(uint256(10_000), uint48(block.timestamp + 10 minutes))
            )
        );
    }

    function _judge(bytes32 id, uint8 score, bytes32 h, string memory tag) internal {
        _react(address(rc), _validationLog(registry, validator, AGENT, id, score, h, tag));
    }

    function _void(bytes32 id, uint8 score, uint8 reason) internal pure returns (bytes memory) {
        return abi.encodeCall(ICourtCallback.courtVoid, (address(0), id, AGENT, score, reason));
    }

    // ------------------------------------------------------------------ empty body

    function test_emptyBodyHash_isZero_evenIfJudgeSays99() public {
        bytes32 id = keccak256("empty");
        _open(id);
        vm.expectEmit(true, false, false, true, address(rc));
        emit CourtReactiveBase.ScoreChecked(id, 99, 0, 0, 1);
        _judge(id, 99, EMPTY_SHA256, "dc1:200:0:3000");
        assertEq(sys.callbackCount(), 1);
        assertEq(sys.callbackAt(0).payload, _void(id, 0, 3));
    }

    function test_emptyBodyHash_winsOverAGoodLookingTag() public {
        bytes32 id = keccak256("empty2");
        _open(id);
        _judge(id, 99, EMPTY_SHA256, DELIVERED_TAG);
        assertEq(sys.callbackAt(0).payload, _void(id, 0, 3));
    }

    // ------------------------------------------------------------------ the judge cannot raise

    function test_judgeCannotRaise_a404() public {
        bytes32 id = keccak256("404");
        _open(id);
        _judge(id, 99, BODY, "dc1:404:30:200");
        assertEq(sys.callbackAt(0).payload, _void(id, 0, 1));
    }

    function test_judgeCannotRaise_a202WithNoContent() public {
        bytes32 id = keccak256("202");
        _open(id);
        uint8 onchain = MetaNet.score(202, 50, 300);
        assertLt(onchain, THRESHOLD);
        _judge(id, 100, BODY, "dc1:202:50:300");
        assertEq(sys.callbackAt(0).payload, _void(id, onchain, 1));
    }

    function test_judgeCannotRaise_a500() public {
        bytes32 id = keccak256("500");
        _open(id);
        _judge(id, 100, BODY, "dc1:500:100:1000");
        assertEq(_selectorOf(0), ICourtCallback.courtVoid.selector);
    }

    // ------------------------------------------------------------------ the judge can lower

    function test_judgeCanLower_aGoodLookingResponse() public {
        bytes32 id = keccak256("lower");
        _open(id);
        assertEq(MetaNet.score(200, 1500, 800), 100);
        // The content network found an error page inside a 200: the judge's 12 stands.
        vm.expectEmit(true, false, false, true, address(rc));
        emit CourtReactiveBase.ScoreChecked(id, 12, 100, 12, 0);
        _judge(id, 12, BODY, DELIVERED_TAG);
        assertEq(sys.callbackAt(0).payload, _void(id, 12, 1));
    }

    function test_capture_carriesTheMinimum() public {
        bytes32 id = keccak256("cap");
        _open(id);
        _judge(id, 88, BODY, DELIVERED_TAG);
        assertEq(
            sys.callbackAt(0).payload,
            abi.encodeCall(ICourtCallback.courtCapture, (address(0), id, AGENT, uint8(88)))
        );
    }

    // ------------------------------------------------------------------ no or broken facts

    function test_noTag_isZero() public {
        bytes32 id = keccak256("v1tag");
        _open(id);
        _judge(id, 99, BODY, "delivery"); // what the v1 judge wrote
        assertEq(sys.callbackAt(0).payload, _void(id, 0, 4));
    }

    function test_emptyTag_isZero() public {
        bytes32 id = keccak256("notag");
        _open(id);
        _judge(id, 99, BODY, "");
        assertEq(sys.callbackAt(0).payload, _void(id, 0, 4));
    }

    function test_brokenTags_areZero() public {
        string[6] memory bad =
            ["dc1:200:1500", "dc1:200:1500:800:1", "dc2:200:1500:800", "dc1:2O0:1500:800", "dc1:200:-1:800", "dc1:1000:5:5"];
        for (uint256 i; i < bad.length; ++i) {
            bytes32 id = keccak256(abi.encode("bad", i));
            _open(id);
            _judge(id, 99, BODY, bad[i]);
            assertEq(sys.callbackAt(i).payload, _void(id, 0, 4), bad[i]);
        }
    }

    function test_nonEmptyHashWithZeroBytes_isZero() public {
        bytes32 id = keccak256("inconsistent");
        _open(id);
        _judge(id, 99, BODY, "dc1:200:0:800");
        assertEq(sys.callbackAt(0).payload, _void(id, 0, 5));
    }

    function test_earlyScore_keepsItsReason() public {
        bytes32 id = keccak256("early-empty");
        _judge(id, 99, EMPTY_SHA256, "dc1:200:0:3000");
        assertEq(sys.callbackCount(), 0);
        _open(id);
        assertEq(sys.callbackAt(0).payload, _void(id, 0, 3));
    }

    // ------------------------------------------------------------------ fuzz

    /// @notice For any facts and any reported score: the final score never exceeds the judge's, a
    /// capture needs both the judge and the on-chain network at or above the threshold.
    function testFuzz_judgeCanOnlyLower(uint8 reported, uint16 status, uint32 bodyBytes, uint32 latencyMs) public {
        reported = uint8(bound(reported, 0, 100));
        status = uint16(bound(status, 100, 599));
        bodyBytes = uint32(bound(bodyBytes, 1, type(uint32).max));
        string memory tag = string.concat(
            "dc1:", vm.toString(uint256(status)), ":", vm.toString(uint256(bodyBytes)), ":", vm.toString(uint256(latencyMs))
        );
        bytes32 id = keccak256(abi.encode(reported, status, bodyBytes, latencyMs));
        _open(id);
        _judge(id, reported, BODY, tag);
        uint8 onchain = MetaNet.score(status, bodyBytes, latencyMs);
        uint8 fin = reported < onchain ? reported : onchain;
        bool capture = reported >= THRESHOLD && onchain >= THRESHOLD;
        bytes memory expected = capture
            ? abi.encodeCall(ICourtCallback.courtCapture, (address(0), id, AGENT, fin))
            : _void(id, fin, 1);
        assertEq(sys.callbackAt(0).payload, expected);
    }

    // ------------------------------------------------------------------ gas (Lasna react budget)
    // Measured with the mock system contract in log-only mode (one log per callback request instead
    // of storing it), so the number is react() itself. The real system contract's own cost for
    // requestCallbackV_1_0 is not included. Storage is cooled first (vm.cool) as in a fresh transaction;
    // the 21k base cost of the transaction is not included either.

    function _measure(IReactive.LogRecord memory l) internal returns (uint256 used) {
        sys.setLogOnly(true);
        // Cold storage and accounts, as in a fresh react transaction.
        vm.cool(address(rc));
        vm.cool(SYSTEM);
        vm.prank(SYSTEM);
        uint256 g = gasleft();
        rc.react(l);
        used = g - gasleft();
        sys.setLogOnly(false);
    }

    /// @notice react() on a ValidationResponse that captures: decode + ScoreGuard + MetaNet + callback request.
    function test_gas_reactOnValidationResponse() public {
        bytes32 id = keccak256("gas");
        _open(id);
        uint256 used = _measure(_validationLog(registry, validator, AGENT, id, 92, BODY, DELIVERED_TAG));
        emit log_named_uint("react(ValidationResponse, capture) gas", used);
        (CourtReactiveBase.State st,) = rc.payments(id);
        assertEq(uint8(st), uint8(CourtReactiveBase.State.Decided));
        assertLt(used, 300_000);
    }

    /// @notice The cheapest path for comparison: empty body hash, MetaNet is skipped.
    function test_gas_reactOnValidationResponse_emptyBody() public {
        bytes32 id = keccak256("gas-empty");
        _open(id);
        uint256 used = _measure(_validationLog(registry, validator, AGENT, id, 99, EMPTY_SHA256, "dc1:200:0:3000"));
        emit log_named_uint("react(ValidationResponse, empty body) gas", used);
    }

    /// @notice The worst cron tick: 32 entries looked at, 3 voided and removed.
    function test_gas_reactOnCronTick_fullScan() public {
        for (uint256 i; i < 40; ++i) {
            _react(
                address(rc),
                _log(
                    BASE_SEPOLIA,
                    court,
                    rc.DEPOSITED_TOPIC(),
                    i + 1,
                    1,
                    2,
                    abi.encode(uint256(10_000), uint48(block.timestamp + (i % 10 == 0 ? 1 : 1 hours)))
                )
            );
        }
        vm.warp(block.timestamp + 1);
        uint256 used = _measure(_cronLog());
        emit log_named_uint("react(cron, 32 looked at, 3 voided) gas", used);
        // ids 1, 11, 21 expire inside the 32 looks; each removal pulls a far-deadline entry from the end
        // into its slot, which takes one look, so id 31 waits for the next tick.
        assertEq(rc.queueLength(), 37);
        assertLt(used, 400_000);
    }
}
