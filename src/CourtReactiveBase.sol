// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {ICourtCallback} from "./interfaces/ICourtCallback.sol";
import {ScoreGuard} from "./scoring/ScoreGuard.sol";

/// @title CourtReactiveBase (Reactive Lasna)
/// @notice Shared decision logic. Tracks open payments, reads the judge's score from ERC-8004
/// ValidationResponse (requestHash == paymentId), checks it against the facts the judge committed
/// in the same log (ScoreGuard: body hash, and the tag "dc1:<status>:<bodyBytes>:<latencyMs>"
/// re-scored on chain by the metadata network), and asks the destination contract to capture
/// (final score >= threshold) or void (final score < threshold, or deadline passed on a cron tick).
/// final score = min(judge score, on-chain score): the judge key can lower a score, never raise it.
abstract contract CourtReactiveBase is AbstractReactive {
    enum State {
        None,
        Open,
        Decided
    }

    struct Payment {
        State state;
        uint48 deadline;
    }

    struct EarlyScore {
        bool present;
        uint8 score;
        uint8 reason;
        uint256 agentId;
    }

    /// @dev Origin of Reactive cron events (legacy system contract), per reactive-smart-contract-demos@omni.
    address internal constant CRON_ORIGIN = 0x0000000000000000000000000000000000fffFfF;
    uint256 internal constant VALIDATION_RESPONSE_TOPIC =
        0xafddf629e874ccc3963b6a888c477bd464a6c8525024fc88759ea3b2326349ae;

    /// Decision reasons. Same numbers as CourtCallbackBase. 0 = capture.
    uint8 internal constant REASON_LOW_SCORE = 1; // final score below threshold, facts consistent
    uint8 internal constant REASON_EXPIRED = 2; // no score before the deadline (silent seller), voided on a cron tick
    uint8 internal constant REASON_EMPTY_BODY = 3; // responseHash == sha256(""), whatever the judge said
    uint8 internal constant REASON_NO_FACTS = 4; // tag missing or not "dc1:<status>:<bytes>:<latencyMs>"
    uint8 internal constant REASON_INCONSISTENT = 5; // responseHash is not empty but the tag says 0 bytes
    uint8 internal constant REASON_LATE = 6; // a score arrived, but after the deadline

    uint64 public constant CALLBACK_GAS_LIMIT = 1_000_000;
    uint256 public constant MAX_SCAN = 32;
    uint256 public constant MAX_EXPIRE_PER_TICK = 4;

    address public immutable owner;
    uint256 public immutable originChainId;
    address public immutable validationRegistry;
    address public immutable validator;
    uint8 public immutable threshold;
    uint256 public immutable cronTopic;

    address public court;
    bool public cronPaused;

    mapping(bytes32 paymentId => Payment) public payments;
    mapping(bytes32 paymentId => EarlyScore) public earlyScores;
    bytes32[] public queue;
    uint256 public cursor;

    event PaymentOpened(bytes32 indexed paymentId, uint48 deadline);
    event Decision(bytes32 indexed paymentId, bool capture, uint8 score, uint8 reason);
    event EarlyScoreStored(bytes32 indexed paymentId, uint8 score);
    /// @notice What the judge reported, what the reactive contract computed from the committed facts,
    /// and the score it decides on. guard is ScoreGuard's reason (0 ok, 1 empty, 2 no facts, 3 inconsistent).
    event ScoreChecked(bytes32 indexed paymentId, uint8 reported, uint8 onchain, uint8 finalScore, uint8 guard);

    error NotOwner();
    error CourtAlreadySet();
    error ZeroAddress();
    error BadThreshold();
    error CronState();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(uint256 originChainId_, address validationRegistry_, address validator_, uint8 threshold_, uint256 cronTopic_)
        payable
    {
        if (validationRegistry_ == address(0) || validator_ == address(0)) revert ZeroAddress();
        if (threshold_ == 0 || threshold_ > 100) revert BadThreshold();
        owner = msg.sender;
        originChainId = originChainId_;
        validationRegistry = validationRegistry_;
        validator = validator_;
        threshold = threshold_;
        cronTopic = cronTopic_;

        SYSTEM.subscribe(
            originChainId_,
            validationRegistry_,
            VALIDATION_RESPONSE_TOPIC,
            uint256(uint160(validator_)),
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SYSTEM.subscribe(block.chainid, CRON_ORIGIN, cronTopic_, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /// @notice Registers the destination contract once it is deployed with this contract's address.
    function setCourt(address court_) external onlyOwner {
        if (court != address(0)) revert CourtAlreadySet();
        if (court_ == address(0)) revert ZeroAddress();
        court = court_;
        _subscribeDeposits(court_);
    }

    function pauseCron() external onlyOwner {
        if (cronPaused) revert CronState();
        cronPaused = true;
        SYSTEM.unsubscribe(block.chainid, CRON_ORIGIN, cronTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function resumeCron() external onlyOwner {
        if (!cronPaused) revert CronState();
        cronPaused = false;
        SYSTEM.subscribe(block.chainid, CRON_ORIGIN, cronTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /// @notice Pays outstanding debt to the system contract from this contract's balance.
    function coverDebt() external {
        _coverDebt();
    }

    function queueLength() external view returns (uint256) {
        return queue.length;
    }

    function react(LogRecord calldata log_) external onlySystem {
        if (
            log_.chainId == originChainId && log_.contractAddress == validationRegistry
                && log_.topic0 == VALIDATION_RESPONSE_TOPIC && log_.topic1 == uint256(uint160(validator))
        ) {
            _onValidation(bytes32(log_.topic3), log_.topic2, log_.data);
        } else if (log_.contractAddress == CRON_ORIGIN && log_.topic0 == cronTopic) {
            _onCron();
        } else {
            _onOtherLog(log_);
        }
    }

    // ---------------------------------------------------------------- internal

    function _subscribeDeposits(address court_) internal virtual;

    function _onOtherLog(LogRecord calldata log_) internal virtual;

    function _openPayment(bytes32 paymentId, uint48 deadline) internal {
        if (payments[paymentId].state != State.None) return;
        payments[paymentId] = Payment({state: State.Open, deadline: deadline});
        queue.push(paymentId);
        emit PaymentOpened(paymentId, deadline);

        EarlyScore memory early = earlyScores[paymentId];
        if (early.present) {
            delete earlyScores[paymentId];
            _onScore(paymentId, early.agentId, early.score, early.reason);
        }
    }

    /// @dev data = (uint8 response, string responseURI, bytes32 responseHash, string tag).
    function _onValidation(bytes32 paymentId, uint256 agentId, bytes calldata data) internal {
        if (payments[paymentId].state == State.Decided || earlyScores[paymentId].present) return; // first response wins
        (uint8 reported,, bytes32 responseHash, string memory tag) = abi.decode(data, (uint8, string, bytes32, string));
        if (reported > 100) reported = 100;
        (uint8 finalScore, uint8 onchain, uint8 guard) = ScoreGuard.decide(reported, responseHash, bytes(tag));
        emit ScoreChecked(paymentId, reported, onchain, finalScore, guard);
        uint8 reason;
        if (guard == ScoreGuard.R_EMPTY) reason = REASON_EMPTY_BODY;
        else if (guard == ScoreGuard.R_NO_FACTS) reason = REASON_NO_FACTS;
        else if (guard == ScoreGuard.R_INCONSISTENT) reason = REASON_INCONSISTENT;
        else reason = REASON_LOW_SCORE; // used only if finalScore < threshold
        _onScore(paymentId, agentId, finalScore, reason);
    }

    /// @param voidReason the reason to give if this score voids the payment.
    function _onScore(bytes32 paymentId, uint256 agentId, uint8 score, uint8 voidReason) internal {
        Payment storage p = payments[paymentId];
        if (p.state == State.Decided) return; // first response wins
        if (p.state == State.None) {
            if (!earlyScores[paymentId].present) {
                earlyScores[paymentId] =
                    EarlyScore({present: true, score: score, reason: voidReason, agentId: agentId});
                emit EarlyScoreStored(paymentId, score);
            }
            return;
        }
        p.state = State.Decided;
        if (block.timestamp >= p.deadline) {
            _requestVoid(paymentId, agentId, score, REASON_LATE);
        } else if (score >= threshold) {
            emit Decision(paymentId, true, score, 0);
            _request(abi.encodeCall(ICourtCallback.courtCapture, (address(0), paymentId, agentId, score)));
        } else {
            _requestVoid(paymentId, agentId, score, voidReason);
        }
    }

    /// @dev Looks at MAX_SCAN entries from `cursor`, wraps at the end of the queue, and continues
    /// from where it stopped on the next tick, so open payments with a far deadline at the front can
    /// not keep an expired one at the back from being refunded (H2). Decided entries are removed
    /// (swap with the last, pop), so the queue holds open payments only and a full pass stays short.
    function _onCron() internal {
        uint256 len = queue.length;
        if (len == 0) return;
        uint256 i = cursor;
        if (i >= len) i = 0;
        uint256 budget = len < MAX_SCAN ? len : MAX_SCAN; // each entry at most once per tick
        uint256 expired = 0;
        for (uint256 scanned = 0; scanned < budget && expired < MAX_EXPIRE_PER_TICK && len > 0; ++scanned) {
            bytes32 id = queue[i];
            Payment storage p = payments[id];
            if (p.state == State.Open && block.timestamp >= p.deadline) {
                p.state = State.Decided;
                _requestVoid(id, 0, 0, REASON_EXPIRED);
                unchecked {
                    ++expired;
                }
            }
            if (p.state == State.Decided) {
                // Remove; the entry moved into slot i is looked at next.
                --len;
                if (i != len) queue[i] = queue[len];
                queue.pop();
            } else {
                ++i;
            }
            if (i >= len) i = 0;
        }
        cursor = i;
    }

    function _requestVoid(bytes32 paymentId, uint256 agentId, uint8 score, uint8 reason) internal {
        emit Decision(paymentId, false, score, reason);
        _request(abi.encodeCall(ICourtCallback.courtVoid, (address(0), paymentId, agentId, score, reason)));
    }

    function _request(bytes memory payload) internal {
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: originChainId,
                recipient: court,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: payload
            })
        );
    }
}
