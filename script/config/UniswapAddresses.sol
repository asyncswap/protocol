// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library UniswapAddresses {
    uint256 internal constant CHAIN_ID_MAINNET = 1;
    uint256 internal constant CHAIN_ID_UNICHAIN = 130;
    uint256 internal constant CHAIN_ID_UNICHAIN_SEPOLIA = 1301;
    uint256 internal constant CHAIN_ID_ANVIL = 31337;

    /// @notice Canonical PoolManager address for the given chain, or zero if none.
    /// @dev Sources: https://docs.uniswap.org/contracts/v4/deployments
    function poolManager(uint256 chainId) internal pure returns (address) {
        if (chainId == CHAIN_ID_MAINNET) return 0x000000000004444c5dc75cB358380D2e3dE08A90;
        if (chainId == CHAIN_ID_UNICHAIN) return 0x1F98400000000000000000000000000000000004;
        if (chainId == CHAIN_ID_UNICHAIN_SEPOLIA) return 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
        return address(0);
    }

    /// @notice First block to scan for the canonical PoolManager, inclusive.
    function poolManagerStartBlock(uint256 chainId) internal pure returns (uint256) {
        // Ethereum PoolManager creation transaction: block 21,688,329.
        if (chainId == CHAIN_ID_MAINNET) return 21_688_329;

        // Unichain's canonical PoolManager is installed at its genesis address.
        if (chainId == CHAIN_ID_UNICHAIN) return 0;

        // Unichain Sepolia PoolManager creation transaction: block 7,092,034.
        if (chainId == CHAIN_ID_UNICHAIN_SEPOLIA) return 7_092_034;

        revert("Unknown canonical PoolManager chain");
    }

    function hasCanonicalPoolManager(uint256 chainId) internal pure returns (bool) {
        return poolManager(chainId) != address(0);
    }
}
