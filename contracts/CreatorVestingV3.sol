// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IWETH} from "./interfaces/IUniswapV2.sol";

/// @title Vesting of what a v3 launch owes its creator
/// @notice Holds the creator's share of a launch, both the proceeds in the
/// quote asset and the token allocation, and releases it in equal monthly
/// tranches. The first tranche unlocks one month after the token is listed,
/// so the creator receives nothing on listing day.
///
/// The contract has no owner. Nobody can speed the schedule up, pause it or
/// send the funds anywhere but to the creator. Each vesting is a minimal clone
/// of one implementation; the implementation itself can never be initialized.
contract CreatorVestingV3 is Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Length of one tranche.
    uint64 public constant TRANCHE_DURATION = 30 days;

    // Set once, by `initialize`.

    IERC20 public token;
    IERC20 public quoteAsset;
    /// @notice The creator of the launch. Cannot be changed.
    address public beneficiary;
    /// @notice The sale that funds this vesting when the token is listed.
    address public sale;
    address public weth;
    /// @notice Number of monthly tranches.
    uint8 public trancheCount;

    /// @notice When the vesting started: the moment the token was listed.
    /// Zero until then.
    uint64 public startTime;
    uint256 public totalQuote;
    uint256 public totalTokens;
    uint256 public releasedQuote;
    uint256 public releasedTokens;

    event VestingStarted(
        uint64 startTime,
        uint8 trancheCount,
        uint256 totalQuote,
        uint256 totalTokens
    );
    event Released(uint256 quoteAmount, uint256 tokenAmount, uint256 tranchesVested);

    error OnlySale();
    error AlreadyStarted();
    error FundsNotReceived();
    error NothingToRelease();
    error NativeNotAccepted();

    constructor() {
        _disableInitializers();
    }

    /// @notice Only the native currency being unwrapped can be sent here.
    receive() external payable {
        if (msg.sender != weth) revert NativeNotAccepted();
    }

    /// @notice Called once, by the sale that creates this clone.
    function initialize(
        IERC20 token_,
        IERC20 quoteAsset_,
        address beneficiary_,
        address weth_,
        uint8 trancheCount_
    ) external initializer {
        sale = msg.sender;
        token = token_;
        quoteAsset = quoteAsset_;
        beneficiary = beneficiary_;
        weth = weth_;
        trancheCount = trancheCount_;
    }

    /// @notice Starts the schedule. Called once by the sale when it lists the
    /// token, after sending the tokens and the proceeds here.
    function start(uint256 tokenAmount, uint256 quoteAmount) external {
        if (msg.sender != sale) revert OnlySale();
        if (startTime != 0) revert AlreadyStarted();
        if (
            token.balanceOf(address(this)) < tokenAmount ||
            quoteAsset.balanceOf(address(this)) < quoteAmount
        ) revert FundsNotReceived();

        startTime = uint64(block.timestamp);
        totalQuote = quoteAmount;
        totalTokens = tokenAmount;
        emit VestingStarted(startTime, trancheCount, quoteAmount, tokenAmount);
    }

    /// @notice Sends the creator everything unlocked so far. Anyone can call
    /// it; the funds only ever go to the creator.
    function release() external nonReentrant {
        (uint256 quoteAmount, uint256 tokenAmount) = releasable();
        if (quoteAmount == 0 && tokenAmount == 0) revert NothingToRelease();

        releasedQuote += quoteAmount;
        releasedTokens += tokenAmount;
        emit Released(quoteAmount, tokenAmount, tranchesVested());

        if (tokenAmount > 0) token.safeTransfer(beneficiary, tokenAmount);
        if (quoteAmount > 0) _pay(quoteAmount);
    }

    /// @notice Tranches unlocked so far, from zero to `trancheCount`.
    function tranchesVested() public view returns (uint256) {
        if (startTime == 0) return 0;
        uint256 elapsed = (block.timestamp - startTime) / TRANCHE_DURATION;
        return elapsed < trancheCount ? elapsed : trancheCount;
    }

    /// @notice What `release` would send right now.
    function releasable() public view returns (uint256 quoteAmount, uint256 tokenAmount) {
        uint256 vested = tranchesVested();
        // The last tranche pays out whatever rounding left behind.
        quoteAmount = (totalQuote * vested) / trancheCount - releasedQuote;
        tokenAmount = (totalTokens * vested) / trancheCount - releasedTokens;
    }

    /// Pays the creator in the quote asset; in the native currency when the
    /// quote is its wrapped token, or in the wrapped token if the creator
    /// cannot receive the native one.
    function _pay(uint256 amount) private {
        if (address(quoteAsset) != weth) {
            quoteAsset.safeTransfer(beneficiary, amount);
            return;
        }
        IWETH(weth).withdraw(amount);
        (bool sent, ) = beneficiary.call{value: amount}("");
        if (!sent) {
            IWETH(weth).deposit{value: amount}();
            quoteAsset.safeTransfer(beneficiary, amount);
        }
    }
}
