// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Callback surface that the Reactive side calls through the Reactive callback proxy.
/// The first argument is always the requesting reactive contract. The reactive side passes
/// address(0) and the callback proxy overwrites it with the real sender.
interface ICourtCallback {
    function courtCapture(address reactiveSender, bytes32 paymentId, uint256 agentId, uint8 score) external;

    function courtVoid(address reactiveSender, bytes32 paymentId, uint256 agentId, uint8 score, uint8 reason)
        external;
}

/// @notice Extra callback used only by the fallback design (plan B).
interface ICourtDepositRecorder {
    function recordDeposit(address reactiveSender, bytes32 paymentId, address buyer, uint256 amount) external;
}
