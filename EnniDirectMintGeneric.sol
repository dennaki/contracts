// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title EnniDirectMintGeneric
 * @notice 1:1 value minting and redemption for non-USD ENNI stablecoins.
 *
 * - Single backing stablecoin (e.g. ZCHF for enCHF).
 * - Supports different decimals between backing and enStable.
 *   e.g. ZCHF (18 dec) ↔ enCHF (6 dec) — scales automatically.
 * - Mint cap limits total enStable mintable through this contract.
 * - 0.5% redeem fee — burned, not donated.
 * - Immutable. No owner. No admin. No upgrades.
 *
 * Deploy one instance per currency pair.
 */

interface IEnniStable is IERC20Metadata {
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;
}

contract EnniDirectMintGeneric is ReentrancyGuard {
    using SafeERC20 for IERC20Metadata;

    // ==================== CONSTANTS ====================

    uint256 public constant BPS = 10_000;
    uint256 public constant REDEEM_FEE_BPS = 50; // 0.50%

    // ==================== IMMUTABLES ====================

    /// @dev Backing stablecoin (e.g. ZCHF 18 decimals)
    IERC20Metadata public immutable backingToken;

    /// @dev ENNI stablecoin being minted (e.g. enCHF 6 decimals)
    IEnniStable public immutable enStable;

    /// @dev Maximum enStable mintable through this contract (enStable decimals)
    uint256 public immutable mintCap;

    /// @dev Scaling factor: 10^(backingDecimals - enStableDecimals)
    ///      e.g. ZCHF(18) → enCHF(6) = 10^12
    ///      If same decimals, scale = 1 (no conversion needed)
    uint256 public immutable scale;

    /// @dev Decimals of the backing token (for views)
    uint8 public immutable backingDecimals;

    /// @dev Decimals of the enStable token (for views)
    uint8 public immutable enStableDecimals;

    // ==================== STATE ====================

    /// @dev Total enStable minted through this contract (enStable decimals)
    uint256 public totalMinted;

    // ==================== EVENTS ====================

    event Minted(address indexed user, uint256 backingIn, uint256 enStableOut);
    event Redeemed(address indexed user, uint256 enStableIn, uint256 backingOut, uint256 feeBurned);

    // ==================== CONSTRUCTOR ====================

    constructor(
        IERC20Metadata backingToken_,
        IEnniStable enStable_,
        uint256 mintCap_
    ) {
        require(address(backingToken_) != address(0), "backing=0");
        require(address(enStable_) != address(0), "enStable=0");
        require(mintCap_ > 0, "cap=0");
        require(address(backingToken_) != address(enStable_), "backing=enStable");

        uint8 bDec = backingToken_.decimals();
        uint8 sDec = enStable_.decimals();

        // backing decimals must be >= enStable decimals
        // e.g. ZCHF(18) >= enCHF(6) ✓
        // e.g. USDC(6) >= enUSD(6) ✓
        require(bDec >= sDec, "backing decimals < enStable decimals");

        backingToken = backingToken_;
        enStable = enStable_;
        mintCap = mintCap_;

        backingDecimals = bDec;
        enStableDecimals = sDec;
        scale = 10 ** (bDec - sDec); // 1 if same decimals
    }

    // ==================== VIEWS ====================

    /// @notice Preview how much enStable you get for a given backing amount.
    function previewMint(uint256 backingAmount) external view returns (uint256 enStableOut) {
        return backingAmount / scale;
    }

    /// @notice Preview how much backing you get for a given enStable amount.
    function previewRedeem(uint256 enStableAmount)
        external
        view
        returns (uint256 backingOut, uint256 fee, uint256 netBurn)
    {
        fee = (enStableAmount * REDEEM_FEE_BPS) / BPS;
        netBurn = enStableAmount - fee;
        backingOut = netBurn * scale;
    }

    /// @notice Remaining enStable mintable through this contract.
    function remainingMintCap() external view returns (uint256) {
        return mintCap > totalMinted ? (mintCap - totalMinted) : 0;
    }

    // ==================== PUBLIC ACTIONS ====================

    /// @notice Deposit backing stablecoin, receive enStable at 1:1 value.
    ///         e.g. 1 ZCHF (1e18) → 1 enCHF (1e6)
    function mint(uint256 backingAmount) external nonReentrant {
        require(backingAmount > 0, "Zero amount");

        // Scale backing → enStable (round down, safe for protocol)
        uint256 enStableOut = backingAmount / scale;
        require(enStableOut > 0, "amount too small");
        require(totalMinted + enStableOut <= mintCap, "mint cap reached");

        // Transfer backing in (balance-before/after for fee-on-transfer safety)
        uint256 before = backingToken.balanceOf(address(this));
        backingToken.safeTransferFrom(msg.sender, address(this), backingAmount);
        uint256 received = backingToken.balanceOf(address(this)) - before;
        require(received > 0, "received=0");

        // Recalculate enStable from actual received (fee-on-transfer safe)
        uint256 actualEnStable = received / scale;
        require(actualEnStable > 0, "received too small");

        // Re-check cap with actual amount
        require(totalMinted + actualEnStable <= mintCap, "mint cap reached");

        totalMinted += actualEnStable;

        enStable.mint(msg.sender, actualEnStable);

        emit Minted(msg.sender, received, actualEnStable);
    }

    /// @notice Burn enStable, receive backing stablecoin minus 0.5% fee.
    ///         Fee is burned — no treasury, no vault, just removed from supply.
    ///         e.g. 1 enCHF (1e6) → 0.995 ZCHF (0.995e18)
    function redeem(uint256 enStableAmount) external nonReentrant {
        require(enStableAmount > 0, "Zero amount");

        // Calculate fee and net in enStable units
        uint256 fee = (enStableAmount * REDEEM_FEE_BPS) / BPS;
        uint256 net = enStableAmount - fee;

        // Scale net enStable → backing amount
        uint256 backingOut = net * scale;

        require(backingToken.balanceOf(address(this)) >= backingOut, "Insufficient liquidity");

        // Pull enStable from user
        IERC20Metadata(address(enStable)).safeTransferFrom(msg.sender, address(this), enStableAmount);

        // Burn everything — fee + net. Fee is not donated, just destroyed.
        enStable.burn(enStableAmount);

        // Free up mint cap space (full enStable amount, including fee portion)
        if (totalMinted >= enStableAmount) {
            totalMinted -= enStableAmount;
        } else {
            totalMinted = 0;
        }

        // Send backing to user
        backingToken.safeTransfer(msg.sender, backingOut);

        emit Redeemed(msg.sender, enStableAmount, backingOut, fee);
    }

    // ==================== REJECTIONS ====================

    receive() external payable { revert("No ETH"); }
    fallback() external payable { revert("No ETH"); }
}