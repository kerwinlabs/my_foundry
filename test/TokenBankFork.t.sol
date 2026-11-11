// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TokenBank} from "../src/TokenBank.sol";

/// @dev 用标准 IERC20 接口调用代币，并消费其 bool 返回值，
///      模拟修复前 TokenBank 里 `if (!token.transferFrom(...))` 的写法。
contract TypedERC20Caller {
    function transferFrom(IERC20 token, address from, address to, uint256 amount) external returns (bool) {
        return token.transferFrom(from, to, amount);
    }
}

/// @notice 使用主网 USDT 的 fork 测试。
///         运行：MAINNET_RPC_URL=<url> forge test --match-path test/TokenBankFork.t.sol -vv
///         未设置 MAINNET_RPC_URL 时使用 publicnode 公共节点。
contract TokenBankForkTest is Test {
    using SafeERC20 for IERC20;

    /// @notice 主网 USDT 合约地址。
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    /// @notice USDT 精度为 6。
    uint256 internal constant ONE_USDT = 1e6;

    IERC20 internal usdt;
    TokenBank internal bank;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        vm.createSelectFork(rpc);

        usdt = IERC20(USDT);
        bank = new TokenBank(usdt);

        // 直接用 vm 改写 USDT 余额，避免依赖某个大户地址的实时余额
        deal(USDT, alice, 1_000 * ONE_USDT);
        deal(USDT, bob, 1_000 * ONE_USDT);
    }

    function _approve(address owner, uint256 amount) internal {
        _approve(owner, address(bank), amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        vm.prank(owner);
        // USDT 的 approve 不返回 bool，forceApprove 会处理这种情况
        usdt.forceApprove(spender, amount);
    }

    // ---------------------------------------------------------------
    // 基本配置
    // ---------------------------------------------------------------

    function test_TokenAndDecimals() public view {
        assertEq(address(bank.token()), USDT);
        assertEq(address(usdt), USDT);
        assertEq(IERC20Metadata(USDT).decimals(), 6);
        assertGt(USDT.code.length, 0, "fork not active or USDT not deployed");
    }

    /// @notice 验证 USDT 是非标准 ERC20：transfer 不返回 bool（返回数据长度为 0）。
    ///         这也正是 TokenBank 必须使用 SafeERC20 的原因。
    function test_USDTTransferHasNoReturnData() public {
        vm.prank(alice);
        (bool success, bytes memory returndata) =
            USDT.call(abi.encodeWithSignature("transfer(address,uint256)", bob, 1));

        assertTrue(success);
        assertEq(returndata.length, 0, "USDT should return no data");
        assertEq(usdt.balanceOf(alice), 1_000 * ONE_USDT - 1);
        assertEq(usdt.balanceOf(bob), 1_000 * ONE_USDT + 1);
    }

    /// @notice 按标准 IERC20（returns bool）调用 USDT：底层调用成功，但返回数据为空。
    function test_StandardIERC20CallOnUSDTReturnsNoData() public {
        deal(USDT, address(this), 10 * ONE_USDT);

        (bool success, bytes memory returndata) = USDT.call(abi.encodeWithSelector(IERC20.transfer.selector, bob, 1));
        assertTrue(success);
        assertEq(returndata.length, 0);
    }

    /// @notice 消费 IERC20 的 bool 返回值时（旧 TokenBank 的写法），
    ///         USDT 空返回数据会导致整个调用 revert —— 旧代码无法存 USDT 的根因。
    function test_TypedIERC20TransferFromRevertsOnUSDT() public {
        TypedERC20Caller caller = new TypedERC20Caller();
        _approve(alice, address(caller), 1 * ONE_USDT);

        vm.expectRevert();
        caller.transferFrom(usdt, alice, bob, 1);
    }

    // ---------------------------------------------------------------
    // 存款
    // ---------------------------------------------------------------

    function test_DepositUSDT() public {
        uint256 amount = 100 * ONE_USDT;
        _approve(alice, amount);

        vm.expectEmit(true, false, false, true, address(bank));
        emit TokenBank.Deposited(alice, amount, amount);

        vm.prank(alice);
        bank.deposit(amount);

        assertEq(bank.deposits(alice), amount);
        assertEq(bank.getDeposit(alice), amount);
        assertEq(bank.totalDeposits(), amount);

        assertEq(usdt.balanceOf(alice), 900 * ONE_USDT);
        assertEq(usdt.balanceOf(address(bank)), amount);
    }

    function test_MultipleUsersDepositUSDT() public {
        _approve(alice, 100 * ONE_USDT);
        _approve(bob, 250 * ONE_USDT);

        vm.prank(alice);
        bank.deposit(100 * ONE_USDT);

        vm.prank(bob);
        bank.deposit(250 * ONE_USDT);

        assertEq(bank.deposits(alice), 100 * ONE_USDT);
        assertEq(bank.deposits(bob), 250 * ONE_USDT);
        assertEq(bank.totalDeposits(), 350 * ONE_USDT);
        assertEq(usdt.balanceOf(address(bank)), 350 * ONE_USDT);
    }

    function test_DepositAccumulatesForSameUser() public {
        _approve(alice, 300 * ONE_USDT);

        vm.startPrank(alice);
        bank.deposit(100 * ONE_USDT);
        bank.deposit(200 * ONE_USDT);
        vm.stopPrank();

        assertEq(bank.deposits(alice), 300 * ONE_USDT);
        assertEq(bank.totalDeposits(), 300 * ONE_USDT);
        assertEq(usdt.balanceOf(address(bank)), 300 * ONE_USDT);
    }

    function test_DepositWithoutApprovalReverts() public {
        vm.prank(alice);
        vm.expectRevert();
        bank.deposit(1 * ONE_USDT);
    }

    function test_DepositAboveAllowanceReverts() public {
        _approve(alice, 10 * ONE_USDT);

        vm.prank(alice);
        vm.expectRevert();
        bank.deposit(11 * ONE_USDT);
    }

    function test_DepositZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(TokenBank.ZeroAmount.selector);
        bank.deposit(0);
    }

    // ---------------------------------------------------------------
    // 提取
    // ---------------------------------------------------------------

    function test_WithdrawUSDT() public {
        _approve(alice, 100 * ONE_USDT);
        vm.prank(alice);
        bank.deposit(100 * ONE_USDT);

        vm.expectEmit(true, false, false, true, address(bank));
        emit TokenBank.Withdrawn(alice, 40 * ONE_USDT, 60 * ONE_USDT);

        vm.prank(alice);
        bank.withdraw(40 * ONE_USDT);

        assertEq(bank.deposits(alice), 60 * ONE_USDT);
        assertEq(bank.totalDeposits(), 60 * ONE_USDT);
        assertEq(usdt.balanceOf(alice), 940 * ONE_USDT);
        assertEq(usdt.balanceOf(address(bank)), 60 * ONE_USDT);
    }

    function test_WithdrawAllUSDT() public {
        _approve(alice, 100 * ONE_USDT);
        vm.prank(alice);
        bank.deposit(100 * ONE_USDT);

        vm.prank(alice);
        bank.withdraw(100 * ONE_USDT);

        assertEq(bank.deposits(alice), 0);
        assertEq(bank.totalDeposits(), 0);
        assertEq(usdt.balanceOf(alice), 1_000 * ONE_USDT);
        assertEq(usdt.balanceOf(address(bank)), 0);
    }

    function test_WithdrawTooMuchReverts() public {
        _approve(alice, 100 * ONE_USDT);
        vm.prank(alice);
        bank.deposit(100 * ONE_USDT);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TokenBank.InsufficientDeposit.selector, 100 * ONE_USDT, 101 * ONE_USDT));
        bank.withdraw(101 * ONE_USDT);
    }

    function test_WithdrawZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(TokenBank.ZeroAmount.selector);
        bank.withdraw(0);
    }

    /// @notice 用户只能取回自己的存款，不能动用别人的。
    function test_UsersCannotWithdrawEachOtherFunds() public {
        _approve(alice, 100 * ONE_USDT);
        vm.prank(alice);
        bank.deposit(100 * ONE_USDT);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TokenBank.InsufficientDeposit.selector, 0, 1));
        bank.withdraw(1);
    }

    // ---------------------------------------------------------------
    // 回调与任意地址
    // ---------------------------------------------------------------

    function test_FakeCallbackReverts() public {
        vm.prank(alice);
        vm.expectRevert(TokenBank.NotToken.selector);
        bank.onTokensReceived(alice, alice, 1 * ONE_USDT, "");
    }

    // ---------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------

    function testFuzz_DepositAndPartialWithdraw(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 1, 1_000 * ONE_USDT);
        uint256 withdrawAmount = amount / 2;

        _approve(alice, amount);
        vm.prank(alice);
        bank.deposit(amount);

        assertEq(bank.deposits(alice), amount);
        assertEq(usdt.balanceOf(address(bank)), amount);

        if (withdrawAmount > 0) {
            vm.prank(alice);
            bank.withdraw(withdrawAmount);

            assertEq(bank.deposits(alice), amount - withdrawAmount);
            assertEq(bank.totalDeposits(), amount - withdrawAmount);
            assertEq(usdt.balanceOf(address(bank)), amount - withdrawAmount);
        }
    }
}
