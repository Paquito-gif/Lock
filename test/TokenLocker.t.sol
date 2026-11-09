// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TokenLocker} from "../contracts/TokenLocker.sol";
import {MockERC20, FeeOnTransferERC20, ReentrantERC20, RejectNative} from "../contracts/mocks/Mocks.sol";

contract TokenLockerTest is Test {
    TokenLocker locker;
    MockERC20 token;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address eve = makeAddr("eve");

    uint256 constant FEE = 0.05 ether;
    uint256 constant AMOUNT = 1_000e18;

    function setUp() public {
        vm.warp(1_800_000_000);
        locker = new TokenLocker(admin, treasury, FEE);
        token = new MockERC20();
        token.mint(alice, 1_000_000e18);
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        token.approve(address(locker), type(uint256).max);
    }

    function _lock(uint256 amount, uint40 unlockTime, address owner_) internal returns (uint256) {
        vm.prank(alice);
        return locker.lock{value: FEE}(address(token), amount, unlockTime, owner_);
    }

    function _in(uint256 secs) internal view returns (uint40) {
        return uint40(block.timestamp + secs);
    }

    // ------------------------------------------------------------------ constructor

    function test_constructor_setsState() public view {
        assertEq(locker.owner(), admin);
        assertEq(locker.feeRecipient(), treasury);
        assertEq(locker.fee(), FEE);
        assertEq(locker.lockCount(), 0);
    }

    function test_constructor_rejectsBadParams() public {
        vm.expectRevert(TokenLocker.ZeroAddress.selector);
        new TokenLocker(admin, address(0), FEE);
        vm.expectRevert(TokenLocker.FeeTooHigh.selector);
        new TokenLocker(admin, treasury, 1 ether + 1);
    }

    // ------------------------------------------------------------------ lock

    function test_lock_storesLockAndMovesTokens() public {
        uint40 t = _in(30 days);
        vm.expectEmit(address(locker));
        emit TokenLocker.Locked(0, address(token), bob, alice, AMOUNT, t);
        uint256 id = _lock(AMOUNT, t, bob);

        assertEq(id, 0);
        assertEq(locker.lockCount(), 1);
        TokenLocker.Lock memory l = locker.getLock(id);
        assertEq(l.token, address(token));
        assertEq(l.owner, bob);
        assertEq(l.amount, AMOUNT);
        assertEq(l.unlockTime, t);
        assertFalse(l.withdrawn);
        assertEq(token.balanceOf(address(locker)), AMOUNT);
        assertEq(address(locker).balance, FEE);
        assertEq(locker.userLockCount(bob), 1);
        assertEq(locker.tokenLockCount(address(token)), 1);
    }

    function test_lock_requiresExactFee() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(TokenLocker.WrongFee.selector, FEE, FEE - 1));
        locker.lock{value: FEE - 1}(address(token), AMOUNT, _in(1 days), bob);
        vm.expectRevert(abi.encodeWithSelector(TokenLocker.WrongFee.selector, FEE, FEE + 1));
        locker.lock{value: FEE + 1}(address(token), AMOUNT, _in(1 days), bob);
        vm.stopPrank();
    }

    function test_lock_rejectsBadInputs() public {
        uint40 tooFar = _in(locker.MAX_LOCK_DURATION() + 1);
        vm.startPrank(alice);
        vm.expectRevert(TokenLocker.ZeroAmount.selector);
        locker.lock{value: FEE}(address(token), 0, _in(1 days), bob);
        vm.expectRevert(TokenLocker.ZeroAddress.selector);
        locker.lock{value: FEE}(address(token), AMOUNT, _in(1 days), address(0));
        vm.expectRevert(TokenLocker.ZeroAddress.selector);
        locker.lock{value: FEE}(address(0), AMOUNT, _in(1 days), bob);
        vm.expectRevert(TokenLocker.InvalidUnlockTime.selector);
        locker.lock{value: FEE}(address(token), AMOUNT, uint40(block.timestamp), bob);
        vm.expectRevert(TokenLocker.InvalidUnlockTime.selector);
        locker.lock{value: FEE}(address(token), AMOUNT, tooFar, bob);
        vm.stopPrank();
    }

    function test_lock_acceptsMaxDuration() public {
        _lock(AMOUNT, _in(locker.MAX_LOCK_DURATION()), bob);
    }

    function test_ownerlessFunctionsCannotMoveTokens() public {
        // The admin has no way to pull locked tokens: the only token transfer out is withdraw(), owner-gated.
        uint256 id = _lock(AMOUNT, _in(1 days), bob);
        vm.startPrank(admin);
        locker.setFee(0);
        locker.setFeeRecipient(admin);
        vm.expectRevert(TokenLocker.NotLockOwner.selector);
        locker.withdraw(id);
        vm.expectRevert(TokenLocker.NotLockOwner.selector);
        locker.transferLock(id, admin);
        vm.stopPrank();
        assertEq(token.balanceOf(address(locker)), AMOUNT);
    }

    function test_lock_rejectsFeeOnTransferToken() public {
        FeeOnTransferERC20 taxed = new FeeOnTransferERC20();
        taxed.mint(alice, AMOUNT);
        vm.startPrank(alice);
        taxed.approve(address(locker), AMOUNT);
        vm.expectRevert(TokenLocker.UnsupportedToken.selector);
        locker.lock{value: FEE}(address(taxed), AMOUNT, _in(1 days), bob);
        vm.stopPrank();
    }

    function test_lock_worksWithZeroFee() public {
        vm.prank(admin);
        locker.setFee(0);
        vm.prank(alice);
        locker.lock(address(token), AMOUNT, _in(1 days), bob);
        assertEq(address(locker).balance, 0);
    }

    // ------------------------------------------------------------------ withdraw

    function test_withdraw_afterUnlock() public {
        uint40 t = _in(30 days);
        uint256 id = _lock(AMOUNT, t, bob);
        vm.warp(t);
        vm.expectEmit(address(locker));
        emit TokenLocker.Withdrawn(id, bob, AMOUNT);
        vm.prank(bob);
        locker.withdraw(id);

        assertEq(token.balanceOf(bob), AMOUNT);
        assertEq(token.balanceOf(address(locker)), 0);
        assertTrue(locker.getLock(id).withdrawn);
    }

    function test_withdraw_revertsBeforeUnlock() public {
        uint40 t = _in(30 days);
        uint256 id = _lock(AMOUNT, t, bob);
        vm.warp(t - 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TokenLocker.StillLocked.selector, t));
        locker.withdraw(id);
    }

    function test_withdraw_onlyOwner() public {
        uint40 t = _in(1 days);
        uint256 id = _lock(AMOUNT, t, bob);
        vm.warp(t);
        // Neither the creator, a stranger, nor the contract admin can withdraw.
        address[3] memory others = [alice, eve, admin];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(TokenLocker.NotLockOwner.selector);
            locker.withdraw(id);
        }
    }

    function test_withdraw_onlyOnce() public {
        uint40 t = _in(1 days);
        uint256 id = _lock(AMOUNT, t, bob);
        vm.warp(t);
        vm.startPrank(bob);
        locker.withdraw(id);
        vm.expectRevert(TokenLocker.AlreadyWithdrawn.selector);
        locker.withdraw(id);
        vm.stopPrank();
    }

    function test_withdraw_unknownId() public {
        vm.expectRevert(TokenLocker.LockNotFound.selector);
        locker.withdraw(42);
    }

    function test_withdraw_doesNotTouchOtherLocks() public {
        uint256 a = _lock(AMOUNT, _in(1 days), bob);
        uint256 b = _lock(2 * AMOUNT, _in(10 days), bob);
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        locker.withdraw(a);
        assertEq(token.balanceOf(address(locker)), 2 * AMOUNT);
        vm.prank(bob);
        vm.expectRevert();
        locker.withdraw(b);
    }

    function test_withdraw_reentrancyBlocked() public {
        ReentrantERC20 re = new ReentrantERC20();
        re.mint(alice, 2 * AMOUNT);
        vm.startPrank(alice);
        re.approve(address(locker), type(uint256).max);
        uint40 t = _in(1 days);
        uint256 id1 = locker.lock{value: FEE}(address(re), AMOUNT, t, alice);
        locker.lock{value: FEE}(address(re), AMOUNT, t, alice);
        vm.stopPrank();

        vm.warp(t);
        re.arm(address(locker), abi.encodeCall(TokenLocker.withdraw, (id1 + 1)));
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        locker.withdraw(id1);
    }

    // ------------------------------------------------------------------ extend

    function test_extend() public {
        uint40 t = _in(1 days);
        uint256 id = _lock(AMOUNT, t, bob);
        uint40 t2 = _in(60 days);
        vm.expectEmit(address(locker));
        emit TokenLocker.LockExtended(id, t, t2);
        vm.prank(bob);
        locker.extendLock(id, t2);
        assertEq(locker.getLock(id).unlockTime, t2);

        vm.warp(t);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TokenLocker.StillLocked.selector, t2));
        locker.withdraw(id);
    }

    function test_extend_cannotShortenOrKeep() public {
        uint40 t = _in(10 days);
        uint256 id = _lock(AMOUNT, t, bob);
        vm.startPrank(bob);
        vm.expectRevert(TokenLocker.InvalidUnlockTime.selector);
        locker.extendLock(id, t);
        vm.expectRevert(TokenLocker.InvalidUnlockTime.selector);
        locker.extendLock(id, t - 1);
        vm.stopPrank();
    }

    function test_extend_afterUnlockMustBeInFuture() public {
        uint40 t = _in(1 days);
        uint256 id = _lock(AMOUNT, t, bob);
        vm.warp(t + 10);
        vm.startPrank(bob);
        // Later than the old unlock time but already in the past: rejected.
        vm.expectRevert(TokenLocker.InvalidUnlockTime.selector);
        locker.extendLock(id, t + 5);
        locker.extendLock(id, _in(1 days));
        vm.stopPrank();
    }

    function test_extend_onlyOwnerAndNotWithdrawn() public {
        uint40 t = _in(1 days);
        uint256 id = _lock(AMOUNT, t, bob);
        vm.prank(alice);
        vm.expectRevert(TokenLocker.NotLockOwner.selector);
        locker.extendLock(id, _in(2 days));

        vm.warp(t);
        vm.startPrank(bob);
        locker.withdraw(id);
        vm.expectRevert(TokenLocker.AlreadyWithdrawn.selector);
        locker.extendLock(id, _in(2 days));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ transfer

    function test_transferLock() public {
        uint40 t = _in(1 days);
        uint256 id = _lock(AMOUNT, t, bob);
        vm.expectEmit(address(locker));
        emit TokenLocker.LockTransferred(id, bob, eve);
        vm.prank(bob);
        locker.transferLock(id, eve);
        assertEq(locker.getLock(id).owner, eve);
        assertEq(locker.userLockIds(eve, 0, 10)[0], id);

        vm.warp(t);
        vm.prank(bob);
        vm.expectRevert(TokenLocker.NotLockOwner.selector);
        locker.withdraw(id);
        vm.prank(eve);
        locker.withdraw(id);
        assertEq(token.balanceOf(eve), AMOUNT);
    }

    function test_transferLock_rejectsBadTargets() public {
        uint256 id = _lock(AMOUNT, _in(1 days), bob);
        vm.startPrank(bob);
        vm.expectRevert(TokenLocker.ZeroAddress.selector);
        locker.transferLock(id, address(0));
        vm.expectRevert(TokenLocker.ZeroAddress.selector);
        locker.transferLock(id, address(locker));
        vm.stopPrank();
        vm.prank(eve);
        vm.expectRevert(TokenLocker.NotLockOwner.selector);
        locker.transferLock(id, eve);
    }

    // ------------------------------------------------------------------ fees & admin

    function test_setFee_onlyOwnerAndCapped() public {
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        locker.setFee(0);

        vm.startPrank(admin);
        vm.expectRevert(TokenLocker.FeeTooHigh.selector);
        locker.setFee(1 ether + 1);
        locker.setFee(1 ether);
        vm.stopPrank();
        assertEq(locker.fee(), 1 ether);
    }

    function test_setFeeRecipient() public {
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        locker.setFeeRecipient(eve);

        vm.startPrank(admin);
        vm.expectRevert(TokenLocker.ZeroAddress.selector);
        locker.setFeeRecipient(address(0));
        locker.setFeeRecipient(bob);
        vm.stopPrank();
        assertEq(locker.feeRecipient(), bob);
    }

    function test_withdrawFees_goesToRecipientNotCaller() public {
        _lock(AMOUNT, _in(1 days), bob);
        _lock(AMOUNT, _in(1 days), bob);
        vm.prank(eve);
        locker.withdrawFees();
        assertEq(treasury.balance, 2 * FEE);
        assertEq(eve.balance, 0);
        assertEq(address(locker).balance, 0);
        // Locked tokens are untouched.
        assertEq(token.balanceOf(address(locker)), 2 * AMOUNT);

        vm.expectRevert(TokenLocker.NothingToWithdraw.selector);
        locker.withdrawFees();
    }

    function test_withdrawFees_revertsIfRecipientRejects() public {
        RejectNative r = new RejectNative();
        vm.prank(admin);
        locker.setFeeRecipient(address(r));
        _lock(AMOUNT, _in(1 days), bob);
        vm.expectRevert(TokenLocker.NativeTransferFailed.selector);
        locker.withdrawFees();
    }

    function test_ownershipIsTwoStep() public {
        vm.prank(admin);
        locker.transferOwnership(bob);
        assertEq(locker.owner(), admin);
        vm.prank(bob);
        locker.acceptOwnership();
        assertEq(locker.owner(), bob);
    }

    function test_locksSurviveRenouncedOwnership() public {
        uint40 t = _in(1 days);
        uint256 id = _lock(AMOUNT, t, bob);
        vm.prank(admin);
        locker.renounceOwnership();
        vm.warp(t);
        vm.prank(bob);
        locker.withdraw(id);
        assertEq(token.balanceOf(bob), AMOUNT);
        locker.withdrawFees();
        assertEq(treasury.balance, FEE);
    }

    // ------------------------------------------------------------------ views

    function test_pagination() public {
        for (uint256 i; i < 5; ++i) {
            _lock(1e18, _in(1 days), bob);
        }
        uint256[] memory page = locker.userLockIds(bob, 1, 2);
        assertEq(page.length, 2);
        assertEq(page[0], 1);
        assertEq(page[1], 2);
        assertEq(locker.userLockIds(bob, 3, 100).length, 2);
        assertEq(locker.userLockIds(bob, 5, 1).length, 0);
        assertEq(locker.userLockIds(bob, 2, type(uint256).max).length, 3);
        assertEq(locker.tokenLockIds(address(token), 0, 10).length, 5);
        assertEq(locker.userLockIds(eve, 0, 10).length, 0);
    }

    function test_getLock_unknownId() public {
        vm.expectRevert(TokenLocker.LockNotFound.selector);
        locker.getLock(0);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_lockThenWithdraw(uint256 amount, uint256 duration, uint256 waitAfter) public {
        amount = bound(amount, 1, token.balanceOf(alice));
        duration = bound(duration, 1, locker.MAX_LOCK_DURATION());
        waitAfter = bound(waitAfter, 0, 365 days);
        uint40 t = _in(duration);
        uint256 id = _lock(amount, t, bob);

        vm.warp(uint256(t) - 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TokenLocker.StillLocked.selector, t));
        locker.withdraw(id);

        vm.warp(uint256(t) + waitAfter);
        vm.prank(bob);
        locker.withdraw(id);
        assertEq(token.balanceOf(bob), amount);
    }

    function testFuzz_unlockTimeBounds(uint40 unlockTime) public {
        bool valid = unlockTime > block.timestamp && unlockTime <= block.timestamp + locker.MAX_LOCK_DURATION();
        vm.prank(alice);
        if (!valid) vm.expectRevert(TokenLocker.InvalidUnlockTime.selector);
        locker.lock{value: FEE}(address(token), AMOUNT, unlockTime, bob);
    }
}
