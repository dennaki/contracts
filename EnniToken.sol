// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract EnniToken is ERC20, ERC20Permit {
    uint8 private immutable _decimals;
    uint256 public immutable maxMintable;

    address public owner;
    address public minter1;
    address public minter2;

    uint256 public totalMinted;
    uint256 public totalBurned;

    event Burn(address indexed from, uint256 amount);
    event OwnerTransferred(address indexed oldOwner, address indexed newOwner);
    event Minter1Changed(address indexed oldMinter, address indexed newMinter);
    event Minter2Changed(address indexed oldMinter, address indexed newMinter);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyMinter() {
        require(msg.sender == minter1 || msg.sender == minter2, "Not authorized minter");
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 initialSupply_,
        uint256 maxMintable_,
        address owner_,
        address minter1_,
        address minter2_
    )
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        require(owner_ != address(0), "owner zero address");
        require(minter1_ != address(0), "minter1 zero address");
        require(minter2_ != address(0), "minter2 zero address");
        require(maxMintable_ == 0 || initialSupply_ <= maxMintable_, "Initial supply exceeds maxMintable");

        _decimals = decimals_;
        maxMintable = maxMintable_;
        owner = owner_;
        minter1 = minter1_;
        minter2 = minter2_;

        if (initialSupply_ > 0) {
            totalMinted = initialSupply_;
            _mint(minter1_, initialSupply_);
        }
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function setMinter1(address newMinter) external onlyOwner {
        require(newMinter != address(0), "zero address");
        emit Minter1Changed(minter1, newMinter);
        minter1 = newMinter;
    }

    function setMinter2(address newMinter) external onlyOwner {
        require(newMinter != address(0), "zero address");
        emit Minter2Changed(minter2, newMinter);
        minter2 = newMinter;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "newOwner=0");
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    function renounceOwnership() external onlyOwner {
        emit OwnerTransferred(owner, address(0));
        owner = address(0);
    }

    function mint(address to, uint256 amount) external onlyMinter {
        require(maxMintable == 0 || totalMinted + amount <= maxMintable, "Mint exceeds maxMintable");
        totalMinted += amount;
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
        totalBurned += amount;
        emit Burn(msg.sender, amount);
    }

    function burnFrom(address account, uint256 amount) external {
        uint256 allowed = allowance(account, msg.sender);
        require(allowed >= amount, "Burn exceeds allowance");

        if (allowed != type(uint256).max) {
            _approve(account, msg.sender, allowed - amount);
        }

        _burn(account, amount);
        totalBurned += amount;
        emit Burn(account, amount);
    }
}
