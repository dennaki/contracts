// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title EnniRouter
 * @notice One-tx router for ENNI protocol (enUSD only).
 *
 * - stakeUSDC / stakeUSDT:  → DirectMint → enUSD → Savings (earn 6% APR)
 * - repayUSDC / repayUSDT:  → DirectMint → enUSD → CDP (reduce debt)
 *
 * Design:
 * - Stateless: no funds remain between transactions.
 * - Owner exists only to set Savings address after deployment.
 * - Once Savings is set and ownership renounced, fully immutable.
 * - Beneficiary is always msg.sender — hardcoded, cannot be overridden.
 *
 * Deployment:
 * 1. Deploy Router (owner = deployer, savings = 0x0)
 * 2. Deploy Savings (with Router address)
 * 3. Router.setSavings(savings)
 * 4. Router.renounceOwnership()
 */

interface IEnniDirectMint {
    function mintWithUSDC(uint256 amount) external;
    function mintWithUSDT(uint256 amount) external;
}

interface IEnniSavings {
    function depositFor(uint256 amount, address beneficiary) external;
}

interface IEnniCDP {
    function repayFor(address owner, uint256 amount) external;
}

contract EnniRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;
    IERC20 public immutable USDT;
    IERC20 public immutable enUSD;
    IEnniDirectMint public immutable directMint;
    IEnniCDP public immutable cdp;

    IEnniSavings public savings;
    address public owner;

    // --- events ---
    event Stake(address indexed user, address indexed stableIn, uint256 stableAmount, uint256 enUsdStaked);
    event Repay(address indexed user, address indexed stableIn, uint256 stableAmount, uint256 debtRepaid);
    event SavingsSet(address indexed savings);
    event OwnerTransferred(address indexed oldOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(
        IERC20 usdc_,
        IERC20 usdt_,
        IERC20 enUsd_,
        IEnniDirectMint directMint_,
        IEnniCDP cdp_,
        address owner_
    ) {
        require(address(usdc_) != address(0), "USDC=0");
        require(address(usdt_) != address(0), "USDT=0");
        require(address(enUsd_) != address(0), "enUSD=0");
        require(address(directMint_) != address(0), "DirectMint=0");
        require(address(cdp_) != address(0), "CDP=0");
        require(owner_ != address(0), "owner=0");

        USDC = usdc_;
        USDT = usdt_;
        enUSD = enUsd_;
        directMint = directMint_;
        cdp = cdp_;
        owner = owner_;

        // Approvals that don't depend on Savings
        usdc_.forceApprove(address(directMint_), type(uint256).max);
        usdt_.forceApprove(address(directMint_), type(uint256).max);
        enUsd_.forceApprove(address(cdp_), type(uint256).max);
    }

    // ==================== OWNER ====================

    /// @notice Set the Savings contract. Can only be called once.
    function setSavings(IEnniSavings savings_) external onlyOwner {
        require(address(savings_) != address(0), "savings=0");
        require(address(savings) == address(0), "already set");

        savings = savings_;
        enUSD.forceApprove(address(savings_), type(uint256).max);

        emit SavingsSet(address(savings_));
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "newOwner=0");
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    function renounceOwnership() external onlyOwner {
        require(address(savings) != address(0), "set savings first");
        emit OwnerTransferred(owner, address(0));
        owner = address(0);
    }

    // ==================== STAKE (Savings) ====================

    /// @notice USDC → enUSD → staked in Savings. Position owned by msg.sender.
    function stakeUSDC(uint256 amount) external nonReentrant {
        _stake(USDC, amount, true);
    }

    /// @notice USDT → enUSD → staked in Savings. Position owned by msg.sender.
    function stakeUSDT(uint256 amount) external nonReentrant {
        _stake(USDT, amount, false);
    }

    function _stake(IERC20 stable, uint256 amount, bool isUSDC) internal {
        require(amount > 0, "amount=0");
        require(address(savings) != address(0), "savings not set");

        stable.safeTransferFrom(msg.sender, address(this), amount);

        uint256 received = _mintEnUSD(amount, isUSDC);

        savings.depositFor(received, msg.sender);

        emit Stake(msg.sender, address(stable), amount, received);
    }

    // ==================== REPAY (CDP) ====================

    /// @notice USDC → enUSD → repay CDP debt. Debt owner is msg.sender.
    function repayUSDC(uint256 amount) external nonReentrant {
        _repay(USDC, amount, true);
    }

    /// @notice USDT → enUSD → repay CDP debt. Debt owner is msg.sender.
    function repayUSDT(uint256 amount) external nonReentrant {
        _repay(USDT, amount, false);
    }

    function _repay(IERC20 stable, uint256 amount, bool isUSDC) internal {
        require(amount > 0, "amount=0");

        stable.safeTransferFrom(msg.sender, address(this), amount);

        uint256 received = _mintEnUSD(amount, isUSDC);

        cdp.repayFor(msg.sender, received);

        emit Repay(msg.sender, address(stable), amount, received);
    }

    // ==================== INTERNAL ====================

    function _mintEnUSD(uint256 amount, bool isUSDC) internal returns (uint256 received) {
        uint256 before = enUSD.balanceOf(address(this));

        if (isUSDC) {
            directMint.mintWithUSDC(amount);
        } else {
            directMint.mintWithUSDT(amount);
        }

        received = enUSD.balanceOf(address(this)) - before;
        require(received > 0, "mint failed");
    }

    // Reject raw ETH
    receive() external payable { revert("no ETH"); }
    fallback() external payable { revert("no ETH"); }
}