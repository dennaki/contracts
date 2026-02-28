// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

interface IEnniMasterChef {
    function deposit(uint256 pid, uint256 amount) external;
    function withdraw(uint256 pid, uint256 amount) external;
    function harvest(uint256 pid) external;
    function pendingEnni(uint256 pid, address user) external view returns (uint256);
}

contract EnniRewardsVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant ACC_PRECISION = 1e18;

    IERC20 public immutable ENNI;
    IERC20 public immutable WETH;
    IERC20 public immutable enUSD;

    IEnniMasterChef public immutable chef;
    uint256 public immutable chefPid;

    uint256 public totalShares;

    // per-share accumulators
    uint256 public accEnniPerShare;
    uint256 public accWethPerShare;
    uint256 public accEnUsdPerShare;

    // queued rewards when totalShares == 0
    uint256 public queuedEnni;
    uint256 public queuedWeth;
    uint256 public queuedEnUsd;

    // dust carry
    uint256 public enniDust;
    uint256 public wethDust;
    uint256 public enUsdDust;

    struct UserInfo {
        uint256 shares;
        uint256 enniDebt;
        uint256 wethDebt;
        uint256 enUsdDebt;
    }

    mapping(address => UserInfo) public userInfo;

    event Deposit(address indexed user, uint256 amountReceived);
    event Withdraw(address indexed user, uint256 amount);
    event Claim(address indexed user, uint256 enniOut, uint256 wethOut, uint256 enUsdOut);
    event Donate(address indexed from, address indexed token, uint256 amountReceived);

    constructor(
        IERC20 enni_,
        IERC20 weth_,
        IERC20 enUsd_,
        IEnniMasterChef chef_,
        uint256 chefPid_
    ) {
        require(address(enni_) != address(0), "ENNI=0");
        require(address(weth_) != address(0), "WETH=0");
        require(address(enUsd_) != address(0), "enUSD=0");
        require(address(chef_) != address(0), "chef=0");
        require(IERC20Metadata(address(enUsd_)).decimals() == 6, "enUSD decimals");

        ENNI = enni_;
        WETH = weth_;
        enUSD = enUsd_;
        chef = chef_;
        chefPid = chefPid_;

        ENNI.forceApprove(address(chef_), type(uint256).max);
    }

    // ---------------- internal accounting ----------------

    function _creditQueuedIfPossible()
        internal
        returns (uint256 distEnni, uint256 distWeth, uint256 distEnUsd)
    {
        if (totalShares == 0) return (0, 0, 0);

        if (queuedEnni > 0) {
            distEnni = queuedEnni;
            _distributeEnni(distEnni);
            queuedEnni = 0;
        }
        if (queuedWeth > 0) {
            distWeth = queuedWeth;
            _distributeWeth(distWeth);
            queuedWeth = 0;
        }
        if (queuedEnUsd > 0) {
            distEnUsd = queuedEnUsd;
            _distributeEnUsd(distEnUsd);
            queuedEnUsd = 0;
        }
    }

    function _updateUserDebt(address user) internal {
        UserInfo storage u = userInfo[user];
        u.enniDebt  = Math.mulDiv(u.shares, accEnniPerShare,  ACC_PRECISION);
        u.wethDebt  = Math.mulDiv(u.shares, accWethPerShare,  ACC_PRECISION);
        u.enUsdDebt = Math.mulDiv(u.shares, accEnUsdPerShare, ACC_PRECISION);
    }

    function _claimTo(address user, address to)
        internal
        returns (uint256 outEnni, uint256 outWeth, uint256 outEnUsd)
    {
        UserInfo storage u = userInfo[user];

        uint256 enniAcc  = Math.mulDiv(u.shares, accEnniPerShare,  ACC_PRECISION);
        uint256 wethAcc  = Math.mulDiv(u.shares, accWethPerShare,  ACC_PRECISION);
        uint256 enUsdAcc = Math.mulDiv(u.shares, accEnUsdPerShare, ACC_PRECISION);

        outEnni  = enniAcc  > u.enniDebt  ? (enniAcc  - u.enniDebt)  : 0;
        outWeth  = wethAcc  > u.wethDebt  ? (wethAcc  - u.wethDebt)  : 0;
        outEnUsd = enUsdAcc > u.enUsdDebt ? (enUsdAcc - u.enUsdDebt) : 0;

        u.enniDebt  = enniAcc;
        u.wethDebt  = wethAcc;
        u.enUsdDebt = enUsdAcc;

        if (outEnni  > 0) ENNI.safeTransfer(to, outEnni);
        if (outWeth  > 0) WETH.safeTransfer(to, outWeth);
        if (outEnUsd > 0) enUSD.safeTransfer(to, outEnUsd);
    }

    // ---------------- reward distribution helpers ----------------

    function _distributeEnni(uint256 amount) internal {
        if (amount == 0) return;

        if (totalShares == 0) {
            queuedEnni += amount;
            return;
        }
        amount += enniDust;
        uint256 delta = Math.mulDiv(amount, ACC_PRECISION, totalShares);
        uint256 distributed = Math.mulDiv(delta, totalShares, ACC_PRECISION);
        enniDust = amount - distributed;
        accEnniPerShare += delta;
    }

    function _distributeWeth(uint256 amount) internal {
        if (amount == 0) return;

        if (totalShares == 0) {
            queuedWeth += amount;
            return;
        }
        amount += wethDust;
        uint256 delta = Math.mulDiv(amount, ACC_PRECISION, totalShares);
        uint256 distributed = Math.mulDiv(delta, totalShares, ACC_PRECISION);
        wethDust = amount - distributed;
        accWethPerShare += delta;
    }

    function _distributeEnUsd(uint256 amount) internal {
        if (amount == 0) return;

        if (totalShares == 0) {
            queuedEnUsd += amount;
            return;
        }
        amount += enUsdDust;
        uint256 delta = Math.mulDiv(amount, ACC_PRECISION, totalShares);
        uint256 distributed = Math.mulDiv(delta, totalShares, ACC_PRECISION);
        enUsdDust = amount - distributed;
        accEnUsdPerShare += delta;
    }

    // ---------------- public actions ----------------

    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "amount=0");

        bool wasZero = (totalShares == 0);

        // distribute queued donations to existing stakers
        _creditQueuedIfPossible();

        // pull principal
        uint256 beforeBal = ENNI.balanceOf(address(this));
        ENNI.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = ENNI.balanceOf(address(this)) - beforeBal;
        require(received > 0, "received=0");

        // Chef.deposit auto-harvests; capture only reward (not principal)
        uint256 beforeChef = ENNI.balanceOf(address(this));
        chef.deposit(chefPid, received);
        uint256 afterChef = ENNI.balanceOf(address(this));

        require(afterChef + received >= beforeChef, "bad enni delta");
        uint256 rewardGained = (afterChef + received) - beforeChef;
        if (rewardGained > 0) _distributeEnni(rewardGained);

        // settle caller rewards (so existing stakers get their cut of rewardGained)
        (uint256 outEnni, uint256 outWeth, uint256 outEnUsd) = _claimTo(msg.sender, msg.sender);
        if (outEnni + outWeth + outEnUsd > 0) emit Claim(msg.sender, outEnni, outWeth, outEnUsd);

        // mint shares 1:1 with principal received
        UserInfo storage u = userInfo[msg.sender];
        u.shares += received;
        totalShares += received;

        _updateUserDebt(msg.sender);

        // if first staker just arrived, make queued immediately claimable
        if (wasZero) {
            _creditQueuedIfPossible();
        }

        emit Deposit(msg.sender, received);
    }

    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0, "amount=0");

        UserInfo storage u = userInfo[msg.sender];
        require(u.shares >= amount, "withdraw>shares");

        _creditQueuedIfPossible();

        uint256 beforeChef = ENNI.balanceOf(address(this));
        chef.withdraw(chefPid, amount);
        uint256 afterChef = ENNI.balanceOf(address(this));

        require(afterChef >= beforeChef, "bad enni delta");
        uint256 delta = afterChef - beforeChef; // principal + reward
        require(delta >= amount, "chef principal short");
        uint256 rewardGained = delta - amount;
        if (rewardGained > 0) _distributeEnni(rewardGained);

        (uint256 outEnni, uint256 outWeth, uint256 outEnUsd) = _claimTo(msg.sender, msg.sender);
        if (outEnni + outWeth + outEnUsd > 0) emit Claim(msg.sender, outEnni, outWeth, outEnUsd);

        u.shares -= amount;
        totalShares -= amount;

        ENNI.safeTransfer(msg.sender, amount);

        _updateUserDebt(msg.sender);
        emit Withdraw(msg.sender, amount);
    }

    function claim() external nonReentrant {
        _creditQueuedIfPossible();

        uint256 before = ENNI.balanceOf(address(this));
        chef.harvest(chefPid);
        uint256 afterBal = ENNI.balanceOf(address(this));
        uint256 harvested = afterBal > before ? (afterBal - before) : 0;
        if (harvested > 0) _distributeEnni(harvested);

        (uint256 outEnni, uint256 outWeth, uint256 outEnUsd) = _claimTo(msg.sender, msg.sender);
        emit Claim(msg.sender, outEnni, outWeth, outEnUsd);
    }

    // ---------------- donations (DONATE-ONLY) ----------------

    function donateWETH(uint256 amount) external nonReentrant {
        require(amount > 0, "amount=0");

        uint256 beforeBal = WETH.balanceOf(address(this));
        WETH.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = WETH.balanceOf(address(this)) - beforeBal;
        require(received > 0, "received=0");

        _distributeWeth(received);
        emit Donate(msg.sender, address(WETH), received);
    }

    function donateEnUSD(uint256 amount) external nonReentrant {
        require(amount > 0, "amount=0");

        uint256 beforeBal = enUSD.balanceOf(address(this));
        enUSD.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = enUSD.balanceOf(address(this)) - beforeBal;
        require(received > 0, "received=0");

        _distributeEnUsd(received);
        emit Donate(msg.sender, address(enUSD), received);
    }

    // ---------------- views ----------------

    function pending(address user) external view returns (uint256 pEnni, uint256 pWeth, uint256 pEnUsd) {
        UserInfo memory u = userInfo[user];

        uint256 _accEnni = accEnniPerShare;
        uint256 _accWeth = accWethPerShare;
        uint256 _accEnUsd = accEnUsdPerShare;

        if (totalShares > 0) {
            if (queuedEnni  > 0) _accEnni  += Math.mulDiv(queuedEnni,  ACC_PRECISION, totalShares);
            if (queuedWeth  > 0) _accWeth  += Math.mulDiv(queuedWeth,  ACC_PRECISION, totalShares);
            if (queuedEnUsd > 0) _accEnUsd += Math.mulDiv(queuedEnUsd, ACC_PRECISION, totalShares);

            uint256 chefPending = chef.pendingEnni(chefPid, address(this));
            if (chefPending > 0) _accEnni += Math.mulDiv(chefPending, ACC_PRECISION, totalShares);
        }

        uint256 enniAcc  = Math.mulDiv(u.shares, _accEnni,  ACC_PRECISION);
        uint256 wethAcc  = Math.mulDiv(u.shares, _accWeth,  ACC_PRECISION);
        uint256 enUsdAcc = Math.mulDiv(u.shares, _accEnUsd, ACC_PRECISION);

        pEnni  = enniAcc  > u.enniDebt  ? (enniAcc  - u.enniDebt)  : 0;
        pWeth  = wethAcc  > u.wethDebt  ? (wethAcc  - u.wethDebt)  : 0;
        pEnUsd = enUsdAcc > u.enUsdDebt ? (enUsdAcc - u.enUsdDebt) : 0;
    }
}
