// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Token launched on Somewhere
/// @notice A plain ERC-20 with a fixed supply. Everything is minted once, when
/// the launch is created, and handed to the sale that distributes it. Nobody
/// can mint more, pause transfers or change balances afterwards: the contract
/// has no owner and no admin function.
contract LaunchToken is ERC20 {
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 totalSupply_,
        address holder
    ) ERC20(name_, symbol_) {
        _mint(holder, totalSupply_);
    }
}
