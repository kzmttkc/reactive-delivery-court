// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AuthCaptureEscrow} from "commerce-payments/AuthCaptureEscrow.sol";
import {CourtCallbackBase} from "./CourtCallbackBase.sol";
import {IIdentityRegistry, IReputationRegistry, IValidationRegistry} from "./interfaces/IERC8004.sol";

/// @title DeliveryCourtCallback (Base Sepolia)
/// @notice x402 auth-capture "custom" operator. Collect (`authorize`) is permissionless as the
/// x402 auth-capture EVM spec requires. Lifecycle (capture to the seller, void back to the buyer)
/// is out of band and only reachable from the Reactive callback proxy, on behalf of the paired
/// DeliveryCourtReactive contract on Lasna.
/// Collect is bounded so open payments cannot crowd the reactive contract's cron (H2): at least
/// MIN_AMOUNT, a capture deadline at most MAX_WINDOW ahead, and only to sellers the owner registered.
/// Before a capture it reads the ERC-8004 ValidationRegistry again and pays only if the judge's
/// entry there agrees with the decision (#12). Otherwise it refunds.
contract DeliveryCourtCallback is CourtCallbackBase {
    uint256 public constant MIN_AMOUNT = 1000; // 0.001 USDC
    uint256 public constant MAX_WINDOW = 1 hours;
    bytes32 internal constant EMPTY_SHA256 = 0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855;

    AuthCaptureEscrow public immutable escrow;
    address public immutable token;
    IValidationRegistry public immutable validationRegistry;
    address public immutable validator;

    mapping(bytes32 paymentId => AuthCaptureEscrow.PaymentInfo) internal _paymentInfo;
    mapping(bytes32 paymentId => uint256) public amountOf;

    /// @notice Emitted after the canonical escrow holds the buyer's funds.
    /// The reactive contract subscribes to this event (topic1 = paymentId).
    event Deposited(
        bytes32 indexed paymentId, address indexed payer, address indexed receiver, uint256 amount, uint48 deadline
    );

    error WrongOperator(address operator);
    error WrongToken(address token);
    error FeesNotAllowed();
    error AlreadyDeposited(bytes32 paymentId);
    error ChargeNotSupported();
    error AmountTooSmall(uint256 amount);
    error DeadlineTooFar(uint48 authorizationExpiry);
    error SellerNotRegistered(address receiver);

    constructor(
        address callbackProxy_,
        address reactiveSender_,
        AuthCaptureEscrow escrow_,
        address token_,
        IIdentityRegistry identityRegistry_,
        IReputationRegistry reputationRegistry_,
        IValidationRegistry validationRegistry_,
        address validator_
    ) CourtCallbackBase(callbackProxy_, reactiveSender_, identityRegistry_, reputationRegistry_) {
        escrow = escrow_;
        token = token_;
        validationRegistry = validationRegistry_;
        validator = validator_;
    }

    /// @notice Permissionless collect wrapper (same ABI as AuthCaptureEscrow.authorize).
    /// The buyer's signature inside `collectorData` is what authorizes the transfer.
    function authorize(
        AuthCaptureEscrow.PaymentInfo calldata paymentInfo,
        uint256 amount,
        address tokenCollector,
        bytes calldata collectorData
    ) external nonReentrant {
        if (paymentInfo.operator != address(this)) revert WrongOperator(paymentInfo.operator);
        if (paymentInfo.token != token) revert WrongToken(paymentInfo.token);
        // Zero fee bounds keep the conservation rule exact: deposited == captured + voided.
        if (paymentInfo.minFeeBps != 0 || paymentInfo.maxFeeBps != 0) revert FeesNotAllowed();
        if (amount < MIN_AMOUNT) revert AmountTooSmall(amount);
        if (paymentInfo.authorizationExpiry > block.timestamp + MAX_WINDOW) {
            revert DeadlineTooFar(paymentInfo.authorizationExpiry);
        }
        if (!sellers[paymentInfo.receiver].registered) revert SellerNotRegistered(paymentInfo.receiver);

        bytes32 paymentId = escrow.getHash(paymentInfo);
        if (status[paymentId] != Status.None) revert AlreadyDeposited(paymentId);
        status[paymentId] = Status.Pending;
        _paymentInfo[paymentId] = paymentInfo;
        amountOf[paymentId] = amount;

        escrow.authorize(paymentInfo, amount, tokenCollector, collectorData);

        emit Deposited(paymentId, paymentInfo.payer, paymentInfo.receiver, amount, paymentInfo.authorizationExpiry);
    }

    /// @notice Exposed for ABI compatibility with the collect surface. Charging would skip the
    /// court (immediate capture), so it is refused.
    function charge(AuthCaptureEscrow.PaymentInfo calldata, uint256, address, bytes calldata, uint256, address)
        external
        pure
    {
        revert ChargeNotSupported();
    }

    function paymentInfoOf(bytes32 paymentId) external view returns (AuthCaptureEscrow.PaymentInfo memory) {
        return _paymentInfo[paymentId];
    }

    function _capture(bytes32 paymentId) internal override returns (uint256 amount) {
        amount = amountOf[paymentId];
        escrow.capture(_paymentInfo[paymentId], amount, 0, address(0));
    }

    function _void(bytes32 paymentId) internal override returns (uint256 amount) {
        amount = amountOf[paymentId];
        escrow.void(_paymentInfo[paymentId]);
    }

    /// @dev The registry's entry for this payment must come from the judge, carry at least the score
    /// the reactive contract decided on (it decides on min(judge, on-chain), never more), and not be
    /// the hash of an empty body. A registry that reverts counts as disagreement.
    function _registryAgrees(bytes32 paymentId, uint8 score) internal view override returns (bool) {
        try validationRegistry.getValidationStatus(paymentId) returns (
            address v, uint256, uint8 response, bytes32 responseHash, string memory, uint256 lastUpdate
        ) {
            return v == validator && response >= score && responseHash != EMPTY_SHA256 && lastUpdate != 0;
        } catch {
            return false;
        }
    }

    /// @dev The registry reverts for an unknown requestHash; a request (from anyone) makes it answer.
    function _validationRequested(bytes32 paymentId) internal view override returns (bool) {
        try validationRegistry.getValidationStatus(paymentId) returns (address, uint256, uint8, bytes32, string memory, uint256) {
            return true;
        } catch {
            return false;
        }
    }

    function _receiverOf(bytes32 paymentId) internal view override returns (address) {
        return _paymentInfo[paymentId].receiver;
    }
}
