// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IEnUSD is IERC20Metadata {
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;
}

interface IEnniRewardsVault {
    function donateEnUSD(uint256 amount) external;
}

contract EnniDirectMint is ReentrancyGuard {
    using SafeERC20 for IERC20Metadata;

    uint256 public constant BPS = 10_000;
    uint256 public constant REDEEM_FEE_BPS = 50; // 0.50%

    IERC20Metadata public immutable USDC;
    IERC20Metadata public immutable USDT;

    IEnUSD public immutable enUSD;

    // Where redeem fees go (enUSD)
    IEnniRewardsVault public immutable rewardsVault;

    event Minted(address indexed user, address indexed stableIn, uint256 stableInAmount, uint256 enUsdOut);
    event Redeemed(
        address indexed user,
        address indexed stableOut,
        uint256 enUsdIn,
        uint256 stableOutAmount,
        uint256 feeEnUsd
    );

    constructor(
        IERC20Metadata usdc_,
        IERC20Metadata usdt_,
        IEnUSD enUSD_,
        IEnniRewardsVault rewardsVault_
    ) {
        require(address(usdc_) != address(0), "USDC=0");
        require(address(usdt_) != address(0), "USDT=0");
        require(address(enUSD_) != address(0), "enUSD=0");
        require(address(rewardsVault_) != address(0), "vault=0");

        require(address(usdc_) != address(usdt_), "USDC=USDT");
        require(address(enUSD_) != address(usdc_), "enUSD=USDC");
        require(address(enUSD_) != address(usdt_), "enUSD=USDT");
        require(address(rewardsVault_) != address(this), "vault=this");

        require(usdc_.decimals() == 6, "USDC decimals");
        require(usdt_.decimals() == 6, "USDT decimals");
        require(enUSD_.decimals() == 6, "enUSD decimals");

        USDC = usdc_;
        USDT = usdt_;
        enUSD = enUSD_;
        rewardsVault = rewardsVault_;

        IERC20Metadata(address(enUSD_)).forceApprove(address(rewardsVault_), type(uint256).max);
    }

    function previewMint(uint256 stableInAmount) external pure returns (uint256 enUsdOut) {
        return stableInAmount;
    }

    function previewRedeem(uint256 enUsdInAmount)
        external
        pure
        returns (uint256 stableOutAmount, uint256 feeEnUsd, uint256 netBurnEnUsd)
    {
        feeEnUsd = (enUsdInAmount * REDEEM_FEE_BPS) / BPS;
        netBurnEnUsd = enUsdInAmount - feeEnUsd;
        stableOutAmount = netBurnEnUsd;
    }

    function mintWithUSDC(uint256 amount) external nonReentrant {
        _mint(USDC, amount);
    }

    function mintWithUSDT(uint256 amount) external nonReentrant {
        _mint(USDT, amount);
    }

    function redeemToUSDC(uint256 amount) external nonReentrant {
        _redeem(USDC, amount);
    }

    function redeemToUSDT(uint256 amount) external nonReentrant {
        _redeem(USDT, amount);
    }

    function _mint(IERC20Metadata stable, uint256 amount) internal {
        require(amount > 0, "Zero amount");

        stable.safeTransferFrom(msg.sender, address(this), amount);
        enUSD.mint(msg.sender, amount);

        emit Minted(msg.sender, address(stable), amount, amount);
    }

    function _redeem(IERC20Metadata stable, uint256 amount) internal {
        require(amount > 0, "Zero amount");

        uint256 fee = (amount * REDEEM_FEE_BPS) / BPS;
        uint256 net = amount - fee;

        require(stable.balanceOf(address(this)) >= net, "Insufficient liquidity");

        IERC20Metadata(address(enUSD)).safeTransferFrom(msg.sender, address(this), amount);

        // Donate fee to vault — non-blocking to guarantee liveness
        if (fee > 0) {
            try rewardsVault.donateEnUSD(fee) {} catch {}
        }

        enUSD.burn(net);

        stable.safeTransfer(msg.sender, net);

        emit Redeemed(msg.sender, address(stable), amount, net, fee);
    }

    receive() external payable { revert("No ETH"); }
    fallback() external payable { revert("No ETH"); }
}