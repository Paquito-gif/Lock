// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TokenLocker} from "../contracts/TokenLocker.sol";
import {MockERC20} from "../contracts/mocks/Mocks.sol";

/// @dev Drives random sequences of lock / withdraw / extend / transfer / time jumps.
contract Handler is Test {
    TokenLocker public locker;
    MockERC20 public token;
    address[] public actors;
    uint256 public totalWithdrawn;
    uint256 public totalLocked;

    constructor(TokenLocker locker_, MockERC20 token_) {
        locker = locker_;
        token = token_;
        for (uint256 i; i < 4; ++i) {
            address a = makeAddr(string(abi.encodePacked("actor", vm.toString(i))));
            actors.push(a);
            token.mint(a, 1e30);
            vm.deal(a, 1_000 ether);
            vm.prank(a);
            token.approve(address(locker), type(uint256).max);
        }
    }

    function lock(uint256 actorSeed, uint256 ownerSeed, uint256 amount, uint256 duration) external {
        address from = actors[actorSeed % actors.length];
        address to = actors[ownerSeed % actors.length];
        amount = bound(amount, 1, 1e24);
        duration = bound(duration, 1, 4 * 365 days);
        uint256 fee = locker.fee();
        vm.prank(from);
        locker.lock{value: fee}(address(token), amount, uint40(block.timestamp + duration), to);
        totalLocked += amount;
    }

    function withdraw(uint256 idSeed) external {
        uint256 n = locker.lockCount();
        if (n == 0) return;
        uint256 id = idSeed % n;
        TokenLocker.Lock memory l = locker.getLock(id);
        if (l.withdrawn || block.timestamp < l.unlockTime) return;
        vm.prank(l.owner);
        locker.withdraw(id);
        totalWithdrawn += l.amount;
    }

    function extend(uint256 idSeed, uint256 extra) external {
        uint256 n = locker.lockCount();
        if (n == 0) return;
        uint256 id = idSeed % n;
        TokenLocker.Lock memory l = locker.getLock(id);
        if (l.withdrawn) return;
        uint256 base = l.unlockTime > block.timestamp ? l.unlockTime : block.timestamp;
        uint256 t = base + bound(extra, 1, 365 days);
        vm.prank(l.owner);
        locker.extendLock(id, uint40(t));
    }

    function transfer(uint256 idSeed, uint256 toSeed) external {
        uint256 n = locker.lockCount();
        if (n == 0) return;
        uint256 id = idSeed % n;
        TokenLocker.Lock memory l = locker.getLock(id);
        if (l.withdrawn) return;
        vm.prank(l.owner);
        locker.transferLock(id, actors[toSeed % actors.length]);
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 180 days));
    }
}

contract TokenLockerInvariantTest is Test {
    TokenLocker locker;
    MockERC20 token;
    Handler handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        locker = new TokenLocker(address(this), address(this), 0.05 ether);
        token = new MockERC20();
        handler = new Handler(locker, token);
        targetContract(address(handler));
    }

    /// The contract always holds exactly the tokens of locks not yet withdrawn.
    function invariant_balanceMatchesOpenLocks() public view {
        uint256 open;
        uint256 n = locker.lockCount();
        for (uint256 i; i < n; ++i) {
            TokenLocker.Lock memory l = locker.getLock(i);
            if (!l.withdrawn) open += l.amount;
        }
        assertEq(token.balanceOf(address(locker)), open);
        assertEq(handler.totalLocked() - handler.totalWithdrawn(), open);
    }

    /// Native balance is only ever fees: one fee per lock created.
    function invariant_nativeBalanceIsFees() public view {
        assertEq(address(locker).balance, locker.lockCount() * locker.fee());
    }
}
