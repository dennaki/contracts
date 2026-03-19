// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title EnniRouter
 * @notice Unified one-tx router for ENNI protocol.
 *
 * Functions:
 * - stakeUSDC / stakeUSDT  → DirectMint → enUSD → MasterChef (earn ENNI)
 * - repayUSDC / repayUSDT  → DirectMint → enUSD → CDP (reduce debt)
 *
 * Design:
 * - Stateless: no funds remain between transactions.
 * - Immutable: no owner, no admin, no upgrades.
 * - Beneficiary is always msg.sender — hardcoded, cannot be overridden.
 */

interface IEnniDirectMint {
    function mintWithUSDC(uint256 amount) external;
    function mintWithUSDT(uint256 amount) external;
}

interface IEnniMasterChef {
    function depositFor(uint256 pid, uint256 amount, address beneficiary) external;
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
    IEnniMasterChef public immutable masterChef;
    IEnniCDP public immutable cdp;

    uint256 public immutable enUsdPoolId;

    // --- events ---
    event Stake(address indexed user, address indexed stableIn, uint256 stableAmount, uint256 enUsdStaked);
    event Repay(address indexed user, address indexed stableIn, uint256 stableAmount, uint256 debtRepaid);

    constructor(
        IERC20 usdc_,
        IERC20 usdt_,
        IERC20 enUsd_,
        IEnniDirectMint directMint_,
        IEnniMasterChef masterChef_,
        IEnniCDP cdp_,
        uint256 enUsdPoolId_
    ) {
        require(address(usdc_) != address(0), "USDC=0");
        require(address(usdt_) != address(0), "USDT=0");
        require(address(enUsd_) != address(0), "enUSD=0");
        require(address(directMint_) != address(0), "DirectMint=0");
        require(address(masterChef_) != address(0), "MasterChef=0");
        require(address(cdp_) != address(0), "CDP=0");

        USDC = usdc_;
        USDT = usdt_;
        enUSD = enUsd_;
        directMint = directMint_;
        masterChef = masterChef_;
        cdp = cdp_;
        enUsdPoolId = enUsdPoolId_;

        // One-time approvals
        usdc_.forceApprove(address(directMint_), type(uint256).max);
        usdt_.forceApprove(address(directMint_), type(uint256).max);
        enUsd_.forceApprove(address(masterChef_), type(uint256).max);
        enUsd_.forceApprove(address(cdp_), type(uint256).max);
    }

    // ==================== STAKE (Savings) ====================

    /// @notice USDC → enUSD → staked in MasterChef. Position owned by msg.sender.
    function stakeUSDC(uint256 amount) external nonReentrant {
        _stake(USDC, amount, true);
    }

    /// @notice USDT → enUSD → staked in MasterChef. Position owned by msg.sender.
    function stakeUSDT(uint256 amount) external nonReentrant {
        _stake(USDT, amount, false);
    }

    function _stake(IERC20 stable, uint256 amount, bool isUSDC) internal {
        require(amount > 0, "amount=0");

        stable.safeTransferFrom(msg.sender, address(this), amount);

        uint256 enUsdReceived = _mintEnUSD(amount, isUSDC);

        masterChef.depositFor(enUsdPoolId, enUsdReceived, msg.sender);

        emit Stake(msg.sender, address(stable), amount, enUsdReceived);
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

        uint256 enUsdReceived = _mintEnUSD(amount, isUSDC);

        cdp.repayFor(msg.sender, enUsdReceived);

        emit Repay(msg.sender, address(stable), amount, enUsdReceived);
    }

    // ==================== SHARED ====================

    /// @dev Pull is already done by caller. Mints enUSD via DirectMint.
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