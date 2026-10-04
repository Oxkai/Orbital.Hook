// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice A stablecoin with its issuer's emergency controls, the way the real
///         ones on Arbitrum have them: a global pause (Paxos USDG's `pause`,
///         Circle's `pauser`) and per-address freezing (Circle's blacklist,
///         Tether's blocklist, Paxos' `freeze`). A paused token moves for no
///         one; a frozen address can neither send nor receive.
contract FreezableToken is MockERC20 {
    bool public paused;
    mapping(address => bool) public frozen;

    constructor(uint8 decimals_) MockERC20("Frozen Dollar", "FRZ", decimals_) {}

    function pause(bool on) external {
        paused = on;
    }

    function freeze(address who, bool on) external {
        frozen[who] = on;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _check(msg.sender, to);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _check(from, to);
        return super.transferFrom(from, to, amount);
    }

    function _check(address from, address to) internal view {
        require(!paused, "PAUSED");
        require(!frozen[from] && !frozen[to], "FROZEN");
    }
}
