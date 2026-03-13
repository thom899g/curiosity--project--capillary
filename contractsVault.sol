// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Capillary Vault
 * @dev Treasury management with time-locked withdrawals and NAV tracking
 * @notice Holds exactly $10 initial capital split between ETH and stablecoin
 */
contract Vault is ReentrancyGuard, Ownable {
    struct WithdrawalRequest {
        uint256 amount;
        uint256 timestamp;
        bool executed;
    }
    
    IERC20 public immutable stableToken;
    uint256 public constant INITIAL_CAPITAL_USD = 10 * 10**6; // $10 in USD (6 decimals)
    uint256 public constant WITHDRAWAL_DELAY = 48 hours;
    uint256 public constant EVOLUTION_THRESHOLD = 11 * 10**6; // $11
    
    uint256 public ethBalance;
    uint256 public stableBalance;
    uint256 public feesAccrued;
    uint256 public lastNAVUpdate;
    
    address public strategy;
    mapping(address => WithdrawalRequest) public withdrawalRequests;
    
    event FundsDeposited(address indexed depositor, uint256 ethAmount, uint256 stableAmount);
    event WithdrawalRequested(address indexed requester, uint256 amount, uint256 unlockTime);
    event WithdrawalExecuted(address indexed requester, uint256 amount);
    event StrategyWithdrawal(address indexed strategy, uint256 ethAmount, uint256 stableAmount);
    event FeeAccrued(uint256 amount, uint256 timestamp);
    event EvolutionTriggered(uint256 treasuryValue);
    
    modifier onlyStrategy() {
        require(msg.sender == strategy, "Vault: caller is not strategy");
        _;
    }
    
    constructor(address _stableToken) {
        require(_stableToken != address(0), "Vault: zero address");
        stableToken = IERC20(_stableToken);
        lastNAVUpdate = block.timestamp;
    }
    
    /**
     * @dev Initialize vault with initial capital (5 ETH, 5 USD equivalent)
     */
    function initializeVault() external payable onlyOwner {
        require(ethBalance == 0 && stableBalance == 0, "Vault: already initialized");
        require(msg.value > 0, "Vault: ETH required");
        
        // Convert half of ETH to stablecoin (simplified for testnet)
        // In production, this would use a DEX swap
        ethBalance = msg.value / 2;
        stableBalance = msg.value / 2; // Assuming 1 ETH = $1 for simplicity
        
        emit FundsDeposited(msg.sender, msg.value, 0);
    }
    
    /**
     * @dev Calculate current Net Asset Value
     */
    function calculateNAV() public view returns (uint256 nav) {
        // Simplified NAV calculation
        // In production: use oracle for ETH price
        nav = ethBalance + stableBalance + feesAccrued;
    }
    
    /**
     * @dev Strategy can withdraw funds for rebalancing
     */
    function withdrawToStrategy(uint256 ethAmount, uint256 stableAmount) 
        external 
        onlyStrategy 
        nonReentrant 
    {
        require(address(this).balance >= ethAmount, "Vault: insufficient ETH");
        require(stableToken.balanceOf(address(this)) >= stableAmount, "Vault: insufficient stable");
        
        ethBalance -= ethAmount;
        stableBalance -= stableAmount;
        
        (bool success, ) = strategy.call{value: ethAmount}("");
        require(success, "Vault: ETH transfer failed");
        
        require(stableToken.transfer(strategy, stableAmount), "Vault: stable transfer failed");
        
        emit StrategyWithdrawal(strategy, ethAmount, stableAmount);
    }
    
    /**
     * @dev Strategy returns funds after rebalancing
     */
    function returnFromStrategy(uint256 ethAmount, uint256 stableAmount) 
        external 
        onlyStrategy 
        nonReentrant 
    {
        ethBalance += ethAmount;
        stableBalance += stableAmount;
        
        // Check for evolution trigger
        uint256 currentValue = calculateNAV();
        if (currentValue >= EVOLUTION_THRESHOLD) {
            emit EvolutionTriggered(currentValue);
        }
    }
    
    /**
     * @dev Accrue fees from strategy
     */
    function accrueFees(uint256 feeAmount) external onlyStrategy {
        feesAccrued += feeAmount;
        emit FeeAccrued(feeAmount, block.timestamp);
    }
    
    /**
     * @dev Request withdrawal (48-hour timelock)
     */
    function requestWithdrawal(uint256 amount) external {
        require(amount <= calculateNAV(), "Vault: amount exceeds NAV");
        
        withdrawalRequests[msg.sender] = WithdrawalRequest({
            amount: amount,
            timestamp: block.timestamp,
            executed: false
        });
        
        emit WithdrawalRequested(msg.sender, amount, block.timestamp + WITHDRAWAL_DELAY);
    }
    
    /**
     * @dev Execute withdrawal after timelock
     */
    function executeWithdrawal() external nonReentrant {
        WithdrawalRequest storage request = withdrawalRequests[msg.sender];
        require(request.amount > 0, "Vault: no request");
        require(!request.executed, "Vault: already executed");
        require(block.timestamp >= request.timestamp + WITHDRAWAL_DELAY, "Vault: timelock not passed");
        
        uint256 amount = request.amount;
        request.executed = true;
        
        // Pro-rata distribution between ETH and stable
        uint256 totalAssets = ethBalance + stableBalance;
        uint256 ethShare = (amount * ethBalance) / totalAssets;
        uint256 stableShare = (amount * stableBalance) / totalAssets;
        
        ethBalance -= ethShare;
        stableBalance -= stableShare;
        
        (bool success, ) = msg.sender.call{value: ethShare}("");
        require(success, "Vault: ETH transfer failed");
        require(stableToken.transfer(msg.sender, stableShare), "Vault: stable transfer failed");
        
        emit WithdrawalExecuted(msg.sender, amount);
    }
    
    /**
     * @dev Set strategy address (only once)
     */
    function setStrategy(address _strategy) external onlyOwner {
        require(strategy == address(0), "Vault: strategy already set");
        strategy = _strategy;
    }
    
    receive() external payable {
        ethBalance += msg.value;
    }
}