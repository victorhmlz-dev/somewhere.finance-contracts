// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

// Quote assets for the v3 tests only.

/// A dollar stablecoin with 6 decimals and EIP-2612 permits, like USDC or USDG.
contract MockStablecoin is ERC20Permit {
    constructor() ERC20("Mock Dollar", "MUSD") ERC20Permit("Mock Dollar") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// A token whose issuer can pause it, block addresses and burn anyone's
/// balance, like Robinhood Stock Tokens (`pause`, `isBlocked`, `adminBurn`).
contract MockIssuerToken is ERC20Permit {
    bool public paused;
    mapping(address account => bool) public isBlocked;

    constructor() ERC20("Mock Stock", "MSTK") ERC20Permit("Mock Stock") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function setBlocked(address account, bool blocked) external {
        isBlocked[account] = blocked;
    }

    function adminBurn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        // Burning by the issuer works even while paused, as it can on the real token.
        if (to != address(0)) {
            require(!paused, "PAUSED");
            require(!isBlocked[from] && !isBlocked[to], "BLOCKED");
        }
        super._update(from, to, value);
    }
}

/// A token that keeps 1% of every transfer.
contract MockFeeToken is ERC20 {
    constructor() ERC20("Mock Fee Token", "MFEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = value / 100;
        super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}

/// A contributor that cannot receive the native currency, to check that the
/// v3 sale then pays it in the wrapped token.
contract NativeRefuser {
    struct TierProof {
        uint8 tier;
        uint64 expiresAt;
        bytes signature;
    }

    function contributeNative(address sale) external payable {
        TierProof memory proof;
        (bool ok, bytes memory reason) = sale.call{value: msg.value}(
            abi.encodeWithSignature("contributeNative((uint8,uint64,bytes))", proof)
        );
        if (!ok) {
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    function refund(address sale) external {
        (bool ok, bytes memory reason) = sale.call(abi.encodeWithSignature("refund()"));
        if (!ok) {
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }
}
