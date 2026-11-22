// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {CourtReactiveBase} from "../CourtReactiveBase.sol";
import {ICourtDepositRecorder} from "../interfaces/ICourtCallback.sol";

/// @title DeliveryCourtReactiveB (Reactive Lasna, fallback design)
/// @notice Subscribes to USDC Transfer(to = DeliveryEscrowB) only, so it does not pay for every
/// USDC transfer on the chain. paymentId = keccak256(chainId, txHash, logIndex) of the Transfer.
contract DeliveryCourtReactiveB is CourtReactiveBase {
    uint256 internal constant TRANSFER_TOPIC = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    address public immutable token;
    uint48 public immutable window;

    constructor(
        uint256 originChainId_,
        address token_,
        address validationRegistry_,
        address validator_,
        uint8 threshold_,
        uint256 cronTopic_,
        uint48 window_
    ) payable CourtReactiveBase(originChainId_, validationRegistry_, validator_, threshold_, cronTopic_) {
        token = token_;
        window = window_;
    }

    /// @notice The id a seller uses as the ERC-8004 requestHash for a given payment.
    function paymentIdOf(uint256 chainId, uint256 txHash, uint256 logIndex) public pure returns (bytes32) {
        return keccak256(abi.encode(chainId, txHash, logIndex));
    }

    function _subscribeDeposits(address escrow_) internal override {
        SYSTEM.subscribe(
            originChainId, token, TRANSFER_TOPIC, REACTIVE_IGNORE, uint256(uint160(escrow_)), REACTIVE_IGNORE
        );
    }

    function _onOtherLog(LogRecord calldata log_) internal override {
        if (
            log_.chainId != originChainId || log_.contractAddress != token || log_.topic0 != TRANSFER_TOPIC
                || log_.topic2 != uint256(uint160(court))
        ) return;
        uint256 amount = abi.decode(log_.data, (uint256));
        if (amount == 0) return;
        bytes32 paymentId = paymentIdOf(log_.chainId, log_.txHash, log_.logIndex);
        if (payments[paymentId].state != State.None) return;
        address buyer = address(uint160(log_.topic1));

        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: originChainId,
                recipient: court,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: abi.encodeCall(ICourtDepositRecorder.recordDeposit, (address(0), paymentId, buyer, amount))
            })
        );
        // Lasna-side deadline. The escrow keeps its own Base Sepolia deadline for reclaimExpired.
        _openPayment(paymentId, uint48(block.timestamp) + window);
    }
}
