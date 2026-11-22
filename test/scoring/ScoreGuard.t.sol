// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {ScoreGuard} from "../../src/scoring/ScoreGuard.sol";

contract ScoreGuardTest is Test {
    bytes32 constant SOME_BODY = keccak256("not empty");

    function _data(uint8 score, bytes32 h, string memory tag) internal pure returns (bytes memory) {
        return abi.encode(score, "https://delivery-court.fly.dev/responses/x.json", h, tag);
    }

    function test_emptyBodyIsZeroEvenIfJudgeSays99() public pure {
        (uint8 f,, uint8 r) = ScoreGuard.fromLogData(_data(99, ScoreGuard.EMPTY_SHA256, "dc1:200:1500:800"));
        assertEq(f, 0);
        assertEq(r, ScoreGuard.R_EMPTY);
    }

    function test_honestDelivery() public pure {
        (uint8 f, uint8 onchain, uint8 r) = ScoreGuard.fromLogData(_data(99, SOME_BODY, "dc1:200:1500:800"));
        assertEq(r, ScoreGuard.R_OK);
        assertGe(onchain, 70);
        assertEq(f, onchain < 99 ? onchain : 99);
    }

    function test_judgeCannotRaiseA404() public pure {
        (uint8 f, uint8 onchain,) = ScoreGuard.fromLogData(_data(99, SOME_BODY, "dc1:404:30:200"));
        assertLt(onchain, 70);
        assertEq(f, onchain);
    }

    function test_judgeCanStillLower() public pure {
        (uint8 f,,) = ScoreGuard.fromLogData(_data(10, SOME_BODY, "dc1:200:1500:800"));
        assertEq(f, 10); // content model said "error page in a 200"
    }

    function test_noFactsIsZero() public pure {
        (uint8 f,, uint8 r) = ScoreGuard.fromLogData(_data(99, SOME_BODY, "delivery"));
        assertEq(f, 0);
        assertEq(r, ScoreGuard.R_NO_FACTS);
    }

    function test_inconsistentZeroBytes() public pure {
        (uint8 f,, uint8 r) = ScoreGuard.fromLogData(_data(99, SOME_BODY, "dc1:200:0:800"));
        assertEq(f, 0);
        assertEq(r, ScoreGuard.R_INCONSISTENT);
    }

    function test_parse() public pure {
        (bool ok, uint256 a, uint256 b, uint256 c) = ScoreGuard.parse("dc1:202:7:123456");
        assertTrue(ok);
        assertEq(a, 202); assertEq(b, 7); assertEq(c, 123456);
        (ok,,,) = ScoreGuard.parse("dc1:200::5"); assertFalse(ok);
        (ok,,,) = ScoreGuard.parse("dc1:200:5:5:5"); assertFalse(ok);
        (ok,,,) = ScoreGuard.parse("dc1:2x0:5:5"); assertFalse(ok);
        (ok,,,) = ScoreGuard.parse("dc1:200:5:9999999999999"); assertFalse(ok);
    }

    function testFuzz_parseNeverReverts(bytes calldata t) public pure {
        ScoreGuard.parse(t);
    }

    function testFuzz_finalNeverAboveReported(uint8 rep, uint16 st, uint32 nb, uint32 lat) public pure {
        string memory tag = string.concat("dc1:", vm.toString(uint256(st % 1000)), ":", vm.toString(uint256(nb)), ":", vm.toString(uint256(lat)));
        (uint8 f,,) = ScoreGuard.decide(rep > 100 ? 100 : rep, SOME_BODY, bytes(tag));
        assertLe(f, rep > 100 ? 100 : rep);
    }
}
