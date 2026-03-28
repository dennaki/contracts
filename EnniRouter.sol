// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title EnniRouter
 * @notice One-tx router for ENNI protocol.
 *
 * USD path:
 * - stakeUSDC / stakeUSDT:  → DirectMint → enUSD → Savings(enUSD)
 * - repayUSDC / repayUSDT:  → DirectMint → enUSD → CDP(enUSD)
 *
 * CHF path:
 * - stakeZCHF:  → DirectMintGeneric → enCHF → Savings(enCHF)
 * - repayZCHF:  → DirectMintGeneric → enCHF → CDP(enCHF)
 *
 * Design:
 * - Stateless: no funds remain between transactions.
 * - Owner exists only to set Savings addresses after deployment.
 * - Once both Savings are set and ownership renounced, fully immutable.
 * - Beneficiary is always msg.sender — hardcoded, cannot be overridden.
 *
 * Deployment:
 * 1. Deploy Router (owner = deployer, both savings = 0x0)
 * 2. Deploy Savings(enUSD) with Router address
 * 3. Deploy Savings(enCHF) with Router address
 * 4. Router.setSavingsUSD(savingsUSD)
 * 5. Router.setSavingsCHF(savingsCHF)
 * 6. Router.renounceOwnership()
 */

interface IEnniDirectMint {
    function mintWithUSDC(uint256 amount) external;
    function mintWithUSDT(uint256 amount) external;
}

interface IEnniDirectMintGeneric {
    function mint(uint256 amount) external;
}

interface IEnniSavings {
    function depositFor(uint256 amount, address beneficiary) external;
}

interface IEnniCDP {
    function repayFor(address owner, uint256 amount) external;
}

contract EnniRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- USD immutables ---
    IERC20 public immutable USDC;
    IERC20 public immutable USDT;
    IERC20 public immutable enUSD;
    IEnniDirectMint public immutable directMintUSD;
    IEnniCDP public immutable cdpUSD;

    // --- CHF immutables ---
    IERC20 public immutable ZCHF;
    IERC20 public immutable enCHF;
    IEnniDirectMintGeneric public immutable directMintCHF;
    IEnniCDP public immutable cdpCHF;

    // --- set by owner, then locked ---
    IEnniSavings public savingsUSD;
    IEnniSavings public savingsCHF;
    address public owner;

    // --- events ---
    event Stake(address indexed user, address indexed stableIn, uint256 stableAmount, uint256 enStableStaked);
    event Repay(address indexed user, address indexed stableIn, uint256 stableAmount, uint256 debtRepaid);
    event SavingsUSDSet(address indexed savings);
    event SavingsCHFSet(address indexed savings);
    event OwnerTransferred(address indexed oldOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(
        IERC20 usdc_,
        IERC20 usdt_,
        IERC20 enUsd_,
        IEnniDirectMint directMintUSD_,
        IEnniCDP cdpUSD_,
        IERC20 zchf_,
        IERC20 enChf_,
        IEnniDirectMintGeneric directMintCHF_,
        IEnniCDP cdpCHF_,
        address owner_
    ) {
        require(address(usdc_) != address(0), "USDC=0");
        require(address(usdt_) != address(0), "USDT=0");
        require(address(enUsd_) != address(0), "enUSD=0");
        require(address(directMintUSD_) != address(0), "DirectMintUSD=0");
        require(address(cdpUSD_) != address(0), "CDP_USD=0");
        require(address(zchf_) != address(0), "ZCHF=0");
        require(address(enChf_) != address(0), "enCHF=0");
        require(address(directMintCHF_) != address(0), "DirectMintCHF=0");
        require(address(cdpCHF_) != address(0), "CDP_CHF=0");
        require(owner_ != address(0), "owner=0");

        USDC = usdc_;
        USDT = usdt_;
        enUSD = enUsd_;
        directMintUSD = directMintUSD_;
        cdpUSD = cdpUSD_;

        ZCHF = zchf_;
        enCHF = enChf_;
        directMintCHF = directMintCHF_;
        cdpCHF = cdpCHF_;

        owner = owner_;

        // USD approvals (savings deferred)
        usdc_.forceApprove(address(directMintUSD_), type(uint256).max);
        usdt_.forceApprove(address(directMintUSD_), type(uint256).max);
        enUsd_.forceApprove(address(cdpUSD_), type(uint256).max);

        // CHF approvals (savings deferred)
        zchf_.forceApprove(address(directMintCHF_), type(uint256).max);
        enChf_.forceApprove(address(cdpCHF_), type(uint256).max);
    }

    // ==================== OWNER ====================

    /// @notice Set the enUSD Savings contract. Can only be called once.
    function setSavingsUSD(IEnniSavings savings_) external onlyOwner {
        require(address(savings_) != address(0), "savings=0");
        require(address(savingsUSD) == address(0), "already set");

        savingsUSD = savings_;
        enUSD.forceApprove(address(savings_), type(uint256).max);

        emit SavingsUSDSet(address(savings_));
    }

    /// @notice Set the enCHF Savings contract. Can only be called once.
    function setSavingsCHF(IEnniSavings savings_) external onlyOwner {
        require(address(savings_) != address(0), "savings=0");
        require(address(savingsCHF) == address(0), "already set");

        savingsCHF = savings_;
        enCHF.forceApprove(address(savings_), type(uint256).max);

        emit SavingsCHFSet(address(savings_));
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "newOwner=0");
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    function renounceOwnership() external onlyOwner {
        require(address(savingsUSD) != address(0), "set savingsUSD first");
        require(address(savingsCHF) != address(0), "set savingsCHF first");
        emit OwnerTransferred(owner, address(0));
        owner = address(0);
    }

    // ==================== USD: STAKE (Savings) ====================

    /// @notice USDC → enUSD → staked in Savings(enUSD). Position owned by msg.sender.
    function stakeUSDC(uint256 amount) external nonReentrant {
        _stakeUSD(USDC, amount, true);
    }

    /// @notice USDT → enUSD → staked in Savings(enUSD). Position owned by msg.sender.
    function stakeUSDT(uint256 amount) external nonReentrant {
        _stakeUSD(USDT, amount, false);
    }

    function _stakeUSD(IERC20 stable, uint256 amount, bool isUSDC) internal {
        require(amount > 0, "amount=0");
        require(address(savingsUSD) != address(0), "savingsUSD not set");

        stable.safeTransferFrom(msg.sender, address(this), amount);

        uint256 received = _mintEnUSD(amount, isUSDC);

        savingsUSD.depositFor(received, msg.sender);

        emit Stake(msg.sender, address(stable), amount, received);
    }

    // ==================== USD: REPAY (CDP) ====================

    /// @notice USDC → enUSD → repay CDP(enUSD) debt. Debt owner is msg.sender.
    function repayUSDC(uint256 amount) external nonReentrant {
        _repayUSD(USDC, amount, true);
    }

    /// @notice USDT → enUSD → repay CDP(enUSD) debt. Debt owner is msg.sender.
    function repayUSDT(uint256 amount) external nonReentrant {
        _repayUSD(USDT, amount, false);
    }

    function _repayUSD(IERC20 stable, uint256 amount, bool isUSDC) internal {
        require(amount > 0, "amount=0");

        stable.safeTransferFrom(msg.sender, address(this), amount);

        uint256 received = _mintEnUSD(amount, isUSDC);

        cdpUSD.repayFor(msg.sender, received);

        emit Repay(msg.sender, address(stable), amount, received);
    }

    // ==================== CHF: STAKE (Savings) ====================

    /// @notice ZCHF → enCHF → staked in Savings(enCHF). Position owned by msg.sender.
    function stakeZCHF(uint256 amount) external nonReentrant {
        require(amount > 0, "amount=0");
        require(address(savingsCHF) != address(0), "savingsCHF not set");

        ZCHF.safeTransferFrom(msg.sender, address(this), amount);

        uint256 received = _mintEnCHF(amount);

        savingsCHF.depositFor(received, msg.sender);

        emit Stake(msg.sender, address(ZCHF), amount, received);
    }

    // ==================== CHF: REPAY (CDP) ====================

    /// @notice ZCHF → enCHF → repay CDP(enCHF) debt. Debt owner is msg.sender.
    function repayZCHF(uint256 amount) external nonReentrant {
        require(amount > 0, "amount=0");

        ZCHF.safeTransferFrom(msg.sender, address(this), amount);

        uint256 received = _mintEnCHF(amount);

        cdpCHF.repayFor(msg.sender, received);

        emit Repay(msg.sender, address(ZCHF), amount, received);
    }

    // ==================== INTERNAL ====================

    function _mintEnUSD(uint256 amount, bool isUSDC) internal returns (uint256 received) {
        uint256 before = enUSD.balanceOf(address(this));

        if (isUSDC) {
            directMintUSD.mintWithUSDC(amount);
        } else {
            directMintUSD.mintWithUSDT(amount);
        }

        received = enUSD.balanceOf(address(this)) - before;
        require(received > 0, "mint failed");
    }

    function _mintEnCHF(uint256 amount) internal returns (uint256 received) {
        uint256 before = enCHF.balanceOf(address(this));

        directMintCHF.mint(amount);

        received = enCHF.balanceOf(address(this)) - before;
        require(received > 0, "mint failed");
    }

    // Reject raw ETH
    receive() external payable { revert("no ETH"); }
    fallback() external payable { revert("no ETH"); }
}