// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/AggregatorV3Interface.sol";

/**
 * @title KipuBankV2
 * @dev A secure multi-token vault contract with role-based access control and Chainlink price feeds
 * @notice This is an enhanced version of the KipuBank contract supporting multiple tokens and USD value tracking
 */
contract KipuBankV2 is AccessControl {
    using SafeERC20 for IERC20;

    // Role definitions
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // Constants
    uint256 public constant USD_DECIMALS = 6; // USDC decimals
    uint256 public constant PRICE_FEED_DECIMALS = 8; // Chainlink price feed decimals
    
    // State variables
    uint256 public bankCap;
    uint256 public withdrawalLimit;
    uint256 public totalDepositsUSD;
    uint256 public totalWithdrawalsUSD;
    uint256 public withdrawalCount;
    
    // Token information structure
    struct TokenInfo {
        bool isSupported;
        AggregatorV3Interface priceFeed;
        uint8 decimals;
    }
    
    // Mappings
    mapping(address => mapping(address => uint256)) private _balances;
    mapping(address => TokenInfo) public supportedTokens;
    mapping(address => uint256) public userTotalDepositsUSD;
    
    // Track all supported token addresses for iteration
    address[] public supportedTokenList;
    
    // Events
    event Deposited(
        address indexed user, 
        address indexed token, 
        uint256 amount,
        uint256 usdValue
    );
    event Withdrawn(
        address indexed user, 
        address indexed token, 
        uint256 amount,
        uint256 usdValue
    );
    event TokenSupported(
        address indexed token, 
        address priceFeed,
        uint8 decimals
    );
    event TokenRemoved(address indexed token);
    event AdminUpdated(address indexed admin, bool isAdded);
    event OperatorUpdated(address indexed operator, bool isAdded);
    
    // Custom errors
    error InsufficientBalance(uint256 available, uint256 required);
    error ExceedsBankCap(uint256 amount, uint256 bankCap);
    error ExceedsWithdrawalLimit(uint256 amount, uint256 withdrawalLimit);
    error WithdrawalFailed();
    error UnauthorizedAccess(address caller, bytes32 requiredRole);
    error TransferFailed();
    error InvalidTokenAddress();
    error InvalidPriceFeed();
    error InvalidDecimals();
    error TokenNotSupported(address token);
    error InvalidAmount();
    error ZeroAddressNotAllowed();

    /**
     * @dev Modifier to check if the caller has admin role
     */
    modifier onlyAdmin() {
        if (!hasRole(ADMIN_ROLE, msg.sender)) {
            revert UnauthorizedAccess(msg.sender, ADMIN_ROLE);
        }
        _;
    }

    /**
     * @dev Modifier to check if the caller has admin or operator role
     */
    modifier onlyOperatorOrAdmin() {
        if (!hasRole(ADMIN_ROLE, msg.sender) && !hasRole(OPERATOR_ROLE, msg.sender)) {
            revert UnauthorizedAccess(msg.sender, OPERATOR_ROLE);
        }
        _;
    }

    /**
     * @dev Constructor that sets up the initial admin and initializes the contract
     * @param _admin Address of the initial admin
     * @param _withdrawalLimit Maximum amount that can be withdrawn in a single transaction
     * @param _bankCap Maximum total deposits allowed in the bank
     * @param _nativeTokenPriceFeed Address of the Chainlink price feed for the native token
     */
    constructor(
        address _admin,
        uint256 _withdrawalLimit,
        uint256 _bankCap,
        address _nativeTokenPriceFeed
    ) {
        if (_admin == address(0)) revert ZeroAddressNotAllowed();
        if (_nativeTokenPriceFeed == address(0)) revert InvalidPriceFeed();
        
        // Set up roles
        _setRoleAdmin(ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(OPERATOR_ROLE, ADMIN_ROLE);
        
        // Grant roles to the deployer
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        
        // Initialize state variables
        withdrawalLimit = _withdrawalLimit;
        bankCap = _bankCap;
        
        // Set up native token (address(0) for ETH/BNB/MATIC)
        supportedTokens[address(0)] = TokenInfo({
            isSupported: true,
            priceFeed: AggregatorV3Interface(_nativeTokenPriceFeed),
            decimals: 18 // Standard for native tokens
        });
        
        supportedTokenList.push(address(0));
        emit TokenSupported(address(0), _nativeTokenPriceFeed, 18);
    }
    
    /**
     * @notice Add a supported token with its price feed
     * @param _token Address of the token (address(0) for native token)
     * @param _priceFeed Address of the Chainlink price feed for the token
     * @param _decimals Number of decimals the token uses
     */
    function addSupportedToken(
        address _token,
        address _priceFeed,
        uint8 _decimals
    ) external onlyAdmin {
        _addSupportedToken(_token, AggregatorV3Interface(_priceFeed), _decimals);
    }
    
    /**
     * @dev Internal function to add a supported token
     */
    function _addSupportedToken(
        address _token,
        AggregatorV3Interface _priceFeed,
        uint8 _decimals
    ) internal {
        if (_token == address(0) && _priceFeed == AggregatorV3Interface(address(0))) {
            revert InvalidPriceFeed();
        }
        
        if (_decimals > 18) revert InvalidDecimals();
        
        supportedTokens[_token] = TokenInfo({
            isSupported: true,
            priceFeed: _priceFeed,
            decimals: _decimals
        });
        
        // Add to supported token list if not already present
        bool exists = false;
        for (uint i = 0; i < supportedTokenList.length; i++) {
            if (supportedTokenList[i] == _token) {
                exists = true;
                break;
            }
        }
        
        if (!exists) {
            supportedTokenList.push(_token);
        }
        
        emit TokenSupported(_token, address(_priceFeed), _decimals);
    }
    
    /**
     * @notice Remove a supported token
     * @param _token Address of the token to remove
     */
    function removeSupportedToken(address _token) external onlyAdmin {
        if (_token == address(0)) revert InvalidTokenAddress();
        
        delete supportedTokens[_token];
        
        // Remove from supported token list
        for (uint i = 0; i < supportedTokenList.length; i++) {
            if (supportedTokenList[i] == _token) {
                supportedTokenList[i] = supportedTokenList[supportedTokenList.length - 1];
                supportedTokenList.pop();
                break;
            }
        }
        
        emit TokenRemoved(_token);
    }
    
    /**
     * @notice Deposit tokens into the vault
     * @param _token Address of the token to deposit (address(0) for native token)
     * @param _amount Amount of tokens to deposit
     */
    function deposit(address _token, uint256 _amount) external payable {
        if (_amount == 0) revert InvalidAmount();
        if (!supportedTokens[_token].isSupported) revert TokenNotSupported(_token);
        
        uint256 usdValue = _getUSDValue(_token, _amount);
        
        // Check bank cap
        if (totalDepositsUSD + usdValue > bankCap) {
            revert ExceedsBankCap(usdValue, bankCap - totalDepositsUSD);
        }
        
        // Handle native token (ETH/BNB/MATIC) or ERC20
        if (_token == address(0)) {
            if (msg.value != _amount) revert InvalidAmount();
        } else {
            IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        }
        
        // Update balances
        _balances[_token][msg.sender] += _amount;
        totalDepositsUSD += usdValue;
        userTotalDepositsUSD[msg.sender] += usdValue;
        
        emit Deposited(msg.sender, _token, _amount, usdValue);
    }
    
    /**
     * @notice Withdraw tokens from the vault
     * @param _token Address of the token to withdraw (address(0) for native token)
     * @param _amount Amount of tokens to withdraw
     */
    function withdraw(address _token, uint256 _amount) external {
        if (_amount == 0) revert InvalidAmount();
        if (!supportedTokens[_token].isSupported) revert TokenNotSupported(_token);
        
        uint256 usdValue = _getUSDValue(_token, _amount);
        
        // Check withdrawal limit
        if (usdValue > withdrawalLimit) {
            revert ExceedsWithdrawalLimit(usdValue, withdrawalLimit);
        }
        
        // Check user balance
        if (_balances[_token][msg.sender] < _amount) {
            revert InsufficientBalance(_balances[_token][msg.sender], _amount);
        }
        
        // Update balances before transfer (checks-effects-interactions pattern)
        _balances[_token][msg.sender] -= _amount;
        totalWithdrawalsUSD += usdValue;
        userTotalDepositsUSD[msg.sender] -= usdValue;
        
        // Transfer tokens
        if (_token == address(0)) {
            (bool success, ) = payable(msg.sender).call{value: _amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(_token).safeTransfer(msg.sender, _amount);
        }
        
        emit Withdrawn(msg.sender, _token, _amount, usdValue);
    }
    
    /**
     * @dev Internal function to get USD value of an amount of tokens
     * @param _token Address of the token
     * @param _amount Amount of tokens
     * @return usdValue Value in USD (6 decimals)
     */
    function _getUSDValue(address _token, uint256 _amount) internal view returns (uint256) {
        TokenInfo storage tokenInfo = supportedTokens[_token];
        
        // Get price from Chainlink price feed
        (, int256 price, , , ) = tokenInfo.priceFeed.latestRoundData();
        require(price > 0, "Invalid price");
        
        // Convert to 18 decimals for calculation
        uint256 amountInWei = _amount * (10 ** (18 - tokenInfo.decimals));
        
        // Calculate USD value with 6 decimals (USDC standard)
        uint256 usdValue = (amountInWei * uint256(price)) / 
            (10 ** (PRICE_FEED_DECIMALS + 18 - USD_DECIMALS));
            
        return usdValue;
    }
    
    /**
     * @notice Get the balance of a specific token for a user
     * @param _token Address of the token
     * @param _user Address of the user
     * @return Balance of the token for the user
     */
    function getBalance(address _token, address _user) external view returns (uint256) {
        return _balances[_token][_user];
    }
    
    /**
     * @notice Get the USD value of a user's balance for a specific token
     * @param _token Address of the token
     * @param _user Address of the user
     * @return usdValue Value in USD (6 decimals)
     */
    function getBalanceInUSD(address _token, address _user) external view returns (uint256) {
        return _getUSDValue(_token, _balances[_token][_user]);
    }
    
    /**
     * @notice Get the total USD value of all user's balances
     * @param _user Address of the user
     * @return totalValue Total value in USD (6 decimals)
     */
    function getTotalBalanceInUSD(address _user) external view returns (uint256 totalValue) {
        for (uint i = 0; i < supportedTokenList.length; i++) {
            address token = supportedTokenList[i];
            if (supportedTokens[token].isSupported) {
                totalValue += _getUSDValue(token, _balances[token][_user]);
            }
        }
    }
    
    /**
     * @notice Update the bank's withdrawal limit (admin only)
     * @param _newLimit New withdrawal limit in USD (6 decimals)
     */
    function updateWithdrawalLimit(uint256 _newLimit) external onlyAdmin {
        withdrawalLimit = _newLimit;
    }
    
    /**
     * @notice Update the bank's total deposit cap (admin only)
     * @param _newCap New deposit cap in USD (6 decimals)
     */
    function updateBankCap(uint256 _newCap) external onlyAdmin {
        bankCap = _newCap;
    }
    
    /**
     * @notice Add a new admin (admin only)
     * @param _admin Address to grant admin role
     */
    function addAdmin(address _admin) external onlyAdmin {
        grantRole(ADMIN_ROLE, _admin);
        emit AdminUpdated(_admin, true);
    }
    
    /**
     * @notice Remove an admin (admin only)
     * @param _admin Address to revoke admin role from
     */
    function removeAdmin(address _admin) external onlyAdmin {
        revokeRole(ADMIN_ROLE, _admin);
        emit AdminUpdated(_admin, false);
    }
    
    /**
     * @notice Add a new operator (admin only)
     * @param _operator Address to grant operator role
     */
    function addOperator(address _operator) external onlyAdmin {
        grantRole(OPERATOR_ROLE, _operator);
        emit OperatorUpdated(_operator, true);
    }
    
    /**
     * @notice Remove an operator (admin only)
     * @param _operator Address to revoke operator role from
     */
    function removeOperator(address _operator) external onlyAdmin {
        revokeRole(OPERATOR_ROLE, _operator);
        emit OperatorUpdated(_operator, false);
    }
    
    /**
     * @notice Emergency withdraw tokens (admin only)
     * @param _token Address of the token to withdraw (address(0) for native token)
     */
    function emergencyWithdraw(address _token) external onlyAdmin {
        uint256 amount;
        if (_token == address(0)) {
            amount = address(this).balance;
            (bool success, ) = msg.sender.call{value: amount}("");
            require(success, "Transfer failed");
        } else {
            amount = IERC20(_token).balanceOf(address(this));
            IERC20(_token).safeTransfer(msg.sender, amount);
        }
    }
    
    // Allow the contract to receive native tokens
    receive() external payable {}
    
    /**
     * @notice Get the current price of a token in USD
     * @param _token Address of the token (address(0) for native token)
     * @return price Price in USD (8 decimals)
     */
    function getTokenPrice(address _token) external view returns (int256) {
        if (!supportedTokens[_token].isSupported) revert TokenNotSupported(_token);
        (, int256 price, , , ) = supportedTokens[_token].priceFeed.latestRoundData();
        return price;
    }
    
    /**
     * @notice Get the list of all supported tokens
     * @return Array of token addresses
     */
    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokenList;
    }
    
    /**
     * @notice Check if an address has admin role
     * @param _address Address to check
     * @return True if the address has admin role
     */
    function isAdmin(address _address) external view returns (bool) {
        return hasRole(ADMIN_ROLE, _address);
    }
    
    /**
     * @notice Check if an address has operator role
     * @param _address Address to check
     * @return True if the address has operator role
     */
    function isOperator(address _address) external view returns (bool) {
        return hasRole(OPERATOR_ROLE, _address);
    }
    
    /**
     * @notice Get the total number of supported tokens
     * @return Count of supported tokens
     */
    function getSupportedTokenCount() external view returns (uint256) {
        return supportedTokenList.length;
    }
    
    /**
     * @notice Get token info for a specific token
     * @param _token Address of the token
     * @return isSupported Whether the token is supported
     * @return priceFeed Address of the price feed
     * @return decimals Number of decimals for the token
     */
    function getTokenInfo(address _token) 
        external 
        view 
        returns (bool isSupported, address priceFeed, uint8 decimals) 
    {
        TokenInfo memory token = supportedTokens[_token];
        return (token.isSupported, address(token.priceFeed), token.decimals);
    }
    
    /**
     * @notice Calculate the USD value of an amount of tokens
     * @param _token Address of the token
     * @param _amount Amount of tokens
     * @return usdValue Value in USD (6 decimals)
     */
    function calculateUSDValue(address _token, uint256 _amount) external view returns (uint256) {
        return _getUSDValue(_token, _amount);
    }
    
    /**
     * @notice Get the total TVL (Total Value Locked) in the contract in USD
     * @return tvl Total value locked in USD (6 decimals)
     */
    function getTotalValueLocked() external view returns (uint256 tvl) {
        for (uint i = 0; i < supportedTokenList.length; i++) {
            address token = supportedTokenList[i];
            if (token == address(0)) {
                tvl += _getUSDValue(token, address(this).balance);
            } else {
                tvl += _getUSDValue(token, IERC20(token).balanceOf(address(this)));
            }
        }
    }
    
    // Required override for AccessControl
    function supportsInterface(bytes4 interfaceId) 
        public 
        view 
        override(AccessControl) 
        returns (bool) 
    {
        return super.supportsInterface(interfaceId);
    }
}
