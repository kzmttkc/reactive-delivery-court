// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console2} from "forge-std/Script.sol";
import {AuthCaptureEscrow} from "commerce-payments/AuthCaptureEscrow.sol";
import {DeliveryCourtReactive} from "../src/DeliveryCourtReactive.sol";
import {DeliveryCourtCallback} from "../src/DeliveryCourtCallback.sol";
import {IIdentityRegistry, IReputationRegistry, IValidationRegistry} from "../src/interfaces/IERC8004.sol";

interface IUSDC3009 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

interface IDepositTo {
    function depositTo(address) external payable;
}

/// @notice Stage 0 on testnets. The key comes from the environment (EVM_PRIVATE_KEY), set by
/// scripts/with-evm-key.mjs. It is never printed.
/// Each entry point is one transaction (or one deploy) so every send is checked on its own.
contract Stage0 is Script {
    // Ethereum Sepolia
    address constant LREACT_FAUCET_SEPOLIA = 0x9b9BB25f1A81078C544C829c5EB7822d747Cf434;
    address constant BASE_SEPOLIA_L1_STANDARD_BRIDGE = 0xfd0Bf71F60660E2f608ed56e1659C450eB113120;

    // Base Sepolia
    uint256 constant BASE_SEPOLIA = 84532;
    AuthCaptureEscrow constant ESCROW = AuthCaptureEscrow(0xf96815976523E00e65Be8f34cA5e64b4f41EB19c);
    address constant ERC3009_COLLECTOR = 0x8612dfdc421f80336cd14E8EF9cb1E765dB5ab88;
    address constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address constant CALLBACK_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;
    IIdentityRegistry constant IDENTITY = IIdentityRegistry(0x8004A818BFB912233c491871b3d84c89A494BD9e);
    IReputationRegistry constant REPUTATION = IReputationRegistry(0x8004B663056A597Dffe9eCcC1965A193B7388713);
    IValidationRegistry constant VALIDATION = IValidationRegistry(0x8004Cb1BF31DAf7788923b405b754f57acEB4272);

    // Lasna
    uint256 constant CRON100_TOPIC = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
    uint8 constant THRESHOLD = 70;

    bytes32 constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    function _key() internal view returns (uint256) {
        return vm.envUint("EVM_PRIVATE_KEY");
    }

    // ------------------------------------------------------------ Ethereum Sepolia

    function faucet(uint256 weiAmount) external {
        require(block.chainid == 11155111, "not Sepolia");
        require(weiAmount <= 0.3 ether, "over approved amount");
        vm.startBroadcast(_key());
        (bool ok,) = LREACT_FAUCET_SEPOLIA.call{value: weiAmount}("");
        require(ok, "faucet send failed");
        vm.stopBroadcast();
    }

    function bridge(uint256 weiAmount) external {
        require(block.chainid == 11155111, "not Sepolia");
        require(weiAmount <= 0.05 ether, "over approved amount");
        vm.startBroadcast(_key());
        (bool ok,) = BASE_SEPOLIA_L1_STANDARD_BRIDGE.call{value: weiAmount}("");
        require(ok, "bridge send failed");
        vm.stopBroadcast();
    }

    // ------------------------------------------------------------ Lasna

    function deployReactive(address validator, uint256 fundWei) external {
        require(block.chainid == 5318007, "not Lasna");
        vm.startBroadcast(_key());
        DeliveryCourtReactive rc =
            new DeliveryCourtReactive{value: fundWei}(BASE_SEPOLIA, address(VALIDATION), validator, THRESHOLD, CRON100_TOPIC);
        vm.stopBroadcast();
        console2.log("DeliveryCourtReactive", address(rc));
    }

    function setCourt(address rc, address court) external {
        require(block.chainid == 5318007, "not Lasna");
        vm.startBroadcast(_key());
        DeliveryCourtReactive(payable(rc)).setCourt(court);
        vm.stopBroadcast();
    }

    function pauseCron(address rc) external {
        require(block.chainid == 5318007, "not Lasna");
        vm.startBroadcast(_key());
        DeliveryCourtReactive(payable(rc)).pauseCron();
        vm.stopBroadcast();
    }

    function resumeCron(address rc) external {
        require(block.chainid == 5318007, "not Lasna");
        vm.startBroadcast(_key());
        DeliveryCourtReactive(payable(rc)).resumeCron();
        vm.stopBroadcast();
    }

    // ------------------------------------------------------------ Base Sepolia

    /// @param validator the judge address, the same one the reactive contract was deployed with.
    function deployCallback(address rc, address validator) external {
        require(block.chainid == BASE_SEPOLIA, "not Base Sepolia");
        require(validator != address(0), "validator");
        vm.startBroadcast(_key());
        DeliveryCourtCallback court =
            new DeliveryCourtCallback(CALLBACK_PROXY, rc, ESCROW, USDC, IDENTITY, REPUTATION, VALIDATION, validator);
        vm.stopBroadcast();
        console2.log("DeliveryCourtCallback", address(court));
    }

    /// @notice v2: authorize only accepts payments to registered sellers. agentId 0 = no ERC-8004 agent.
    function registerSeller(address court, address seller, uint256 agentId) external {
        require(block.chainid == BASE_SEPOLIA, "not Base Sepolia");
        vm.startBroadcast(_key());
        DeliveryCourtCallback(payable(court)).registerSeller(seller, agentId);
        vm.stopBroadcast();
    }

    function fundCallback(address court, uint256 weiAmount) external {
        require(block.chainid == BASE_SEPOLIA, "not Base Sepolia");
        vm.startBroadcast(_key());
        IDepositTo(CALLBACK_PROXY).depositTo{value: weiAmount}(court);
        vm.stopBroadcast();
    }

    /// @notice Buyer side: builds PaymentInfo and the ERC-3009 signature, writes them to
    /// stage0/pay-<tag>.json. Sends nothing.
    function sign(address court, address receiver, uint120 amount, uint48 ttl, uint256 salt, string calldata tag)
        external
    {
        require(block.chainid == BASE_SEPOLIA, "not Base Sepolia");
        AuthCaptureEscrow.PaymentInfo memory info = _info(court, receiver, amount, ttl, salt);
        bytes memory sig = _sig(info);
        bytes memory callData = abi.encodeCall(DeliveryCourtCallback.authorize, (info, amount, ERC3009_COLLECTOR, sig));
        bytes32 id = ESCROW.getHash(info);
        _write(info, id, callData, tag);
        console2.logBytes32(id);
    }

    function _info(address court, address receiver, uint120 amount, uint48 ttl, uint256 salt)
        internal
        view
        returns (AuthCaptureEscrow.PaymentInfo memory)
    {
        uint48 t = uint48(block.timestamp);
        return AuthCaptureEscrow.PaymentInfo({
            operator: court,
            payer: vm.addr(_key()),
            receiver: receiver,
            token: USDC,
            maxAmount: amount,
            preApprovalExpiry: t + ttl,
            authorizationExpiry: t + ttl,
            refundExpiry: t + ttl,
            minFeeBps: 0,
            maxFeeBps: 0,
            feeReceiver: address(0),
            salt: salt
        });
    }

    function _sig(AuthCaptureEscrow.PaymentInfo memory info) internal view returns (bytes memory) {
        address buyer = info.payer;
        info.payer = address(0);
        bytes32 nonce = ESCROW.getHash(info);
        info.payer = buyer;
        bytes32 structHash = keccak256(
            abi.encode(
                RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
                buyer,
                ERC3009_COLLECTOR,
                uint256(info.maxAmount),
                uint256(0),
                uint256(info.preApprovalExpiry),
                nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IUSDC3009(USDC).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_key(), digest);
        return abi.encodePacked(r, s, v);
    }

    function _write(AuthCaptureEscrow.PaymentInfo memory info, bytes32 id, bytes memory callData, string memory tag)
        internal
    {
        string memory o = "pay";
        vm.serializeAddress(o, "court", info.operator);
        vm.serializeAddress(o, "payer", info.payer);
        vm.serializeAddress(o, "receiver", info.receiver);
        vm.serializeUint(o, "amount", info.maxAmount);
        vm.serializeUint(o, "authorizationExpiry", info.authorizationExpiry);
        vm.serializeUint(o, "salt", info.salt);
        vm.serializeBytes32(o, "paymentId", id);
        string memory out = vm.serializeBytes(o, "calldata", callData);
        vm.writeJson(out, string.concat("stage0/pay-", tag, ".json"));
    }

    /// @notice Relayer side: sends the authorize calldata written by sign().
    function relay(string calldata tag) external {
        require(block.chainid == BASE_SEPOLIA, "not Base Sepolia");
        string memory j = vm.readFile(string.concat("stage0/pay-", tag, ".json"));
        address court = vm.parseJsonAddress(j, ".court");
        bytes memory callData = vm.parseJsonBytes(j, ".calldata");
        vm.startBroadcast(_key());
        (bool ok, bytes memory ret) = court.call(callData);
        vm.stopBroadcast();
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    /// @notice Dry run only (no broadcast): request then response from the same account on a fork.
    function simulateJudge(address account, uint256 agentId, bytes32 paymentId, uint8 score) external {
        vm.startPrank(account);
        VALIDATION.validationRequest(account, agentId, "https://delivery-court.local/request", paymentId);
        VALIDATION.validationResponse(paymentId, score, "https://delivery-court.local/response", bytes32(0), "dc1:200:1500:800");
        vm.stopPrank();
        console2.log("simulateJudge ok");
    }

    function validationRequest(address validator, uint256 agentId, bytes32 paymentId) external {
        require(block.chainid == BASE_SEPOLIA, "not Base Sepolia");
        vm.startBroadcast(_key());
        VALIDATION.validationRequest(validator, agentId, "https://delivery-court.local/request", paymentId);
        vm.stopBroadcast();
    }

    /// @param tag v2 needs "dc1:<status>:<bodyBytes>:<latencyMs>", or the reactive contract scores 0.
    function validationResponse(bytes32 paymentId, uint8 score, bytes32 responseHash, string calldata tag) external {
        require(block.chainid == BASE_SEPOLIA, "not Base Sepolia");
        vm.startBroadcast(_key());
        VALIDATION.validationResponse(paymentId, score, "https://delivery-court.local/response", responseHash, tag);
        vm.stopBroadcast();
    }
}
