// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {MetaNetWeights as W} from "./MetaNetWeights.sol";

/// The metadata network of Delivery Court (10-8-1, tanh, sigmoid) in
/// 1e18 fixed point, so a reactive contract can score the facts the judge commits on chain
/// (HTTP status, body size, latency) itself. Matches model/features.py forward() + score().
library MetaNet {
    int256 internal constant S = 1e18;
    int256 internal constant LN2 = 693147180559945309;

    /// status 0 = no response (feature status_none).
    function score(uint16 status, uint256 bodyBytes, uint256 latencyMs) internal pure returns (uint8) {
        int256[10] memory x;
        if (status == 0) {
            x[5] = S;
        } else {
            if (status >= 200 && status < 300) x[status == 202 ? 1 : 0] = S;
            else if (status >= 300 && status < 400) x[2] = S;
            else if (status >= 400 && status < 500) x[3] = S;
            else x[4] = S;
            x[6] = S;
            x[7] = ln1p(bodyBytes) / 10;
            x[8] = bodyBytes > 0 ? S : int256(0);
            x[9] = ln1p(latencyMs) / 10;
        }
        (int256[80] memory w1, int256[8] memory b1, int256[8] memory w2) = W.all();
        int256 z = W.B2;
        for (uint256 j = 0; j < 8; j++) {
            int256 a = b1[j];
            for (uint256 i = 0; i < 10; i++) {
                if (x[i] != 0) a += (x[i] * w1[i * 8 + j]) / S;
            }
            z += (tanh(a) * w2[j]) / S;
        }
        int256 p = (S * S) / (S + exp(-z)); // sigmoid
        int256 s = (p * 100 + S / 2) / S; // floor(100p + 0.5)
        return uint8(uint256(s < 0 ? int256(0) : s > 100 ? int256(100) : s));
    }

    /// ln(1 + n) in 1e18, n an integer.
    function ln1p(uint256 n) internal pure returns (int256) {
        uint256 v = n + 1;
        int256 k = 0;
        while (v >= 2 << uint256(k)) k++; // 2^k <= v < 2^(k+1)
        // m = v / 2^k in [1, 2), ln m = 2 atanh((m-1)/(m+1))
        int256 m = int256((v * uint256(S)) >> uint256(k));
        int256 zz = ((m - S) * S) / (m + S);
        int256 z2 = (zz * zz) / S;
        int256 term = zz;
        int256 sum = 0;
        for (int256 i = 1; i < 60; i += 2) {
            sum += term / i;
            term = (term * z2) / S;
            if (term == 0) break;
        }
        return k * LN2 + 2 * sum;
    }

    /// e^x in 1e18, clamped to [-41, 41].
    function exp(int256 x) internal pure returns (int256) {
        if (x < -41 * S) return 0;
        if (x > 41 * S) x = 41 * S;
        int256 k = (x >= 0 ? x + LN2 / 2 : x - LN2 / 2) / LN2;
        int256 r = x - k * LN2; // |r| <= ln2/2
        int256 term = S;
        int256 sum = S;
        for (int256 i = 1; i < 30; i++) {
            term = (term * r) / (S * i);
            if (term == 0) break;
            sum += term;
        }
        return k >= 0 ? sum << uint256(k) : sum >> uint256(-k);
    }

    function tanh(int256 x) internal pure returns (int256) {
        if (x > 20 * S) return S;
        if (x < -20 * S) return -S;
        int256 e = exp(2 * x);
        return S - (2 * S * S) / (e + S);
    }
}
