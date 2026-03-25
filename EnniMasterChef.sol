// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IMintableERC20 is IERC20 {
    function mint(address to, uint256 amount) external;
}

/**
 * EnniMasterChef (single reward token: ENNI)
 *
 * Emission schedule (30 years, 365d "year"):
 * - Years  1- 2: 2,000,000 ENNI / year
 * - Years  3-10: 1,000,000 ENNI / year
 * - Years 11-30:   400,000 ENNI / year
 *
 * Notes:
 * - Global schedule only. All pools stop earning after global endTime.
 * - Pools use allocPoint share of global emissions.
 * - Uses totalStaked accounting (prevents reward skew if LP is transferred directly to the contract).
 * - Deposit measures received amount to support fee-on-transfer LP tokens.
 * - Withdraw transfers requested amount; fee-on-transfer LP may deliver less to the receiver.
 * - Emissions are clamped by MAX_CHEF_MINT so the Chef never intentionally mints above its budget.
 * - depositFor() allows approved routers (e.g. Zap contracts) to deposit on behalf of a user.
 */
contract EnniMasterChef is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------- constants ----------------
    uint256 public constant ACC_PRECISION = 1e12;

    // Keep pool count small to keep admin ops and gas predictable.
    uint256 public constant MAX_POOLS = 8;

    // We define "year" as 365 days for emission math.
    uint256 private constant YEAR = 365 days;

    // Chef-only mint budget (does not include premint done elsewhere).
    // Assumes ENNI has 18 decimals.
    uint256 public constant MAX_CHEF_MINT = 20_000_000e18;

    // Emissions per year
    uint256 private constant PHASE1_YEARLY = 2_000_000e18; // years 1-2
    uint256 private constant PHASE2_YEARLY = 1_000_000e18; // years 3-10
    uint256 private constant PHASE3_YEARLY =   400_000e18; // years 11-30

    // ---------------- immutables ----------------
    IMintableERC20 public immutable enni;

    uint64 public immutable startTime;
    uint64 public immutable phase1EndTime; // start + 2y
    uint64 public immutable phase2EndTime; // start + 10y
    uint64 public immutable endTime;       // start + 30y

    // ---------------- storage ----------------
    struct PoolInfo {
        IERC20 lpToken;
        uint96 allocPoint;
        uint64 lastRewardTime;
        uint256 accEnniPerShare; // scaled by ACC_PRECISION
        uint256 totalStaked;     // tracked deposits (not raw token balance)
    }

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // duplicate protection
    mapping(IERC20 => bool) public isLpAdded;

    // sum of allocPoint across all pools
    uint256 public totalAllocPoint;

    // total minted by this Chef (clamped to MAX_CHEF_MINT)
    uint256 public mintedByChef;

    // ---------------- events ----------------
    event PoolAdded(uint256 indexed pid, address indexed lpToken, uint256 allocPoint);
    event PoolUpdated(uint256 indexed pid, uint256 allocPoint);

    event Deposit(address indexed user, uint256 indexed pid, uint256 amountIn);
    event DepositFor(address indexed caller, address indexed beneficiary, uint256 indexed pid, uint256 amountIn);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amountOut);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amountOut);

    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);

    // ---------------- constructor ----------------
    constructor(IMintableERC20 enni_, uint64 startTime_) Ownable(msg.sender) {
        require(address(enni_) != address(0), "ENNI=0");
        require(IERC20Metadata(address(enni_)).decimals() == 18, "ENNI decimals");

        enni = enni_;
        startTime = startTime_;

        phase1EndTime = startTime_ + uint64(2 * YEAR);
        phase2EndTime = startTime_ + uint64(10 * YEAR);
        endTime       = startTime_ + uint64(30 * YEAR);

        require(startTime_ < endTime, "bad time");
    }

    // ---------------- views ----------------
    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function _requirePid(uint256 pid) internal view {
        require(pid < poolInfo.length, "bad pid");
    }

    function _clampToGlobal(uint64 t) internal view returns (uint64) {
        if (t < startTime) return startTime;
        if (t > endTime) return endTime;
        return t;
    }

    function _segmentEmission(
        uint64 from,
        uint64 to,
        uint64 segStart,
        uint64 segEnd,
        uint256 yearly
    ) internal pure returns (uint256) {
        if (to <= segStart || from >= segEnd) return 0;

        uint64 a = from > segStart ? from : segStart;
        uint64 b = to   < segEnd   ? to   : segEnd;
        if (b <= a) return 0;

        uint256 secs = uint256(b - a);
        return Math.mulDiv(secs, yearly, YEAR);
    }

    function _globalEmissionBetween(uint64 from, uint64 to) internal view returns (uint256) {
        if (to <= from) return 0;
        if (to <= startTime || from >= endTime) return 0;

        uint64 a = from < startTime ? startTime : from;
        uint64 b = to   > endTime   ? endTime   : to;
        if (b <= a) return 0;

        uint256 r = 0;
        r += _segmentEmission(a, b, startTime,      phase1EndTime, PHASE1_YEARLY);
        r += _segmentEmission(a, b, phase1EndTime,  phase2EndTime, PHASE2_YEARLY);
        r += _segmentEmission(a, b, phase2EndTime,  endTime,       PHASE3_YEARLY);
        return r;
    }

    // pool share of global emission between [from,to)
    function _poolRewardBetween(uint256 pid, uint64 from, uint64 to) internal view returns (uint256) {
        if (to <= from) return 0;

        uint256 _totalAlloc = totalAllocPoint;
        if (_totalAlloc == 0) return 0;

        uint256 emission = _globalEmissionBetween(from, to);
        if (emission == 0) return 0;

        uint256 poolAlloc = uint256(poolInfo[pid].allocPoint);
        if (poolAlloc == 0) return 0;

        return Math.mulDiv(emission, poolAlloc, _totalAlloc);
    }

    function _pendingEnni(uint256 pid, address user) internal view returns (uint256) {
        PoolInfo memory pool = poolInfo[pid];
        UserInfo memory u = userInfo[pid][user];

        uint64 toTime = _clampToGlobal(uint64(block.timestamp));
        uint256 acc = pool.accEnniPerShare;

        if (
            toTime > pool.lastRewardTime &&
            pool.totalStaked > 0 &&
            pool.allocPoint > 0 &&
            totalAllocPoint > 0
        ) {
            uint256 r = _poolRewardBetween(pid, pool.lastRewardTime, toTime);

            // clamp by remaining chef budget (view approximation)
            if (mintedByChef >= MAX_CHEF_MINT) r = 0;
            else {
                uint256 remaining = MAX_CHEF_MINT - mintedByChef;
                if (r > remaining) r = remaining;
            }

            if (r > 0) acc += Math.mulDiv(r, ACC_PRECISION, pool.totalStaked);
        }

        uint256 accumulated = Math.mulDiv(u.amount, acc, ACC_PRECISION);
        return accumulated > u.rewardDebt ? (accumulated - u.rewardDebt) : 0;
    }

    function pendingEnni(uint256 pid, address user) external view returns (uint256) {
        _requirePid(pid);
        return _pendingEnni(pid, user);
    }

    // ---------------- admin (owner) ----------------
    function addPool(uint96 allocPoint, IERC20 lpToken) external onlyOwner {
        require(poolInfo.length < MAX_POOLS, "too many pools");
        require(address(lpToken) != address(0), "lp=0");
        require(!isLpAdded[lpToken], "lp exists");

        // settle existing pools before changing allocation shares
        massUpdatePools();

        isLpAdded[lpToken] = true;

        uint64 last = _clampToGlobal(uint64(block.timestamp));

        poolInfo.push(
            PoolInfo({
                lpToken: lpToken,
                allocPoint: allocPoint,
                lastRewardTime: last,
                accEnniPerShare: 0,
                totalStaked: 0
            })
        );

        totalAllocPoint += uint256(allocPoint);

        emit PoolAdded(poolInfo.length - 1, address(lpToken), allocPoint);
    }

    function setPool(uint256 pid, uint96 allocPoint) external onlyOwner {
        _requirePid(pid);

        massUpdatePools();

        uint256 prev = uint256(poolInfo[pid].allocPoint);
        poolInfo[pid].allocPoint = allocPoint;

        totalAllocPoint = totalAllocPoint - prev + uint256(allocPoint);

        emit PoolUpdated(pid, allocPoint);
    }

    // ---------------- core accounting ----------------
    function massUpdatePools() public {
        uint256 len = poolInfo.length;
        for (uint256 pid = 0; pid < len; pid++) {
            _updatePool(pid);
        }
    }

    function updatePool(uint256 pid) external {
        _requirePid(pid);
        _updatePool(pid);
    }

    function _updatePool(uint256 pid) internal {
        PoolInfo storage pool = poolInfo[pid];

        uint64 toTime = _clampToGlobal(uint64(block.timestamp));
        if (toTime <= pool.lastRewardTime) return;

        uint256 lpSupply = pool.totalStaked;
        if (lpSupply == 0 || pool.allocPoint == 0 || totalAllocPoint == 0) {
            pool.lastRewardTime = toTime;
            return;
        }

        uint256 reward = _poolRewardBetween(pid, pool.lastRewardTime, toTime);

        // clamp reward so Chef never intentionally exceeds its mint budget
        if (reward > 0) {
            if (mintedByChef >= MAX_CHEF_MINT) {
                reward = 0;
            } else {
                uint256 remaining = MAX_CHEF_MINT - mintedByChef;
                if (reward > remaining) reward = remaining;
            }
        }

        // finalize time boundary BEFORE external call
        pool.lastRewardTime = toTime;

        if (reward > 0) {
            mintedByChef += reward;
            enni.mint(address(this), reward);
            pool.accEnniPerShare += Math.mulDiv(reward, ACC_PRECISION, lpSupply);
        }
    }

    function _safeEnniTransfer(address to, uint256 amount) internal {
        uint256 bal = enni.balanceOf(address(this));
        if (amount > bal) amount = bal;
        if (amount > 0) IERC20(address(enni)).safeTransfer(to, amount);
    }

    // ---------------- user actions ----------------

    /// @notice Deposit LP tokens for yourself.
    function deposit(uint256 pid, uint256 amount) external nonReentrant {
        _deposit(pid, amount, msg.sender, msg.sender);
    }

    /// @notice Deposit LP tokens on behalf of `beneficiary`.
    ///         LP tokens are pulled from msg.sender (the caller pays).
    ///         Position is credited to `beneficiary`.
    ///         Any pending rewards for `beneficiary` are harvested to `beneficiary`.
    function depositFor(uint256 pid, uint256 amount, address beneficiary) external nonReentrant {
        require(beneficiary != address(0), "beneficiary=0");
        _deposit(pid, amount, msg.sender, beneficiary);
    }

    /// @dev Internal deposit logic shared by deposit() and depositFor().
    /// @param pid       Pool ID
    /// @param amount    Amount of LP tokens to deposit
    /// @param from      Address to pull LP tokens from (always msg.sender in public fns)
    /// @param beneficiary Address to credit in UserInfo and receive pending rewards
    function _deposit(uint256 pid, uint256 amount, address from, address beneficiary) internal {
        _requirePid(pid);

        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage u = userInfo[pid][beneficiary];

        _updatePool(pid);

        // harvest pending rewards to beneficiary
        if (u.amount > 0) {
            uint256 accumulated = Math.mulDiv(u.amount, pool.accEnniPerShare, ACC_PRECISION);
            uint256 pending = accumulated > u.rewardDebt ? (accumulated - u.rewardDebt) : 0;
            if (pending > 0) {
                _safeEnniTransfer(beneficiary, pending);
                emit Harvest(beneficiary, pid, pending);
            }
        }

        uint256 received = 0;
        if (amount > 0) {
            uint256 beforeBal = pool.lpToken.balanceOf(address(this));
            pool.lpToken.safeTransferFrom(from, address(this), amount);
            uint256 afterBal = pool.lpToken.balanceOf(address(this));
            received = afterBal - beforeBal;
            require(received > 0, "no lp received");

            u.amount += received;
            pool.totalStaked += received;
        }

        u.rewardDebt = Math.mulDiv(u.amount, pool.accEnniPerShare, ACC_PRECISION);

        emit Deposit(beneficiary, pid, received);
        if (from != beneficiary) {
            emit DepositFor(from, beneficiary, pid, received);
        }
    }

    function withdraw(uint256 pid, uint256 amount) external nonReentrant {
        _requirePid(pid);

        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage u = userInfo[pid][msg.sender];

        require(u.amount >= amount, "withdraw>stake");

        _updatePool(pid);

        uint256 accumulated = Math.mulDiv(u.amount, pool.accEnniPerShare, ACC_PRECISION);
        uint256 pending = accumulated > u.rewardDebt ? (accumulated - u.rewardDebt) : 0;
        if (pending > 0) {
            _safeEnniTransfer(msg.sender, pending);
            emit Harvest(msg.sender, pid, pending);
        }

        if (amount > 0) {
            u.amount -= amount;
            pool.totalStaked -= amount;
            pool.lpToken.safeTransfer(msg.sender, amount);
        }

        u.rewardDebt = Math.mulDiv(u.amount, pool.accEnniPerShare, ACC_PRECISION);
        emit Withdraw(msg.sender, pid, amount);
    }

    function harvest(uint256 pid) external nonReentrant {
        _requirePid(pid);

        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage u = userInfo[pid][msg.sender];

        _updatePool(pid);

        uint256 accumulated = Math.mulDiv(u.amount, pool.accEnniPerShare, ACC_PRECISION);
        uint256 pending = accumulated > u.rewardDebt ? (accumulated - u.rewardDebt) : 0;

        u.rewardDebt = accumulated;

        if (pending > 0) {
            _safeEnniTransfer(msg.sender, pending);
            emit Harvest(msg.sender, pid, pending);
        }
    }

    function emergencyWithdraw(uint256 pid) external nonReentrant {
        _requirePid(pid);

        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage u = userInfo[pid][msg.sender];

        uint256 amt = u.amount;
        require(amt > 0, "nothing");

        u.amount = 0;
        u.rewardDebt = 0;

        pool.totalStaked -= amt;
        pool.lpToken.safeTransfer(msg.sender, amt);

        emit EmergencyWithdraw(msg.sender, pid, amt);
    }
}