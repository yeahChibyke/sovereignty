- Cngn.sol:

```solidity
    // SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.8.0) (token/ERC20/ERC20.sol)

pragma solidity ^0.8.4;

import {IERC20Upgradeable} from "./interfaces/IERC20Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol"; // Added for reentrancy protection
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20MetadataUpgradeable} from "./interfaces/IERC20MetadataUpgradeable.sol";
import "./interfaces/IOperations.sol";

contract Cngn is
    Initializable,
    OwnableUpgradeable,
    IERC20Upgradeable,
    IERC20MetadataUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable // Added for reentrancy protection
{
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    uint256 private _totalSupply;
    string private _name;
    string private _symbol;
    address trustedForwarderContract;
    address adminOperationsContract;

    // /// @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    modifier onlyDeployerOrForwarder() {
        require(
            msg.sender == owner() || isTrustedForwarder(msg.sender),
            "Caller is not the deployer or the trusted forwarder"
        );
        _;
    }

    function __ERC20_init(string memory name_, string memory symbol_) internal onlyInitializing {
        __ERC20_init_unchained(name_, symbol_);
    }

    function __ERC20_init_unchained(string memory name_, string memory symbol_) internal onlyInitializing {
        _name = name_;
        _symbol = symbol_;
    }

    function initialize(address _trustedForwarderContract, address _adminOperationsContract) public initializer {
        __ERC20_init("cNGN", "cNGN");
        __Ownable_init(msg.sender);
        __Pausable_init();
        __ReentrancyGuard_init(); // Initialize ReentrancyGuardUpgradeable

        // _disableInitializers();
        trustedForwarderContract = _trustedForwarderContract;
        adminOperationsContract = _adminOperationsContract;
    }

    function isTrustedForwarder(address forwarder) public view virtual returns (bool) {
        return forwarder == trustedForwarderContract;
    }

    function msgSender() internal view returns (address payable signer) {
        if (msg.data.length >= 20 && isTrustedForwarder(msg.sender)) {
            assembly {
                signer := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            signer = payable(msg.sender);
        }
        return signer;
    }

    function updateAdminOperationsAddress(address _newAdmin) public virtual onlyOwner returns (bool) {
        adminOperationsContract = _newAdmin;
        return true;
    }

    function updateForwarderContract(address _newForwarderContract) public virtual onlyOwner returns (bool) {
        trustedForwarderContract = _newForwarderContract;
        return true;
    }

    function name() public view virtual override returns (string memory) {
        return _name;
    }

    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    function decimals() public view virtual override returns (uint8) {
        return 6;
    }

    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view virtual override returns (uint256) {
        return _balances[account];
    }

    // Added nonReentrant modifier to prevent reentrancy attacks
    function transfer(address to, uint256 amount) public virtual override nonReentrant returns (bool) {
        address owner = _msgSender();
        if (
            !IAdmin(adminOperationsContract).isBlackListed(_msgSender())
                && !IAdmin(adminOperationsContract).isBlackListed(to)
                && IAdmin(adminOperationsContract).isInternalUserWhitelisted(to)
                && IAdmin(adminOperationsContract).isExternalSenderWhitelisted(_msgSender())
        ) {
            _transfer(owner, to, amount);
            _burn(to, amount);
            return true;
        } else {
            require(!IAdmin(adminOperationsContract).isBlackListed(_msgSender()));
            require(!IAdmin(adminOperationsContract).isBlackListed(to));
            _transfer(owner, to, amount);
            return true;
        }
    }

    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, amount);
        return true;
    }

    // Added nonReentrant modifier to prevent reentrancy attacks
    function transferFrom(address from, address to, uint256 amount)
        public
        virtual
        override
        whenNotPaused
        nonReentrant
        returns (bool)
    {
        require(!IAdmin(adminOperationsContract).isBlackListed(_msgSender()));
        require(!IAdmin(adminOperationsContract).isBlackListed(from));
        require(!IAdmin(adminOperationsContract).isBlackListed(to));
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, allowance(owner, spender) + addedValue);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        address owner = _msgSender();
        uint256 currentAllowance = allowance(owner, spender);

        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        unchecked {
            _approve(owner, spender, currentAllowance - subtractedValue);
        }

        return true;
    }

    function mint(uint256 _amount, address _mintTo)
        public
        virtual
        onlyDeployerOrForwarder
        nonReentrant
        returns (bool)
    {
        // Added nonReentrant modifier for reentrancy protection
        address signer = msgSender();
        require(!IAdmin(adminOperationsContract).isBlackListed(signer), "User is blacklisted");
        require(!IAdmin(adminOperationsContract).isBlackListed(_mintTo), "Receiver is blacklisted");
        require(IAdmin(adminOperationsContract).canMint(signer), "Minter not authorized to sign");
        require(IAdmin(adminOperationsContract).mintAmount(signer) == _amount, "Attempting to mint more than allowed");
        _mint(_mintTo, _amount);

        bool removed = IAdmin(adminOperationsContract).removeCanMint(signer);
        require(removed, "Failed to revoke minting authorization");

        return true;
    }

    function burnByUser(uint256 _amount) public virtual onlyDeployerOrForwarder nonReentrant returns (bool) {
        // Added nonReentrant modifier for reentrancy protection
        _burn(_msgSender(), _amount);
        return true;
    }

    function pause() public virtual onlyOwner returns (bool) {
        _pause();
        return true;
    }

    function unPause() public virtual onlyOwner returns (bool) {
        _unpause();
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        _beforeTokenTransfer(from, to, amount);

        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[from] = fromBalance - amount;
            _balances[to] += amount;
        }

        emit Transfer(from, to, amount);

        _afterTokenTransfer(from, to, amount);
    }

    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");

        _beforeTokenTransfer(address(0), account, amount);

        _totalSupply += amount;
        unchecked {
            _balances[account] += amount;
        }
        emit Transfer(address(0), account, amount);

        _afterTokenTransfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: burn from the zero address");

        _beforeTokenTransfer(account, address(0), amount);

        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
        unchecked {
            _balances[account] = accountBalance - amount;
            _totalSupply -= amount;
        }

        emit Transfer(account, address(0), amount);

        _afterTokenTransfer(account, address(0), amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "ERC20: insufficient allowance");
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual whenNotPaused {}

    function _afterTokenTransfer(address from, address to, uint256 amount) internal virtual {}

    uint256[45] private __gap;
}

```

- IERC20MetadataUpgradeable.sol:

```solidity
    // SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v4.4.1 (token/ERC20/extensions/IERC20Metadata.sol)

pragma solidity ^0.8.0;

import "./IERC20Upgradeable.sol";

/**
 * @dev Interface for the optional metadata functions from the ERC20 standard.
 *
 * _Available since v4.1._
 */
interface IERC20MetadataUpgradeable is IERC20Upgradeable {
    /**
     * @dev Returns the name of the token.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the symbol of the token.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the decimals places of the token.
     */
    function decimals() external view returns (uint8);
}

```

- IERC20Upgradeable.sol:

```solidity
    // SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.9.0) (token/ERC20/IERC20.sol)

pragma solidity ^0.8.0;

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20Upgradeable {
    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves `amount` tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 amount) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `from` to `to` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

```

- IOperations.sol:

```solidity
    // SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

interface IAdmin {
    function canForward(address user) external view returns (bool);

    function canMint(address user) external view returns (bool);

    function mintAmount(address user) external view returns (uint256);

    function isBlackListed(address user) external view returns (bool);

    function trustedContract(address contractAddress) external view returns (bool);

    function isExternalSenderWhitelisted(address user) external view returns (bool);

    function isInternalUserWhitelisted(address user) external view returns (bool);

    function addCanMint(address user) external returns (bool);

    function removeCanMint(address user) external returns (bool);

    function addMintAmount(address user, uint256 amount) external returns (bool);

    function removeMintAmount(address user) external returns (bool);

    function whitelistInternalUser(address user) external returns (bool);

    function blacklistInternalUser(address user) external returns (bool);

    function whitelistExternalSender(address user) external returns (bool);

    function blacklistExternalSender(address user) external returns (bool);

    function addCanForward(address user) external returns (bool);

    function removeCanForward(address user) external returns (bool);

    function addTrustedContract(address contractAddress) external returns (bool);

    function removeTrustedContract(address contractAddress) external returns (bool);

    function addBlackList(address evilUser) external returns (bool);

    function removeBlackList(address clearedUser) external returns (bool);
}

```

----