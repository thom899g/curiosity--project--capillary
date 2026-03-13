// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IVault.sol";
import "./interfaces/ILens.sol";
import "./interfaces/ISentinel.sol";

/**
 * @title Capillary Strategy V1
 * @dev Simple narrow-range market maker with upgradeability via UUPS
 * @notice Initial strategy for $10-11 treasury range
 */
contract StrategyV1 is UUPSUpgradeable, OwnableUpgradeable {
    struct Position {
        uint256 tokenId;
        int24 lowerTick;
        int24 upperTick;
        uint128 liquidity;
        uint256 timestamp;
    }
    
    IVault public vault;
    ILens public lens;
    ISentinel public sentinel;
    
    address public constant UNISWAP_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address public pool;
    
    Position public currentPosition;
    uint256 public lastRebalance;
    uint256 public constant REBALANCE_COOLDOWN = 1 hours;
    uint256 public constant MAX_GAS_PERCENT = 30; // 30% of expected gain
    
    uint256 public feeEarned;
    uint256 public totalGasUsed;
    
    event PositionOpened(uint256 tokenId, int24 lowerTick, int24 upperTick, uint128 liquidity);
    event PositionClosed(uint256 tokenId, uint256 feesCollected);
    event RebalanceExecuted(uint256 timestamp, uint256 gasUsed