// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CourtCallbackBase} from "../CourtCallbackBase.sol";
import {IIdentityRegistry, IReputationRegistry} from "../interfaces/IERC8004.sol";

/// @title DeliveryEscrowB (Base Sepolia, fallback design)
/// @notice One escrow per seller. The x402 seller sets payTo = this contract and keeps the
/// official `exact` facilitator, which calls USDC.transferWithAuthorization(to = this).
/// This contract is never called on deposit, so the reactive side reads USDC Transfer(to = this)
/// and records the deposit here through a callback.
contract DeliveryEscrowB is CourtCallbackBase {
    using SafeERC20 for IERC20;

    struct Deposit {
        address buyer;
        uint96 deadline;
        uint256 amount;
    }

    IERC20 public immutable token;
    address public immutable seller;
    uint256 public immutable window;

    mapping(bytes32 paymentId => Deposit) public deposits;
    /// @notice Sum of all pending deposits. Never exceeds the token balance.
    uint256 public committed;

    event DepositRecorded(bytes32 indexed paymentId, address indexed buyer, uint256 amount, uint256 deadline);
    event Reclaimed(bytes32 indexed paymentId, address indexed buyer, uint256 amount);

    error AlreadyRecorded(bytes32 paymentId);
    error Uncovered(uint256 balance, uint256 needed);
    error NotExpired(uint256 deadline);
    error ZeroAmount();

    constructor(
        address callbackProxy_,
        address reactiveSender_,
        IERC20 token_,
        address seller_,
        uint256 window_,
        IIdentityRegistry identityRegistry_,
        IReputationRegistry reputationRegistry_
    ) CourtCallbackBase(callbackProxy_, reactiveSender_, identityRegistry_, reputationRegistry_) {
        token = token_;
        seller = seller_;
        window = window_;
    }

    function recordDeposit(address reactiveSender, bytes32 paymentId, address buyer, uint256 amount)
        external
        nonReentrant
        onlyServiceProvider
        onlyCallbackSender(reactiveSender)
    {
        if (amount == 0) revert ZeroAmount();
        if (status[paymentId] != Status.None) revert AlreadyRecorded(paymentId);
        uint256 needed = committed + amount;
        uint256 balance = token.balanceOf(address(this));
        if (balance < needed) revert Uncovered(balance, needed);

        committed = needed;
        status[paymentId] = Status.Pending;
        uint256 deadline = block.timestamp + window;
        deposits[paymentId] = Deposit({buyer: buyer, deadline: uint96(deadline), amount: amount});
        emit DepositRecorded(paymentId, buyer, amount, deadline);
    }

    /// @notice Safety net if the reactive side is down: after the deadline anyone can send the
    /// deposit back to the buyer. Never sends to the seller.
    function reclaimExpired(bytes32 paymentId) external nonReentrant {
        Deposit memory d = deposits[paymentId];
        if (block.timestamp < d.deadline) revert NotExpired(d.deadline);
        _takePending(paymentId, Status.Voided);
        uint256 amount = _void(paymentId);
        emit Reclaimed(paymentId, d.buyer, amount);
    }

    function _capture(bytes32 paymentId) internal override returns (uint256 amount) {
        amount = deposits[paymentId].amount;
        committed -= amount;
        token.safeTransfer(seller, amount);
    }

    function _void(bytes32 paymentId) internal override returns (uint256 amount) {
        Deposit memory d = deposits[paymentId];
        amount = d.amount;
        committed -= amount;
        token.safeTransfer(d.buyer, amount);
    }

    function _receiverOf(bytes32) internal view override returns (address) {
        return seller;
    }
}
