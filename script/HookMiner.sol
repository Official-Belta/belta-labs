// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title HookMiner
/// @notice CREATE2 salt mining for Uniswap V4 Hook address matching
/// @dev Finds a salt that produces a hook address whose lower bits match required permission flags
library HookMiner {
    /// @notice Find a salt that produces a hook address matching the required flags
    /// @param deployer The CREATE2 deployer address (e.g., CREATE2Deployer or your own)
    /// @param flags The required hook permission flags (lower 14 bits of address)
    /// @param creationCode The creation code of the hook contract (type(Hook).creationCode)
    /// @param constructorArgs The ABI-encoded constructor arguments
    /// @return hookAddress The computed hook address
    /// @return salt The salt to use with CREATE2
    function find(
        address deployer,
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal pure returns (address hookAddress, bytes32 salt) {
        bytes memory initCode = abi.encodePacked(creationCode, constructorArgs);
        bytes32 initCodeHash = keccak256(initCode);

        // Mask for lower 14 bits (Uniswap V4 hook flags)
        uint160 FLAG_MASK = uint160(0x3FFF);

        for (uint256 i = 0; i < 100_000; i++) {
            salt = bytes32(i);
            hookAddress = _computeAddress(deployer, salt, initCodeHash);

            if (uint160(hookAddress) & FLAG_MASK == flags & FLAG_MASK) {
                return (hookAddress, salt);
            }
        }

        revert("HookMiner: no salt found in 100k iterations");
    }

    function _computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash)
        internal
        pure
        returns (address)
    {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)
                    )
                )
            )
        );
    }
}
