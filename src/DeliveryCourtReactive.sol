// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {CourtReactiveBase} from "./CourtReactiveBase.sol";

/// @title DeliveryCourtReactive (Reactive Lasna)
/// @notice Main design. Subscribes to DeliveryCourtCallback.Deposited on Base Sepolia, to the
/// model's ERC-8004 ValidationResponse, and to a Reactive cron. Decides capture or void.
contract DeliveryCourtReactive is CourtReactiveBase {
    /// @dev keccak256("Deposited(bytes32,address,address,uint256,uint48)")
    uint256 public constant DEPOSITED_TOPIC = uint256(keccak256("Deposited(bytes32,address,address,uint256,uint48)"));

    constructor(uint256 originChainId_, address validationRegistry_, address validator_, uint8 threshold_, uint256 cronTopic_)
        payable
        CourtReactiveBase(originChainId_, validationRegistry_, validator_, threshold_, cronTopic_)
    {}

    function _subscribeDeposits(address court_) internal override {
        SYSTEM.subscribe(originChainId, court_, DEPOSITED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function _onOtherLog(LogRecord calldata log_) internal override {
        if (log_.chainId != originChainId || log_.contractAddress != court || log_.topic0 != DEPOSITED_TOPIC) return;
        (, uint48 deadline) = abi.decode(log_.data, (uint256, uint48));
        _openPayment(bytes32(log_.topic1), deadline);
    }
}
