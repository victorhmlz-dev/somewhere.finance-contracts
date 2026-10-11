// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Factory} from "./interfaces/IUniswapV2.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {TokenSale} from "./TokenSale.sol";

/// @title Somewhere token launchpad
/// @notice Creates token launches. Each launch is a new token with a fixed
/// supply and a `TokenSale` that holds all of it. Anyone can create a launch;
/// the rules below cannot be skipped by the creator or by the platform.
///
/// How the supply of a launch is split:
/// - the creator allocation, at most 1%;
/// - half of the rest is offered in the sale;
/// - the other half is reserved for the exchange liquidity.
/// Tokens left unsold, with their share of the liquidity reserve, are burned.
///
/// The owner (the platform) can only change the fee of future launches and who
/// receives it. It has no power over a launch once created, nor over its funds.
contract Launchpad is Ownable2Step {
    struct LaunchParams {
        string name;
        string symbol;
        /// Whole supply of the token, with 18 decimals.
        uint256 totalSupply;
        /// Share of the supply for the creator, in basis points (100 = 1%).
        uint16 creatorAllocationBps;
        /// Minimum to raise, in wei, for the launch to go ahead.
        uint256 softCap;
        /// Maximum to raise, in wei.
        uint256 hardCap;
        uint64 startTime;
        uint64 endTime;
    }

    struct Launch {
        address token;
        address sale;
        address creator;
    }

    uint256 private constant BPS = 10_000;

    /// @notice No creator can keep more than 1% of the supply.
    uint16 public constant MAX_CREATOR_ALLOCATION_BPS = 100;
    /// @notice The platform fee can never be set above 5% of what is raised.
    uint16 public constant MAX_FEE_BPS = 500;
    uint64 public constant MAX_SALE_DURATION = 30 days;
    /// @notice A sale cannot be scheduled further ahead than this.
    uint64 public constant MAX_START_DELAY = 90 days;
    /// @notice Keeps every amount far from overflowing: 10^15 whole tokens.
    uint256 public constant MAX_TOTAL_SUPPLY = 1e33;

    IUniswapV2Factory public immutable dexFactory;
    address public immutable weth;

    /// @notice Fee applied to launches created from now on.
    uint16 public feeBps;
    address public feeRecipient;

    Launch[] private _launches;

    event LaunchCreated(
        uint256 indexed launchId,
        address indexed creator,
        address indexed token,
        address sale,
        LaunchParams params,
        uint256 tokensForSale,
        uint256 creatorAllocation,
        uint16 feeBps
    );
    event FeeUpdated(uint16 feeBps);
    event FeeRecipientUpdated(address feeRecipient);

    error ZeroAddress();
    error EmptyName();
    error InvalidTotalSupply();
    error CreatorAllocationTooHigh();
    error InvalidCaps();
    error InvalidSchedule();
    error FeeTooHigh();

    constructor(
        address owner_,
        IUniswapV2Factory dexFactory_,
        address weth_,
        address feeRecipient_,
        uint16 feeBps_
    ) Ownable(owner_) {
        if (address(dexFactory_) == address(0) || weth_ == address(0)) revert ZeroAddress();
        dexFactory = dexFactory_;
        weth = weth_;
        _setFeeRecipient(feeRecipient_);
        _setFee(feeBps_);
    }

    /// @notice Creates a token and its sale. The caller becomes the creator.
    function createLaunch(
        LaunchParams calldata params
    ) external returns (uint256 launchId, address token, address sale) {
        if (bytes(params.name).length == 0 || bytes(params.symbol).length == 0) revert EmptyName();
        if (params.totalSupply == 0 || params.totalSupply > MAX_TOTAL_SUPPLY) {
            revert InvalidTotalSupply();
        }
        if (params.creatorAllocationBps > MAX_CREATOR_ALLOCATION_BPS) {
            revert CreatorAllocationTooHigh();
        }
        if (params.softCap == 0 || params.softCap > params.hardCap) revert InvalidCaps();
        if (
            params.startTime < block.timestamp ||
            params.startTime > block.timestamp + MAX_START_DELAY ||
            params.endTime <= params.startTime ||
            params.endTime - params.startTime > MAX_SALE_DURATION
        ) revert InvalidSchedule();

        uint256 creatorAllocation = (params.totalSupply * params.creatorAllocationBps) / BPS;
        uint256 tokensForSale = (params.totalSupply - creatorAllocation) / 2;
        // Every wei has to buy at least one unit of the token.
        if (tokensForSale < params.hardCap) revert InvalidTotalSupply();

        // The supply is minted here and handed over to the sale in the same
        // transaction; this contract never holds tokens outside of this call.
        token = address(
            new LaunchToken(params.name, params.symbol, params.totalSupply, address(this))
        );
        sale = _deploySale(IERC20(token), params, tokensForSale, creatorAllocation);
        // LaunchToken is a standard OpenZeppelin ERC-20: it reverts on failure.
        IERC20(token).transfer(sale, params.totalSupply);

        launchId = _launches.length;
        _launches.push(Launch({token: token, sale: sale, creator: msg.sender}));

        emit LaunchCreated(
            launchId,
            msg.sender,
            token,
            sale,
            params,
            tokensForSale,
            creatorAllocation,
            feeBps
        );
    }

    function setFee(uint16 feeBps_) external onlyOwner {
        _setFee(feeBps_);
    }

    function setFeeRecipient(address feeRecipient_) external onlyOwner {
        _setFeeRecipient(feeRecipient_);
    }

    function launchCount() external view returns (uint256) {
        return _launches.length;
    }

    function getLaunch(uint256 launchId) external view returns (Launch memory) {
        return _launches[launchId];
    }

    function _deploySale(
        IERC20 token,
        LaunchParams calldata params,
        uint256 tokensForSale,
        uint256 creatorAllocation
    ) private returns (address) {
        return
            address(
                new TokenSale(
                    TokenSale.Config({
                        token: token,
                        creator: msg.sender,
                        feeRecipient: feeRecipient,
                        dexFactory: dexFactory,
                        weth: weth,
                        tokensForSale: tokensForSale,
                        creatorAllocation: creatorAllocation,
                        softCap: params.softCap,
                        hardCap: params.hardCap,
                        startTime: params.startTime,
                        endTime: params.endTime,
                        feeBps: feeBps
                    })
                )
            );
    }

    function _setFee(uint16 feeBps_) private {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = feeBps_;
        emit FeeUpdated(feeBps_);
    }

    function _setFeeRecipient(address feeRecipient_) private {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        feeRecipient = feeRecipient_;
        emit FeeRecipientUpdated(feeRecipient_);
    }
}
