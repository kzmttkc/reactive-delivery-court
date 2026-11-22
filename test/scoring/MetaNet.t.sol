// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {MetaNet} from "../../src/scoring/MetaNet.sol";
import {MetaNetVectors as V} from "./MetaNetVectors.sol";

contract MetaNetTest is Test {
    function test_matchesNumpyOnTestRows() public pure {
        uint256 exact;
        uint256 sameSide;
        uint256[2000] memory v = V.all();
        for (uint256 i = 0; i < V.N; i++) {
            (uint16 st, uint256 nb, uint256 lat, uint8 want) = (uint16(v[i * 4]), v[i * 4 + 1], v[i * 4 + 2], uint8(v[i * 4 + 3]));
            uint8 got = MetaNet.score(st, nb, lat);
            int256 d = int256(uint256(got)) - int256(uint256(want));
            assertLe(d < 0 ? -d : d, 1, "more than 1 point from numpy");
            assertEq(got, want, "score differs from numpy");
            if (got == want) exact++;
            if ((got >= 70) == (want >= 70)) sameSide++;
        }
        console.log("vectors", V.N);
        console.log("exact", exact);
        assertEq(sameSide, V.N, "capture/void decision differs from numpy");
    }

    function test_emptyBodyVoids() public pure {
        assertLt(MetaNet.score(200, 0, 500), 70);
        assertLt(MetaNet.score(0, 0, 0), 70);
        assertGe(MetaNet.score(200, 1500, 800), 70);
    }

    function test_gas() public {
        uint256 g = gasleft();
        MetaNet.score(200, 1500, 800);
        emit log_named_uint("gas for one score", g - gasleft());
    }

    function testFuzz_neverReverts(uint16 st, uint64 nb, uint32 lat) public pure {
        uint8 s = MetaNet.score(st, nb, lat);
        assertLe(s, 100);
    }
}
