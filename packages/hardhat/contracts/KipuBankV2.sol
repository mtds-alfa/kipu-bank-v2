// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title KipuBankV2
 * @dev A secure vault contract for depositing and withdrawing ETH with withdrawal limits
 * @notice This is an upgraded version of the KipuBank contract
 */
contract KipuBankV2 {
    // Custom errors
    error ExceedsBankCap(uint256 amount, uint256 bankCap);
    error ExceedsWithdrawalLimit(uint256 amount, uint256 withdrawalLimit);
    error InsufficientBalance(uint256 available, uint256 requested);
    error NotOwner(address caller);
    error WithdrawalFailed();

    // Events
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);

    // State variables
    address public immutable owner;
    uint256 public immutable bankCap;
    uint256 public immutable withdrawalLimit;
    uint256 public totalDeposits;
    uint256 public totalWithdrawals;
    uint256 public depositCount;
    uint256 public withdrawalCount;
    
    mapping(address => uint256) private _balances;

    /**
     * @dev Modifier to check if the caller is the owner
     */
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    /**
     * @dev Constructor sets the owner, bank cap, and withdrawal limit
     * @param _withdrawalLimit Maximum amount that can be withdrawn in a single transaction
     * @param _bankCap Maximum total deposits allowed in the bank
     */
    constructor(uint256 _withdrawalLimit, uint256 _bankCap) {
        owner = msg.sender;
        withdrawalLimit = _withdrawalLimit;
        bankCap = _bankCap;
    }

    /**
     * @notice Deposit ETH into the vault
     * @dev Emits a Deposited event on success
     */
    function deposit() external payable {
        if (msg.value == 0) revert("Cannot deposit 0 ETH");
        if (totalDeposits + msg.value > bankCap) {
            revert ExceedsBankCap(msg.value, bankCap - totalDeposits);
        }

        _balances[msg.sender] += msg.value;
        totalDeposits += msg.value;
        depositCount++;
        
        emit Deposited(msg.sender, msg.value);
    }

    /**
     * @notice Withdraw ETH from the vault
     * @param amount Amount to withdraw
     * @dev Emits a Withdrawn event on success
     */
    function withdraw(uint256 amount) external {
        if (amount > _balances[msg.sender]) {
            revert InsufficientBalance(_balances[msg.sender], amount);
        }
        if (amount > withdrawalLimit) {
            revert ExceedsWithdrawalLimit(amount, withdrawalLimit);
        }

        _withdraw(msg.sender, amount);
    }

    /**
     * @dev Internal function to handle the actual withdrawal
     * @param to Address to send ETH to
     * @param amount Amount to withdraw
     */
    function _withdraw(address to, uint256 amount) private {
        _balances[to] -= amount;
        totalWithdrawals += amount;
        withdrawalCount++;
        
        (bool success, ) = payable(to).call{value: amount}("");
        if (!success) revert WithdrawalFailed();
        
        emit Withdrawn(to, amount);
    }

    /**
     * @notice Get the balance of a specific user
     * @param user Address to check balance for
     * @return The user's balance
     */
    function balanceOf(address user) external view returns (uint256) {
        return _balances[user];
    }

    /**
     * @notice Get the total ETH balance of the contract
     * @return The contract's ETH balance
     */
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    // Allow the contract to receive ETH
    receive() external payable {
        // Directly handle the deposit logic here instead of calling deposit()
        if (msg.value == 0) return;
        if (totalDeposits + msg.value > bankCap) {
            revert ExceedsBankCap(msg.value, bankCap - totalDeposits);
        }

        _balances[msg.sender] += msg.value;
        totalDeposits += msg.value;
        depositCount++;
        
        emit Deposited(msg.sender, msg.value);
    }
}
