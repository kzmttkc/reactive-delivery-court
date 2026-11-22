// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {MockSystem} from "../mocks/Mocks.sol";

abstract contract CourtTestBase is Test {
    address internal constant SYSTEM = 0x8888888888888888888888888888888888888888;
    address internal constant CRON_ORIGIN = 0x0000000000000000000000000000000000fffFfF;
    uint256 internal constant CRON100_TOPIC = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
    uint256 internal constant VALIDATION_RESPONSE_TOPIC =
        0xafddf629e874ccc3963b6a888c477bd464a6c8525024fc88759ea3b2326349ae;
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    MockSystem internal sys;

    function _etchSystem() internal {
        MockSystem impl = new MockSystem();
        vm.etch(SYSTEM, address(impl).code);
        sys = MockSystem(payable(SYSTEM));
    }

    function _log(uint256 chainId, address emitter, uint256 t0, uint256 t1, uint256 t2, uint256 t3, bytes memory data)
        internal
        view
        returns (IReactive.LogRecord memory r)
    {
        r.chainId = chainId;
        r.contractAddress = emitter;
        r.topic0 = t0;
        r.topic1 = t1;
        r.topic2 = t2;
        r.topic3 = t3;
        r.data = data;
        r.blockNumber = block.number;
        r.txHash = uint256(keccak256(abi.encode(emitter, t0, t1, t2, t3, data, block.number)));
    }

    /// @dev Converts a log captured with vm.recordLogs into the Reactive LogRecord shape.
    function _fromVmLog(Vm.Log memory l, uint256 chainId, uint256 txHash, uint256 logIndex)
        internal
        view
        returns (IReactive.LogRecord memory r)
    {
        r.chainId = chainId;
        r.contractAddress = l.emitter;
        if (l.topics.length > 0) r.topic0 = uint256(l.topics[0]);
        if (l.topics.length > 1) r.topic1 = uint256(l.topics[1]);
        if (l.topics.length > 2) r.topic2 = uint256(l.topics[2]);
        if (l.topics.length > 3) r.topic3 = uint256(l.topics[3]);
        r.data = l.data;
        r.blockNumber = block.number;
        r.txHash = txHash;
        r.logIndex = logIndex;
    }

    /// @dev A delivered JSON body: 200, 1500 bytes, 800 ms. The on-chain metadata network gives it 100,
    /// so min(judge, on-chain) is the judge's score and decisions follow the judge as in v1.
    string internal constant DELIVERED_TAG = "dc1:200:1500:800";
    bytes32 internal constant EMPTY_SHA256 = 0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855;

    function _validationLog(address registry, address validator, uint256 agentId, bytes32 requestHash, uint8 score)
        internal
        view
        returns (IReactive.LogRecord memory)
    {
        return _validationLog(registry, validator, agentId, requestHash, score, keccak256("body"), DELIVERED_TAG);
    }

    function _validationLog(
        address registry,
        address validator,
        uint256 agentId,
        bytes32 requestHash,
        uint8 score,
        bytes32 responseHash,
        string memory tag
    ) internal view returns (IReactive.LogRecord memory) {
        return _log(
            BASE_SEPOLIA,
            registry,
            VALIDATION_RESPONSE_TOPIC,
            uint256(uint160(validator)),
            agentId,
            uint256(requestHash),
            abi.encode(score, "ipfs://response", responseHash, tag)
        );
    }

    function _cronLog() internal view returns (IReactive.LogRecord memory) {
        return _log(block.chainid, CRON_ORIGIN, CRON100_TOPIC, 0, 0, 0, "");
    }

    function _react(address reactive, IReactive.LogRecord memory l) internal {
        vm.prank(SYSTEM);
        IReactive(payable(reactive)).react(l);
    }

    /// @dev Delivers callback #i the way the callback proxy does: the first argument is replaced
    /// with the requesting reactive contract and the call comes from the proxy.
    function _deliver(uint256 i, address proxy, address reactiveSender) internal returns (bool ok, bytes memory ret) {
        ISystemContract.CallbackConfiguration_V_1_0 memory cb = sys.callbackAt(i);
        bytes memory payload = cb.payload;
        assembly {
            mstore(add(payload, 36), reactiveSender)
        }
        vm.prank(proxy);
        (ok, ret) = cb.recipient.call{gas: cb.gasLimit}(payload);
    }

    function _selectorOf(uint256 i) internal view returns (bytes4 sel) {
        bytes memory p = sys.callbackAt(i).payload;
        assembly {
            sel := mload(add(p, 32))
        }
    }
}
