// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library UniswapAddresses {
    uint256 internal constant CHAIN_ID_MAINNET = 1;
    uint256 internal constant CHAIN_ID_OPTIMISM = 10;
    uint256 internal constant CHAIN_ID_BNB = 56;
    uint256 internal constant CHAIN_ID_UNICHAIN = 130;
    uint256 internal constant CHAIN_ID_MONAD = 143;
    uint256 internal constant CHAIN_ID_X_LAYER = 196;
    uint256 internal constant CHAIN_ID_WORLD_CHAIN = 480;
    uint256 internal constant CHAIN_ID_HYPEREVM = 999;
    uint256 internal constant CHAIN_ID_UNICHAIN_SEPOLIA = 1301;
    uint256 internal constant CHAIN_ID_SONEIUM = 1868;
    uint256 internal constant CHAIN_ID_TEMPO = 4217;
    uint256 internal constant CHAIN_ID_MEGAETH = 4326;
    uint256 internal constant CHAIN_ID_ARC = 5042;
    uint256 internal constant CHAIN_ID_INK = 57073;
    uint256 internal constant CHAIN_ID_LINEA = 59144;
    uint256 internal constant CHAIN_ID_BASE = 8453;
    uint256 internal constant CHAIN_ID_POLYGON = 137;
    uint256 internal constant CHAIN_ID_AVALANCHE = 43114;
    uint256 internal constant CHAIN_ID_CELO = 42220;
    uint256 internal constant CHAIN_ID_ARBITRUM = 42161;
    uint256 internal constant CHAIN_ID_ROBINHOOD = 4663;
    uint256 internal constant CHAIN_ID_ZORA = 7777777;
    uint256 internal constant CHAIN_ID_SEPOLIA = 11155111;
    uint256 internal constant CHAIN_ID_BASE_SEPOLIA = 84532;
    uint256 internal constant CHAIN_ID_ARBITRUM_SEPOLIA = 421614;
    uint256 internal constant CHAIN_ID_INTEROP_ALPHA_0 = 420120000;
    uint256 internal constant CHAIN_ID_INTEROP_ALPHA_1 = 420120001;
    uint256 internal constant CHAIN_ID_ANVIL = 31337;

    /// @notice Canonical Uniswap v4 PoolManager address for a chain, or zero if unsupported.
    /// @dev Addresses follow Uniswap's active v4 deployment feed and deployment documentation.
    /// The current Unichain Sepolia deployment (0x00B036...) supersedes the older address in
    /// the feed generated on 2026-09-22.
    /// Source: https://developers.uniswap.org/deployments.json
    function poolManager(uint256 chainId) internal pure returns (address) {
        if (chainId == CHAIN_ID_MAINNET) return 0x000000000004444c5dc75cB358380D2e3dE08A90;
        if (chainId == CHAIN_ID_OPTIMISM) return 0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3;
        if (chainId == CHAIN_ID_BNB) return 0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF;
        if (chainId == CHAIN_ID_UNICHAIN) return 0x1F98400000000000000000000000000000000004;
        if (chainId == CHAIN_ID_MONAD) return 0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e;
        if (chainId == CHAIN_ID_X_LAYER) return 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
        if (chainId == CHAIN_ID_WORLD_CHAIN) return 0xb1860D529182ac3BC1F51Fa2ABd56662b7D13f33;
        if (chainId == CHAIN_ID_HYPEREVM) return 0x12D4Fd9C5DeDd00ab8a0bCe2CF0167bbf94b6B1F;
        if (chainId == CHAIN_ID_UNICHAIN_SEPOLIA) return 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
        if (chainId == CHAIN_ID_SONEIUM) return 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
        if (chainId == CHAIN_ID_TEMPO) return 0x33620f62C5b9B2086dD6b62F4A297A9f30347029;
        if (chainId == CHAIN_ID_MEGAETH) return 0xaCB7e78fa05D562e0A5D3089ec896D57D057d38E;
        if (chainId == CHAIN_ID_ARC) return 0x8366a39CC670B4001A1121B8F6A443A643e40951;
        if (chainId == CHAIN_ID_INK) return 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
        if (chainId == CHAIN_ID_LINEA) return 0x248083Fb965359d82b06C1F5322480Dcfc1AD857;
        if (chainId == CHAIN_ID_BASE) return 0x498581fF718922c3f8e6A244956aF099B2652b2b;
        if (chainId == CHAIN_ID_POLYGON) return 0x67366782805870060151383F4BbFF9daB53e5cD6;
        if (chainId == CHAIN_ID_AVALANCHE) return 0x06380C0e0912312B5150364B9DC4542BA0DbBc85;
        if (chainId == CHAIN_ID_CELO) return 0x288dc841A52FCA2707c6947B3A777c5E56cd87BC;
        if (chainId == CHAIN_ID_ARBITRUM) return 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
        if (chainId == CHAIN_ID_ROBINHOOD) return 0x8366a39CC670B4001A1121B8F6A443A643e40951;
        if (chainId == CHAIN_ID_ZORA) return 0x0575338e4C17006aE181B47900A84404247CA30f;
        if (chainId == CHAIN_ID_SEPOLIA) return 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
        if (chainId == CHAIN_ID_BASE_SEPOLIA) return 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
        if (chainId == CHAIN_ID_ARBITRUM_SEPOLIA) return 0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317;
        if (chainId == CHAIN_ID_INTEROP_ALPHA_0 || chainId == CHAIN_ID_INTEROP_ALPHA_1) {
            return 0x9131B9084E6017Be19c6a0ef23f73dbB1Bf41f96;
        }
        return address(0);
    }

    /// @notice First block to scan for the canonical PoolManager, inclusive.
    /// @dev Values are Uniswap's v4 subgraph PoolManager start blocks, except HyperEVM, whose
    /// creation block was verified from its explorer, and interop alpha, which is absent from
    /// the subgraph manifest and therefore scans from genesis.
    /// Source: https://github.com/Uniswap/v4-subgraph/blob/main/networks.json
    function poolManagerStartBlock(uint256 chainId) internal pure returns (uint256) {
        if (chainId == CHAIN_ID_MAINNET) return 21_688_329;
        if (chainId == CHAIN_ID_OPTIMISM) return 130_947_675;
        if (chainId == CHAIN_ID_BNB) return 45_970_610;
        if (chainId == CHAIN_ID_UNICHAIN) return 25_500;
        if (chainId == CHAIN_ID_MONAD) return 29_255_895;
        if (chainId == CHAIN_ID_X_LAYER) return 46_460_144;
        if (chainId == CHAIN_ID_WORLD_CHAIN) return 9_111_872;
        if (chainId == CHAIN_ID_HYPEREVM) return 45_998_366;
        if (chainId == CHAIN_ID_UNICHAIN_SEPOLIA) return 7_092_034;
        if (chainId == CHAIN_ID_SONEIUM) return 2_473_300;
        if (chainId == CHAIN_ID_TEMPO) return 6_606_180;
        if (chainId == CHAIN_ID_MEGAETH) return 7_009_653;
        if (chainId == CHAIN_ID_ARC) return 1_948_011;
        if (chainId == CHAIN_ID_INK) return 4_580_556;
        if (chainId == CHAIN_ID_LINEA) return 28_974_969;
        if (chainId == CHAIN_ID_BASE) return 25_350_988;
        if (chainId == CHAIN_ID_POLYGON) return 66_980_384;
        if (chainId == CHAIN_ID_AVALANCHE) return 56_195_376;
        if (chainId == CHAIN_ID_CELO) return 43_985_160;
        if (chainId == CHAIN_ID_ARBITRUM) return 297_842_872;
        if (chainId == CHAIN_ID_ROBINHOOD) return 9_070;
        if (chainId == CHAIN_ID_ZORA) return 25_434_534;
        if (chainId == CHAIN_ID_SEPOLIA) return 7_258_946;
        if (chainId == CHAIN_ID_BASE_SEPOLIA) return 19_088_197;
        if (chainId == CHAIN_ID_ARBITRUM_SEPOLIA) return 105_909_222;
        if (chainId == CHAIN_ID_INTEROP_ALPHA_0 || chainId == CHAIN_ID_INTEROP_ALPHA_1) return 0;

        revert("Unknown canonical PoolManager chain");
    }

    function hasCanonicalPoolManager(uint256 chainId) internal pure returns (bool) {
        return poolManager(chainId) != address(0);
    }
}
