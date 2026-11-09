// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Burns 1% of every transfer, so the receiver gets less than `amount`.
contract FeeOnTransferERC20 is ERC20 {
    constructor() ERC20("Taxed", "TAX") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 burnt = value / 100;
            super._update(from, address(0), burnt);
            value -= burnt;
        }
        super._update(from, to, value);
    }
}

/// @dev Tries to re-enter the locker during a transfer.
contract ReentrantERC20 is ERC20 {
    address public target;
    bytes public payload;

    constructor() ERC20("Reenter", "RE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (target != address(0)) {
            address t = target;
            target = address(0);
            (bool ok, bytes memory ret) = t.call(payload);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }
}

/// @dev A fee recipient that refuses native currency.
contract RejectNative {}

/// @dev Standard token with a real burn(uint256) that lowers totalSupply.
contract BurnableERC20 is ERC20 {
    constructor() ERC20("Burnable", "BURN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

/// @dev Has a burn(uint256) that returns successfully but does nothing.
contract FakeBurnERC20 is ERC20 {
    constructor() ERC20("FakeBurn", "FAKE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256) external pure returns (bool) {
        return true;
    }
}

/// @dev burn(uint256) destroys only half of what it is asked to.
contract HalfBurnERC20 is ERC20 {
    constructor() ERC20("HalfBurn", "HALF") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount / 2);
    }
}
