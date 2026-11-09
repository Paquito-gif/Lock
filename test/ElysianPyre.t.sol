// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ElysianPyre} from "../contracts/ElysianPyre.sol";
import {
    MockERC20,
    FeeOnTransferERC20,
    ReentrantERC20,
    RejectNative,
    BurnableERC20,
    FakeBurnERC20,
    HalfBurnERC20
} from "../contracts/mocks/Mocks.sol";

contract ElysianPyreTest is Test {
    ElysianPyre pyre;
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
        pyre = new ElysianPyre(admin, treasury, FEE);
        token = new MockERC20();
        token.mint(alice, 1_000_000e18);
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        token.approve(address(pyre), type(uint256).max);
    }

    function _lock(uint256 amount, uint40 unlockTime, address owner_) internal returns (uint256) {
        vm.prank(alice);
        return pyre.lock{value: FEE}(address(token), amount, unlockTime, owner_);
    }

    function _in(uint256 secs) internal view returns (uint40) {
        return uint40(block.timestamp + secs);
    }

    // ------------------------------------------------------------------ constructor

    function test_constructor_setsState() public view {
        assertEq(pyre.owner(), admin);
        assertEq(pyre.feeRecipient(), treasury);
        assertEq(pyre.fee(), FEE);
        assertEq(pyre.lockCount(), 0);
    }

    function test_constructor_rejectsBadParams() public {
        vm.expectRevert(ElysianPyre.ZeroAddress.selector);
        new ElysianPyre(admin, address(0), FEE);
        vm.expectRevert(ElysianPyre.FeeTooHigh.selector);
        new ElysianPyre(admin, treasury, 1 ether + 1);
    }

    // ------------------------------------------------------------------ lock

    function test_lock_storesLockAndMovesTokens() public {
        uint40 t = _in(30 days);
        vm.expectEmit(address(pyre));
        emit ElysianPyre.Locked(0, address(token), bob, alice, AMOUNT, t);
        uint256 id = _lock(AMOUNT, t, bob);

        assertEq(id, 0);
        assertEq(pyre.lockCount(), 1);
        ElysianPyre.Lock memory l = pyre.getLock(id);
        assertEq(l.token, address(token));
        assertEq(l.owner, bob);
        assertEq(l.amount, AMOUNT);
        assertEq(l.unlockTime, t);
        assertFalse(l.withdrawn);
        assertEq(token.balanceOf(address(pyre)), AMOUNT);
        assertEq(address(pyre).balance, FEE);
        assertEq(pyre.userLockCount(bob), 1);
        assertEq(pyre.tokenLockCount(address(token)), 1);
    }

    function test_lock_requiresExactFee() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ElysianPyre.WrongFee.selector, FEE, FEE - 1));
        pyre.lock{value: FEE - 1}(address(token), AMOUNT, _in(1 days), bob);
        vm.expectRevert(abi.encodeWithSelector(ElysianPyre.WrongFee.selector, FEE, FEE + 1));
        pyre.lock{value: FEE + 1}(address(token), AMOUNT, _in(1 days), bob);
        vm.stopPrank();
    }

    function test_lock_rejectsBadInputs() public {
        uint40 tooFar = _in(pyre.MAX_LOCK_DURATION() + 1);
        vm.startPrank(alice);
        vm.expectRevert(ElysianPyre.ZeroAmount.selector);
        pyre.lock{value: FEE}(address(token), 0, _in(1 days), bob);
        vm.expectRevert(ElysianPyre.ZeroAddress.selector);
        pyre.lock{value: FEE}(address(token), AMOUNT, _in(1 days), address(0));
        vm.expectRevert(ElysianPyre.ZeroAddress.selector);
        pyre.lock{value: FEE}(address(0), AMOUNT, _in(1 days), bob);
        vm.expectRevert(ElysianPyre.InvalidUnlockTime.selector);
        pyre.lock{value: FEE}(address(token), AMOUNT, uint40(block.timestamp), bob);
        vm.expectRevert(ElysianPyre.InvalidUnlockTime.selector);
        pyre.lock{value: FEE}(address(token), AMOUNT, tooFar, bob);
        vm.stopPrank();
    }

    function test_lock_acceptsMaxDuration() public {
        _lock(AMOUNT, _in(pyre.MAX_LOCK_DURATION()), bob);
    }

    function test_ownerlessFunctionsCannotMoveTokens() public {
        // The admin has no way to pull locked tokens: the only token transfer out is withdraw(), owner-gated.
        uint256 id = _lock(AMOUNT, _in(1 days), bob);
        vm.startPrank(admin);
        pyre.setFee(0);
        pyre.setFeeRecipient(admin);
        vm.expectRevert(ElysianPyre.NotLockOwner.selector);
        pyre.withdraw(id);
        vm.expectRevert(ElysianPyre.NotLockOwner.selector);
        pyre.transferLock(id, admin);
        vm.stopPrank();
        assertEq(token.balanceOf(address(pyre)), AMOUNT);
    }

    function test_lock_rejectsFeeOnTransferToken() public {
        FeeOnTransferERC20 taxed = new FeeOnTransferERC20();
        taxed.mint(alice, AMOUNT);
        vm.startPrank(alice);
        taxed.approve(address(pyre), AMOUNT);
        vm.expectRevert(ElysianPyre.UnsupportedToken.selector);
        pyre.lock{value: FEE}(address(taxed), AMOUNT, _in(1 days), bob);
        vm.stopPrank();
    }

    function test_lock_worksWithZeroFee() public {
        vm.prank(admin);
        pyre.setFee(0);
        vm.prank(alice);
        pyre.lock(address(token), AMOUNT, _in(1 days), bob);
        assertEq(address(pyre).balance, 0);
    }

    // ------------------------------------------------------------------ withdraw

    function test_withdraw_afterUnlock() public {
        uint40 t = _in(30 days);
        uint256 id = _lock(AMOUNT, t, bob);
        vm.warp(t);
        vm.expectEmit(address(pyre));
        emit ElysianPyre.Withdrawn(id, bob, AMOUNT);
        vm.prank(bob);
        pyre.withdraw(id);

        assertEq(token.balanceOf(bob), AMOUNT);
        assertEq(token.balanceOf(address(pyre)), 0);
        assertTrue(pyre.getLock(id).withdrawn);
    }

    function test_withdraw_revertsBeforeUnlock() public {
        uint40 t = _in(30 days);
        uint256 id = _lock(AMOUNT, t, bob);
        vm.warp(t - 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ElysianPyre.StillLocked.selector, t));
        pyre.withdraw(id);
    }

    function test_withdraw_onlyOwner() public {
        uint40 t = _in(1 days);
        uint256 id = _lock(AMOUNT, t, bob);
        vm.warp(t);
        // Neither the creator, a stranger, nor the contract admin can withdraw.
        address[3] memory others = [alice, eve, admin];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(ElysianPyre.NotLockOwner.selector);
            pyre.withdraw(id);
        }
    }

    function test_withdraw_onlyOnce() public {
        uint40 t = _in(1 days);
        uint256 id = _lock(AMOUNT, t, bob);
        vm.warp(t);
        vm.startPrank(bob);
        pyre.withdraw(id);
        vm.expectRevert(ElysianPyre.AlreadyWithdrawn.selector);
        pyre.withdraw(id);
        vm.stopPrank();
    }

    function test_withdraw_unknownId() public {
        vm.expectRevert(ElysianPyre.LockNotFound.selector);
        pyre.withdraw(42);
    }

    function test_withdraw_doesNotTouchOtherLocks() public {
        uint256 a = _lock(AMOUNT, _in(1 days), bob);
        uint256 b = _lock(2 * AMOUNT, _in(10 days), bob);
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        pyre.withdraw(a);
        assertEq(token.balanceOf(address(pyre)), 2 * AMOUNT);
        vm.prank(bob);
        vm.expectRevert();
        pyre.withdraw(b);
    }

    function test_withdraw_reentrancyBlocked() public {
        ReentrantERC20 re = new ReentrantERC20();
        re.mint(alice, 2 * AMOUNT);
        vm.startPrank(alice);
        re.approve(address(pyre), type(uint256).max);
        uint40 t = _in(1 days);
        uint256 id1 = pyre.lock{value: FEE}(address(re), AMOUNT, t, alice);
        pyre.lock{value: FEE}(address(re), AMOUNT, t, alice);
        vm.stopPrank();

        vm.warp(t);
        re.arm(address(pyre), abi.encodeCall(ElysianPyre.withdraw, (id1 + 1)));
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        pyre.withdraw(id1);
    }

    // ------------------------------------------------------------------ extend

    function test_extend() public {
        uint40 t = _in(1 days);
        uint256 id = _lock(AMOUNT, t, bob);
        uint40 t2 = _in(60 days);
        vm.expectEmit(address(pyre));
        emit ElysianPyre.LockExtended(id, t, t2);
        vm.prank(bob);
        pyre.extendLock(id, t2);
        assertEq(pyre.getLock(id).unlockTime, t2);

        vm.warp(t);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ElysianPyre.StillLocked.selector, t2));
        pyre.withdraw(id);
    }

    function test_extend_cannotShortenOrKeep() public {
        uint40 t = _in(10 days);
        uint256 id = _lock(AMOUNT, t, bob);
        vm.startPrank(bob);
        vm.expectRevert(ElysianPyre.InvalidUnlockTime.selector);
        pyre.extendLock(id, t);
        vm.expectRevert(ElysianPyre.InvalidUnlockTime.selector);
        pyre.extendLock(id, t - 1);
        vm.stopPrank();
    }

    function test_extend_afterUnlockMustBeInFuture() public {
        uint40 t = _in(1 days);
        uint256 id = _lock(AMOUNT, t, bob);
        vm.warp(t + 10);
        vm.startPrank(bob);
        // Later than the old unlock time but already in the past: rejected.
        vm.expectRevert(ElysianPyre.InvalidUnlockTime.selector);
        pyre.extendLock(id, t + 5);
        pyre.extendLock(id, _in(1 days));
        vm.stopPrank();
    }

    function test_extend_onlyOwnerAndNotWithdrawn() public {
        uint40 t = _in(1 days);
        uint256 id = _lock(AMOUNT, t, bob);
        vm.prank(alice);
        vm.expectRevert(ElysianPyre.NotLockOwner.selector);
        pyre.extendLock(id, _in(2 days));

        vm.warp(t);
        vm.startPrank(bob);
        pyre.withdraw(id);
        vm.expectRevert(ElysianPyre.AlreadyWithdrawn.selector);
        pyre.extendLock(id, _in(2 days));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ transfer

    function test_transferLock() public {
        uint40 t = _in(1 days);
        uint256 id = _lock(AMOUNT, t, bob);
        vm.expectEmit(address(pyre));
        emit ElysianPyre.LockTransferred(id, bob, eve);
        vm.prank(bob);
        pyre.transferLock(id, eve);
        assertEq(pyre.getLock(id).owner, eve);
        assertEq(pyre.userLockIds(eve, 0, 10)[0], id);

        vm.warp(t);
        vm.prank(bob);
        vm.expectRevert(ElysianPyre.NotLockOwner.selector);
        pyre.withdraw(id);
        vm.prank(eve);
        pyre.withdraw(id);
        assertEq(token.balanceOf(eve), AMOUNT);
    }

    function test_transferLock_rejectsBadTargets() public {
        uint256 id = _lock(AMOUNT, _in(1 days), bob);
        vm.startPrank(bob);
        vm.expectRevert(ElysianPyre.ZeroAddress.selector);
        pyre.transferLock(id, address(0));
        vm.expectRevert(ElysianPyre.ZeroAddress.selector);
        pyre.transferLock(id, address(pyre));
        vm.stopPrank();
        vm.prank(eve);
        vm.expectRevert(ElysianPyre.NotLockOwner.selector);
        pyre.transferLock(id, eve);
    }

    // ------------------------------------------------------------------ fees & admin

    function test_setFee_onlyOwnerAndCapped() public {
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        pyre.setFee(0);

        vm.startPrank(admin);
        vm.expectRevert(ElysianPyre.FeeTooHigh.selector);
        pyre.setFee(1 ether + 1);
        pyre.setFee(1 ether);
        vm.stopPrank();
        assertEq(pyre.fee(), 1 ether);
    }

    function test_setFeeRecipient() public {
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, eve));
        pyre.setFeeRecipient(eve);

        vm.startPrank(admin);
        vm.expectRevert(ElysianPyre.ZeroAddress.selector);
        pyre.setFeeRecipient(address(0));
        pyre.setFeeRecipient(bob);
        vm.stopPrank();
        assertEq(pyre.feeRecipient(), bob);
    }

    function test_withdrawFees_goesToRecipientNotCaller() public {
        _lock(AMOUNT, _in(1 days), bob);
        _lock(AMOUNT, _in(1 days), bob);
        vm.prank(eve);
        pyre.withdrawFees();
        assertEq(treasury.balance, 2 * FEE);
        assertEq(eve.balance, 0);
        assertEq(address(pyre).balance, 0);
        // Locked tokens are untouched.
        assertEq(token.balanceOf(address(pyre)), 2 * AMOUNT);

        vm.expectRevert(ElysianPyre.NothingToWithdraw.selector);
        pyre.withdrawFees();
    }

    function test_withdrawFees_revertsIfRecipientRejects() public {
        RejectNative r = new RejectNative();
        vm.prank(admin);
        pyre.setFeeRecipient(address(r));
        _lock(AMOUNT, _in(1 days), bob);
        vm.expectRevert(ElysianPyre.NativeTransferFailed.selector);
        pyre.withdrawFees();
    }

    function test_ownershipIsTwoStep() public {
        vm.prank(admin);
        pyre.transferOwnership(bob);
        assertEq(pyre.owner(), admin);
        vm.prank(bob);
        pyre.acceptOwnership();
        assertEq(pyre.owner(), bob);
    }

    function test_locksSurviveRenouncedOwnership() public {
        uint40 t = _in(1 days);
        uint256 id = _lock(AMOUNT, t, bob);
        vm.prank(admin);
        pyre.renounceOwnership();
        vm.warp(t);
        vm.prank(bob);
        pyre.withdraw(id);
        assertEq(token.balanceOf(bob), AMOUNT);
        pyre.withdrawFees();
        assertEq(treasury.balance, FEE);
    }

    // ------------------------------------------------------------------ views

    function test_pagination() public {
        for (uint256 i; i < 5; ++i) {
            _lock(1e18, _in(1 days), bob);
        }
        uint256[] memory page = pyre.userLockIds(bob, 1, 2);
        assertEq(page.length, 2);
        assertEq(page[0], 1);
        assertEq(page[1], 2);
        assertEq(pyre.userLockIds(bob, 3, 100).length, 2);
        assertEq(pyre.userLockIds(bob, 5, 1).length, 0);
        assertEq(pyre.userLockIds(bob, 2, type(uint256).max).length, 3);
        assertEq(pyre.tokenLockIds(address(token), 0, 10).length, 5);
        assertEq(pyre.userLockIds(eve, 0, 10).length, 0);
    }

    function test_getLock_unknownId() public {
        vm.expectRevert(ElysianPyre.LockNotFound.selector);
        pyre.getLock(0);
    }

    // ------------------------------------------------------------------ permanent locks

    function test_lockPermanent_neverWithdrawable() public {
        vm.prank(alice);
        uint256 id = pyre.lockPermanent{value: FEE}(address(token), AMOUNT, bob);
        assertTrue(pyre.isPermanent(id));
        assertEq(pyre.getLock(id).unlockTime, pyre.PERMANENT());

        uint40 permanent = pyre.PERMANENT();
        vm.warp(uint256(permanent) + 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ElysianPyre.StillLocked.selector, permanent));
        pyre.withdraw(id);
        assertEq(token.balanceOf(address(pyre)), AMOUNT);
    }

    function test_lock_acceptsPermanentSentinel() public {
        uint40 permanent = pyre.PERMANENT();
        uint256 id = _lock(AMOUNT, permanent, bob);
        assertTrue(pyre.isPermanent(id));
    }

    function test_lockPermanent_requiresFeeAndInputs() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ElysianPyre.WrongFee.selector, FEE, 0));
        pyre.lockPermanent(address(token), AMOUNT, bob);
        vm.expectRevert(ElysianPyre.ZeroAmount.selector);
        pyre.lockPermanent{value: FEE}(address(token), 0, bob);
        vm.expectRevert(ElysianPyre.ZeroAddress.selector);
        pyre.lockPermanent{value: FEE}(address(token), AMOUNT, address(0));
        vm.stopPrank();
    }

    function test_extend_toPermanentThenStuck() public {
        uint256 id = _lock(AMOUNT, _in(1 days), bob);
        uint40 permanent = pyre.PERMANENT();
        vm.startPrank(bob);
        pyre.extendLock(id, permanent);
        assertTrue(pyre.isPermanent(id));
        // Nothing is later than forever.
        vm.expectRevert(ElysianPyre.InvalidUnlockTime.selector);
        pyre.extendLock(id, permanent);
        vm.stopPrank();
    }

    function test_permanentLock_canBeTransferred() public {
        vm.prank(alice);
        uint256 id = pyre.lockPermanent{value: FEE}(address(token), AMOUNT, bob);
        vm.prank(bob);
        pyre.transferLock(id, eve);
        assertEq(pyre.getLock(id).owner, eve);
    }

    // ------------------------------------------------------------------ burn

    function _burn(address t, uint256 amount) internal returns (uint256 burned, bool reduced) {
        vm.prank(alice);
        return pyre.burn{value: FEE}(t, amount);
    }

    function test_burn_realBurnLowersSupply() public {
        BurnableERC20 b = new BurnableERC20();
        b.mint(alice, AMOUNT);
        vm.prank(alice);
        b.approve(address(pyre), AMOUNT);

        vm.expectEmit(address(pyre));
        emit ElysianPyre.Burned(address(b), alice, 400e18, true);
        (uint256 burned, bool reduced) = _burn(address(b), 400e18);

        assertEq(burned, 400e18);
        assertTrue(reduced);
        assertEq(b.totalSupply(), AMOUNT - 400e18);
        assertEq(b.balanceOf(address(pyre)), 0);
        assertEq(b.balanceOf(pyre.DEAD()), 0);
        assertEq(pyre.totalBurned(address(b)), 400e18);
        assertEq(address(pyre).balance, FEE);
    }

    function test_burn_fallsBackToDeadAddress() public {
        (uint256 burned, bool reduced) = _burn(address(token), AMOUNT);
        assertEq(burned, AMOUNT);
        assertFalse(reduced);
        assertEq(token.balanceOf(pyre.DEAD()), AMOUNT);
        assertEq(token.balanceOf(address(pyre)), 0);
        assertEq(pyre.totalBurned(address(token)), AMOUNT);
    }

    function test_burn_noOpBurnFallsBackToDead() public {
        FakeBurnERC20 f = new FakeBurnERC20();
        f.mint(alice, AMOUNT);
        vm.prank(alice);
        f.approve(address(pyre), AMOUNT);
        (, bool reduced) = _burn(address(f), AMOUNT);
        assertFalse(reduced);
        assertEq(f.balanceOf(pyre.DEAD()), AMOUNT);
        assertEq(f.balanceOf(address(pyre)), 0);
    }

    function test_burn_partialBurnRejected() public {
        HalfBurnERC20 h = new HalfBurnERC20();
        h.mint(alice, AMOUNT);
        vm.prank(alice);
        h.approve(address(pyre), AMOUNT);
        vm.prank(alice);
        vm.expectRevert(ElysianPyre.UnsupportedToken.selector);
        pyre.burn{value: FEE}(address(h), AMOUNT);
        assertEq(h.balanceOf(alice), AMOUNT);
    }

    function test_burn_feeOnTransferRecordsReceived() public {
        FeeOnTransferERC20 taxed = new FeeOnTransferERC20();
        taxed.mint(alice, AMOUNT);
        vm.prank(alice);
        taxed.approve(address(pyre), AMOUNT);
        (uint256 burned,) = _burn(address(taxed), AMOUNT);
        assertEq(burned, AMOUNT - AMOUNT / 100);
        assertEq(taxed.balanceOf(address(pyre)), 0);
        assertEq(pyre.totalBurned(address(taxed)), burned);
    }

    function test_burn_doesNotTouchLockedTokens() public {
        _lock(AMOUNT, _in(1 days), bob);
        _burn(address(token), 500e18);
        assertEq(token.balanceOf(address(pyre)), AMOUNT);
    }

    function test_burn_rejectsBadInputs() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ElysianPyre.WrongFee.selector, FEE, 0));
        pyre.burn(address(token), AMOUNT);
        vm.expectRevert(ElysianPyre.ZeroAmount.selector);
        pyre.burn{value: FEE}(address(token), 0);
        vm.expectRevert(ElysianPyre.ZeroAddress.selector);
        pyre.burn{value: FEE}(address(0), AMOUNT);
        vm.stopPrank();
    }

    function test_burn_reentrancyBlocked() public {
        ReentrantERC20 re = new ReentrantERC20();
        re.mint(alice, 2 * AMOUNT);
        vm.prank(alice);
        re.approve(address(pyre), type(uint256).max);
        re.arm(address(pyre), abi.encodeCall(ElysianPyre.withdrawFees, ()));
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        pyre.burn{value: FEE}(address(re), AMOUNT);
    }

    function testFuzz_burn(uint256 amount, bool burnable) public {
        amount = bound(amount, 1, 1e30);
        address t;
        if (burnable) {
            BurnableERC20 b = new BurnableERC20();
            b.mint(alice, amount);
            t = address(b);
        } else {
            MockERC20 m = new MockERC20();
            m.mint(alice, amount);
            t = address(m);
        }
        vm.prank(alice);
        MockERC20(t).approve(address(pyre), amount);
        (uint256 burned, bool reduced) = _burn(t, amount);
        assertEq(burned, amount);
        assertEq(reduced, burnable);
        assertEq(MockERC20(t).balanceOf(address(pyre)), 0);
        assertEq(MockERC20(t).balanceOf(alice), 0);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_lockThenWithdraw(uint256 amount, uint256 duration, uint256 waitAfter) public {
        amount = bound(amount, 1, token.balanceOf(alice));
        duration = bound(duration, 1, pyre.MAX_LOCK_DURATION());
        waitAfter = bound(waitAfter, 0, 365 days);
        uint40 t = _in(duration);
        uint256 id = _lock(amount, t, bob);

        vm.warp(uint256(t) - 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ElysianPyre.StillLocked.selector, t));
        pyre.withdraw(id);

        vm.warp(uint256(t) + waitAfter);
        vm.prank(bob);
        pyre.withdraw(id);
        assertEq(token.balanceOf(bob), amount);
    }

    function testFuzz_unlockTimeBounds(uint40 unlockTime) public {
        bool valid = unlockTime == type(uint40).max
            || (unlockTime > block.timestamp && unlockTime <= block.timestamp + pyre.MAX_LOCK_DURATION());
        vm.prank(alice);
        if (!valid) vm.expectRevert(ElysianPyre.InvalidUnlockTime.selector);
        pyre.lock{value: FEE}(address(token), AMOUNT, unlockTime, bob);
    }
}
