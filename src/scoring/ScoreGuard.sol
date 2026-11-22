// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {MetaNet} from "./MetaNet.sol";

/// Runs in DeliveryCourtReactive.react() on each ERC-8004 ValidationResponse before it asks for
/// a capture:
///   1. responseHash == sha256("")  -> 0. An empty body can never be paid, whatever the judge says.
///   2. tag "dc1:<status>:<bodyBytes>:<latencyMs>" -> the reactive contract scores those facts with
///      the metadata network itself (MetaNet) and takes min(judge score, its own score).
///      The judge key can only lower a score below what the on-chain facts allow, never raise it.
///   3. no or malformed tag -> 0 (v2 requires the facts on chain).
///   4. responseHash says non-empty but the tag says 0 bytes -> 0.
library ScoreGuard {
    bytes32 internal constant EMPTY_SHA256 = 0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855;
    uint8 internal constant R_OK = 0;
    uint8 internal constant R_EMPTY = 1;
    uint8 internal constant R_NO_FACTS = 2;
    uint8 internal constant R_INCONSISTENT = 3;

    /// `data` is the non-indexed part of ValidationResponse: (uint8 response, string responseURI, bytes32 responseHash, string tag).
    function fromLogData(bytes memory data) internal pure returns (uint8 finalScore, uint8 onchain, uint8 reason) {
        (uint8 response,, bytes32 responseHash, string memory tag) = abi.decode(data, (uint8, string, bytes32, string));
        return decide(response > 100 ? 100 : response, responseHash, bytes(tag));
    }

    function decide(uint8 reported, bytes32 responseHash, bytes memory tag)
        internal
        pure
        returns (uint8 finalScore, uint8 onchain, uint8 reason)
    {
        if (responseHash == EMPTY_SHA256) return (0, 0, R_EMPTY);
        (bool ok, uint256 status, uint256 bodyBytes, uint256 latencyMs) = parse(tag);
        if (!ok || status > 999) return (0, 0, R_NO_FACTS);
        if (bodyBytes == 0) return (0, 0, R_INCONSISTENT); // hash says non-empty, tag says 0 bytes
        onchain = MetaNet.score(uint16(status), bodyBytes, latencyMs);
        finalScore = reported < onchain ? reported : onchain;
        reason = R_OK;
    }

    /// "dc1:" then three decimal fields separated by ':'. At most 12 digits each.
    function parse(bytes memory t) internal pure returns (bool ok, uint256 a, uint256 b, uint256 c) {
        if (t.length < 10 || t[0] != "d" || t[1] != "c" || t[2] != "1" || t[3] != ":") return (false, 0, 0, 0);
        uint256[3] memory v;
        uint256 f;
        uint256 digits;
        for (uint256 i = 4; i < t.length; i++) {
            bytes1 ch = t[i];
            if (ch == ":") {
                if (digits == 0 || f == 2) return (false, 0, 0, 0);
                f++;
                digits = 0;
            } else if (ch >= "0" && ch <= "9") {
                if (++digits > 12) return (false, 0, 0, 0);
                v[f] = v[f] * 10 + (uint8(ch) - 48);
            } else {
                return (false, 0, 0, 0);
            }
        }
        if (f != 2 || digits == 0) return (false, 0, 0, 0);
        return (true, v[0], v[1], v[2]);
    }
}
