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

    /// @notice Indexer start block for the canonical PoolManager. 0 = "scan from genesis".
    function poolManagerStartBlock(uint256 chainId) internal pure returns (uint256) {
        if (chainId == CHAIN_ID_MAINNET) return 0;
        if (chainId == CHAIN_ID_UNICHAIN) return 0;
        if (chainId == CHAIN_ID_UNICHAIN_SEPOLIA) return 0;
        return 0;
    }

    function hasCanonicalPoolManager(uint256 chainId) internal pure returns (bool) {
        return poolManager(chainId) != address(0);
    }
}
