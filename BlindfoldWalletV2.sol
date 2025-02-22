// SPDX-License-Identifier: MIT

// Blindfold Wallet Arbitrum
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Interface for the Position Router
interface IPositionRouter {
    function createIncreasePosition(
        address[] memory path,
        address indexToken,
        uint256 amountIn,
        uint256 minOut,
        uint256 sizeDelta,
        bool isLong,
        uint256 acceptablePrice,
        uint256 executionFee,
        bytes32 referralCode,
        address callbackTarget
    ) external payable;

    function createDecreasePosition(
        address[] memory path,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        address receiver,
        uint256 acceptablePrice,
        uint256 minOut,
        uint256 executionFee,
        bool withdrawETH,
        address callbackTarget
    ) external payable;
}

interface IRouter {
    function approvePlugin(address _plugin) external;

    function swap(
        address[] memory _path,
        uint256 _amountIn,
        uint256 _minOut,
        address _receiver
    ) external;

    function swapTokensToETH(
        address[] memory _path,
        uint256 _amountIn,
        uint256 _minOut,
        address payable _receiver
    ) external;
}

// Interface for the WETH token contract
interface IWETH {
    function deposit() external payable;

    function withdraw(uint256) external;

    function transfer(address recipient, uint256 amount)
        external
        returns (bool);

    function balanceOf(address account) external view returns (uint256);
}

contract BlindfoldWallet {
    using SafeERC20 for IERC20;
    string public ContractName;
    address public owner1;
    address public owner2;
    address public owner3;
    address public paymaster;
    uint256 public transferCap = 0.01 ether;
    uint256 public dailyLimit = 0.3 ether;
    uint256 public dailyTransferTotal;
    uint256 public lastTransferTimestamp;
    bool public owner1Approval;
    bool public owner2Approval;
    bool public owner3Approval;
    uint256 public approvalTimestamp;
    // % of withdrawal amount shared with paymaster
    uint256 public paymasterSharePercentage = 1;
    // Enable trading
    bool public tradesEnabled;
    // Enable/disable tokens
    mapping(string => bool) public tokenSettings;
    // owner balances
    mapping(address => uint256) public ownerBalance;
    mapping(address => mapping(address => bool)) public approvedPlugins;
    mapping(address => WithdrawalRequest) public pendingTokenWithdrawals;
    ExecutedWithdrawal[] public executedWithdrawals;
    TokenDeposit[] public tokenDeposits;
    TokenSwap[] public tokenSwaps;
    // tokens
    address public constant USDC_ADDRESS =
        0xaf88d065e77c8cC2239327C5EDb3A432268e5831; //arb
    address public constant USDCE_ADDRESS =
        0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8; //arb
    address public constant ETH_ADDRESS = address(0); // native ETH
    address public constant WETH_ADDRESS =
        0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // arb weth
    address public constant WBTC_ADDRESS =
        0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f; // arb wbtc
    address public constant LINK_ADDRESS =
        0xf97f4df75117a78c1A5a0DBb814Af92458539FB4; //arb link
    address public constant UNI_ADDRESS =
        0xFa7F8980b0f1E64A2062791cc3b0871572f1F7f0; //arb uni
    address public constant ROUTER_ADDRESS =
        0xaBBc5F99639c9B6bCb58544ddf04EFA6802F4064; // arb gmx router
    address public constant POSITION_ROUTER_ADDRESS =
        0xb87a436B93fFE9D75c5cFA7bAcFff96430b09868; // arb gmx position router

    struct WithdrawalRequest {
        uint256 amount;
        uint256 timestamp;
        bool executed;
        address requester;
    }

    struct TokenDeposit {
        address depositor;
        address token;
        uint256 amount;
        uint256 timestamp;
    }

    struct ExecutedWithdrawal {
        address token;
        uint256 amount;
        address executor;
        uint256 timestamp;
    }

    struct TokenSwap {
        address requester;
        address inputToken;
        address outputToken;
        uint256 amountIn;
        uint256 minOut;
        uint256 timestamp;
    }

    struct EthTransferPaymaster {
        address paymaster;
        uint256 amount;
        uint256 timestamp;
    }

    EthTransferPaymaster[] public ethTransfersPaymaster;

    event ApprovalGranted(address indexed owner, bool approved);
    event TokenWithdrawn(
        address indexed token,
        uint256 amount,
        address executor
    );

    constructor(
        address _owner1,
        address _owner2,
        address _owner3,
        address _paymaster,
        string memory _contractName
    ) {
        require(
            _owner1 != address(0) &&
                _owner2 != address(0) &&
                _owner3 != address(0) &&
                _paymaster != address(0),
            "Owners cannot be zero address"
        );
        ContractName = _contractName;
        owner1 = _owner1;
        owner2 = _owner2;
        owner3 = _owner3;
        paymaster = _paymaster;
        tradesEnabled = false;
        tokenSettings["linkShort"] = false;
        tokenSettings["linkLong"] = false;
        tokenSettings["wethShort"] = true;
        tokenSettings["wethLong"] = true;
        tokenSettings["uniShort"] = false;
        tokenSettings["uniLong"] = false;
        tokenSettings["wbtcLong"] = false;
        tokenSettings["wbtcShort"] = false;
    }

    // owners modifier
    modifier onlyOwners() {
        require(
            msg.sender == owner1 ||
                msg.sender == owner2 ||
                msg.sender == owner3,
            "Only an owner can call this function."
        );
        _;
    }
    // Modifier to restrict access to the paymaster
    modifier onlyPaymaster() {
        require(msg.sender == paymaster, "Not the paymaster");
        _;
    }
    // Modifier to restrict access to either owners or the paymaster
    modifier onlyOwnersOrPaymaster() {
        require(
            msg.sender == owner1 ||
                msg.sender == owner2 ||
                msg.sender == owner3 ||
                msg.sender == paymaster,
            "Not authorized"
        );
        _;
    }

    // Approve withdrawals from contract
    function approveTransfer(bool approval) public onlyOwners {
        if (msg.sender == owner1) {
            owner1Approval = approval;
        } else if (msg.sender == owner2) {
            owner2Approval = approval;
        } else if (msg.sender == owner3) {
            // Add owner3 approval
            owner3Approval = approval;
        }
        // Check if all three owners have approved
        bool allApproved = owner1Approval && owner2Approval && owner3Approval;

        if (allApproved) {
            approvalTimestamp = block.timestamp;
        }

        emit ApprovalGranted(msg.sender, approval);
    }

    // Function to approve the PositionRouter as a plugin
    function approvePositionRouter() public onlyOwners {
        approvedPlugins[address(this)][POSITION_ROUTER_ADDRESS] = true;
        IRouter(ROUTER_ADDRESS).approvePlugin(POSITION_ROUTER_ADDRESS);
    }

    // Function to check if a plugin is approved
    function isPluginApproved(address user, address plugin)
        public
        view
        returns (bool)
    {
        return approvedPlugins[user][plugin];
    }

    // Function to approve spending of any token defined on the contract
    function approveTokenSpending(address tokenAddress, uint256 amount)
        public
        onlyOwners
    {
        require(amount > 0, "Amount must be greater than zero.");
        require(
            tokenAddress == USDC_ADDRESS ||
                tokenAddress == USDCE_ADDRESS ||
                tokenAddress == UNI_ADDRESS ||
                tokenAddress == LINK_ADDRESS ||
                tokenAddress == WETH_ADDRESS ||
                tokenAddress == WBTC_ADDRESS,
            "Token not supported."
        );
        require(
            IERC20(tokenAddress).approve(ROUTER_ADDRESS, amount),
            "Approval failed."
        );
    }

    // Receive ether
    receive() external payable {
        uint256 ownerShare = msg.value / 3;
        ownerBalance[owner1] += ownerShare;
        ownerBalance[owner2] += ownerShare;
        ownerBalance[owner3] += ownerShare;
        TokenDeposit memory newDeposit = TokenDeposit({
            depositor: msg.sender,
            token: address(0),
            amount: msg.value,
            timestamp: block.timestamp
        });
        tokenDeposits.push(newDeposit);
    }

    // Reset approvals
    function resetApprovals() internal {
        owner1Approval = false;
        owner2Approval = false;
        owner3Approval = false;
        approvalTimestamp = 0;
    }

    // Function to get all token deposits (can also add pagination if the array gets large)
    function getTokenDeposits() public view returns (TokenDeposit[] memory) {
        return tokenDeposits;
    }

    // request withdrawal for specific token and amount
    function requestTokenWithdrawal(address token, uint256 amount)
        public
        onlyOwners
    {
        require(
            token == USDC_ADDRESS ||
                token == USDCE_ADDRESS ||
                token == LINK_ADDRESS ||
                token == UNI_ADDRESS ||
                token == WETH_ADDRESS ||
                token == WBTC_ADDRESS,
            "Token not accepted."
        );
        require(
            IERC20(token).balanceOf(address(this)) >= amount,
            "Insufficient token balance."
        );
        require(
            pendingTokenWithdrawals[token].amount == 0,
            "A token withdrawal is already pending."
        );

        pendingTokenWithdrawals[token] = WithdrawalRequest({
            amount: amount,
            timestamp: block.timestamp,
            executed: false,
            requester: msg.sender
        });
    }

    // Execute approved token withdrawal request
    function executeTokenWithdrawal(address token) public onlyOwners {
        require(
            owner1Approval && owner2Approval && owner3Approval,
            "All owners must approve."
        );
        require(
            block.timestamp <= approvalTimestamp + 1 hours,
            "Approval expired."
        );
        require(!pendingTokenWithdrawals[token].executed, "Already executed.");
        require(
            pendingTokenWithdrawals[token].amount > 0,
            "No pending withdrawal."
        );
        require(
            pendingTokenWithdrawals[token].requester != msg.sender,
            "Requester cannot execute."
        );
        // Total amount to be withdrawn
        uint256 totalAmount = pendingTokenWithdrawals[token].amount;
        // Calculate paymaster's share (0.5% = 0.5, 1% = 1)
        uint256 paymasterShare = (totalAmount * paymasterSharePercentage) / 100;
        uint256 remainingAmount = totalAmount - paymasterShare;
        // Divide remaining amount among owners
        uint256 ownerShare = remainingAmount / 3;
        // Mark withdrawal as executed
        pendingTokenWithdrawals[token].executed = true;
        // Record executed withdrawal
        executedWithdrawals.push(
            ExecutedWithdrawal({
                token: token,
                amount: totalAmount,
                executor: msg.sender,
                timestamp: block.timestamp
            })
        );

        // Reset pending withdrawal
        pendingTokenWithdrawals[token] = WithdrawalRequest(
            0,
            0,
            false,
            address(0)
        );
        resetApprovals();

        // Transfer tokens
        IERC20(token).safeTransfer(owner1, ownerShare);
        IERC20(token).safeTransfer(owner2, ownerShare);
        IERC20(token).safeTransfer(owner3, ownerShare);
        if (paymasterShare > 0) {
            IERC20(token).safeTransfer(paymaster, paymasterShare);
        }

        emit TokenWithdrawn(token, totalAmount, msg.sender);
    }

    // native balance
    function getBalance() public view returns (uint256) {
        return address(this).balance;
    }

    // erc20 balance
    function getTokenBalance(address token) public view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    // call createIncreasePosition on position router contract
    function createIncreasePosition(
        address[] memory path, // Path for token swaps
        address indexToken, // Token to be indexed
        uint256 amountIn, // Amount of tokens to increase position
        uint256 minOut, // Minimum acceptable output amount
        uint256 sizeDelta, // Change in position size
        bool isLong, // Indicator if the position is long
        uint256 acceptablePrice, // Acceptable price for the position
        uint256 executionFee, // Fee for executing the position increase
        bytes32 referralCode, // Referral code for tracking
        address callbackTarget // Callback target address
    ) public payable onlyPaymaster {
        require(
            isPluginApproved(address(this), POSITION_ROUTER_ADDRESS),
            "Plugin not approved"
        );
        require(tradesEnabled, "Trades are currently disabled");

        IPositionRouter(POSITION_ROUTER_ADDRESS).createIncreasePosition{
            value: msg.value
        }(
            path,
            indexToken,
            amountIn,
            minOut,
            sizeDelta,
            isLong,
            acceptablePrice,
            executionFee,
            referralCode,
            callbackTarget
        );
    }

    // call createDecreasePosition on position router contract
    function createDecreasePosition(
        address[] memory path,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 acceptablePrice,
        uint256 minOut,
        uint256 executionFee,
        bool withdrawETH,
        address callbackTarget
    ) public payable onlyPaymaster {
        require(
            isPluginApproved(address(this), POSITION_ROUTER_ADDRESS),
            "Plugin not approved"
        );
        require(tradesEnabled, "Trades are currently disabled");

        address receiver = address(this);

        IPositionRouter(POSITION_ROUTER_ADDRESS).createDecreasePosition{
            value: msg.value
        }(
            path,
            indexToken,
            collateralDelta,
            sizeDelta,
            isLong,
            receiver,
            acceptablePrice,
            minOut,
            executionFee,
            withdrawETH,
            callbackTarget
        );
    }

    // swap token balance to contract
    function swapTokens(
        address[] memory _path,
        uint256 _amountIn,
        uint256 _minOut
    ) public onlyOwnersOrPaymaster {
        // Use IERC20 to check the current allowance
        uint256 currentAllowance = IERC20(_path[0]).allowance(
            address(this),
            ROUTER_ADDRESS
        );
        // If the current allowance is less than the amount needed, reset it to zero, then approve the required amount
        if (currentAllowance < _amountIn) {
            // Reset the allowance to zero first
            require(
                IERC20(_path[0]).approve(ROUTER_ADDRESS, 0),
                "Resetting token approval to zero failed."
            );
            // Approve the required amount
            require(
                IERC20(_path[0]).approve(ROUTER_ADDRESS, _amountIn),
                "Token approval failed."
            );
        }
        IRouter(ROUTER_ADDRESS).swap(_path, _amountIn, _minOut, address(this));
        TokenSwap memory newSwap = TokenSwap({
            requester: msg.sender,
            inputToken: _path[0],
            outputToken: _path[_path.length - 1],
            amountIn: _amountIn,
            minOut: _minOut,
            timestamp: block.timestamp
        });

        tokenSwaps.push(newSwap);
    }

    // Swap WETH into native ETH and transfer to the contract
    function swapTokensToETH(
        address[] memory _path,
        uint256 _amountIn,
        uint256 _minOut
    ) external onlyOwnersOrPaymaster {
        require(_path.length > 0, "Invalid path");

        // Ensure the last token in the path is WETH
        require(
            _path[_path.length - 1] == WETH_ADDRESS,
            "Router: invalid _path"
        );

        address payable receiver = payable(address(this));

        if (_path[0] == WETH_ADDRESS) {
            // If we are directly dealing with WETH, just unwrap it to ETH
            require(
                IERC20(WETH_ADDRESS).balanceOf(address(this)) >= _amountIn,
                "Insufficient WETH balance"
            );

            // Transfer WETH to this contract if necessary (not needed if already held)
            if (
                IERC20(WETH_ADDRESS).allowance(address(this), ROUTER_ADDRESS) <
                _amountIn
            ) {
                IERC20(WETH_ADDRESS).approve(ROUTER_ADDRESS, _amountIn);
            }

            // Unwrap WETH to ETH
            IWETH(WETH_ADDRESS).withdraw(_amountIn);
        } else {
            // Otherwise, swap tokens to ETH using the router
            uint256 currentAllowance = IERC20(_path[0]).allowance(
                address(this),
                ROUTER_ADDRESS
            );
            if (currentAllowance < _amountIn) {
                IERC20(_path[0]).approve(ROUTER_ADDRESS, _amountIn);
            }

            // Call the swapToETH function on the Router contract
            IRouter(ROUTER_ADDRESS).swapTokensToETH(
                _path,
                _amountIn,
                _minOut,
                receiver
            );
        }
    }

    // Function to transfer native ETH tokens to the paymaster address with a cap and daily limit
    function transferEthToPaymaster(uint256 _amount)
        public
        onlyOwnersOrPaymaster
    {
        require(
            _amount <= transferCap,
            "Transfer exceeds the transaction cap."
        );
        require(address(this).balance >= _amount, "Insufficient ETH balance.");
        // Reset daily transfer total if 24 hours have passed
        if (block.timestamp >= lastTransferTimestamp + 24 hours) {
            dailyTransferTotal = 0;
            lastTransferTimestamp = block.timestamp;
        }
        // Check if the transfer exceeds the 24-hour daily limit
        require(
            dailyTransferTotal + _amount <= dailyLimit,
            "Transfer exceeds the 24-hour limit."
        );
        (bool success, ) = paymaster.call{value: _amount}("");
        require(success, "ETH transfer failed.");
        dailyTransferTotal += _amount;
        EthTransferPaymaster memory newTransfer = EthTransferPaymaster({
            paymaster: paymaster,
            amount: _amount,
            timestamp: block.timestamp
        });

        ethTransfersPaymaster.push(newTransfer);
    }

    // Function to update the transaction cap
    function setTransferCap(uint256 _newCap) external onlyOwners {
        require(_newCap > 0, "Transfer cap must be greater than zero.");
        transferCap = _newCap;
    }

    // Function to update the daily limit (only owners can change the limit)
    function setDailyLimit(uint256 _newLimit) external onlyOwners {
        require(_newLimit > 0, "Daily limit must be greater than zero.");
        dailyLimit = _newLimit;
    }

    // Enable/disable trading
    function setTradeStatus(bool _enabled) external onlyOwnersOrPaymaster {
        tradesEnabled = _enabled;
    }

    // enable/disable tokens
    function setTokenStatus(string memory token, bool status)
        external
        onlyOwners
    {
        tokenSettings[token] = status;
    }

    function getTokenStatus(string memory token) external view returns (bool) {
        return tokenSettings[token];
    }

    function setPaymasterSharePercentage(uint256 _percentage)
        external
        onlyOwners
    {
        require(_percentage <= 10, "Max paymaster share: 10%");
        paymasterSharePercentage = _percentage;
    }
}
