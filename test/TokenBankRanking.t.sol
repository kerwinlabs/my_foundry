// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TokenBank} from "../src/TokenBank.sol";
import {CalledToken} from "../src/CalledToken.sol";

/// @dev 排行榜测试用的简单 ERC20，任何人可以 mint。
contract RankingMockERC20 is ERC20 {
    constructor() ERC20("Ranking Token", "RTK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice 针对 TokenBank 前 10 名排行榜（GUARD + `mapping(address => address)` 单向循环链表）的测试。
/// 运行：
///   forge test --match-path test/TokenBankRanking.t.sol -vv
contract TokenBankRankingTest is Test {
    RankingMockERC20 internal token;
    TokenBank internal bank;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        token = new RankingMockERC20();
        bank = new TokenBank(IERC20(address(token)));
    }

    // ---------------------------------------------------------------
    // 辅助函数
    // ---------------------------------------------------------------

    function _deposit(address user, uint256 amount) internal {
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(bank), amount);
        bank.deposit(amount);
        vm.stopPrank();
    }

    function _withdraw(address user, uint256 amount) internal {
        vm.prank(user);
        bank.withdraw(amount);
    }

    function _top() internal view returns (address[] memory users, uint256[] memory amounts) {
        return bank.getTopDepositors();
    }

    function _assertNotInTop(address user) internal view {
        (address[] memory users, ) = _top();
        for (uint256 i = 0; i < users.length; ++i) {
            assertTrue(users[i] != user, "user should not be in top list");
        }
    }

    /// @dev 生成 count 个用户，第 i 个存入 (i + 1) * 100 ether。
    function _depositMany(uint256 count) internal returns (address[] memory users) {
        users = new address[](count);
        for (uint256 i = 0; i < count; ++i) {
            users[i] = makeAddr(string.concat("depositor", vm.toString(i)));
            _deposit(users[i], (i + 1) * 100 ether);
        }
    }

    // ---------------------------------------------------------------
    // 空榜 / 基础状态
    // ---------------------------------------------------------------

    function test_EmptyLeaderboard() public {
        assertEq(bank.topCount(), 0);
        assertEq(bank.topHead(), address(0));
        assertEq(bank.topTail(), address(0));

        (address[] memory users, uint256[] memory amounts) = _top();
        assertEq(users.length, 0);
        assertEq(amounts.length, 0);
    }

    function test_FirstDepositBecomesLeader() public {
        _deposit(alice, 100 ether);

        assertEq(bank.topCount(), 1);
        assertEq(bank.topHead(), alice);
        assertEq(bank.topTail(), alice);

        (address[] memory users, uint256[] memory amounts) = _top();
        assertEq(users.length, 1);
        assertEq(users[0], alice);
        assertEq(amounts[0], 100 ether);
    }

    // ---------------------------------------------------------------
    // 排序
    // ---------------------------------------------------------------

    function test_LeaderboardSortedDescending() public {
        _deposit(alice, 100 ether);
        _deposit(bob, 300 ether);
        _deposit(carol, 200 ether);

        (address[] memory users, uint256[] memory amounts) = _top();
        assertEq(users.length, 3);
        assertEq(users[0], bob);
        assertEq(amounts[0], 300 ether);
        assertEq(users[1], carol);
        assertEq(amounts[1], 200 ether);
        assertEq(users[2], alice);
        assertEq(amounts[2], 100 ether);

        assertEq(bank.topHead(), bob);
        assertEq(bank.topTail(), alice);
    }

    function test_EqualAmountsKeepArrivalOrder() public {
        _deposit(alice, 100 ether);
        _deposit(bob, 100 ether);
        _deposit(carol, 100 ether);

        (address[] memory users, ) = _top();
        assertEq(users.length, 3);
        assertEq(users[0], alice);
        assertEq(users[1], bob);
        assertEq(users[2], carol);
    }

    function test_AdditionalDepositMovesUserUp() public {
        _deposit(alice, 100 ether);
        _deposit(bob, 200 ether);
        _deposit(carol, 150 ether); // bob, carol, alice

        _deposit(alice, 200 ether); // alice = 300

        (address[] memory users, uint256[] memory amounts) = _top();
        assertEq(users[0], alice);
        assertEq(amounts[0], 300 ether);
        assertEq(users[1], bob);
        assertEq(amounts[1], 200 ether);
        assertEq(users[2], carol);
        assertEq(amounts[2], 150 ether);
    }

    function test_WithdrawMovesUserDown() public {
        _deposit(alice, 300 ether);
        _deposit(bob, 200 ether);
        _deposit(carol, 100 ether); // alice, bob, carol

        _withdraw(alice, 150 ether); // alice = 150

        (address[] memory users, uint256[] memory amounts) = _top();
        assertEq(users[0], bob);
        assertEq(amounts[0], 200 ether);
        assertEq(users[1], alice);
        assertEq(amounts[1], 150 ether);
        assertEq(users[2], carol);
        assertEq(amounts[2], 100 ether);
    }

    function test_WithdrawAllRemovesFromLeaderboard() public {
        _deposit(alice, 100 ether);
        _deposit(bob, 200 ether); // bob, alice

        _withdraw(alice, 100 ether);

        assertEq(bank.topCount(), 1);
        assertEq(bank.topHead(), bob);
        assertEq(bank.topTail(), bob);

        (address[] memory users, uint256[] memory amounts) = _top();
        assertEq(users.length, 1);
        assertEq(users[0], bob);
        assertEq(amounts[0], 200 ether);

        _assertNotInTop(alice);
    }

    // ---------------------------------------------------------------
    // 前 10 名上限与淘汰
    // ---------------------------------------------------------------

    function test_LeaderboardCapsAtTen() public {
        address[] memory users = _depositMany(12); // 100 ~ 1200 ether

        (address[] memory topUsers, uint256[] memory topAmounts) = _top();
        assertEq(bank.topCount(), 10);
        assertEq(topUsers.length, 10);
        assertEq(topAmounts[0], 1200 ether);
        assertEq(topAmounts[9], 300 ether);

        // 最小的两个用户（100、200）被挤出榜单
        _assertNotInTop(users[0]);
        _assertNotInTop(users[1]);
    }

    function test_FullLeaderboardEvictsSmallest() public {
        address[] memory users = _depositMany(10); // 100 ~ 1000 ether
        address late = makeAddr("late");

        _deposit(late, 550 ether);

        (address[] memory topUsers, uint256[] memory topAmounts) = _top();
        assertEq(topUsers.length, 10);

        // 550 应排在第 6 名：1000, 900, 800, 700, 600, 550, ...
        assertEq(topUsers[5], late);
        assertEq(topAmounts[5], 550 ether);

        // 原榜尾（100 ether）被挤出，新榜尾为 200 ether
        assertEq(topUsers[9], users[1]);
        assertEq(topAmounts[9], 200 ether);
        _assertNotInTop(users[0]);
    }

    function test_NewDepositMustStrictlyExceedTail() public {
        address[] memory users = _depositMany(10); // 榜尾 100 ether
        address equalUser = makeAddr("equalUser");
        address smallerUser = makeAddr("smallerUser");

        _deposit(equalUser, 100 ether); // 等于榜尾，不进入
        _deposit(smallerUser, 99 ether); // 小于榜尾，不进入

        (address[] memory topUsers, uint256[] memory topAmounts) = _top();
        assertEq(topUsers.length, 10);
        assertEq(topUsers[9], users[0]);
        assertEq(topAmounts[9], 100 ether);

        _assertNotInTop(equalUser);
        _assertNotInTop(smallerUser);
    }

    function test_EvictedUserCanReenter() public {
        address[] memory users = _depositMany(10);
        address late = makeAddr("late");
        _deposit(late, 550 ether); // users[0]（100）被挤出

        // users[0] 累计 600，重新进榜并排到 late（550）前面
        _deposit(users[0], 500 ether);

        (address[] memory topUsers, uint256[] memory topAmounts) = _top();
        assertEq(topUsers.length, 10);

        // 600 与 users[5]（600）相同，按稳定排序排在它后面
        assertEq(topUsers[5], users[0]);
        assertEq(topAmounts[5], 600 ether);
        assertEq(topUsers[6], late);
        assertEq(topAmounts[6], 550 ether);

        // 本次被挤出的变成 users[1]（200），新榜尾是 users[2]（300）
        _assertNotInTop(users[1]);
        assertEq(topUsers[9], users[2]);
        assertEq(topAmounts[9], 300 ether);
    }

    // ---------------------------------------------------------------
    // 其他存款入口
    // ---------------------------------------------------------------

    /// @dev transferAndCall -> onTokensReceived -> _deposit 也应更新排行榜。
    function test_TransferAndCallUpdatesRanking() public {
        CalledToken called = new CalledToken("Called Token", "CALL", 1_000 ether);
        TokenBank calledBank = new TokenBank(IERC20(address(called)));

        called.transferAndCall(address(calledBank), 500 ether, "");

        (address[] memory users, uint256[] memory amounts) = calledBank.getTopDepositors();
        assertEq(users.length, 1);
        assertEq(users[0], address(this));
        assertEq(amounts[0], 500 ether);
        assertEq(calledBank.topHead(), address(this));
    }

    // ---------------------------------------------------------------
    // Fuzz：任意 12 笔存款后，榜单必须有序、不重复、且最多 10 人
    // ---------------------------------------------------------------

    function testFuzz_LeaderboardSortedAndCapped(uint256[12] memory rawAmounts) public {
        address[] memory users = new address[](12);
        for (uint256 i = 0; i < 12; ++i) {
            users[i] = makeAddr(string.concat("fuzzUser", vm.toString(i)));
            uint256 amount = bound(rawAmounts[i], 1, 1_000 ether);
            _deposit(users[i], amount);
        }

        (address[] memory topUsers, uint256[] memory topAmounts) = _top();
        assertEq(topUsers.length, 10);
        assertEq(topUsers.length, bank.topCount());

        for (uint256 i = 0; i < topUsers.length; ++i) {
            // 榜单里的金额必须和 deposits 一致
            assertEq(topAmounts[i], bank.deposits(topUsers[i]), "amount mismatch");

            // 降序排列
            if (i > 0) {
                assertGe(topAmounts[i - 1], topAmounts[i], "not sorted");
            }

            // 不能出现重复用户
            for (uint256 j = i + 1; j < topUsers.length; ++j) {
                assertTrue(topUsers[i] != topUsers[j], "duplicate user");
            }
        }
    }
}
