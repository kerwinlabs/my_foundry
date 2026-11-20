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

    event Deposited(address indexed user, uint256 amount, uint256 userDeposit);
    event Withdrawn(address indexed user, uint256 amount, uint256 userDeposit);

    error ZeroAmount();
    error InsufficientDeposit(uint256 deposit, uint256 needed);
    error NotToken();
    error IncorrectToken(address token);

    constructor(IERC20 _token) {
        token = _token;
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

        token.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount, userDeposit - amount);
    }

    /// @notice 查询某个用户当前存入的 Token 数量。
    function getDeposit(address user) external view returns (uint256) {
        return deposits[user];
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

        emit Deposited(user, amount, newDeposit);
    }
}
