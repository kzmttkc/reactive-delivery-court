// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {DeliveryCourtReactive} from "../../src/DeliveryCourtReactive.sol";
import {CourtReactiveBase} from "../../src/CourtReactiveBase.sol";
import {ICourtCallback} from "../../src/interfaces/ICourtCallback.sol";
import {CourtTestBase} from "../utils/CourtTestBase.sol";

/// @notice H2, from the external audit. v1's cron looked at the first MAX_SCAN open entries from the
/// first undecided one and never further: 32 small payments with a far deadline at the front of the
/// queue kept every later expired payment from being refunded, forever. The audit's PoC asserted that
/// the victim was never voided. These tests are that PoC turned around: the victim is refunded.
contract CronStarvationTest is CourtTestBase {
    DeliveryCourtReactive rc;
    address registry = makeAddr("validationRegistry");
    address validator = makeAddr("modelValidator");
    address court = makeAddr("court");

    function setUp() public {
        vm.warp(1_800_000_000);
        _etchSystem();
        rc = new DeliveryCourtReactive(BASE_SEPOLIA, registry, validator, 70, CRON100_TOPIC);
        rc.setCourt(court);
    }

    function _deposit(bytes32 id, uint48 deadline) internal {
        _react(
            address(rc),
            _log(BASE_SEPOLIA, court, rc.DEPOSITED_TOPIC(), uint256(id), 1, 2, abi.encode(uint256(1000), deadline))
        );
    }

    function _tick() internal {
        _react(address(rc), _cronLog());
    }

    function _voided(bytes32 id) internal view returns (bool) {
        bytes memory want = abi.encodeCall(ICourtCallback.courtVoid, (address(0), id, 0, uint8(0), uint8(2)));
        for (uint256 i; i < sys.callbackCount(); ++i) {
            if (keccak256(sys.callbackAt(i).payload) == keccak256(want)) return true;
        }
        return false;
    }

    /// @notice The audit's exact setup: 32 minimum payments with the longest deadline v2 still allows
    /// (1 hour, DeliveryCourtCallback.MAX_WINDOW), then the victim with a 90 s deadline (the silent scene).
    function test_H2_fixed_32FarDeadlinesDoNotBlockTheVictim() public {
        uint256 n = rc.MAX_SCAN();
        for (uint256 i; i < n; ++i) {
            _deposit(bytes32(i + 1), uint48(block.timestamp + 1 hours));
        }
        bytes32 victim = keccak256("victim");
        _deposit(victim, uint48(block.timestamp + 90));

        vm.warp(block.timestamp + 90);
        _tick(); // looks at entries 0..31, none expired, cursor moves to 32
        assertEq(rc.cursor(), n);
        _tick(); // looks at the victim
        assertTrue(_voided(victim), "victim refunded on the second tick");
        assertEq(sys.callbackCount(), 1, "the far-deadline payments are untouched");
    }

    /// @notice Any number of spam entries only delays the victim by ceil(N / MAX_SCAN) ticks.
    function test_H2_fixed_delayIsBoundedByQueueLength() public {
        uint256 spam = 200;
        bytes32 victim = keccak256("victim");
        // Victim in the middle of the queue this time.
        for (uint256 i; i < spam; ++i) {
            if (i == 117) _deposit(victim, uint48(block.timestamp + 90));
            _deposit(bytes32(i + 1), uint48(block.timestamp + 1 hours));
        }
        vm.warp(block.timestamp + 90);
        uint256 maxTicks = (spam + 1 + rc.MAX_SCAN() - 1) / rc.MAX_SCAN();
        uint256 ticks;
        while (!_voided(victim)) {
            _tick();
            ++ticks;
            assertLe(ticks, maxTicks, "victim not reached within ceil(N / MAX_SCAN) ticks");
        }
        emit log_named_uint("ticks to refund the victim behind 200 open payments", ticks);
    }

    /// @notice The cursor wraps: entries before the cursor are seen again on the next pass.
    function test_H2_fixed_cursorWrapsToTheFront() public {
        for (uint256 i; i < 40; ++i) {
            _deposit(bytes32(i + 1), uint48(block.timestamp + 1 hours));
        }
        _tick(); // 0..31
        _tick(); // 32..39, wraps at 40, then 0..23
        assertEq(rc.cursor(), 24);
        // Entry 5 (id 6) expires now: it sits before nothing special, the next ticks reach it.
        vm.warp(block.timestamp + 1 hours);
        _tick();
        assertEq(sys.callbackCount(), rc.MAX_EXPIRE_PER_TICK());
        for (uint256 i; i < 20; ++i) {
            _tick();
        }
        assertEq(sys.callbackCount(), 40, "every expired payment voided exactly once");
        assertEq(rc.queueLength(), 0);
    }

    /// @notice Decided entries leave the queue, so the scan does not grow with history.
    function test_H2_decidedEntriesAreRemoved() public {
        for (uint256 i; i < 10; ++i) {
            bytes32 id = bytes32(i + 1);
            _deposit(id, uint48(block.timestamp + 1 hours));
            _react(
                address(rc), _validationLog(registry, validator, 7, id, 90, keccak256("body"), DELIVERED_TAG)
            );
        }
        assertEq(rc.queueLength(), 10);
        _tick();
        assertEq(rc.queueLength(), 0);
        assertEq(sys.callbackCount(), 10); // captures only, the tick voided nothing
    }
}
