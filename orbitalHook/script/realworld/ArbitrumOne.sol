// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Live Arbitrum One contracts the real-world run uses, each checked
///         on-chain (symbol, decimals, code) before it was written here.
library ArbitrumOne {
    /// Circle's native USDC, 6 decimals. Blacklist and pause: `blacklister`, `pauser`.
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    /// Tether's USDT0 (LayerZero OFT), 6 decimals. Blocklist: `isBlocked`.
    address internal constant USDT0 = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    /// Paxos Global Dollar, 6 decimals. Pause and freeze by role. NOT the
    /// Ethereum address 0xe343…491D, which is an unrelated token here.
    address internal constant USDG = 0x004B506865409877C9fA29bfb1ebA929984B9bbC;
    /// Bridged DAI, 18 decimals.
    address internal constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;

    /// The benchmark: Uniswap v3's USDC/USDT0 pool at the 0.01% fee tier,
    /// the same 1 bp Orbital charges.
    address internal constant V3_USDC_USDT0_POOL = 0xbE3aD6a5669Dc0B8b12FeBC03608860C31E2eef6;
    /// Uniswap's SwapRouter02, to trade that pool.
    address internal constant V3_SWAP_ROUTER02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    function stables() internal pure returns (address[] memory t) {
        t = new address[](4);
        (t[0], t[1], t[2], t[3]) = (USDC, USDT0, USDG, DAI);
    }
}
