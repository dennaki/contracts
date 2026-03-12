// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

interface IEnniOracle {
    /// @dev Price is fiat per ETH, scaled by 1e18. (e.g., $2,500 → 2500e18)
    ///      Primary: USD. Future: EUR, CHF, JPY or any fiat with a supported oracle.
    function peekPriceWithTimestamp() external view returns (uint256 price, uint256 updatedAt);
}

interface IEnniStable {
    /// @dev Any Enni-issued fiat stablecoin. Primary: enUSD. Future: enEUR, enCHF, enJPY, ...
    ///      All Enni stablecoins use 6 decimals by convention.
    function decimals() external view returns (uint8);
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;
}

interface IEnniRewardsVault {
    /// @dev donateWETH() is expected to pull WETH from msg.sender via transferFrom
    ///      This CDP pre-approves the vault in the constructor
    function donateWETH(uint256 amount) external;
}

contract EnniCDP is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ----------------- immutables -----------------
    IERC20 public immutable weth;
    IEnniOracle public immutable oracle;

    /// @dev The fiat stablecoin this CDP issues. Primary: enUSD. Future: enEUR, enCHF, enJPY, ...
    ///      Deploy a separate CDP instance per stablecoin, each with its own oracle and stable token.
    IERC20 public immutable stableToken;
    IEnniStable public immutable stable;

    IEnniRewardsVault public immutable rewardsVault;

    // ----------------- constants -----------------
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_LTV_BPS = 8_500; // 85.00%
    uint256 public constant LIQ_LTV_BPS = 8_800; // 88.00%
    uint256 public constant MIN_DEBT = 400e6;     // 400 units of stablecoin (6 decimals)
                                                  // e.g. $400 for enUSD. For enJPY deployments
                                                  // consider a higher value to reflect weaker unit.

    uint256 public constant DONATION_BPS = 300;   // 3% of seized WETH donated ONLY during liquidation
    uint256 public constant ORACLE_MAX_AGE = 24 hours;

    uint256 private constant WETH_DECIMALS = 1e18;
    uint256 private constant FIAT_SCALE = 1e12;                                // 1e18 -> 1e6
    uint256 private constant FIAT_TO_ETH_NUMERATOR = FIAT_SCALE * WETH_DECIMALS; // 1e30

    // ----------------- storage -----------------
    struct Position {
        uint256 collateral; // WETH 1e18
        uint256 debt;       // stablecoin 1e6
    }

    /// @dev One position slot per wallet. A position is considered "active" if collateral/debt/credit is nonzero
    mapping(address => Position) private _pos;

    /// @dev Premium credit earned by owner (stablecoin 1e6)
    mapping(address => uint256) public premiumCredit;

    // ----------------- events -----------------
    event PositionOpened(address indexed owner, uint256 collateral, uint256 timestamp);
    event CollateralDeposited(address indexed owner, uint256 amount, uint256 newCollateral, uint256 timestamp);
    event CollateralWithdrawn(address indexed owner, uint256 amount, uint256 newCollateral, uint256 timestamp);
    event Borrowed(address indexed owner, uint256 amount, uint256 newDebt, uint256 timestamp);
    event Repaid(address indexed owner, uint256 amount, uint256 remainingDebt, uint256 timestamp);
    event RepaidFor(address indexed caller, address indexed owner, uint256 amount, uint256 remainingDebt, uint256 timestamp);

    event Buyout(
        address indexed owner,
        address indexed buyer,
        uint256 repayAmount,
        uint256 premiumPaid,
        uint256 collateralOut,
        uint256 price,
        uint256 ltvBpsBefore
    );

    event Liquidated(
        address indexed owner,
        address indexed liquidator,
        uint256 repayAmount,
        uint256 collateralSeized, // netToLiquidator (after donation)
        uint256 price,
        uint256 ltvBpsBefore
    );

    event PremiumClaimed(address indexed owner, uint256 amount, uint256 remainingCredit, uint256 timestamp);
    event PositionClosed(address indexed owner, uint256 collateralOut, uint256 premiumOut, uint256 timestamp);

    // ----------------- errors -----------------
    error PositionAlreadyExists();
    error NoPosition();
    error ZeroAmount();
    error InvalidRepay();
    error InsufficientCollateral();
    error OracleBad();
    error OracleStale();
    error LtvTooHigh();
    error MinDebt();
    error RemainingDebtRule();
    error NotLiquidatable();
    error UseLiquidation();

    // ----------------- constructor -----------------
    /// @param _weth         Collateral token (WETH)
    /// @param _oracle       Price feed returning fiat/ETH at 1e18. Primary: USD. Future: EUR, CHF, JPY, ...
    /// @param _stable       Fiat stablecoin this CDP mints. Primary: enUSD. Future: enEUR, enCHF, enJPY, ...
    /// @param _rewardsVault Rewards vault receiving WETH liquidation donations
    constructor(address _weth, address _oracle, address _stable, address _rewardsVault) {
        require(_weth != address(0), "WETH=0");
        require(_oracle != address(0), "Oracle=0");
        require(_stable != address(0), "Stable=0");
        require(_rewardsVault != address(0), "Vault=0");

        weth = IERC20(_weth);
        oracle = IEnniOracle(_oracle);

        stableToken = IERC20(_stable);
        stable = IEnniStable(_stable);

        rewardsVault = IEnniRewardsVault(_rewardsVault);

        require(stable.decimals() == 6, "stable decimals");
        require(DONATION_BPS < BPS, "bad donation bps");

        // Allow vault to pull WETH donations from this contract
        weth.forceApprove(_rewardsVault, type(uint256).max);
    }

    // ----------------- position existence (derived) -----------------
    /// @dev Derived activity check (not an explicit flag): true if collateral/debt/credit is nonzero
    function _hasPosition(address owner) internal view returns (bool) {
        Position storage p = _pos[owner];
        return (p.collateral != 0 || p.debt != 0 || premiumCredit[owner] != 0);
    }

    // ----------------- oracle helpers -----------------
    function _readPrice() internal view returns (uint256 price, uint256 updatedAt, bool isFresh) {
        (price, updatedAt) = oracle.peekPriceWithTimestamp();
        if (price == 0) revert OracleBad();
        if (updatedAt == 0) revert OracleBad();
        if (updatedAt > block.timestamp) revert OracleBad();
        isFresh = (block.timestamp - updatedAt) <= ORACLE_MAX_AGE;
    }

    function _requireFreshPrice() internal view returns (uint256 price) {
        (uint256 p,, bool ok) = _readPrice();
        if (!ok) revert OracleStale();
        return p;
    }

    function _tryFreshPrice() internal view returns (uint256 p, bool ok) {
        try oracle.peekPriceWithTimestamp() returns (uint256 price, uint256 updatedAt) {
            if (price == 0) return (0, false);
            if (updatedAt == 0 || updatedAt > block.timestamp) return (0, false);
            if (block.timestamp - updatedAt > ORACLE_MAX_AGE) return (0, false);
            return (price, true);
        } catch {
            return (0, false);
        }
    }

    // ----------------- math helpers -----------------
    function _ethToFiatWithPrice(uint256 ethAmount, uint256 price) internal pure returns (uint256) {
        uint256 fiat18 = Math.mulDiv(ethAmount, price, WETH_DECIMALS);
        return fiat18 / FIAT_SCALE; // 1e6
    }

    function _fiatToEthWithPrice(uint256 fiatAmount, uint256 price) internal pure returns (uint256) {
        return Math.mulDiv(fiatAmount, FIAT_TO_ETH_NUMERATOR, price); // 1e18
    }

    // ----------------- views -----------------
    function positionOf(address owner)
        external
        view
        returns (bool active, uint256 collateral, uint256 debt, uint256 credit)
    {
        Position storage p = _pos[owner];
        return (_hasPosition(owner), p.collateral, p.debt, premiumCredit[owner]);
    }

    /// @dev LTV in BPS, ok=false if oracle stale/unusable
    function ltvBps(address owner) public view returns (uint256 ltv, bool ok) {
        if (!_hasPosition(owner)) return (0, true);
        Position storage p = _pos[owner];
        if (p.debt == 0) return (0, true);

        (uint256 price, bool fresh) = _tryFreshPrice();
        if (!fresh) return (0, false);

        uint256 collateralFiat = _ethToFiatWithPrice(p.collateral, price);
        if (collateralFiat == 0) return (0, false);

        return (Math.mulDiv(p.debt, BPS, collateralFiat), true);
    }

    function isLiquidatable(address owner) external view returns (bool) {
        (uint256 ltv, bool ok) = ltvBps(owner);
        if (!ok) return false;
        return ltv >= LIQ_LTV_BPS;
    }

    // ----------------- owner actions -----------------
    function open(uint256 collateralAmt) external nonReentrant {
        if (collateralAmt == 0) revert ZeroAmount();
        if (_hasPosition(msg.sender)) revert PositionAlreadyExists();

        weth.safeTransferFrom(msg.sender, address(this), collateralAmt);

        Position storage p = _pos[msg.sender];
        p.collateral = collateralAmt;
        p.debt = 0;

        emit PositionOpened(msg.sender, collateralAmt, block.timestamp);
    }

    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (!_hasPosition(msg.sender)) revert NoPosition();

        weth.safeTransferFrom(msg.sender, address(this), amount);

        Position storage p = _pos[msg.sender];
        p.collateral += amount;

        emit CollateralDeposited(msg.sender, amount, p.collateral, block.timestamp);
    }

    function borrow(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (!_hasPosition(msg.sender)) revert NoPosition();

        uint256 price = _requireFreshPrice();
        Position storage p = _pos[msg.sender];

        uint256 newDebt = p.debt + amount;
        if (p.debt == 0 && newDebt < MIN_DEBT) revert MinDebt();

        uint256 collateralFiat = _ethToFiatWithPrice(p.collateral, price);
        if (collateralFiat == 0) revert OracleBad();

        uint256 maxDebt = Math.mulDiv(collateralFiat, MAX_LTV_BPS, BPS);
        if (newDebt > maxDebt) revert LtvTooHigh();

        p.debt = newDebt;
        stable.mint(msg.sender, amount);

        emit Borrowed(msg.sender, amount, p.debt, block.timestamp);
    }

    /// @notice Repay your own debt with stablecoins from your wallet.
    function repay(uint256 amount) external nonReentrant {
        _repay(msg.sender, msg.sender, amount);
    }

    /// @notice Repay debt on behalf of `owner`. Stablecoins pulled from msg.sender.
    ///         Restricted to contract callers (routers/zaps) only.
    function repayFor(address owner, uint256 amount) external nonReentrant {
        require(owner != address(0), "owner=0");
        require(msg.sender.code.length > 0, "only contracts");
        _repay(owner, msg.sender, amount);
    }

    /// @dev Shared repay logic.
    ///      `owner` = whose debt is reduced
    ///      `payer` = who provides the stablecoins (always msg.sender in public fns)
    function _repay(address owner, address payer, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        if (!_hasPosition(owner)) revert NoPosition();

        Position storage p = _pos[owner];
        if (p.debt < amount) revert InvalidRepay();

        uint256 remaining = p.debt - amount;
        if (remaining != 0 && remaining < MIN_DEBT) revert RemainingDebtRule();

        stableToken.safeTransferFrom(payer, address(this), amount);
        stable.burn(amount);

        p.debt = remaining;

        emit Repaid(owner, amount, p.debt, block.timestamp);
        if (payer != owner) {
            emit RepaidFor(payer, owner, amount, p.debt, block.timestamp);
        }
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (!_hasPosition(msg.sender)) revert NoPosition();

        uint256 price = _requireFreshPrice();
        Position storage p = _pos[msg.sender];
        if (p.collateral < amount) revert InsufficientCollateral();

        uint256 newCollateral = p.collateral - amount;

        if (p.debt > 0) {
            uint256 collateralFiat = _ethToFiatWithPrice(newCollateral, price);
            if (collateralFiat == 0) revert OracleBad();

            uint256 maxDebt = Math.mulDiv(collateralFiat, MAX_LTV_BPS, BPS);
            if (p.debt > maxDebt) revert LtvTooHigh();
        }

        p.collateral = newCollateral;
        weth.safeTransfer(msg.sender, amount);

        emit CollateralWithdrawn(msg.sender, amount, p.collateral, block.timestamp);
    }

    function claimPremium(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 credit = premiumCredit[msg.sender];
        if (credit < amount) revert InvalidRepay();

        premiumCredit[msg.sender] = credit - amount;
        stableToken.safeTransfer(msg.sender, amount);

        emit PremiumClaimed(msg.sender, amount, premiumCredit[msg.sender], block.timestamp);
    }

    function close() external nonReentrant {
        if (!_hasPosition(msg.sender)) revert NoPosition();

        Position storage p = _pos[msg.sender];
        if (p.debt != 0) revert InvalidRepay(); // debt must be zero

        uint256 c = p.collateral;
        uint256 prem = premiumCredit[msg.sender];

        // clear state first
        p.collateral = 0;
        p.debt = 0;
        premiumCredit[msg.sender] = 0;

        if (c > 0) weth.safeTransfer(msg.sender, c);
        if (prem > 0) stableToken.safeTransfer(msg.sender, prem);

        emit PositionClosed(msg.sender, c, prem, block.timestamp);
    }

    // ----------------- third-party actions -----------------
    function buyout(address owner, uint256 repayAmount) external nonReentrant {
        if (repayAmount == 0) revert ZeroAmount();
        if (!_hasPosition(owner)) revert NoPosition();

        uint256 price = _requireFreshPrice();
        Position storage p = _pos[owner];
        if (p.debt == 0) revert InvalidRepay();
        if (repayAmount > p.debt) revert InvalidRepay();

        uint256 collateralFiatBefore = _ethToFiatWithPrice(p.collateral, price);
        uint256 ltvBefore = collateralFiatBefore == 0
            ? type(uint256).max
            : Math.mulDiv(p.debt, BPS, collateralFiatBefore);

        // if liquidatable, liquidation path must be used
        if (ltvBefore >= LIQ_LTV_BPS) revert UseLiquidation();

        uint256 remaining = p.debt - repayAmount;
        if (remaining != 0 && remaining < MIN_DEBT) revert RemainingDebtRule();

        uint256 rateBps;
        if (ltvBefore >= 8_500) rateBps = 400;
        else if (ltvBefore >= 6_000) rateBps = 600;
        else rateBps = 900;

        uint256 premium = Math.mulDiv(repayAmount, rateBps, BPS);
        uint256 totalPay = repayAmount + premium;

        uint256 collateralOut = _fiatToEthWithPrice(repayAmount, price);
        if (collateralOut == 0) revert OracleBad();
        if (collateralOut > p.collateral) revert InsufficientCollateral();

        stableToken.safeTransferFrom(msg.sender, address(this), totalPay);
        stable.burn(repayAmount);

        premiumCredit[owner] += premium;

        p.debt = remaining;
        p.collateral -= collateralOut;

        weth.safeTransfer(msg.sender, collateralOut);

        emit Buyout(owner, msg.sender, repayAmount, premium, collateralOut, price, ltvBefore);
    }

    function liquidate(address owner, uint256 repayAmount) external nonReentrant {
        if (repayAmount == 0) revert ZeroAmount();
        if (!_hasPosition(owner)) revert NoPosition();

        uint256 price = _requireFreshPrice();
        Position storage p = _pos[owner];
        if (p.debt == 0) revert InvalidRepay();
        if (repayAmount > p.debt) revert InvalidRepay();

        uint256 collateralFiatBefore = _ethToFiatWithPrice(p.collateral, price);
        uint256 ltvBefore = collateralFiatBefore == 0
            ? type(uint256).max
            : Math.mulDiv(p.debt, BPS, collateralFiatBefore);

        if (ltvBefore < LIQ_LTV_BPS) revert NotLiquidatable();

        uint256 remaining = p.debt - repayAmount;
        if (remaining != 0 && remaining < MIN_DEBT) revert RemainingDebtRule();

        uint256 collateralSeized = Math.mulDiv(p.collateral, repayAmount, p.debt);
        if (collateralSeized == 0) revert OracleBad();

        uint256 donation = Math.mulDiv(collateralSeized, DONATION_BPS, BPS);
        uint256 toLiquidator = collateralSeized - donation;

        stableToken.safeTransferFrom(msg.sender, address(this), repayAmount);
        stable.burn(repayAmount);

        p.debt = remaining;
        p.collateral -= collateralSeized;

        // ---- donation is non-blocking ----
        if (donation > 0) {
            try rewardsVault.donateWETH(donation) {} catch {}
        }

        weth.safeTransfer(msg.sender, toLiquidator);

        emit Liquidated(owner, msg.sender, repayAmount, toLiquidator, price, ltvBefore);
    }
}
