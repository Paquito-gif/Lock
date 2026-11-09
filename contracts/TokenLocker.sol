// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title TokenLocker
/// @notice Locks ERC-20 tokens until a fixed date. After that date the lock owner withdraws everything at once.
/// @dev Design guarantees:
///      - The admin (contract owner) can only change the creation fee (capped by MAX_FEE) and the fee recipient.
///        It has no function that touches locked tokens, and there is no pause.
///      - A lock can never be shortened or canceled. It can only be extended by its owner.
///      - Fee-on-transfer tokens are rejected at creation. Rebasing tokens are not supported.
contract TokenLocker is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Lock {
        address token;
        uint40 unlockTime;
        bool withdrawn;
        address owner;
        uint256 amount;
    }

    /// @notice Hard cap on the creation fee, in native currency (HYPE on Elysium). Cannot be changed.
    uint256 public constant MAX_FEE = 1 ether;
    /// @notice Longest allowed lock, to catch obvious mistakes (e.g. a timestamp in milliseconds).
    uint256 public constant MAX_LOCK_DURATION = 100 * 365 days;

    /// @notice Native-currency fee charged per lock creation.
    uint256 public fee;
    /// @notice Address that receives the collected fees.
    address public feeRecipient;

    Lock[] private _locks;
    mapping(address user => uint256[] ids) private _userLockIds;
    mapping(address token => uint256[] ids) private _tokenLockIds;

    event Locked(
        uint256 indexed id,
        address indexed token,
        address indexed owner,
        address creator,
        uint256 amount,
        uint40 unlockTime
    );
    event Withdrawn(uint256 indexed id, address indexed owner, uint256 amount);
    event LockExtended(uint256 indexed id, uint40 oldUnlockTime, uint40 newUnlockTime);
    event LockTransferred(uint256 indexed id, address indexed from, address indexed to);
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);
    event FeesWithdrawn(address indexed recipient, uint256 amount);

    error ZeroAmount();
    error ZeroAddress();
    error InvalidUnlockTime();
    error WrongFee(uint256 expected, uint256 sent);
    error FeeTooHigh();
    error UnsupportedToken();
    error LockNotFound();
    error NotLockOwner();
    error StillLocked(uint40 unlockTime);
    error AlreadyWithdrawn();
    error NothingToWithdraw();
    error NativeTransferFailed();

    constructor(address initialOwner, address initialFeeRecipient, uint256 initialFee) Ownable(initialOwner) {
        if (initialFeeRecipient == address(0)) revert ZeroAddress();
        if (initialFee > MAX_FEE) revert FeeTooHigh();
        feeRecipient = initialFeeRecipient;
        fee = initialFee;
        emit FeeRecipientUpdated(address(0), initialFeeRecipient);
        emit FeeUpdated(0, initialFee);
    }

    // ---------------------------------------------------------------------
    // Lock lifecycle
    // ---------------------------------------------------------------------

    /// @notice Locks `amount` of `token` until `unlockTime`, owned by `lockOwner`.
    /// @dev The caller must approve this contract for `amount` beforehand and send exactly `fee` in native currency.
    function lock(address token, uint256 amount, uint40 unlockTime, address lockOwner)
        external
        payable
        nonReentrant
        returns (uint256 id)
    {
        if (msg.value != fee) revert WrongFee(fee, msg.value);
        if (token == address(0) || lockOwner == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _checkUnlockTime(unlockTime);

        IERC20 t = IERC20(token);
        uint256 balanceBefore = t.balanceOf(address(this));
        t.safeTransferFrom(msg.sender, address(this), amount);
        if (t.balanceOf(address(this)) - balanceBefore != amount) revert UnsupportedToken();

        id = _locks.length;
        _locks.push(
            Lock({token: token, unlockTime: unlockTime, withdrawn: false, owner: lockOwner, amount: amount})
        );
        _userLockIds[lockOwner].push(id);
        _tokenLockIds[token].push(id);

        emit Locked(id, token, lockOwner, msg.sender, amount, unlockTime);
    }

    /// @notice Withdraws all tokens of lock `id` to its owner, once the unlock time has passed.
    function withdraw(uint256 id) external nonReentrant {
        Lock storage l = _getLock(id);
        if (msg.sender != l.owner) revert NotLockOwner();
        if (l.withdrawn) revert AlreadyWithdrawn();
        if (block.timestamp < l.unlockTime) revert StillLocked(l.unlockTime);

        l.withdrawn = true;
        uint256 amount = l.amount;
        IERC20(l.token).safeTransfer(msg.sender, amount);

        emit Withdrawn(id, msg.sender, amount);
    }

    /// @notice Pushes the unlock time of lock `id` further into the future. It can never be brought forward.
    function extendLock(uint256 id, uint40 newUnlockTime) external {
        Lock storage l = _getLock(id);
        if (msg.sender != l.owner) revert NotLockOwner();
        if (l.withdrawn) revert AlreadyWithdrawn();
        if (newUnlockTime <= l.unlockTime) revert InvalidUnlockTime();
        _checkUnlockTime(newUnlockTime);

        uint40 old = l.unlockTime;
        l.unlockTime = newUnlockTime;
        emit LockExtended(id, old, newUnlockTime);
    }

    /// @notice Hands lock `id` over to `to`, who becomes the only address able to withdraw or extend it.
    function transferLock(uint256 id, address to) external {
        Lock storage l = _getLock(id);
        if (msg.sender != l.owner) revert NotLockOwner();
        if (l.withdrawn) revert AlreadyWithdrawn();
        if (to == address(0) || to == address(this)) revert ZeroAddress();

        l.owner = to;
        _userLockIds[to].push(id);
        emit LockTransferred(id, msg.sender, to);
    }

    // ---------------------------------------------------------------------
    // Fees (the only admin surface)
    // ---------------------------------------------------------------------

    function setFee(uint256 newFee) external onlyOwner {
        if (newFee > MAX_FEE) revert FeeTooHigh();
        emit FeeUpdated(fee, newFee);
        fee = newFee;
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    /// @notice Sends all collected fees to `feeRecipient`. Anyone may call it.
    /// @dev The contract never holds native currency for any other purpose, so its whole balance is fees.
    function withdrawFees() external nonReentrant {
        uint256 amount = address(this).balance;
        if (amount == 0) revert NothingToWithdraw();
        address recipient = feeRecipient;
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
        emit FeesWithdrawn(recipient, amount);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function lockCount() external view returns (uint256) {
        return _locks.length;
    }

    function getLock(uint256 id) external view returns (Lock memory) {
        return _getLock(id);
    }

    /// @notice Number of entries in the lock-id list of `user`.
    /// @dev The list is append-only: it also keeps locks the user later transferred away.
    ///      Check `getLock(id).owner` to know who owns a lock today.
    function userLockCount(address user) external view returns (uint256) {
        return _userLockIds[user].length;
    }

    function userLockIds(address user, uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        return _slice(_userLockIds[user], offset, limit);
    }

    function tokenLockCount(address token) external view returns (uint256) {
        return _tokenLockIds[token].length;
    }

    function tokenLockIds(address token, uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        return _slice(_tokenLockIds[token], offset, limit);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _getLock(uint256 id) private view returns (Lock storage) {
        if (id >= _locks.length) revert LockNotFound();
        return _locks[id];
    }

    function _checkUnlockTime(uint40 unlockTime) private view {
        if (unlockTime <= block.timestamp || unlockTime > block.timestamp + MAX_LOCK_DURATION) {
            revert InvalidUnlockTime();
        }
    }

    function _slice(uint256[] storage arr, uint256 offset, uint256 limit) private view returns (uint256[] memory out) {
        uint256 len = arr.length;
        if (offset >= len) return new uint256[](0);
        uint256 end = limit > len - offset ? len : offset + limit;
        out = new uint256[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            out[i - offset] = arr[i];
        }
    }
}
