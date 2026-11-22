// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {ICourtCallback} from "./interfaces/ICourtCallback.sol";
import {IIdentityRegistry, IReputationRegistry} from "./interfaces/IERC8004.sol";

/// @title CourtCallbackBase
/// @notice Shared destination-chain logic: one decision per payment, callable only by the
/// Reactive callback proxy on behalf of the paired reactive contract.
/// A low ERC-8004 reputation entry is written only when the seller is at fault on the facts alone:
/// it never answered before the deadline (REASON_EXPIRED) or the body the buyer got was empty
/// (REASON_EMPTY_BODY). A low score by itself refunds the buyer and writes nothing (M4).
abstract contract CourtCallbackBase is AbstractCallback, ICourtCallback {
    enum Status {
        None,
        Pending,
        Captured,
        Voided
    }

    /// Same numbers as CourtReactiveBase. 0 = capture.
    uint8 public constant REASON_LOW_SCORE = 1;
    uint8 public constant REASON_EXPIRED = 2;
    uint8 public constant REASON_EMPTY_BODY = 3;
    uint8 public constant REASON_NO_FACTS = 4;
    uint8 public constant REASON_INCONSISTENT = 5;
    uint8 public constant REASON_LATE = 6;
    /// Set here, not by the reactive side: the registry read before a capture did not agree.
    uint8 public constant REASON_REGISTRY_MISMATCH = 7;

    struct Seller {
        bool registered;
        uint256 agentId; // ERC-8004 agent that reputation entries go to. 0 = none.
    }

    address public immutable owner;
    IIdentityRegistry public immutable identityRegistry;
    IReputationRegistry public immutable reputationRegistry;

    mapping(bytes32 paymentId => Status) public status;
    mapping(address seller => Seller) public sellers;

    uint256 private _lock = 1;

    event Resolved(bytes32 indexed paymentId, bool captured, uint256 amount, uint8 score, uint8 reason);
    event FeedbackGiven(bytes32 indexed paymentId, uint256 indexed agentId, uint8 score);
    event FeedbackSkipped(bytes32 indexed paymentId, uint256 indexed agentId);
    event SellerRegistered(address indexed seller, uint256 indexed agentId);
    event SellerRemoved(address indexed seller);

    error NotPending(bytes32 paymentId, Status current);
    error BadReason(uint8 reason);
    error Reentrancy();
    error NotOwner();
    error ZeroSeller();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(
        address callbackProxy_,
        address reactiveSender_,
        IIdentityRegistry identityRegistry_,
        IReputationRegistry reputationRegistry_
    ) AbstractCallback(IPayable(payable(callbackProxy_)), reactiveSender_) {
        owner = msg.sender;
        identityRegistry = identityRegistry_;
        reputationRegistry = reputationRegistry_;
    }

    /// @notice Allows payments to `seller` and names its ERC-8004 agent (0 = none). Calling it again updates the agent.
    function registerSeller(address seller, uint256 agentId) external onlyOwner {
        if (seller == address(0)) revert ZeroSeller();
        sellers[seller] = Seller({registered: true, agentId: agentId});
        emit SellerRegistered(seller, agentId);
    }

    /// @notice Stops new payments to `seller`. Payments already in escrow are still decided.
    function removeSeller(address seller) external onlyOwner {
        delete sellers[seller];
        emit SellerRemoved(seller);
    }

    /// @inheritdoc ICourtCallback
    function courtCapture(address reactiveSender, bytes32 paymentId, uint256, uint8 score)
        external
        nonReentrant
        onlyServiceProvider
        onlyCallbackSender(reactiveSender)
    {
        if (!_registryAgrees(paymentId, score)) {
            // Doubt goes to the buyer: refund instead of paying out.
            _takePending(paymentId, Status.Voided);
            emit Resolved(paymentId, false, _void(paymentId), score, REASON_REGISTRY_MISMATCH);
            return;
        }
        _takePending(paymentId, Status.Captured);
        uint256 amount = _capture(paymentId);
        emit Resolved(paymentId, true, amount, score, 0);
    }

    /// @inheritdoc ICourtCallback
    function courtVoid(address reactiveSender, bytes32 paymentId, uint256 agentId, uint8 score, uint8 reason)
        external
        nonReentrant
        onlyServiceProvider
        onlyCallbackSender(reactiveSender)
    {
        if (reason == 0 || reason > REASON_LATE) revert BadReason(reason);
        _takePending(paymentId, Status.Voided);
        uint256 amount = _void(paymentId);
        emit Resolved(paymentId, false, amount, score, reason);
        // "silent" is written only when no validation request exists for the payment at all. Anyone can
        // file the first request for a paymentId (the registry refuses a second one), so a request from a
        // third party, or a judge that never answered, must not be read as the seller's silence.
        if (reason == REASON_EXPIRED) {
            if (_validationRequested(paymentId)) emit FeedbackSkipped(paymentId, agentId);
            else _feedback(paymentId, agentId, score, "silent");
        }
        else if (reason == REASON_EMPTY_BODY) _feedback(paymentId, agentId, score, "empty-body");
    }

    /// @notice Pays any outstanding debt to the callback proxy from this contract's balance.
    function coverDebt() external {
        _coverDebt();
    }

    function _takePending(bytes32 paymentId, Status next) internal {
        Status current = status[paymentId];
        if (current != Status.Pending) revert NotPending(paymentId, current);
        status[paymentId] = next;
    }

    /// @dev Records "paid but not delivered" on ERC-8004 Reputation. Never blocks the refund.
    /// The agent is the one the owner registered for the receiver; without one, the agent named in the
    /// judge's log (none on a cron expiry). Written only when that agent really belongs to the receiver.
    function _feedback(bytes32 paymentId, uint256 agentId, uint8 score, string memory why) internal {
        address receiver = _receiverOf(paymentId);
        uint256 registered = sellers[receiver].agentId;
        if (registered != 0) agentId = registered;
        bool owned;
        try identityRegistry.isAuthorizedOrOwner(receiver, agentId) returns (bool ok) {
            owned = ok;
        } catch {}
        if (!owned) {
            emit FeedbackSkipped(paymentId, agentId);
            return;
        }
        try reputationRegistry.giveFeedback(
            agentId, int128(uint128(score)), 0, "delivery", why, "", "", paymentId
        ) {
            emit FeedbackGiven(paymentId, agentId, score);
        } catch {
            emit FeedbackSkipped(paymentId, agentId);
        }
    }

    /// @dev Whether any ERC-8004 validation request exists for this payment. Default: none known.
    function _validationRequested(bytes32) internal view virtual returns (bool) {
        return false;
    }

    /// @dev Second look before money moves to the seller. Default: no extra check.
    function _registryAgrees(bytes32, uint8) internal view virtual returns (bool) {
        return true;
    }

    function _capture(bytes32 paymentId) internal virtual returns (uint256 amount);

    function _void(bytes32 paymentId) internal virtual returns (uint256 amount);

    function _receiverOf(bytes32 paymentId) internal view virtual returns (address);
}
