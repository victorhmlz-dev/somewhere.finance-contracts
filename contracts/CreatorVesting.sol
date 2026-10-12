// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Vesting of what a launch owes its creator
/// @notice Holds the creator's share of a launch, both the proceeds in native
/// currency and the token allocation, and releases it in equal monthly
/// tranches. The first tranche unlocks one month after the token is listed,
/// so the creator receives nothing on listing day.
///
/// The contract has no owner. Nobody can speed the schedule up, pause it or
/// send the funds anywhere but to the creator.
contract CreatorVesting is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Length of one tranche.
    uint64 public constant TRANCHE_DURATION = 30 days;

    IERC20 public immutable token;
    /// @notice The creator of the launch. Cannot be changed.
    address public immutable beneficiary;
    /// @notice The sale that funds this vesting when the token is listed.
    address public immutable sale;
    /// @notice Number of monthly tranches.
    uint8 public immutable trancheCount;

    /// @notice When the vesting started: the moment the token was listed.
    /// Zero until then.
    uint64 public startTime;
    uint256 public totalNative;
    uint256 public totalTokens;
    uint256 public releasedNative;
    uint256 public releasedTokens;

    event VestingStarted(
        uint64 startTime,
        uint8 trancheCount,
        uint256 totalNative,
        uint256 totalTokens
    );
    event Released(uint256 nativeAmount, uint256 tokenAmount, uint256 tranchesVested);

    error OnlySale();
    error AlreadyStarted();
    error TokensNotReceived();
    error NothingToRelease();
    error NativeTransferFailed();

    constructor(IERC20 token_, address beneficiary_, uint8 trancheCount_) {
        token = token_;
        beneficiary = beneficiary_;
        trancheCount = trancheCount_;
        sale = msg.sender;
    }

    /// @notice Starts the schedule. Called once by the sale when it lists the
    /// token, with the proceeds attached and after sending the tokens here.
    function start(uint256 tokenAmount) external payable {
        if (msg.sender != sale) revert OnlySale();
        if (startTime != 0) revert AlreadyStarted();
        if (token.balanceOf(address(this)) < tokenAmount) revert TokensNotReceived();

        startTime = uint64(block.timestamp);
        totalNative = msg.value;
        totalTokens = tokenAmount;
        emit VestingStarted(startTime, trancheCount, msg.value, tokenAmount);
    }

    /// @notice Sends the creator everything unlocked so far. Anyone can call
    /// it; the funds only ever go to the creator.
    function release() external nonReentrant {
        (uint256 nativeAmount, uint256 tokenAmount) = releasable();
        if (nativeAmount == 0 && tokenAmount == 0) revert NothingToRelease();

        releasedNative += nativeAmount;
        releasedTokens += tokenAmount;
        emit Released(nativeAmount, tokenAmount, tranchesVested());

        if (tokenAmount > 0) token.safeTransfer(beneficiary, tokenAmount);
        if (nativeAmount > 0) {
            (bool sent, ) = beneficiary.call{value: nativeAmount}("");
            if (!sent) revert NativeTransferFailed();
        }
    }

    /// @notice Tranches unlocked so far, from zero to `trancheCount`.
    function tranchesVested() public view returns (uint256) {
        if (startTime == 0) return 0;
        uint256 elapsed = (block.timestamp - startTime) / TRANCHE_DURATION;
        return elapsed < trancheCount ? elapsed : trancheCount;
    }

    /// @notice What `release` would send right now.
    function releasable() public view returns (uint256 nativeAmount, uint256 tokenAmount) {
        uint256 vested = tranchesVested();
        // The last tranche pays out whatever rounding left behind.
        nativeAmount = (totalNative * vested) / trancheCount - releasedNative;
        tokenAmount = (totalTokens * vested) / trancheCount - releasedTokens;
    }
}
