// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title EnniSavings
 * @notice Fixed 5% APR savings for ENNI stablecoins.
 *
 * - Deposit enUSD (or enCHF), earn 5% APR in newly minted stablecoin.
 * - Deposit and withdraw: instant, no lock.
 * - Claim and compound: 1h cooldown, reset only on deposit.
 * - No cap. No owner. No admin. No upgrades. Immutable.
 *
 * Yield is funded by the protocol's reserve surplus — the positive spread
 * between total collateral value and outstanding liabilities. Calibrated
 * to sovereign benchmark yields. Maintained by protocol-level capital adequacy.
 *
 * Deploy one instance per stablecoin.
 */

interface IEnniStableMintable is IERC20 {
    function mint(address to, uint256 amount) external;
}

contract EnniSavings is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ==================== CONSTANTS ====================

    uint256 public constant BPS = 10_000;
    uint256 public constant ANNUAL_RATE_BPS = 500;             // 5% APR
    uint256 public constant ACC_PRECISION = 1e18;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant CLAIM_COOLDOWN = 1 hours;

    uint256 public constant RATE_PER_SECOND =
        (ANNUAL_RATE_BPS * ACC_PRECISION) / (BPS * SECONDS_PER_YEAR);

    // ==================== STATE ====================

    IEnniStableMintable public immutable stableToken;
    address public immutable router;

    uint256 public totalStaked;
    uint256 public accRewardPerShare;
    uint64  public lastUpdateTime;
    uint256 public totalRewardsMinted;

    struct UserInfo {
        uint256 staked;
        uint256 rewardDebt;
        uint64  lastClaimTime;
        uint256 settled;
    }

    mapping(address => UserInfo) public userInfo;

    // ==================== EVENTS ====================

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Claim(address indexed user, uint256 amount);
    event Compound(address indexed user, uint256 amount);

    // ==================== CONSTRUCTOR ====================

    constructor(IEnniStableMintable stableToken_, address router_) {
        require(address(stableToken_) != address(0), "token=0");
        require(router_ != address(0), "router=0");
        stableToken = stableToken_;
        router = router_;
        lastUpdateTime = uint64(block.timestamp);
    }

    // ==================== PUBLIC ACTIONS ====================

    /// @notice Deposit stablecoins. Instant. Resets 1h claim cooldown.
    function deposit(uint256 amount) external nonReentrant {
        _deposit(amount, msg.sender);
    }

    /// @notice Deposit on behalf of beneficiary. Router only.
    /// @dev Tokens pulled from msg.sender (Router). Position credited to beneficiary.
    function depositFor(uint256 amount, address beneficiary) external nonReentrant {
        require(msg.sender == router, "only router");
        require(beneficiary != address(0), "beneficiary=0");
        require(beneficiary != address(this), "beneficiary=self");
        _deposit(amount, beneficiary);
    }

    /// @notice Withdraw stablecoins. Instant. Pending rewards settle to u.settled.
    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0, "amount=0");

        UserInfo storage u = userInfo[msg.sender];
        require(u.staked >= amount, "withdraw>staked");

        _updateRewards();
        _settle(msg.sender);

        u.staked -= amount;
        totalStaked -= amount;
        u.rewardDebt = _debt(u.staked);

        IERC20(address(stableToken)).safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount);
    }

    /// @notice Claim settled rewards. Requires 1h since last deposit.
    function claim() external nonReentrant {
        _updateRewards();
        _settle(msg.sender);

        UserInfo storage u = userInfo[msg.sender];
        require(block.timestamp >= u.lastClaimTime + CLAIM_COOLDOWN, "1h");

        uint256 amount = u.settled;
        require(amount > 0, "nothing");

        u.settled = 0;
        totalRewardsMinted += amount;

        uint256 before = IERC20(address(stableToken)).balanceOf(msg.sender);
        stableToken.mint(msg.sender, amount);
        require(
            IERC20(address(stableToken)).balanceOf(msg.sender) >= before + amount,
            "mint failed"
        );

        emit Claim(msg.sender, amount);
    }

    /// @notice Compound settled rewards into staked balance. Requires 1h since last deposit.
    function compound() external nonReentrant {
        _updateRewards();
        _settle(msg.sender);

        UserInfo storage u = userInfo[msg.sender];
        require(block.timestamp >= u.lastClaimTime + CLAIM_COOLDOWN, "1h");

        uint256 amount = u.settled;
        require(amount > 0, "nothing");

        u.settled = 0;
        totalRewardsMinted += amount;

        uint256 before = IERC20(address(stableToken)).balanceOf(address(this));
        stableToken.mint(address(this), amount);
        require(
            IERC20(address(stableToken)).balanceOf(address(this)) >= before + amount,
            "mint failed"
        );

        u.staked += amount;
        totalStaked += amount;
        u.rewardDebt = _debt(u.staked);

        emit Compound(msg.sender, amount);
    }

    // ==================== VIEWS ====================

    /// @notice Pending rewards (settled + unsettled) for a user.
    function pending(address user) external view returns (uint256) {
        UserInfo memory u = userInfo[user];

        uint256 _acc = accRewardPerShare;
        if (block.timestamp > lastUpdateTime && totalStaked > 0) {
            _acc += (block.timestamp - lastUpdateTime) * RATE_PER_SECOND;
        }

        uint256 accumulated = (u.staked * _acc) / ACC_PRECISION;
        uint256 unsettled = accumulated > u.rewardDebt ? (accumulated - u.rewardDebt) : 0;

        return u.settled + unsettled;
    }

    // ==================== INTERNAL ====================

    function _deposit(uint256 amount, address beneficiary) internal {
        require(amount > 0, "amount=0");

        _updateRewards();
        _settle(beneficiary);

        IERC20(address(stableToken)).safeTransferFrom(msg.sender, address(this), amount);

        UserInfo storage u = userInfo[beneficiary];
        u.staked += amount;
        totalStaked += amount;
        u.rewardDebt = _debt(u.staked);
        u.lastClaimTime = uint64(block.timestamp);

        emit Deposit(beneficiary, amount);
    }

    function _updateRewards() internal {
        uint64 now_ = uint64(block.timestamp);
        if (now_ > lastUpdateTime) {
            if (totalStaked > 0) {
                accRewardPerShare += (now_ - lastUpdateTime) * RATE_PER_SECOND;
            }
            lastUpdateTime = now_;
        }
    }

    function _settle(address user) internal {
        UserInfo storage u = userInfo[user];
        if (u.staked > 0) {
            uint256 accumulated = (u.staked * accRewardPerShare) / ACC_PRECISION;
            uint256 unsettled = accumulated > u.rewardDebt ? (accumulated - u.rewardDebt) : 0;
            if (unsettled > 0) {
                u.settled += unsettled;
            }
            u.rewardDebt = accumulated;
        }
    }

    function _debt(uint256 staked) internal view returns (uint256) {
        return (staked * accRewardPerShare) / ACC_PRECISION;
    }

    // ==================== REJECTIONS ====================

    receive() external payable { revert("No ETH"); }
    fallback() external payable { revert("No ETH"); }
}
