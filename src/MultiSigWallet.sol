// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MultiSigWallet
/// @notice 简单的 2/3 多签钱包：固定 3 个 owner，任意交易需要 2 个 owner 确认。
/// @dev 流程：
///      1. owner 调用 proposal() 提交交易，提案人自动视为已确认；
///      2. 其它 owner 调用 confirm() 确认；
///      3. 确认数达到 2 后，任何人都可以调用 execute() 执行交易。
contract MultiSigWallet {
    /// @notice 待执行的提案交易。 提案结构体
    struct Transaction {
        address to;
        uint256 value;
        bytes data;
        bool executed;
        uint256 confirmations;
    }

    /// @notice owner 数量，固定为 3。
    uint256 public constant OWNER_COUNT = 3;

    /// @notice 多签门槛，三分之二即 2 个确认。
    uint256 public constant THRESHOLD = 2;

    /// @notice 三个多签持有人。
    address[3] public owners;

    /// @notice 地址是否为多签持有人。
    mapping(address => bool) public isOwner;

    /// @notice txId => 提案交易。
    mapping(uint256 => Transaction) public transactions;

    /// @notice txId => owner => 是否已确认。
    mapping(uint256 => mapping(address => bool)) public isConfirmed;

    /// @notice 已提交的提案数量，同时作为下一个提案的 txId。
    uint256 public transactionCount;

    event ProposalCreated(
        uint256 indexed txId,
        address indexed proposer,
        address indexed to,
        uint256 value,
        bytes data
    );
    event Confirmed(uint256 indexed txId, address indexed owner, uint256 confirmations);
    event Executed(uint256 indexed txId, address indexed executor);
    event Deposit(address indexed sender, uint256 amount);

    error NotOwner();
    error ZeroAddress();
    error DuplicateOwner();
    error NotExistTransaction();
    error AlreadyExecuted();
    error AlreadyConfirmed();
    error NotEnoughConfirmations();
    error CallFailed();

    modifier onlyOwner() {
        if (!isOwner[msg.sender]) revert NotOwner();
        _;
    }

    /// @param initialOwners 三个多签持有人地址，不能为零地址且互不相同。
    constructor(address[3] memory initialOwners) {
        for (uint256 i = 0; i < OWNER_COUNT; ++i) {
            address owner = initialOwners[i];
            if (owner == address(0)) revert ZeroAddress();
            if (isOwner[owner]) revert DuplicateOwner();

            owners[i] = owner;
            isOwner[owner] = true;
        }
    }

    /// @notice 接收 ETH，钱包中的资金只能通过提案 + 确认 + 执行转出。
    receive() external payable {
        emit Deposit(msg.sender, msg.value);
    }

    /// @notice 多签持有人提交一笔提案交易。
    /// @dev 提案人自动视为确认（确认数从 1 开始），还需要另一个 owner 调用 confirm()。
    /// @param to 目标地址。
    /// @param value 随调用发送的 ETH 数量。
    /// @param data 调用数据，普通 ETH 转账可传空 bytes。
    /// @return txId 提案编号。
    function proposal(
        address to,
        uint256 value,
        bytes calldata data
    ) external onlyOwner returns (uint256 txId) {
        if (to == address(0)) revert ZeroAddress();

        txId = transactionCount;
        transactions[txId] = Transaction({
            to: to,
            value: value,
            data: data,
            executed: false,
            confirmations: 1
        });
        isConfirmed[txId][msg.sender] = true;
        transactionCount = txId + 1;

        emit ProposalCreated(txId, msg.sender, to, value, data);
        emit Confirmed(txId, msg.sender, 1);
    }

    /// @notice 其它多签持有人确认已提交的提案。
    /// @param txId 提案编号。
    function confirm(uint256 txId) external onlyOwner {
        if (txId >= transactionCount) revert NotExistTransaction();

        Transaction storage txn = transactions[txId];
        if (txn.executed) revert AlreadyExecuted();
        if (isConfirmed[txId][msg.sender]) revert AlreadyConfirmed();

        isConfirmed[txId][msg.sender] = true;
        txn.confirmations += 1;

        emit Confirmed(txId, msg.sender, txn.confirmations);
    }

    /// @notice 执行已确认达到门槛的提案，任何人都可以调用。
    /// @param txId 提案编号。
    function execute(uint256 txId) external {
        if (txId >= transactionCount) revert NotExistTransaction();

        Transaction storage txn = transactions[txId];
        if (txn.executed) revert AlreadyExecuted();
        if (txn.confirmations < THRESHOLD) revert NotEnoughConfirmations();

        // 先更新状态再外部调用，防止重入重复执行。
        txn.executed = true;

        (bool success, ) = txn.to.call{value: txn.value}(txn.data);
        if (!success) revert CallFailed();

        emit Executed(txId, msg.sender);
    }

    /// @notice 一次性返回三个多签持有人地址。
    function getOwners() external view returns (address[3] memory) {
        return owners;
    }
}
