// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Pons (PONS)
/// @notice A fixed-supply ERC-20 token. The whole supply, 1,000,000,000 PONS with 18 decimals, is
/// minted once to the deployer in the constructor. There is no owner, no minting after deployment,
/// no pause, no blocklist, no fee and no burn: the contract is a plain, immutable ERC-20.
/// @dev Self-contained on purpose: no external library, no delegatecall, no selfdestruct, no
/// proxy. The deployer is `msg.sender` of the constructor, which at launch is the ProjectFactory
/// that pays the supply out. The contract name is `PonsToken`; the token's `name()` is "Pons".
contract PonsToken {
    // ──────────────────────────────────────────────────────────────────────────
    // ERC-20 events
    // ──────────────────────────────────────────────────────────────────────────

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ──────────────────────────────────────────────────────────────────────────
    // Errors (ERC-6093 names)
    // ──────────────────────────────────────────────────────────────────────────

    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error ERC20InvalidSender(address sender);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InvalidApprover(address approver);
    error ERC20InvalidSpender(address spender);

    // ──────────────────────────────────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────────────────────────────────

    string public constant name = "Pons";
    string public constant symbol = "PONS";
    uint8 public constant decimals = 18;

    /// @notice The fixed total supply: one billion tokens in minor units (18 decimals).
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    // ──────────────────────────────────────────────────────────────────────────
    // Storage
    // ──────────────────────────────────────────────────────────────────────────

    mapping(address account => uint256) private _balances;
    mapping(address owner => mapping(address spender => uint256)) private _allowances;

    // ──────────────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Mints the whole supply to the deployer. Nothing else can ever mint.
    constructor() {
        _balances[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // ERC-20 views
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice The total supply never changes: there is no mint and no burn.
    function totalSupply() external pure returns (uint256) {
        return TOTAL_SUPPLY;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    // ──────────────────────────────────────────────────────────────────────────
    // ERC-20 mutators
    // ──────────────────────────────────────────────────────────────────────────

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value);
        return true;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Internals
    // ──────────────────────────────────────────────────────────────────────────

    function _transfer(address from, address to, uint256 value) private {
        if (from == address(0)) revert ERC20InvalidSender(address(0));
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));

        uint256 fromBalance = _balances[from];
        if (fromBalance < value) revert ERC20InsufficientBalance(from, fromBalance, value);
        unchecked {
            // Cannot underflow: checked above.
            _balances[from] = fromBalance - value;
            // Cannot overflow: the sum of all balances is TOTAL_SUPPLY, which fits in uint256.
            _balances[to] += value;
        }

        emit Transfer(from, to, value);
    }

    function _approve(address owner, address spender, uint256 value) private {
        if (owner == address(0)) revert ERC20InvalidApprover(address(0));
        if (spender == address(0)) revert ERC20InvalidSpender(address(0));
        _allowances[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    /// @dev An allowance of type(uint256).max is treated as infinite and is not decremented.
    function _spendAllowance(address owner, address spender, uint256 value) private {
        uint256 current = _allowances[owner][spender];
        if (current == type(uint256).max) return;
        if (current < value) revert ERC20InsufficientAllowance(spender, current, value);
        unchecked {
            _allowances[owner][spender] = current - value;
        }
        emit Approval(owner, spender, current - value);
    }
}
