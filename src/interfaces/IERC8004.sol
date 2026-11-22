// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Minimal ERC-8004 v2.0.0 interfaces, matching the registries deployed on Base Sepolia.
/// Source: erc-8004/erc-8004-contracts @ b9e466c25074 (contracts/*Upgradeable.sol).
interface IIdentityRegistry {
    function register(string memory agentURI) external returns (uint256 agentId);
    function ownerOf(uint256 agentId) external view returns (address);
    function isAuthorizedOrOwner(address spender, uint256 agentId) external view returns (bool);
}

interface IReputationRegistry {
    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata endpoint,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external;

    function getLastIndex(uint256 agentId, address clientAddress) external view returns (uint64);
}

interface IValidationRegistry {
    function validationRequest(address validatorAddress, uint256 agentId, string calldata requestURI, bytes32 requestHash)
        external;

    function validationResponse(
        bytes32 requestHash,
        uint8 response,
        string calldata responseURI,
        bytes32 responseHash,
        string calldata tag
    ) external;

    /// @dev Reverts ("unknown") for a requestHash that was never requested.
    function getValidationStatus(bytes32 requestHash)
        external
        view
        returns (
            address validatorAddress,
            uint256 agentId,
            uint8 response,
            bytes32 responseHash,
            string memory tag,
            uint256 lastUpdate
        );

    event ValidationResponse(
        address indexed validatorAddress,
        uint256 indexed agentId,
        bytes32 indexed requestHash,
        uint8 response,
        string responseURI,
        bytes32 responseHash,
        string tag
    );
}
