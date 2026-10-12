// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Factory} from "./interfaces/IUniswapV2.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {TokenSale} from "./TokenSale.sol";

/// @title Somewhere Launchpad: fixed-price token launches
/// @notice Creates token launches. Each launch is a new token with a fixed
/// supply, a `TokenSale` that holds all of it, and a `CreatorVesting` for what
/// the creator is owed. Anyone can create a launch; the limits below cannot be
/// skipped by the creator or by the platform, and a launch cannot be changed
/// once created.
///
/// How the supply of a launch is split:
/// - the creator allocation, at most 1%, released through vesting;
/// - the tokens offered in the sale;
/// - the tokens reserved for the exchange liquidity, in the same proportion
///   as the share of the raise that goes to liquidity.
/// Tokens left unsold, with their share of the liquidity reserve, are burned.
///
/// The owner (the platform) can only change the fee of future launches, never
/// above 1%, and who collects the fees. It has no power over a launch once
/// created, nor over its funds. There is no upgrade mechanism: a new version
/// of the protocol is a new deployment, and existing launches keep their rules.
contract Launchpad is Ownable2Step {
    struct LaunchParams {
        string name;
        string symbol;
        /// Whole supply of the token, with 18 decimals.
        uint256 totalSupply;
        /// Minimum to raise, in wei, for the launch to go ahead.
        uint256 softCap;
        /// Maximum to raise, in wei.
        uint256 hardCap;
        /// Least a wallet can have contributed, in wei. Zero for no minimum.
        uint256 minContribution;
        /// Most a wallet can contribute, in wei. Zero for no maximum.
        uint256 maxContribution;
        uint64 startTime;
        uint64 endTime;
        /// Share of the supply for the creator, in basis points (100 = 1%).
        uint16 creatorAllocationBps;
        /// Share of the raise that goes to locked liquidity, in basis points.
        uint16 liquidityBps;
        /// Monthly tranches in which the creator receives the rest.
        uint8 vestingTranches;
    }

    struct Launch {
        address token;
        address sale;
        address vesting;
        address creator;
    }

    uint256 private constant BPS = 10_000;

    /// @notice No creator can keep more than 1% of the supply.
    uint16 public constant MAX_CREATOR_ALLOCATION_BPS = 100;
    /// @notice The platform fee can never be set above 1% of what is raised.
    uint16 public constant MAX_FEE_BPS = 100;
    /// @notice At least 70% of what is raised goes to locked liquidity.
    uint16 public constant MIN_LIQUIDITY_BPS = 7000;
    /// @notice The creator is paid in at least three monthly tranches.
    uint8 public constant MIN_VESTING_TRANCHES = 3;
    uint8 public constant MAX_VESTING_TRANCHES = 48;
    uint64 public constant MAX_SALE_DURATION = 30 days;
    /// @notice A sale cannot be scheduled further ahead than this.
    uint64 public constant MAX_START_DELAY = 90 days;
    /// @notice 1,000 whole tokens.
    uint256 public constant MIN_TOTAL_SUPPLY = 1_000e18;
    /// @notice Keeps every amount far from overflowing: 10^15 whole tokens.
    uint256 public constant MAX_TOTAL_SUPPLY = 1e33;
    /// @notice Smallest minimum raise: 0.01 of the native currency. Keeps
    /// launches large enough for the exchange to accept their liquidity.
    uint256 public constant MIN_SOFT_CAP = 0.01 ether;

    IUniswapV2Factory public immutable dexFactory;
    address public immutable weth;

    /// @notice Fee applied to launches created from now on.
    uint16 public feeBps;
    /// @notice Who collects the fees of every launch, past and future.
    address public feeRecipient;

    Launch[] private _launches;

    event LaunchCreated(
        uint256 indexed launchId,
        address indexed creator,
        address indexed token,
        address sale,
        address vesting,
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
    error InvalidContributionLimits();
    error InvalidSchedule();
    error InvalidLiquidityShare();
    error InvalidVesting();
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

    /// @notice Creates a token, its sale and its vesting. The caller becomes
    /// the creator.
    function createLaunch(
        LaunchParams calldata params
    ) external returns (uint256 launchId, address token, address sale) {
        uint16 fee = feeBps;
        _validate(params, fee);

        uint256 creatorAllocation = (params.totalSupply * params.creatorAllocationBps) / BPS;
        // For every token sold, `liquidityBps` of a token is paired on the
        // exchange, so the sale takes 1 part and the liquidity reserve
        // `liquidityBps` parts of what is left after the creator allocation.
        uint256 tokensForSale = ((params.totalSupply - creatorAllocation) * BPS) /
            (BPS + params.liquidityBps);
        // Every wei has to buy at least one unit of the token.
        if (tokensForSale < params.hardCap) revert InvalidTotalSupply();

        // The supply is minted here and handed over to the sale in the same
        // transaction; this contract never holds tokens outside of this call.
        token = address(
            new LaunchToken(params.name, params.symbol, params.totalSupply, address(this))
        );
        sale = _deploySale(IERC20(token), params, tokensForSale, creatorAllocation, fee);
        // LaunchToken is a standard OpenZeppelin ERC-20: it reverts on failure.
        IERC20(token).transfer(sale, params.totalSupply);

        address vesting = address(TokenSale(payable(sale)).vesting());
        launchId = _launches.length;
        _launches.push(
            Launch({token: token, sale: sale, vesting: vesting, creator: msg.sender})
        );

        emit LaunchCreated(
            launchId,
            msg.sender,
            token,
            sale,
            vesting,
            params,
            tokensForSale,
            creatorAllocation,
            fee
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

    function _validate(LaunchParams calldata params, uint16 fee) private view {
        if (bytes(params.name).length == 0 || bytes(params.symbol).length == 0) revert EmptyName();
        if (params.totalSupply < MIN_TOTAL_SUPPLY || params.totalSupply > MAX_TOTAL_SUPPLY) {
            revert InvalidTotalSupply();
        }
        if (params.creatorAllocationBps > MAX_CREATOR_ALLOCATION_BPS) {
            revert CreatorAllocationTooHigh();
        }
        if (params.softCap < MIN_SOFT_CAP || params.softCap > params.hardCap) revert InvalidCaps();
        if (
            params.minContribution > params.hardCap ||
            (params.maxContribution != 0 && params.maxContribution < params.minContribution)
        ) revert InvalidContributionLimits();
        if (
            params.startTime < block.timestamp ||
            params.startTime > block.timestamp + MAX_START_DELAY ||
            params.endTime <= params.startTime ||
            params.endTime - params.startTime > MAX_SALE_DURATION
        ) revert InvalidSchedule();
        // Liquidity and fee together cannot take more than what is raised.
        if (params.liquidityBps < MIN_LIQUIDITY_BPS || params.liquidityBps + fee > BPS) {
            revert InvalidLiquidityShare();
        }
        if (
            params.vestingTranches < MIN_VESTING_TRANCHES ||
            params.vestingTranches > MAX_VESTING_TRANCHES
        ) revert InvalidVesting();
    }

    function _deploySale(
        IERC20 token,
        LaunchParams calldata params,
        uint256 tokensForSale,
        uint256 creatorAllocation,
        uint16 fee
    ) private returns (address) {
        return
            address(
                new TokenSale(
                    TokenSale.Config({
                        token: token,
                        creator: msg.sender,
                        dexFactory: dexFactory,
                        weth: weth,
                        tokensForSale: tokensForSale,
                        creatorAllocation: creatorAllocation,
                        softCap: params.softCap,
                        hardCap: params.hardCap,
                        minContribution: params.minContribution,
                        maxContribution: params.maxContribution,
                        startTime: params.startTime,
                        endTime: params.endTime,
                        liquidityBps: params.liquidityBps,
                        feeBps: fee,
                        vestingTranches: params.vestingTranches
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
