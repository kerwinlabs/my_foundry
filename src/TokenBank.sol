// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITokensReceiver} from "./CalledToken.sol";
import {ISignatureTransfer} from "./interfaces/ISignatureTransfer.sol";

/// @title TokenBank
/// @notice 记录每个用户存入的 Token 数量，用户可以提取自己之前存入的 Token。
///         使用流程：
///         1. 用户先调用 Token.approve(address(tokenBank), amount) 授权；
///         2. 再调用 TokenBank.deposit(amount) 存入；
///         3. 随时调用 TokenBank.withdraw(amount) 提取。
///         如果使用的是 CalledToken，还可以直接
///         CalledToken.transferAndCall(address(tokenBank), amount, "")，
///         由 onTokensReceived 回调完成记账。
///         如果 Token 支持 EIP-2612（如 MyPermitToken），owner 可以离线签名，
///         由任意地址调用 permitDeposit 一次完成“授权 + 存入”。
///         如果 Token 不支持 EIP-2612，也可以借助 Uniswap Permit2：
///         owner 先对 Permit2 合约 approve 一次，之后每笔存款只需离线签名，
///         由任意地址调用 depositWithPermit2 走 Permit2 的 SignatureTransfer 完成转账。
///
///         另外维护一个按存款金额从高到低排序的前 10 名榜单；
///         实现参考 SchoolOptimized：用哨兵 GUARD 作为头指针、
///         `mapping(address => address)` 保存 next 指针的单向循环链表。
///         每次存款/取款后都会调整该用户的名次，榜单满 10 人时新的大额存款会挤掉最后一名。
contract TokenBank {
    using SafeERC20 for IERC20;

    /// @notice Uniswap Permit2 的规范地址（CREATE2 部署，所有主流链与 Sepolia 相同）。
    ///         官方文档：https://docs.uniswap.org/contracts/permit2/overview
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice 存入/提取所使用的 ERC20 代币。
    /// @dev 使用 IERC20 + SafeERC20，兼容 USDT 这类 transfer/transferFrom 不返回 bool 的代币。
    IERC20 public immutable token;

    /// @notice 每个用户当前存入的 Token 数量。
    mapping(address => uint256) public deposits;

    /// @notice 所有用户存入的 Token 总量。
    uint256 public totalDeposits;

    /// @notice 排行榜最多保存的用户数。
    uint256 public constant TOP_N = 10;

    /// @dev 头指针哨兵，参考 SchoolOptimized：榜单头 = `_next[GUARD]`；
    ///      空表时 `_next[GUARD] == GUARD`，最后一个节点的 next 也指回 GUARD，
    ///      因此遍历时只需判断 `cursor == GUARD`，不用处理 address(0)。
    address private constant GUARD = address(1);

    /// @dev 按存款金额从高到低排列的单向循环链表：user => 下一个金额更少的用户。
    ///      节点金额不单独保存，统一读 `deposits[user]`，避免两份数据不一致。
    ///      `_next[user] == address(0)` 表示该用户不在榜单中。
    mapping(address => address) private _next;

    /// @notice 当前榜单人数，最多 TOP_N。
    uint256 public topCount;

    event Deposited(address indexed user, uint256 amount, uint256 userDeposit);
    event Withdrawn(address indexed user, uint256 amount, uint256 userDeposit);

    error ZeroAmount();
    error InsufficientDeposit(uint256 deposit, uint256 needed);
    error NotToken();
    error IncorrectToken(address token);

    constructor(IERC20 _token) {
        token = _token;
        // 初始化空链表：头哨兵指向自己。
        _next[GUARD] = GUARD;
    }

    /// @dev 只允许绑定的 token 合约调用回调，避免别人伪造存款。
    modifier onlyToken() {
        if (msg.sender != address(token)) revert NotToken();
        _;
    }

    /// @notice 存入 amount 数量的 Token。
    /// @dev 需要调用者事先对 TokenBank 完成 approve 授权。
    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        // 使用 transferFrom 把用户的 Token 转到本合约。
        // SafeERC20 兼容 USDT：其 transferFrom 不返回 bool（无返回值）。
        token.safeTransferFrom(msg.sender, address(this), amount);

        _deposit(msg.sender, amount);
    }

    /// @notice 使用 EIP-2612 离线签名完成授权并存款：
    ///         1. 校验 owner 对 Permit 的签名，把 owner 对本合约的额度设为 amount；
    ///         2. 用该额度把 amount 数量的 Token 从 owner 转入本合约；
    ///         3. 把 amount 记到 owner 名下（计入 `deposits` 与 `totalDeposits`）。
    /// @dev 交易发送者（msg.sender）不必是 owner，可以是任意代付人/中继者；
    ///      owner 只需要离线签名，不需要持有 ETH。
    ///      Permit 的 spender 必须是本合约地址，nonce 取 owner 当前 nonce，deadline 之后签名失效。
    ///
    ///      按 EIP-2612 的安全建议，permit 用 try/catch 包裹：
    ///      若签名被他人抢跑（对方先调用 permit 消耗掉 nonce），本笔 permit 会失败，
    ///      但此时额度已经被抢跑者按同一签名设好，继续 transferFrom 即可，不必回滚整笔交易。
    ///      若 permit 因签名无效/过期失败，且 owner 之前没有给本合约留额度，
    ///      后面的 transferFrom 会因额度不足回滚。
    /// @param owner 代币持有人，也是离线签名者。
    /// @param amount 授权并存入的数量。
    /// @param deadline 签名截止时间戳（秒）。
    /// @param v ECDSA 签名参数。
    /// @param r ECDSA 签名参数。
    /// @param s ECDSA 签名参数。
    function permitDeposit(
        address owner,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (amount == 0) revert ZeroAmount();

        // permit 1. 先完成了签名的验证，一定是owner签名的
        // permit 2. 签名验证通过 进行了真正的approve，授权bank可以支配自己amount额度的token
        // 其实签名验证通过后，approve给谁支配owner的token，都可以。
        // 所以就有了permit2，统一的接口。进行签名验证，代替多种token的bank收款。

        // permmit的amount，跟下面真实transfer的amount是一致的，如果不一致会怎么样？
        // permit的底层 其实也是调了一次approve的，完成的授权，因此下面的amount虽然可以改变值，但是不能超过amount
        try IERC20Permit(address(token)).permit(owner, address(this), amount, deadline, v, r, s) {} catch {}

        token.safeTransferFrom(owner, address(this), amount);

        _deposit(owner, amount);
    }

    /// @notice 使用 Uniswap Permit2 的 SignatureTransfer 完成离线签名存款：
    ///         owner 离线签名 PermitTransferFrom，任意地址把签名提交给本函数，
    ///         由 Permit2 校验签名并把 owner 的代币直接转到本合约，随后记到 owner 名下。
    /// @dev 使用前提：owner 已经对 **Permit2 合约** approve 过该代币（只需一次），
    ///      之后每笔存款只需要一个新的 nonce + 签名，不用再发 approve 交易。
    ///      Permit2 的签名 nonce 是 unordered nonce bitmap，
    ///      同一个 (owner, nonce) 只能使用一次，防止签名重放。
    ///      签名中的 spender 字段是调用 permitTransferFrom 的 msg.sender，
    ///      也就是本合约地址，而不是 msg.sender（提交交易的人）——因此允许代付人中继。
    /// @param permit 用户签名的 PermitTransferFrom 结构体（链上不含 spender）。
    /// @param owner 代币持有人，也是离线签名者。
    /// @param signature owner 对 Permit2 EIP-712 结构的签名（65 字节 r,s,v）。
    function depositWithPermit2(
        ISignatureTransfer.PermitTransferFrom calldata permit,
        address owner,
        bytes calldata signature
    ) external {
        if (permit.permitted.amount == 0) revert ZeroAmount();
        if (permit.permitted.token != address(token)) {
            revert IncorrectToken(permit.permitted.token);
        }

        // 调用 Permit2 的 SignatureTransfer：
        // 1. 校验 owner 的签名（spender 会被自动拼成 msg.sender = 本合约）；
        // 2. 消耗 owner 的 unordered nonce；
        // 3. Permit2 以自身身份执行 token.transferFrom(owner, to, requestedAmount)，
        //    所以 owner 需要对 Permit2 合约（而不是本合约）有额度。
        ISignatureTransfer(PERMIT2).permitTransferFrom(
            permit,
            ISignatureTransfer.SignatureTransferDetails({
                to: address(this),
                requestedAmount: permit.permitted.amount
            }),
            owner,
            signature
        );

        _deposit(owner, permit.permitted.amount);
    }

    /// @notice 提取调用者之前存入的 amount 数量的 Token。
    /// @dev 先更新账本再转账（checks-effects-interactions）。
    function withdraw(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        uint256 userDeposit = deposits[msg.sender];
        if (userDeposit < amount) revert InsufficientDeposit(userDeposit, amount);

        deposits[msg.sender] = userDeposit - amount;
        totalDeposits -= amount;

        // 存款减少后重新计算名次（金额降为 0 时会从榜单移除）。
        _updateTopList(msg.sender);

        token.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount, userDeposit - amount);
    }

    /// @notice 查询某个用户当前存入的 Token 数量。
    function getDeposit(address user) external view returns (uint256) {
        return deposits[user];
    }

    /// @notice 当前榜首地址，榜单为空时返回 address(0)。
    function topHead() external view returns (address) {
        address head = _next[GUARD];
        return head == GUARD ? address(0) : head;
    }

    /// @notice 当前榜尾地址，榜单为空时返回 address(0)。
    function topTail() external view returns (address) {
        address tail = _tail();
        return tail == GUARD ? address(0) : tail;
    }

    /// @notice 返回按存款金额从高到低排列的前 10 名榜单。
    /// @dev 从 `_next[GUARD]` 沿 next 指针遍历，最多迭代 TOP_N 个节点。
    function getTopDepositors() external view returns (address[] memory users, uint256[] memory amounts) {
        uint256 count = topCount;
        users = new address[](count);
        amounts = new uint256[](count);

        address cursor = _next[GUARD];
        for (uint256 i = 0; i < count; ++i) {
            users[i] = cursor;
            amounts[i] = deposits[cursor];
            cursor = _next[cursor];
        }
    }

    /// @notice CalledToken.transferAndCall 的转账回调：
    ///         用户通过 transferAndCall 把 Token 转进本合约后，
    ///         这里把金额记到 from 名下，等价于完成一次 deposit。
    /// @dev 只有绑定的 token 合约可以调用；Token 此时已经转到本合约。
    function onTokensReceived(
        address, /* operator */
        address from,
        uint256 amount,
        bytes calldata /* data */
    )
        external
        onlyToken
        returns (bytes4)
    {
        if (amount == 0) revert ZeroAmount();

        _deposit(from, amount);

        return ITokensReceiver.onTokensReceived.selector;
    }

    /// @dev 更新某个用户的存款账本，deposit、permitDeposit、depositWithPermit2 和 onTokensReceived 共用。
    function _deposit(address user, uint256 amount) private {
        uint256 newDeposit = deposits[user] + amount;
        deposits[user] = newDeposit;
        totalDeposits += amount;

        // 存款增加后重新计算名次（可能上榜或向前移动）。
        _updateTopList(user);

        emit Deposited(user, amount, newDeposit);
    }

    /// @dev 用户存款变化后，重新计算其在前 10 名链表中的位置。
    ///      - 已在榜：先摘除，金额不为 0 时再按金额重新插入，相当于自动上移/下移；
    ///      - 不在榜：榜单未满直接插入；已满则只有金额严格大于最后一名时才挤掉榜尾。
    /// @dev 注意：榜单只保存前 10 名，被挤掉的用户不会保留在链表中。
    ///      因此若榜内用户取款后金额下降，无法自动把榜外第 11 名补进来
    ///      （链表中没有第 11 名及以后用户的数据）；这是"只存前 10"方案的固有限制。
    function _updateTopList(address user) private {
        uint256 amount = deposits[user];

        // `_next[user] != address(0)` 表示用户当前在榜单中。
        if (_next[user] != address(0)) {
            _removeFromList(user);
        }

        if (amount == 0) return;

        if (topCount < TOP_N) {
            _insertSorted(user);
            return;
        }

        // 榜单已满：金额严格大于榜尾时才替换最后一名。
        address tail = _tail();
        if (amount > deposits[tail]) {
            _removeFromList(tail);
            _insertSorted(user);
        }
    }

    /// @dev 按金额从高到低把 user 插入单向循环链表（参考 SchoolOptimized 的 addStudent）。
    ///      金额相同时，新插入的用户排在已有用户之后（稳定排序）。
    function _insertSorted(address user) private {
        uint256 amount = deposits[user];

        // 从 GUARD 的下一个节点开始，找到第一个金额小于 amount 的位置插入；
        // 金额 >= amount 的节点会被跳过，从而保证相同金额时先来者在前。
        address prev = GUARD;
        address cursor = _next[GUARD];
        while (cursor != GUARD && deposits[cursor] >= amount) {
            prev = cursor;
            cursor = _next[cursor];
        }

        _next[user] = cursor;
        _next[prev] = user;
        topCount += 1;
    }

    /// @dev 把在榜用户 user 从单向链表中摘除（参考 SchoolOptimized 的 removeStudent）。
    ///      单链表需要先从 GUARD 找到 user 的前驱节点。
    function _removeFromList(address user) private {
        address prev = GUARD;
        while (_next[prev] != user) {
            prev = _next[prev];
        }

        _next[prev] = _next[user];
        _next[user] = address(0);
        topCount -= 1;
    }

    /// @dev 返回榜尾节点（next 指向 GUARD 的节点）；空表时返回 GUARD。
    function _tail() private view returns (address tail) {
        tail = GUARD;
        while (_next[tail] != GUARD) {
            tail = _next[tail];
        }
    }
}
