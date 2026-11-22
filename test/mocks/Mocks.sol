// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AuthCaptureEscrow} from "commerce-payments/AuthCaptureEscrow.sol";
import {TokenCollector} from "commerce-payments/collectors/TokenCollector.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Stand-in for the Reactive system contract (0x8888...8888). Etched in tests.
contract MockSystem {
    struct Sub {
        uint256 chainId;
        address target;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
        bool active;
    }

    Sub[] internal _subs;
    ISystemContract.CallbackConfiguration_V_1_0[] internal _callbacks;

    function subscribe(uint256 c, address t, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external {
        _subs.push(Sub(c, t, t0, t1, t2, t3, true));
    }

    function unsubscribe(uint256 c, address t, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external {
        for (uint256 i; i < _subs.length; ++i) {
            Sub storage s = _subs[i];
            if (s.active && s.chainId == c && s.target == t && s.topic0 == t0 && s.topic1 == t1 && s.topic2 == t2 && s.topic3 == t3) {
                s.active = false;
                return;
            }
        }
        revert("no such subscription");
    }

    /// @dev Gas measurement mode: emit the request as a log instead of storing it, so the number
    /// measured is react() itself plus one log, not this mock's storage.
    bool public logOnly;

    event CallbackRequested(uint256 chainId, address recipient, uint64 gasLimit, bytes payload);

    function setLogOnly(bool v) external {
        logOnly = v;
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        if (logOnly) {
            emit CallbackRequested(config_.chainId, config_.recipient, config_.gasLimit, config_.payload);
            return;
        }
        _callbacks.push(config_);
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}

    function subCount() external view returns (uint256) {
        return _subs.length;
    }

    function sub(uint256 i) external view returns (Sub memory) {
        return _subs[i];
    }

    function activeSubCount() external view returns (uint256 n) {
        for (uint256 i; i < _subs.length; ++i) {
            if (_subs[i].active) ++n;
        }
    }

    function callbackCount() external view returns (uint256) {
        return _callbacks.length;
    }

    function callbackAt(uint256 i) external view returns (ISystemContract.CallbackConfiguration_V_1_0 memory) {
        return _callbacks[i];
    }
}

/// @notice Plain ERC20 with an optional transfer hook, used to probe reentrancy.
contract MockERC20 {
    string public name = "Mock USD";
    string public symbol = "mUSD";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public hook;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function setHook(address h) external {
        hook = h;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
        emit Transfer(address(0), to, amt);
    }

    function approve(address s, uint256 amt) external returns (bool) {
        allowance[msg.sender][s] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _move(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        _move(from, to, amt);
        return true;
    }

    function _move(address from, address to, uint256 amt) internal {
        require(balanceOf[from] >= amt, "balance");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        emit Transfer(from, to, amt);
        if (hook != address(0)) IHook(hook).onTransfer();
    }
}

interface IHook {
    function onTransfer() external;
}

/// @notice Test-only payment collector: pulls `amount` from the payer with a plain allowance.
contract TestCollector is TokenCollector {
    TokenCollector.CollectorType public constant override collectorType = TokenCollector.CollectorType.Payment;

    constructor(address escrow_) TokenCollector(escrow_) {}

    function _collectTokens(AuthCaptureEscrow.PaymentInfo calldata info, address tokenStore, uint256 amount, bytes calldata)
        internal
        override
    {
        MockERC20(info.token).transferFrom(info.payer, tokenStore, amount);
    }
}

/// @notice Callback proxy stand-in that can try to re-enter the court from a token hook.
contract ReentrantProxy is IHook {
    address public target;
    bytes public reentryData;
    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes public reentryError;

    function arm(address target_, bytes calldata data) external {
        target = target_;
        reentryData = data;
    }

    function onTransfer() external {
        if (reentryData.length == 0) return;
        bytes memory d = reentryData;
        delete reentryData;
        reentryAttempted = true;
        (bool ok, bytes memory r) = target.call(d);
        reentrySucceeded = ok;
        reentryError = r;
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}

contract MockIdentity {
    mapping(uint256 => address) public ownerOf;

    function setOwner(uint256 agentId, address o) external {
        ownerOf[agentId] = o;
    }

    function isAuthorizedOrOwner(address spender, uint256 agentId) external view returns (bool) {
        require(ownerOf[agentId] != address(0), "nonexistent");
        return ownerOf[agentId] == spender;
    }
}

contract MockReputation {
    bool public shouldRevert;
    uint256 public count;
    uint256 public lastAgentId;
    int128 public lastValue;
    bytes32 public lastHash;
    string public lastTag2;

    function setRevert(bool r) external {
        shouldRevert = r;
    }

    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8,
        string calldata,
        string calldata tag2,
        string calldata,
        string calldata,
        bytes32 feedbackHash
    ) external {
        require(!shouldRevert, "rep down");
        ++count;
        lastAgentId = agentId;
        lastValue = value;
        lastHash = feedbackHash;
        lastTag2 = tag2;
    }
}

/// @notice ValidationRegistry.getValidationStatus stand-in for the callback's second look (#12).
contract MockValidation {
    struct Entry {
        address validator;
        uint256 agentId;
        uint8 response;
        bytes32 responseHash;
        string tag;
        uint256 lastUpdate;
    }

    mapping(bytes32 => Entry) public entries;
    bool public down;

    function set(bytes32 id, address validator, uint8 response, bytes32 responseHash) external {
        entries[id] = Entry(validator, 0, response, responseHash, "dc1:200:1500:800", block.timestamp);
    }

    function setDown(bool d) external {
        down = d;
    }

    function getValidationStatus(bytes32 id)
        external
        view
        returns (address, uint256, uint8, bytes32, string memory, uint256)
    {
        require(!down, "registry down");
        Entry memory e = entries[id];
        require(e.lastUpdate != 0, "unknown");
        return (e.validator, e.agentId, e.response, e.responseHash, e.tag, e.lastUpdate);
    }
}
